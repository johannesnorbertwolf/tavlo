import XCTest
@testable import TavliEngine

/// The live turn (#269): the mover's roll, half-moves and undos reach the waiting
/// device before the turn is over, via `saveTurn` writes carrying `liveTurn`. Two
/// `FakeDevice`s on the in-memory `FakeGameCenter` (see `OnlineMatchControllerTests`).
@MainActor
final class OnlineLiveTurnTests: XCTestCase {

    private var server: FakeGameCenter!
    private var alice: FakeDevice!   // creator, White, moves first (house Plakoto)
    private var bob: FakeDevice!
    private var matchID = ""

    override func setUp() async throws {
        server = FakeGameCenter()
        alice = FakeDevice("alice", server: server)
        bob = FakeDevice("bob", server: server)
    }

    override func tearDown() async throws {
        // Device ↔ controller retain each other; closing cancels the poll / live-write
        // tasks so nothing fires into a later test.
        alice.controller.close()
        bob.controller.close()
    }

    /// Alice creates an invite match and opens it; Bob accepts and opens it too, so
    /// both have the match on screen with Alice on turn.
    private func startMatch() async {
        matchID = server.createMatch(creator: "alice", opponent: "bob", opponentKnown: true)
        alice.controller.open(server.snapshot(matchID))
        bob.controller.open(server.snapshot(matchID))
        await drain()
        XCTAssertTrue(alice.controller.isLocalTurn)
        XCTAssertFalse(bob.controller.isLocalTurn)
    }

    /// Let the main-queue observers and the (zero-delay) live-write tasks run.
    private func drain(_ turns: Int = 6) async {
        for _ in 0..<turns { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// A single-die hop the session on move can play now.
    private func anyHop(_ s: GameSession) -> (Int, Int)? {
        for from in s.selectableSources.sorted() {
            for to in s.moveBuilder.validDestinations(for: from).sorted()
            where s.moveBuilder.routeOptions(from: from, to: to).first?.count == 1 {
                return (from, to)
            }
        }
        return nil
    }

    private func play(_ s: GameSession) -> [Int] {
        let (f, t) = anyHop(s)!
        s.commitHalfMove(from: f, to: t)
        return [f, t]
    }

    private var aliceSession: GameSession { alice.controller.session! }
    private var bobSession: GameSession { bob.controller.session! }
    private var serverLive: LiveTurn? { server.snapshot(matchID).payload?.liveTurn }

    // MARK: - Roll, half-move, undo

    func testRollShowsDiceOnTheWaitingDevice() async {
        await startMatch()
        aliceSession.setDice(6, 5)
        await drain()

        XCTAssertEqual(serverLive?.die1, 6)
        XCTAssertEqual(serverLive?.die2, 5)
        XCTAssertEqual(serverLive?.halfMoves, [])
        XCTAssertEqual(server.snapshot(matchID).payload?.games.last?.plies.count, 0,
                       "a live write never adds a ply")
        XCTAssertTrue(bobSession.isShowingRemoteTurn)
        XCTAssertEqual(bobSession.game.dice.die1.value, 6)
        XCTAssertEqual(bobSession.game.dice.die2.value, 5)
        XCTAssertEqual(bobSession.phase, .animating, "read-only: every input guard holds")
        XCTAssertFalse(bob.controller.isLocalTurn)
        XCTAssertEqual(bobSession.history.count, 0)
    }

    func testHalfMovesAndUndoAreMirrored() async {
        await startMatch()
        aliceSession.setDice(6, 5)
        await drain()
        let first = play(aliceSession)
        await drain()
        XCTAssertEqual(bobSession.remoteTurnHalfMoves, [first])
        XCTAssertEqual(bobSession.game.board.captureStacks(), aliceSession.game.board.captureStacks())

        aliceSession.undo()
        await drain()
        XCTAssertEqual(serverLive?.halfMoves, [])
        XCTAssertEqual(bobSession.remoteTurnHalfMoves, [])
        XCTAssertEqual(bobSession.game.board.captureStacks(), aliceSession.game.board.captureStacks(),
                       "the undo is reflected")
        XCTAssertTrue(bobSession.isShowingRemoteTurn, "dice still shown after the undo")
    }

    func testEndOfTurnContinuesFromThePreview() async {
        await startMatch()
        aliceSession.setDice(6, 5)
        await drain()
        _ = play(aliceSession)
        await drain()
        XCTAssertEqual(bobSession.remoteTurnHalfMoves.count, 1)
        while aliceSession.history.isEmpty, anyHop(aliceSession) != nil { _ = play(aliceSession) }
        await drain()

        XCTAssertEqual(aliceSession.history.count, 1)
        XCTAssertEqual(bobSession.history, aliceSession.history)
        XCTAssertFalse(bobSession.isShowingRemoteTurn)
        XCTAssertEqual(bobSession.game.board.captureStacks(), aliceSession.game.board.captureStacks())
        XCTAssertTrue(bob.controller.isLocalTurn)
        XCTAssertNil(serverLive, "endTurn's payload carries no live turn")
        XCTAssertEqual(alice.writes.last, "end")

        // Bob's turn is shared the same way, the other way round.
        bobSession.setDice(4, 2)
        await drain()
        XCTAssertTrue(aliceSession.isShowingRemoteTurn)
        XCTAssertEqual(serverLive?.player, Color.black.rawValue)
        XCTAssertEqual(serverLive?.plyIndex, 1)
    }

    // MARK: - Rate limits: coalescing, one write in flight

    func testHalfMovesAreCoalescedIntoOneWrite() async {
        let timing = LiveTurnTiming(debounce: 0.05, minInterval: 0.05, pollInterval: nil)
        alice.controller.close()
        alice = FakeDevice("alice", server: server, liveTurns: timing)
        await startMatch()
        aliceSession.setDice(2, 1)
        await wait(until: { self.alice.writes.filter { $0 == "save" }.count == 2 })
        let savesAfterRoll = alice.writes.filter { $0 == "save" }.count   // opening state + roll
        XCTAssertEqual(savesAfterRoll, 2)

        // A burst: hop, undo, hop — one write with the latest state.
        let hop = play(aliceSession)
        aliceSession.undo()
        _ = play(aliceSession)
        await drain()
        XCTAssertEqual(alice.writes.filter { $0 == "save" }.count, savesAfterRoll, "debounced")
        await wait(until: { self.bobSession.remoteTurnHalfMoves == [hop] })
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(alice.writes.filter { $0 == "save" }.count, savesAfterRoll + 1)
        XCTAssertEqual(bobSession.remoteTurnHalfMoves, [hop])
    }

    func testEndTurnWaitsForTheLiveWriteInFlight() async {
        await startMatch()
        alice.holdSaves = true
        aliceSession.setDice(6, 5)
        await drain()
        XCTAssertEqual(alice.writes.last, "save", "roll write is in flight")
        while aliceSession.history.isEmpty, anyHop(aliceSession) != nil { _ = play(aliceSession) }
        await drain()
        XCTAssertFalse(alice.writes.contains("end"), "endTurn never overlaps a live write")
        XCTAssertTrue(alice.controller.hasUnsentTurn)

        alice.releaseSaves()
        await drain()
        XCTAssertEqual(alice.writes.last, "end")
        XCTAssertFalse(alice.controller.hasUnsentTurn)
        XCTAssertEqual(bobSession.history, aliceSession.history)
        XCTAssertTrue(bob.controller.isLocalTurn)
    }

    func testFailedLiveWriteIsDroppedNotRetriedAsATurn() async {
        await startMatch()
        alice.failNextWrites = 1
        aliceSession.setDice(6, 5)
        await drain()
        XCTAssertNil(alice.controller.status, "a lost preview is not an error")
        XCTAssertFalse(alice.controller.hasUnsentTurn)
        // The next change carries the whole state.
        let hop = play(aliceSession)
        await drain()
        XCTAssertEqual(bobSession.remoteTurnHalfMoves, [hop])
    }

    // MARK: - Ordering, reopening, polling, match end

    func testStaleLiveUpdateIsIgnored() async {
        await startMatch()
        aliceSession.setDice(3, 3)   // a double: four hops, so the turn stays open
        await drain()
        _ = play(aliceSession)
        await drain()
        let older = server.snapshot(matchID)
        let second = play(aliceSession)
        await drain()
        XCTAssertEqual(bobSession.remoteTurnHalfMoves.last, second)
        let shown = bobSession.remoteTurnHalfMoves

        bob.controller.receive(older)        // a late event with an older live turn
        await drain()
        XCTAssertEqual(bobSession.remoteTurnHalfMoves, shown)
    }

    func testReopeningMidTurnShowsTheTurnInProgress() async {
        await startMatch()
        bob.controller.close()
        aliceSession.setDice(6, 5)
        await drain()
        let hop = play(aliceSession)
        await drain()

        bob.controller.open(server.snapshot(matchID))
        XCTAssertTrue(bobSession.isShowingRemoteTurn)
        XCTAssertEqual(bobSession.remoteTurnHalfMoves, [hop])
    }

    func testMissedEventsAreCaughtByThePoll() async {
        let timing = LiveTurnTiming(debounce: 0, minInterval: 0, pollInterval: 0.25, maxPollInterval: 0.5)
        bob.controller.close()
        bob = FakeDevice("bob", server: server, liveTurns: timing)
        await startMatch()
        bob.muted = true
        aliceSession.setDice(3, 1)
        await drain()
        XCTAssertFalse(bobSession.isShowingRemoteTurn, "no event reached Bob")
        await wait(until: { self.bobSession.isShowingRemoteTurn })
        XCTAssertTrue(bobSession.isShowingRemoteTurn, "the poll found the roll")
        XCTAssertEqual(bobSession.game.dice.die1.value, 3)
    }

    func testOpponentLeavingClearsThePreview() async {
        await startMatch()
        let start = bobSession.game.board.captureStacks()
        aliceSession.setDice(6, 5)
        await drain()
        _ = play(aliceSession)
        await drain()
        XCTAssertTrue(bobSession.isShowingRemoteTurn)

        alice.controller.forfeit()
        await drain()
        XCTAssertTrue(bob.controller.isMatchOver)
        XCTAssertFalse(bobSession.isShowingRemoteTurn)
        XCTAssertEqual(bobSession.game.board.captureStacks(), start)
    }

    func testLiveTurnsOffSendsOnlyFinishedTurns() async {
        alice.controller.close()
        alice = FakeDevice("alice", server: server, liveTurns: nil)
        await startMatch()
        let before = alice.writes.count
        aliceSession.setDice(6, 5)
        _ = play(aliceSession)
        await drain()
        XCTAssertEqual(alice.writes.count, before)
        XCTAssertFalse(bobSession.isShowingRemoteTurn)
    }

    // MARK: - Wire format

    func testPayloadWithoutLiveTurnStillDecodes() throws {
        // A payload exactly as builds before #269 wrote it.
        let json = """
        {"schemaVersion":2,"targetWins":2,"startingPlayer":"W","colorByPlayerID":{"a":"W","b":"B"},
         "games":[{"plies":[{"die1":6,"die2":5,"halfMoves":[[1,7],[1,6]]}]}],"variant":"plakoto"}
        """
        let p = try OnlineMatchPayload.decoded(from: Data(json.utf8))
        XCTAssertNil(p.liveTurn)
        XCTAssertEqual(p.games.first?.plies.count, 1)
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("liveTurn"),
                       "no live turn, no key: the wire stays as before")
    }

    func testLiveTurnRoundTripsAndKeepsTheSchemaVersion() throws {
        let live = LiveTurn(gameIndex: 0, plyIndex: 3, player: .black, die1: 4, die2: 4,
                            halfMoves: [[24, 20], [20, 16]], seq: 7)
        let p = OnlineMatchPayload(startingPlayer: .white, colorByPlayerID: ["a": .white],
                                   liveTurn: live)
        let back = try OnlineMatchPayload.decoded(from: p.encoded())
        XCTAssertEqual(back.liveTurn, live)
        XCTAssertEqual(back.schemaVersion, 2, "older builds (v2) still accept it and ignore the key")
    }

    func testUnreadableLiveTurnDoesNotBreakThePayload() throws {
        let json = """
        {"schemaVersion":2,"targetWins":1,"startingPlayer":"W","colorByPlayerID":{"a":"W"},
         "games":[{"plies":[]}],"variant":"plakoto","liveTurn":{"dice":"later"},"handicap":{"x":1}}
        """
        let p = try OnlineMatchPayload.decoded(from: Data(json.utf8))
        XCTAssertNil(p.liveTurn)
        XCTAssertEqual(p.games.count, 1)
    }
}

/// `GameSession.showRemoteTurn` on its own, with animation (the app's path).
@MainActor
final class GameSessionRemoteTurnPreviewTests: XCTestCase {

    private let fast = AnimationTimings(aiDiceRollDuration: 0.01, aiMoveAnimationDuration: 0.01)

    private func session(_ timings: AnimationTimings) -> GameSession {
        let s = GameSession(startingPlayer: .white, agent: nil, aiColor: nil, animationTimings: timings)
        s.start()
        return s
    }

    private func settle(_ s: GameSession) async {
        for _ in 0..<200 {
            if s.aiHopInFlight == nil, !s.aiDiceRolling, s.phase != .animating || s.isShowingRemoteTurn {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if s.aiHopInFlight == nil, !s.aiDiceRolling { return }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The first legal move for a roll, as single-die hops a human would play.
    private func hops(_ s: GameSession, _ d1: Int, _ d2: Int) -> [[Int]] {
        let probe = session(.off)
        probe.setDice(d1, d2)
        var out: [[Int]] = []
        while probe.history.isEmpty {
            guard let from = probe.selectableSources.sorted().first,
                  let to = probe.moveBuilder.validDestinations(for: from).sorted().first(where: {
                      probe.moveBuilder.routeOptions(from: from, to: $0).first?.count == 1
                  }) else { break }
            out.append([from, to])
            probe.commitHalfMove(from: from, to: to)
        }
        return out
    }

    func testAnimatedPreviewThenFinalPlyMatchesReplay() async {
        let s = session(fast)
        let move = hops(s, 6, 5)
        XCTAssertTrue(s.showRemoteTurn(plyIndex: 0, die1: 6, die2: 5, halfMoves: []))
        await settle(s)
        XCTAssertTrue(s.isShowingRemoteTurn)
        XCTAssertTrue(s.showRemoteTurn(plyIndex: 0, die1: 6, die2: 5, halfMoves: [move[0]]))
        await settle(s)
        XCTAssertEqual(s.remoteTurnHalfMoves, [move[0]])

        XCTAssertTrue(s.applyRemoteMove(PlyRecord(die1: 6, die2: 5, halfMoves: move)))
        await settle(s)
        XCTAssertFalse(s.isShowingRemoteTurn)
        XCTAssertEqual(s.history.count, 1)
        XCTAssertEqual(s.phase, .awaitingRoll)
        let reference = session(.off)
        XCTAssertTrue(reference.applyRemoteMove(PlyRecord(die1: 6, die2: 5, halfMoves: move)))
        XCTAssertEqual(s.game.board.captureStacks(), reference.game.board.captureStacks())
    }

    func testFinalPlyDifferentFromThePreviewStillLandsExactly() async {
        let s = session(.off)
        let move = hops(s, 6, 5)
        s.showRemoteTurn(plyIndex: 0, die1: 6, die2: 5, halfMoves: [move[0]])
        // The opponent took it back and played something else: a different roll even.
        let other = hops(s, 3, 1)
        XCTAssertTrue(s.applyRemoteMove(PlyRecord(die1: 3, die2: 1, halfMoves: other)))
        let reference = session(.off)
        reference.applyRemoteMove(PlyRecord(die1: 3, die2: 1, halfMoves: other))
        XCTAssertEqual(s.game.board.captureStacks(), reference.game.board.captureStacks())
    }

    func testIllegalOrStalePreviewNeverCorruptsTheBoard() {
        let s = session(.off)
        let start = s.game.board.captureStacks()
        XCTAssertFalse(s.showRemoteTurn(plyIndex: 5, die1: 6, die2: 5, halfMoves: []), "stale ply")
        XCTAssertFalse(s.showRemoteTurn(plyIndex: 0, die1: 0, die2: 5, halfMoves: []), "bad dice")
        XCTAssertTrue(s.showRemoteTurn(plyIndex: 0, die1: 6, die2: 5, halfMoves: [[3, 9], [99, 1]]))
        XCTAssertEqual(s.remoteTurnHalfMoves, [], "illegal hops are not shown")
        XCTAssertEqual(s.game.board.captureStacks(), start)
        s.clearRemoteTurn()
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertFalse(s.isShowingRemoteTurn)
    }

    func testNewDiceRestartTheTurn() {
        let s = session(.off)
        let start = s.game.board.captureStacks()
        let move = hops(s, 6, 5)
        s.showRemoteTurn(plyIndex: 0, die1: 6, die2: 5, halfMoves: [move[0]])
        XCTAssertNotEqual(s.game.board.captureStacks(), start)
        s.showRemoteTurn(plyIndex: 0, die1: 2, die2: 1, halfMoves: [])
        XCTAssertEqual(s.game.board.captureStacks(), start)
        XCTAssertEqual(s.game.dice.die1.value, 2)
    }
}
