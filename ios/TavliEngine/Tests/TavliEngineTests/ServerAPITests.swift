import XCTest
@testable import TavliEngine

/// The Server v1 contract (#284): the Swift mirror decodes the same shared fixtures as the
/// server's `test/fixtures.test.ts` (read straight from `server/fixtures/` in the repo), and
/// maps onto the engine's online types.
final class ServerAPITests: XCTestCase {
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TavliEngineTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // TavliEngine
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("server/fixtures", isDirectory: true)

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixturesDir.appendingPathComponent(name))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ServerAPI.decoder().decode(T.self, from: fixture(name))
    }

    /// Fixture → the type that must decode it. Same list as the TypeScript test.
    private let decoders: [String: (ServerAPITests) throws -> Any] = [
        "health.json": { try $0.decode(ServerAPI.Health.self, "health.json") },
        "error-stale-revision.json": { try $0.decode(ServerAPI.ErrorResponse.self, "error-stale-revision.json") },
        "error-rate-limited.json": { try $0.decode(ServerAPI.ErrorResponse.self, "error-rate-limited.json") },
        "apple-sign-in-request.json": { try $0.decode(ServerAPI.AppleSignInRequest.self, "apple-sign-in-request.json") },
        "google-sign-in-request.json": { try $0.decode(ServerAPI.GoogleSignInRequest.self, "google-sign-in-request.json") },
        "refresh-request.json": { try $0.decode(ServerAPI.RefreshRequest.self, "refresh-request.json") },
        "auth-session.json": { try $0.decode(ServerAPI.AuthSession.self, "auth-session.json") },
        "update-account-request.json": { try $0.decode(ServerAPI.UpdateAccountRequest.self, "update-account-request.json") },
        "dev-sign-in-request.json": { try $0.decode(ServerAPI.DevSignInRequest.self, "dev-sign-in-request.json") },
        "match-snapshot.json": { try $0.decode(ServerAPI.MatchSnapshot.self, "match-snapshot.json") },
        "match-snapshot-new.json": { try $0.decode(ServerAPI.MatchSnapshot.self, "match-snapshot-new.json") },
        "match-list.json": { try $0.decode(ServerAPI.MatchList.self, "match-list.json") },
        "create-match-request.json": { try $0.decode(ServerAPI.CreateMatchRequest.self, "create-match-request.json") },
        "write-turn-request.json": { try $0.decode(ServerAPI.WriteTurnRequest.self, "write-turn-request.json") },
        "end-match-request.json": { try $0.decode(ServerAPI.EndMatchRequest.self, "end-match-request.json") },
        "quit-request.json": { try $0.decode(ServerAPI.QuitRequest.self, "quit-request.json") },
        "send-request-request.json": { try $0.decode(ServerAPI.SendRequestRequest.self, "send-request-request.json") },
        "dice-change-request.json": { try $0.decode(ServerAPI.DiceChangeRequest.self, "dice-change-request.json") },
        "roll-request.json": { try $0.decode(ServerAPI.RollRequest.self, "roll-request.json") },
        "roll-record.json": { try $0.decode(ServerAPI.RollRecord.self, "roll-record.json") },
        "create-invite-request.json": { try $0.decode(ServerAPI.CreateInviteRequest.self, "create-invite-request.json") },
        "invite.json": { try $0.decode(ServerAPI.Invite.self, "invite.json") },
        "invite-preview.json": { try $0.decode(ServerAPI.InvitePreview.self, "invite-preview.json") },
        "auto-match-request.json": { try $0.decode(ServerAPI.AutoMatchRequest.self, "auto-match-request.json") },
        "push-token-request.json": { try $0.decode(ServerAPI.PushTokenRequest.self, "push-token-request.json") },
        "push-payload.json": { try $0.decode(ServerAPI.PushPayload.self, "push-payload.json") },
        "ws-messages.json": { try $0.decode([ServerAPI.ServerMessage].self, "ws-messages.json") },
    ]

    func testEveryFixtureDecodes() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.fixturesDir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files, decoders.keys.sorted(), "every server fixture needs a Swift decoder")
        for name in files {
            XCTAssertNoThrow(try decoders[name]!(self), name)
        }
    }

    func testSnapshotCarriesAnEnginePayload() throws {
        let snap = try decode(ServerAPI.MatchSnapshot.self, "match-snapshot.json")
        let online = snap.onlineSnapshot
        XCTAssertEqual(online.matchID, snap.matchID)
        XCTAssertEqual(online.currentPlayerID, "acc_alice0001")
        XCTAssertEqual(online.participants.map(\.status), [.active, .active])
        XCTAssertEqual(online.participants[1].displayName, "Βασίλης")

        let payload = try XCTUnwrap(online.payload, "data must be a readable OnlineMatchPayload")
        XCTAssertEqual(payload.variant, snap.variant)
        XCTAssertEqual(payload.startingPlayer, snap.startingPlayer)
        XCTAssertEqual(payload.targetWins, snap.targetWins)
        XCTAssertEqual(payload.color(forPlayerID: "acc_bob000002"), .black)
        XCTAssertEqual(payload.liveTurn?.seq, 7)
        XCTAssertEqual(payload.games[0].plies[1].weighted, -2)
        XCTAssertEqual(payload.dice, snap.diceHandicap.online)

        XCTAssertEqual(snap.lastRoll?.weighted, -2)
        XCTAssertEqual(snap.lastRoll?.plyIndex, payload.games[0].plies.count)
        let request = try XCTUnwrap(snap.requests.first)
        XCTAssertEqual(OnlineDiceRequest.decoded(from: request.data)?.whiteLevel, 1)
    }

    func testNewAutoMatchSnapshot() throws {
        let snap = try decode(ServerAPI.MatchSnapshot.self, "match-snapshot-new.json")
        XCTAssertNil(snap.data)
        XCTAssertNil(snap.onlineSnapshot.payload)
        XCTAssertNil(snap.participants[1].playerID)
        XCTAssertEqual(snap.participants[1].status, .matching)
        XCTAssertEqual(snap.participants[1].colorValue, .black)
        XCTAssertNil(snap.lastRoll)
        XCTAssertEqual(snap.diceHandicap.online, .fair)
    }

    func testRollRequestCarriesTheTwentyOneValuesInOutcomeOrder() throws {
        let req = try decode(ServerAPI.RollRequest.self, "roll-request.json")
        XCTAssertEqual(req.rollValues?.count, ServerAPI.rollCount)
        XCTAssertEqual(HandicapDice.outcomes.count, ServerAPI.rollCount)
        XCTAssertTrue(req.rollValues!.allSatisfy { (0...1).contains($0) })

        // Floats from HandicapDice.rollValues round-trip through the wire type.
        let values: [Float] = (0..<21).map { Float($0) / 20 }
        let encoded = try ServerAPI.encoder().encode(ServerAPI.RollRequest(gameIndex: 1, plyIndex: 4, rollValues: values))
        let back = try ServerAPI.decoder().decode(ServerAPI.RollRequest.self, from: encoded)
        XCTAssertEqual(back.rollValues?.map(Float.init), values)
        // A fair roll omits the key.
        let fair = try ServerAPI.encoder().encode(ServerAPI.RollRequest(gameIndex: 0, plyIndex: 0))
        XCTAssertFalse(String(decoding: fair, as: UTF8.self).contains("rollValues"))
    }

    func testRequestBodiesRoundTrip() throws {
        let payload = try fixture("write-turn-request.json")
        let turn = try ServerAPI.decoder().decode(ServerAPI.WriteTurnRequest.self, from: payload)
        XCTAssertNoThrow(try OnlineMatchPayload.decoded(from: turn.data))
        let again = try ServerAPI.decoder().decode(ServerAPI.WriteTurnRequest.self,
                                                   from: ServerAPI.encoder().encode(turn))
        XCTAssertEqual(again, turn)

        let end = try decode(ServerAPI.EndMatchRequest.self, "end-match-request.json")
        XCTAssertEqual(end.outcome, .won)
        XCTAssertEqual(ServerAPI.DiceChangeRequest(whiteLevel: 9, baseRev: 0).whiteLevel, 4)
    }

    func testErrorsAndUnknownValuesAreTolerated() throws {
        let stale = try decode(ServerAPI.ErrorResponse.self, "error-stale-revision.json")
        XCTAssertEqual(stale.code, .staleRevision)
        let limited = try decode(ServerAPI.ErrorResponse.self, "error-rate-limited.json")
        XCTAssertEqual(limited.code, .rateLimited)
        XCTAssertEqual(limited.error.retryAfter, 60)

        let future = Data(#"{"error":{"code":"brand_new","message":"x"}}"#.utf8)
        XCTAssertNil(try ServerAPI.decoder().decode(ServerAPI.ErrorResponse.self, from: future).code)

        let participant = Data(#"{"playerID":null,"displayName":null,"color":"B","status":"zombie","outcome":"abandoned"}"#.utf8)
        let p = try ServerAPI.decoder().decode(ServerAPI.Participant.self, from: participant)
        XCTAssertEqual(p.status, .unknown)
        XCTAssertEqual(p.outcome, .other)

        let message = Data(#"{"type":"typing","matchID":"m"}"#.utf8)
        XCTAssertEqual(try ServerAPI.decoder().decode(ServerAPI.ServerMessage.self, from: message), .unknown(type: "typing"))
    }

    func testWebSocketMessages() throws {
        let messages = try decode([ServerAPI.ServerMessage].self, "ws-messages.json")
        XCTAssertEqual(messages.count, 5)
        guard case .hello(_, let revision, _) = messages[0] else { return XCTFail("hello first") }
        XCTAssertEqual(revision, 5)
        guard case .match(let event, let match) = messages[1] else { return XCTFail("match second") }
        XCTAssertEqual(ServerAPI.MatchEvent(rawValue: event), .turnSaved)
        XCTAssertEqual(match.revision, revision)
        guard case .roll(_, let roll) = messages[2] else { return XCTFail("roll third") }
        XCTAssertEqual(roll.die1 + roll.die2, 6)
        guard case .error(let code, _) = messages[4] else { return XCTFail("error last") }
        XCTAssertEqual(ServerAPI.ErrorCode(rawValue: code), .forbidden)
    }

    func testHealthAndTimes() throws {
        let health = try decode(ServerAPI.Health.self, "health.json")
        XCTAssertEqual(health.apiVersion, ServerAPI.version)
        XCTAssertEqual(health.checks?.d1, "ok")
        XCTAssertEqual(ServerAPI.date(1_000).timeIntervalSince1970, 1, accuracy: 1e-9)
    }
}
