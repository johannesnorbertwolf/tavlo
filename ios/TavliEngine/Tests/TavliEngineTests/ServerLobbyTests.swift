import Foundation
import XCTest
@testable import TavliEngine

/// The server lobby's logic (#287): invite codes and links, sections + row states/actions,
/// push helpers, and two devices on `FakeTavtavServer` joining by code, by auto-match,
/// cancelling and removing — with the real `OnlineMatchController` + `GameSession`.
@MainActor
final class ServerLobbyTests: XCTestCase {
    // MARK: - Pure helpers

    func testInviteCodesNormalizeTypedTextAndLinks() {
        XCTAssertEqual(InviteCode.normalize(" k7q-4mz "), "K7Q4MZ")
        XCTAssertEqual(InviteCode.normalize("K7Q 4MZ"), "K7Q4MZ")
        XCTAssertEqual(InviteCode.normalize("https://tavtav-server.tavtav.workers.dev/join/k7q4mz"), "K7Q4MZ")
        XCTAssertNil(InviteCode.normalize("abc"))
        XCTAssertNil(InviteCode.normalize("K7Q4MZ!"))
        XCTAssertNil(InviteCode.normalize("ΑΒΓΔΕΖ"))   // Greek capitals are not the code alphabet
        XCTAssertEqual(InviteCode.fromLink(URL(string: "https://tavtav-server-staging.tavtav.workers.dev/join/K7Q4MZ")!), "K7Q4MZ")
        XCTAssertNil(InviteCode.fromLink(URL(string: "https://example.com/other/K7Q4MZ")!))
        XCTAssertNil(InviteCode.fromLink(URL(string: "https://example.com/join/K7Q4MZ/extra")!))
        XCTAssertNil(InviteCode.fromLink(URL(string: "tavtav://join/K7Q4MZ")!))
        XCTAssertFalse(InviteCode.alphabet.contains { "01IOL".contains($0) })
    }

    private func row(_ id: String, _ state: ServerAPI.LobbyState, at: Int64, opponent: String? = "acc_bob",
                     outcome: ServerAPI.MatchOutcome = .none, invite: String? = nil) -> ServerAPI.MatchSummary {
        ServerAPI.MatchSummary(
            matchID: id, variant: "plakoto", targetWins: 2, state: state,
            opponent: .init(playerID: opponent, displayName: opponent == nil ? nil : "Bob"),
            outcome: outcome, updatedAt: at,
            invite: invite.map { .init(code: $0, url: URL(string: "https://x.test/join/\($0)")!, expiresAt: 9) })
    }

    func testSectionsAreYourTurnThenTheirTurnThenFinishedNewestFirst() {
        let rows = [
            row("m_done", .ended, at: 50, outcome: .won),
            row("m_their", .theirTurn, at: 40),
            row("m_mine_old", .yourTurn, at: 10),
            row("m_invited", .invited, at: 30),
            row("m_wait", .waitingForOpponent, at: 60, opponent: nil),
            row("m_mine_new", .yourTurn, at: 20),
        ]
        let sections = ServerLobby.sections(rows)
        XCTAssertEqual(sections.map(\.kind), [.yourTurn, .theirTurn, .finished])
        XCTAssertEqual(sections[0].rows.map(\.matchID), ["m_invited", "m_mine_new", "m_mine_old"])
        XCTAssertEqual(sections[1].rows.map(\.matchID), ["m_wait", "m_their"])
        XCTAssertEqual(sections[2].rows.map(\.matchID), ["m_done"])
        XCTAssertEqual(ServerLobby.sections([row("a", .theirTurn, at: 1)]).map(\.kind), [.theirTurn])
    }

    func testRowStatusesAndActions() {
        let friend = row("m1", .yourTurn, at: 1, opponent: nil, invite: "K7Q4MZ")
        XCTAssertEqual(friend.lobbyStatus, .waitingForFriend(code: "K7Q4MZ"))
        XCTAssertEqual(friend.lobbyActions, [.shareInvite, .cancel])
        let random = row("m2", .waitingForOpponent, at: 1, opponent: nil)
        XCTAssertEqual(random.lobbyStatus, .lookingForOpponent)
        XCTAssertEqual(random.lobbyActions, [.cancel])
        // The auto-match creator may play first: "your turn", still cancellable.
        let randomMine = row("m3", .yourTurn, at: 1, opponent: nil)
        XCTAssertEqual(randomMine.lobbyStatus, .yourTurn)
        XCTAssertTrue(randomMine.isLookingForOpponent)
        XCTAssertEqual(randomMine.lobbyActions, [.cancel])
        XCTAssertEqual(row("m4", .invited, at: 1).lobbyStatus, .invitedToYou)
        XCTAssertEqual(row("m4", .invited, at: 1).lobbyActions, [.decline])
        XCTAssertEqual(row("m5", .waitingForOpponent, at: 1).lobbyStatus, .waitingForAccept)
        XCTAssertEqual(row("m6", .theirTurn, at: 1).lobbyActions, [])
        XCTAssertEqual(row("m7", .ended, at: 1, outcome: .lost).lobbyStatus, .finished(.lost))
        XCTAssertEqual(row("m7", .ended, at: 1, outcome: .lost).lobbyActions, [.remove])
        // An ended open-seat match (cancelled invite) is just finished.
        XCTAssertEqual(row("m8", .ended, at: 1, opponent: nil).lobbyActions, [.remove])
    }

    func testPushHelpers() throws {
        XCTAssertEqual(PushSupport.hex(Data([0x00, 0xab, 0x0f, 0xff])), "00ab0fff")
        // The shared fixture, as it arrives in userInfo.
        let data = try Data(contentsOf: ServerAPITests.fixturesDir.appendingPathComponent("push-payload.json"))
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
        XCTAssertEqual(PushSupport.matchID(fromUserInfo: userInfo), "m_7f3a9c21d4e5")
        XCTAssertEqual(ServerAPI.PushPayload(userInfo: userInfo)?.kind, .yourTurn)
        var future = userInfo
        future["kind"] = "somethingNew"
        XCTAssertEqual(ServerAPI.PushPayload(userInfo: future)?.kind, .unknown)
        XCTAssertNil(PushSupport.matchID(fromUserInfo: ["aps": ["alert": "Game Center"]]))
        XCTAssertTrue(PushSupport.shouldPresentInForeground(pushMatchID: "m_1", openMatchID: "m_2"))
        XCTAssertTrue(PushSupport.shouldPresentInForeground(pushMatchID: "m_1", openMatchID: nil))
        XCTAssertFalse(PushSupport.shouldPresentInForeground(pushMatchID: "m_1", openMatchID: "m_1"))
        XCTAssertTrue(PushSupport.shouldAskPermission(isUndetermined: true, askedBefore: false))
        XCTAssertFalse(PushSupport.shouldAskPermission(isUndetermined: true, askedBefore: true))
        XCTAssertFalse(PushSupport.shouldAskPermission(isUndetermined: false, askedBefore: false))
    }

    // MARK: - Two devices on the fake server

    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func assertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(value, file: file, line: line)
    }

    private var server: FakeTavtavServer!
    private var devices: [ServerLobby] = []

    override func setUp() async throws {
        server = FakeTavtavServer()
        server.names = ["acc_alice": "Alice", "acc_bob": "Bob", "acc_sam": "Sam"]
    }

    override func tearDown() async throws {
        for d in devices {
            d.controller.close()
            d.service.close()
        }
        devices = []
    }

    private func device(_ account: String) -> ServerLobby {
        let service = ServerMatchService(client: FakeServerClient(account, server: server), sockets: server.sockets)
        let controller = OnlineMatchController(service: service, animationTimings: .off, retryDelay: nil,
                                               liveTurns: FakeDevice.instantLive)
        service.controller = controller
        let lobby = ServerLobby(service: service, controller: controller)
        lobby.describeError = { error in (error as? ServerMatchError)?.code ?? (error as? AuthError)?.serverCode?.rawValue ?? "\(error)" }
        devices.append(lobby)
        return lobby
    }

    private func until(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Roll through the server and play the whole turn with the first legal hops.
    private func playTurn(_ controller: OnlineMatchController) async {
        let s = controller.session!
        XCTAssertTrue(controller.isLocalTurn)
        let plies = s.record.plies.count
        s.roll()
        await s.awaitRemoteRollForTesting()
        await until("the dice") { s.phase != .awaitingRoll || s.record.plies.count > plies }
        while s.record.plies.count == plies, let hop = anyHop(s) {
            s.commitHalfMove(from: hop.0, to: hop.1)
        }
        for _ in 0..<12 { try? await Task.sleep(nanoseconds: 1_000_000) }
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

    func testInviteByTypedCodeJoinsAndBothPlay() async throws {
        let alice = device("acc_alice")
        let bob = device("acc_bob")
        var started = 0
        alice.onMatchStarted = { started += 1 }
        bob.onMatchStarted = { started += 1 }

        let invite = try unwrapped(await alice.createInvite(variant: "plakoto", targetWins: 1))
        XCTAssertEqual(invite.url.absoluteString, "https://tavtav.test/join/\(invite.code)")
        XCTAssertEqual(alice.sections.first?.rows.first?.lobbyStatus, .waitingForFriend(code: invite.code))
        XCTAssertEqual(alice.sections.first?.rows.first?.lobbyActions, [.shareInvite, .cancel])

        // Alice starts playing before her friend is there (as with Game Center).
        alice.open(invite.match)
        await until("Alice's session") { alice.controller.session != nil && alice.controller.isLocalTurn }
        server.scriptedDice = [(6, 2), (5, 3), (4, 1)]
        await playTurn(alice.controller)
        await until("Alice's turn on the server") { server.matches[invite.match.matchID]?.snap.revision ?? 0 >= 1 }
        XCTAssertFalse(alice.controller.isLocalTurn)

        // Bob previews and joins with the code as he typed it.
        let typed = invite.code.lowercased().prefix(3) + " " + invite.code.lowercased().dropFirst(3)
        let preview = try unwrapped(await bob.preview(code: String(typed)))
        XCTAssertEqual(preview.from.displayName, "Alice")
        XCTAssertEqual(preview.status, "open")
        let joined = try unwrapped(await bob.join(code: String(typed)))
        XCTAssertEqual(joined.matchID, invite.match.matchID)
        await until("Bob's session") { bob.controller.session != nil }
        XCTAssertTrue(bob.controller.isLocalTurn, "Alice already moved: Bob is on turn")
        XCTAssertEqual(bob.controller.localColor, .black)
        XCTAssertEqual(bob.controller.opponentName, "Alice")
        XCTAssertEqual(started, 2)

        // The code is spent; the lobby rows follow.
        let sam = device("acc_sam")
        assertNil(await sam.join(code: invite.code))
        XCTAssertEqual(sam.error, "invite_unavailable")
        await alice.refresh()
        XCTAssertEqual(alice.matches.first?.invite, nil)
        XCTAssertEqual(alice.matches.first?.lobbyStatus, .theirTurn)

        // Bob's turn reaches Alice over the socket.
        await playTurn(bob.controller)
        await until("Alice on turn again") { alice.controller.isLocalTurn }
        XCTAssertEqual(alice.controller.session?.record.plies.count, 2)
        XCTAssertEqual(alice.controller.opponentName, "Bob")
    }

    func testRandomOpponentPairsTwoPlayersForTheSameVariantAndLength() async throws {
        let alice = device("acc_alice")
        let bob = device("acc_bob")
        let sam = device("acc_sam")
        let waiting = try unwrapped(await alice.autoMatch(variant: "fevga", targetWins: 2))
        XCTAssertNil(waiting.participants[1].playerID)
        await until("Alice's game open") { alice.controller.session != nil || alice.controller.status != nil }
        // Another length: not a partner.
        let other = try unwrapped(await sam.autoMatch(variant: "fevga", targetWins: 1))
        XCTAssertNotEqual(other.matchID, waiting.matchID)
        let joined = try unwrapped(await bob.autoMatch(variant: "fevga", targetWins: 2))
        XCTAssertEqual(joined.matchID, waiting.matchID)
        XCTAssertEqual(joined.participants[1].playerID, "acc_bob")
        await until("Alice sees Bob") { alice.controller.opponentName == "Bob" }
    }

    func testCancelAnInviteAndRemoveFinishedMatches() async throws {
        let alice = device("acc_alice")
        let bob = device("acc_bob")
        _ = try unwrapped(await alice.createInvite(variant: "portes", targetWins: 1))
        let open = try XCTUnwrap(alice.matches.first)
        await alice.cancel(open)
        XCTAssertNil(alice.error)
        let cancelled = try XCTUnwrap(alice.matches.first)
        XCTAssertEqual(cancelled.lobbyStatus, .finished(.none))
        assertNil(await bob.join(code: open.invite!.code))
        XCTAssertEqual(bob.error, "invite_unavailable")

        // Auto-match cancel = leave the queue.
        _ = try unwrapped(await alice.autoMatch(variant: "plakoto", targetWins: 1))
        let queued = try XCTUnwrap(alice.matches.first { $0.isLookingForOpponent })
        await alice.cancel(queued)
        XCTAssertEqual(alice.matches.first { $0.matchID == queued.matchID }?.lobbySection, .finished)

        // Remove: finished rows go (for this player only); a running one can't.
        await alice.remove(cancelled)
        XCTAssertFalse(alice.matches.contains { $0.matchID == cancelled.matchID })
        await alice.refresh()
        XCTAssertFalse(alice.matches.contains { $0.matchID == cancelled.matchID })
        XCTAssertTrue(server.hidden.contains("acc_alice/\(cancelled.matchID)"))
        let running = try await alice.service.createMatch(variant: "plakoto", targetWins: 1, opponentID: "acc_bob")
        await alice.refresh()
        let row = try XCTUnwrap(alice.matches.first { $0.matchID == running.matchID })
        await alice.remove(row)   // not offered: nothing happens
        XCTAssertTrue(alice.matches.contains { $0.matchID == running.matchID })

        // Bob declines the direct challenge from his lobby.
        await bob.refresh()
        let invited = try XCTUnwrap(bob.matches.first { $0.matchID == running.matchID })
        XCTAssertEqual(invited.lobbyStatus, .invitedToYou)
        await bob.decline(invited)
        XCTAssertEqual(bob.matches.first { $0.matchID == running.matchID }?.lobbySection, .finished)
    }

    func testMalformedCodesNeverReachTheServer() async {
        let bob = device("acc_bob")
        let before = server.log.count
        assertNil(await bob.join(code: "no"))
        assertNil(await bob.preview(code: "!!!!!!"))
        XCTAssertEqual(server.log.count, before)
        XCTAssertNotNil(bob.error)
    }

    func testPushTokensRegisterAndUnregister() async throws {
        let alice = device("acc_alice")
        try await alice.service.registerPushToken("ab12", environment: "sandbox", locale: "el-GR")
        XCTAssertEqual(server.pushTokens["acc_alice"], ["ab12"])
        try await alice.service.unregisterPushToken("ab12")
        XCTAssertEqual(server.pushTokens["acc_alice"], [])
    }
}
