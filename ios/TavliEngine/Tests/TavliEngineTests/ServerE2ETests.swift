import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// End to end against a real local server (#286): two signed-in "devices" (AuthClient +
/// ServerMatchService + OnlineMatchController + GameSession, real URLSession HTTP and
/// WebSocket) play turns through `wrangler dev`. Skipped unless `TAVTAV_E2E_SERVER` is set:
///
///     cd server && npm run db:migrate:local && npm run dev        # :8787
///     TAVTAV_E2E_SERVER=http://localhost:8787 swift test --filter ServerE2ETests
@MainActor
final class ServerE2ETests: XCTestCase {
    private struct Device {
        let auth: AuthClient
        let service: ServerMatchService
        let controller: OnlineMatchController
    }

    private var devices: [Device] = []

    override func tearDown() async throws {
        for d in devices {
            d.controller.close()
            d.service.close()
        }
    }

    private func serverURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["TAVTAV_E2E_SERVER"], let url = URL(string: raw) else {
            throw XCTSkip("set TAVTAV_E2E_SERVER=http://localhost:8787 (wrangler dev) to run")
        }
        return url
    }

    private func device(_ name: String, url: URL, agent: Agent?) async throws -> Device {
        let auth = AuthClient(baseURL: url, clientHeader: "ios/e2e (0)", transport: URLSessionTransport(),
                              store: MemoryAuthTokenStore())
        try await auth.developmentSignIn(subject: "e2e-\(name)-\(UUID().uuidString.prefix(8))")
        let service = ServerMatchService(client: auth, sockets: URLSessionSocketFactory())
        let controller = OnlineMatchController(service: service, animationTimings: .off, retryDelay: 2,
                                               liveTurns: .standard, handicapAgent: agent.map { a in { _ in a } })
        service.controller = controller
        let d = Device(auth: auth, service: service, controller: controller)
        devices.append(d)
        return d
    }

    private func loadAgent() -> Agent? {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage"),
              let compiled = try? MLModel.compileModel(at: url) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        guard let model = try? MLModel(contentsOf: compiled, configuration: cfg) else { return nil }
        return Agent(model: model, encoder: BoardEncoder(config: .standard))
    }

    @discardableResult
    private func until(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async -> TimeInterval {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out waiting for \(what)"); break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return Date().timeIntervalSince(start)
    }

    private func anyHop(_ s: GameSession) -> (Int, Int)? {
        for from in s.selectableSources.sorted() {
            for to in s.moveBuilder.validDestinations(for: from).sorted()
            where s.moveBuilder.routeOptions(from: from, to: to).first?.count == 1 {
                return (from, to)
            }
        }
        return nil
    }

    func testTwoDevicesPlayThroughTheLocalServer() async throws {
        let url = try serverURL()
        let agent = loadAgent()
        let a = try await device("alice", url: url, agent: agent)
        let b = try await device("bob", url: url, agent: agent)
        let bobID = try XCTUnwrap(b.auth.account?.id)

        // Alice challenges Bob (best of three, house Plakoto); both open and watch it.
        let created = try await a.service.createMatch(variant: "plakoto", targetWins: 2, opponentID: bobID)
        let id = created.matchID
        a.controller.open(created.onlineSnapshot, newMatchTargetWins: 2, newMatchVariantID: "plakoto")
        a.service.watch(id)
        await until("Alice's opening write") { a.service.snapshot(for: id)?.data != nil }
        b.controller.open(try await b.service.loadSnapshot(matchID: id).onlineSnapshot)
        b.service.watch(id)
        await until("both sockets") { a.service.isSocketConnected && b.service.isSocketConnected }
        await until("Bob joined") { b.controller.session != nil }

        var rollLatency: [TimeInterval] = []
        var turnLatency: [TimeInterval] = []
        for turn in 0..<8 {
            let mover = turn % 2 == 0 ? a : b
            let waiter = turn % 2 == 0 ? b : a
            await until("turn \(turn) on its device") { mover.controller.isLocalTurn }
            let s = try XCTUnwrap(mover.controller.session)
            let plies = s.record.plies.count
            s.roll()
            await until("the server's dice") { s.phase != .awaitingRoll || s.record.plies.count > plies }
            XCTAssertFalse(s.remoteRollFailed)
            // The waiting device sees the dice (the mover's live write, pushed by the socket).
            let dice = (s.game.dice.die1.value, s.game.dice.die2.value)
            if s.record.plies.count == plies {
                rollLatency.append(await until("dice on the other device") {
                    waiter.controller.session?.isShowingRemoteTurn == true
                        && waiter.controller.session?.game.dice.die1.value == dice.0
                        && waiter.controller.session?.game.dice.die2.value == dice.1
                })
            }
            while s.record.plies.count == plies, let hop = anyHop(s) { s.commitHalfMove(from: hop.0, to: hop.1) }
            let ended = Date()
            await until("turn \(turn) reaches the other device") {
                waiter.controller.session?.record.plies.count == plies + 1 && waiter.controller.isLocalTurn
            }
            turnLatency.append(Date().timeIntervalSince(ended))
        }
        // Both devices and the server agree; every ply's dice are the server's rolls.
        let server = try await a.service.loadSnapshot(matchID: id)
        let payload = try OnlineMatchPayload.decoded(from: XCTUnwrap(server.data))
        XCTAssertEqual(payload.games[0].plies.count, 8)
        XCTAssertEqual(a.controller.session!.record.plies, b.controller.session!.record.plies)
        print("e2e: dice on the other device after", rollLatency.map { String(format: "%.2fs", $0) })
        print("e2e: turn on the other device after", turnLatency.map { String(format: "%.2fs", $0) })

        // A stale write is refused with 409 stale_revision (the app reloads and resends).
        do {
            let _: ServerAPI.MatchSnapshot = try await a.auth.authorized(
                method: "POST", path: "/v1/matches/\(id)/save-turn",
                body: ServerAPI.WriteTurnRequest(baseRevision: 0, data: server.data!))
            XCTFail("a stale write was accepted")
        } catch let error as AuthError {
            XCTAssertTrue([.staleRevision, .notYourTurn].contains(error.serverCode), "\(error)")
        }

        // The shared slider through the server: Bob (waiting or not) favours himself, the
        // next roll is bent and stamped.
        if agent != nil {
            b.controller.setDiceHandicap(levelTowardsMe: 2)
            await until("Alice sees Bob's dice change") { a.controller.diceHandicap.whiteLevel == -2 }
            let mover = a.controller.isLocalTurn ? a : b
            let s = try XCTUnwrap(mover.controller.session)
            let plies = s.record.plies.count
            s.roll()
            await until("the weighted dice") { s.phase != .awaitingRoll || s.record.plies.count > plies }
            let roll = try await a.service.loadSnapshot(matchID: id).lastRoll
            XCTAssertEqual(roll?.weighted, -2)
            XCTAssertNotNil(roll?.beta)
            while s.record.plies.count == plies, let hop = anyHop(s) { s.commitHalfMove(from: hop.0, to: hop.1) }
            await until("the stamped ply on the server") {
                (try? OnlineMatchPayload.decoded(from: a.service.snapshot(for: id)?.data ?? Data()))?
                    .games[0].plies.last?.weighted == -2
            }
            print("e2e: weighted roll", roll.map { "\($0.die1)\($0.die2) β=\($0.beta ?? 0)" } ?? "-")
        }

        // Bob forfeits: Alice's device shows the opponent left, the server has the outcomes.
        b.controller.forfeit()
        await until("Alice sees the forfeit") { a.controller.isMatchOver }
        XCTAssertEqual(a.controller.status, .opponentLeft)
        let final = try await a.service.loadSnapshot(matchID: id)
        XCTAssertEqual(final.participants.map(\.outcome), [.won, .quit])
        let list = try await a.service.listMatches(state: "ended")
        XCTAssertTrue(list.matches.contains { $0.matchID == id && $0.outcome == .won })
    }

    // MARK: - #287: invite by code, random opponent, lobby removal

    func testInviteByCodeThroughTheLocalServer() async throws {
        let url = try serverURL()
        let a = try await device("alice", url: url, agent: nil)
        let b = try await device("bob", url: url, agent: nil)
        let alice = ServerLobby(service: a.service, controller: a.controller)
        let bob = ServerLobby(service: b.service, controller: b.controller)

        let created = await alice.createInvite(variant: "fevga", targetWins: 1)
        let invite = try XCTUnwrap(created, alice.error ?? "")
        XCTAssertEqual(invite.url, url.appendingPathComponent("join/\(invite.code)"))
        XCTAssertEqual(alice.matches.first { $0.matchID == invite.match.matchID }?.invite?.code, invite.code)
        alice.open(invite.match)
        await until("Alice's game") { a.controller.session != nil }

        // Bob types the code (lower case, a space) and joins; both sockets live.
        let typed = invite.code.lowercased().prefix(3) + " " + invite.code.lowercased().dropFirst(3)
        let preview = await bob.preview(code: String(typed))
        XCTAssertEqual(preview?.status, "open")
        let joined = await bob.join(code: String(typed))
        XCTAssertEqual(joined?.matchID, invite.match.matchID, bob.error ?? "")
        await until("Bob's game") { b.controller.session != nil }
        await until("both sockets") { a.service.isSocketConnected && b.service.isSocketConnected }
        await until("Alice sees Bob") { a.controller.opponentName != nil && a.controller.opponentName != "" }

        // Two turns across (Fevga: the server drew who starts).
        for turn in 0..<2 {
            await until("turn \(turn)") { a.controller.isLocalTurn || b.controller.isLocalTurn }
            let mover = a.controller.isLocalTurn ? a : b
            let waiter = a.controller.isLocalTurn ? b : a
            let s = try XCTUnwrap(mover.controller.session)
            let plies = s.record.plies.count
            s.roll()
            await until("dice") { s.phase != .awaitingRoll || s.record.plies.count > plies }
            while s.record.plies.count == plies, let hop = anyHop(s) { s.commitHalfMove(from: hop.0, to: hop.1) }
            await until("turn \(turn) arrives") { waiter.controller.session?.record.plies.count == plies + 1 }
        }
        // The code is spent; the invite page knows it.
        let c = try await device("sam", url: url, agent: nil)
        let sam = ServerLobby(service: c.service, controller: c.controller)
        sam.describeError = { ($0 as? AuthError)?.serverCode?.rawValue ?? "\($0)" }
        let late = await sam.join(code: invite.code)
        XCTAssertNil(late)
        XCTAssertEqual(sam.error, "invite_unavailable")
        let (html, response) = try await URLSession.shared.data(from: invite.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("isn’t open any more"))

        // Bob leaves; Alice removes the finished match from her lobby.
        b.controller.forfeit()
        await until("Alice sees the forfeit") { a.controller.isMatchOver }
        await alice.refresh()
        let row = try XCTUnwrap(alice.matches.first { $0.matchID == invite.match.matchID })
        XCTAssertEqual(row.lobbySection, .finished)
        await alice.remove(row)
        await alice.refresh()
        XCTAssertFalse(alice.matches.contains { $0.matchID == invite.match.matchID })
    }

    func testRandomOpponentThroughTheLocalServer() async throws {
        let url = try serverURL()
        let a = try await device("alice", url: url, agent: nil)
        let b = try await device("bob", url: url, agent: nil)
        let alice = ServerLobby(service: a.service, controller: a.controller)
        let bob = ServerLobby(service: b.service, controller: b.controller)
        // A variant + length no other test uses, so earlier runs' waiting matches don't pair.
        let first = await alice.autoMatch(variant: "portes", targetWins: 2)
        let waiting = try XCTUnwrap(first, alice.error ?? "")
        let second = await bob.autoMatch(variant: "portes", targetWins: 2)
        let joined = try XCTUnwrap(second, bob.error ?? "")
        XCTAssertEqual(joined.matchID, waiting.matchID)
        await until("Alice sees her opponent") { a.controller.opponentName != nil }
        // Leave the queue clean for the next run.
        b.controller.forfeit()
    }
}
