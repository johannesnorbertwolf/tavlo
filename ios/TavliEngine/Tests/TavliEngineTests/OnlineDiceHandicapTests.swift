import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// The shared online weighted-dice slider (#272): one signed value per match, either
/// player changes it, the turn holder writes it (the waiting player's change travels as an
/// out-of-turn request = GameKit exchange, or waits for its own turn), every roll uses the
/// value its roller holds and is stamped with it. Two `FakeDevice`s on the in-memory
/// `FakeGameCenter` (see `OnlineMatchControllerTests`), with the fixture value net.
@MainActor
final class OnlineDiceHandicapTests: XCTestCase {

    private var server: FakeGameCenter!
    private var alice: FakeDevice!   // creator, White, moves first (house Plakoto)
    private var bob: FakeDevice!
    private var matchID = ""
    private var agent: Agent!

    override func setUp() async throws {
        agent = try loadAgent()
        server = FakeGameCenter()
        alice = FakeDevice("alice", server: server, handicapAgent: agent)
        bob = FakeDevice("bob", server: server, handicapAgent: agent)
    }

    override func tearDown() async throws {
        alice?.controller.close()
        bob?.controller.close()
    }

    // MARK: - Helpers

    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else { throw XCTSkip("PlakotoValue.mlpackage not found") }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        return Agent(model: try MLModel(contentsOf: compiled, configuration: cfg),
                     encoder: BoardEncoder(config: .standard))
    }

    private func startMatch() async {
        matchID = server.createMatch(creator: "alice", opponent: "bob", opponentKnown: true)
        alice.controller.open(server.snapshot(matchID))
        bob.controller.open(server.snapshot(matchID))
        await drain()
        XCTAssertTrue(alice.controller.isLocalTurn)
        XCTAssertFalse(bob.controller.isLocalTurn)
    }

    private func drain(_ turns: Int = 8) async {
        for _ in 0..<turns { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private var aliceSession: GameSession { alice.controller.session! }
    private var bobSession: GameSession { bob.controller.session! }
    private var serverPayload: OnlineMatchPayload? { server.snapshot(matchID).payload }

    private func uniforms(_ values: [Double]) -> () -> Double {
        var i = 0
        return { defer { i += 1 }; return values[i % values.count] }
    }

    /// Roll (weighted when the dice say so) and play the whole turn with the first
    /// legal hops; returns the ply's dice.
    @discardableResult
    private func rollAndPlay(_ device: FakeDevice) async -> (Int, Int) {
        let s = device.controller.session!
        XCTAssertTrue(device.controller.isLocalTurn)
        let plies = s.record.plies.count
        s.roll()
        if s.preparingDice { await s.awaitDiceForTesting() }
        let dice = (s.game.dice.die1.value, s.game.dice.die2.value)
        while s.record.plies.count == plies, let hop = anyHop(s) {
            s.commitHalfMove(from: hop.0, to: hop.1)
        }
        await drain()
        return dice
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

    private func hybrid(_ level: Int) -> WeightedDice { WeightedDice(mode: .hybrid, level: level) }

    // MARK: - Fair by default, back-compatible wire

    func testFairByDefaultAndNothingNewOnTheWire() async throws {
        await startMatch()
        XCTAssertEqual(alice.controller.diceHandicap, .fair)
        XCTAssertTrue(alice.controller.canChangeDice)
        XCTAssertNil(aliceSession.handicap, "a fair match plays without a handicap state")
        let dice = await rollAndPlay(alice)
        XCTAssertTrue((1...6).contains(dice.0))
        XCTAssertNil(aliceSession.record.plies.last?.weighted, "a fair roll carries no stamp")
        let raw = String(decoding: server.snapshot(matchID).data!, as: UTF8.self)
        XCTAssertFalse(raw.contains("diceHandicap"), "a match that never used the slider encodes as before")
        XCTAssertFalse(raw.contains("weighted"))
    }

    func testOldPayloadsDecodeAsFairAndUnreadableKeysAreTolerated() throws {
        let old = """
        {"schemaVersion":2,"targetWins":1,"startingPlayer":"W","colorByPlayerID":{"a":"W"},
         "games":[{"plies":[{"die1":6,"die2":5,"halfMoves":[[1,7],[1,6]]}]}],"variant":"plakoto"}
        """
        let p = try OnlineMatchPayload.decoded(from: Data(old.utf8))
        XCTAssertNil(p.diceHandicap)
        XCTAssertEqual(p.dice, .fair)
        XCTAssertNil(p.games[0].plies[0].weighted)

        let odd = """
        {"schemaVersion":2,"targetWins":1,"startingPlayer":"W","colorByPlayerID":{"a":"W"},
         "games":[{"plies":[]}],"variant":"plakoto","diceHandicap":"later"}
        """
        XCTAssertEqual(try OnlineMatchPayload.decoded(from: Data(odd.utf8)).dice, .fair)

        // Round trip keeps the value, the stamps and schema v2; out-of-range is clamped.
        var q = OnlineMatchPayload(startingPlayer: .white, colorByPlayerID: ["a": .white],
                                   plies: [PlyRecord(die1: 3, die2: 1, halfMoves: [[1, 4]], weighted: -2)])
        q.diceHandicap = OnlineDiceHandicap(whiteLevel: -2, rev: 3, by: .black)
        let back = try OnlineMatchPayload.decoded(from: q.encoded())
        XCTAssertEqual(back, q)
        XCTAssertEqual(back.schemaVersion, 2)
        XCTAssertEqual(back.dice.favoured, .black)
        XCTAssertEqual(back.dice.level(towards: .black), 2)
        XCTAssertEqual(OnlineDiceHandicap(whiteLevel: 9).whiteLevel, WeightedDice.levels)
        XCTAssertNil(PlyRecord(die1: 1, die2: 2, halfMoves: [], weighted: 0).weighted, "0 = fair, no key")
        // A never-changed value is not written.
        XCTAssertNil(OnlineMatchPayload(startingPlayer: .white, colorByPlayerID: [:],
                                        diceHandicap: .fair).diceHandicap)
    }

    func testRequestAcceptanceRule() {
        let req = OnlineDiceRequest(whiteLevel: -2, baseRev: 1, by: .black)
        XCTAssertTrue(req.isAccepted(over: OnlineDiceHandicap(whiteLevel: 1, rev: 1, by: .white)),
                      "the requester had seen the current value")
        XCTAssertFalse(req.isAccepted(over: OnlineDiceHandicap(whiteLevel: 3, rev: 2, by: .white)),
                       "never over a change by the other player the requester had not seen")
        XCTAssertTrue(req.isAccepted(over: OnlineDiceHandicap(whiteLevel: -1, rev: 2, by: .black)),
                      "the requester's own earlier change never blocks its newer one")
        XCTAssertNil(OnlineDiceRequest.decoded(from: Data("{\"kind\":\"other\"}".utf8)))
        XCTAssertEqual(OnlineDiceRequest.decoded(from: try! req.encoded()), req)
    }

    // MARK: - Set on one device → seen on the other

    func testTurnHoldersChangeReachesTheWaitingDevice() async {
        await startMatch()
        alice.controller.setDiceHandicap(levelTowardsMe: 2)
        XCTAssertEqual(alice.controller.diceHandicap.whiteLevel, 2, "shown at once")
        XCTAssertEqual(aliceSession.handicap?.setup.white.weightedDice, hybrid(2))
        await drain()

        XCTAssertEqual(serverPayload?.dice, OnlineDiceHandicap(whiteLevel: 2, rev: 1, by: .white))
        XCTAssertEqual(alice.writes.last, "save", "written at once with saveCurrentTurn")
        XCTAssertTrue(alice.requests.isEmpty)
        XCTAssertEqual(bob.controller.diceHandicap.level(towards: .black), -2, "favours the opponent")
        XCTAssertEqual(bob.controller.diceHandicap.changedBy, .white)
        XCTAssertFalse(bob.controller.isDiceChangePending)
        XCTAssertEqual(bobSession.handicap?.setup.white.weightedDice, hybrid(2))
        XCTAssertEqual(bobSession.handicap?.setup.black.weightedDice, .off)
    }

    func testWaitingPlayersChangeGoesToTheTurnHolder() async {
        await startMatch()
        bob.controller.setDiceHandicap(levelTowardsMe: 3)
        XCTAssertEqual(bob.controller.diceHandicap.whiteLevel, -3, "the requester sees it at once")
        XCTAssertEqual(bob.requests.count, 1, "sent out of turn (an exchange)")
        XCTAssertEqual(alice.controller.diceHandicap.whiteLevel, -3, "the holder took it")
        XCTAssertEqual(alice.controller.diceHandicap.changedBy, .black)
        XCTAssertEqual(aliceSession.handicap?.setup.black.weightedDice, hybrid(3),
                       "the holder's next roll uses it")
        await drain()

        XCTAssertEqual(serverPayload?.dice, OnlineDiceHandicap(whiteLevel: -3, rev: 1, by: .black))
        XCTAssertFalse(bob.controller.isDiceChangePending, "confirmed by the holder's write")
        XCTAssertEqual(bob.controller.diceHandicap, alice.controller.diceHandicap)

        // A second quick change still lands after the first.
        bob.controller.setDiceHandicap(levelTowardsMe: 1)
        await drain()
        XCTAssertEqual(alice.controller.diceHandicap.whiteLevel, -1)
        XCTAssertEqual(serverPayload?.dice.rev, 2)
        XCTAssertEqual(bob.controller.diceHandicap, alice.controller.diceHandicap)
    }

    func testWithoutTheRequestChannelTheChangeAppliesOnTheRequestersTurn() async {
        await startMatch()
        bob.dropRequests = true
        bob.controller.setDiceHandicap(levelTowardsMe: 1)
        await drain()
        XCTAssertTrue(bob.controller.isDiceChangePending)
        XCTAssertEqual(alice.controller.diceHandicap, .fair, "the holder never heard of it")

        await rollAndPlay(alice)
        XCTAssertNil(aliceSession.record.plies.last?.weighted, "Alice rolled fair: her value")
        XCTAssertTrue(bob.controller.isLocalTurn)
        XCTAssertFalse(bob.controller.isDiceChangePending, "minted as soon as Bob holds the turn")
        XCTAssertEqual(serverPayload?.dice, OnlineDiceHandicap(whiteLevel: -1, rev: 1, by: .black),
                       "written before Bob rolls")
        XCTAssertEqual(alice.controller.diceHandicap.whiteLevel, -1)
        XCTAssertEqual(bobSession.handicap?.setup.adjusted, true, "changed after the first ply")

        await rollAndPlay(bob)
        XCTAssertEqual(bobSession.record.plies.last?.weighted, -1, "Bob's roll used his change")
        XCTAssertEqual(aliceSession.record.plies.last?.weighted, -1, "and the log agrees on Alice's side")
        XCTAssertEqual(serverPayload?.games.last?.plies.last?.weighted, -1)
    }

    func testTheOtherPlayersUnseenChangeWins() async {
        await startMatch()
        bob.dropRequests = true
        bob.controller.setDiceHandicap(levelTowardsMe: 1)
        alice.controller.setDiceHandicap(levelTowardsMe: 2)
        await drain()
        XCTAssertFalse(bob.controller.isDiceChangePending, "Alice's newer change replaced Bob's")
        XCTAssertEqual(bob.controller.diceHandicap, alice.controller.diceHandicap)
        XCTAssertEqual(bob.controller.diceHandicap.whiteLevel, 2)

        // And Bob's turn does not bring the dropped change back.
        await rollAndPlay(alice)
        XCTAssertEqual(bob.controller.diceHandicap.whiteLevel, 2)
        XCTAssertEqual(serverPayload?.dice.rev, 1)
    }

    // MARK: - Rolls use the agreed value

    func testRollsUseTheAgreedValueOnBothSidesAndAreStamped() async throws {
        await startMatch()
        alice.controller.setDiceHandicap(levelTowardsMe: 4)
        await drain()
        let maxPoints = aliceSession.game.variant.maxPoints

        // Alice (favoured) rolls with her own bend.
        let values = try HandicapDice.rollValues(agent: agent, board: aliceSession.game.board, color: .white)
        let beta = HandicapDice.rollBeta(values: values, roller: .white, favoured: .white,
                                         dice: hybrid(4), maxPoints: maxPoints)
        aliceSession.handicapUniform = uniforms([0.37, 0.81])
        aliceSession.roll()
        XCTAssertTrue(aliceSession.preparingDice, "a weighted roll is rated first")
        await aliceSession.awaitDiceForTesting()
        let expected = HandicapDice.weightedFaces(u1: 0.37, u2: 0.81, values: values, beta: beta)
        XCTAssertEqual(aliceSession.game.dice.die1.value, expected.0)
        XCTAssertEqual(aliceSession.game.dice.die2.value, expected.1)
        while aliceSession.record.plies.isEmpty, let hop = anyHop(aliceSession) {
            aliceSession.commitHalfMove(from: hop.0, to: hop.1)
        }
        await drain()
        XCTAssertEqual(aliceSession.record.plies.last?.weighted, 4)
        XCTAssertEqual(bobSession.record.plies.last?.weighted, 4, "the stamp travels with the ply")
        XCTAssertEqual(bobSession.history, aliceSession.history)

        // Bob (unfavoured) rolls with the mirrored bend of the same value.
        let bValues = try HandicapDice.rollValues(agent: agent, board: bobSession.game.board, color: .black)
        let bBeta = HandicapDice.rollBeta(values: bValues, roller: .black, favoured: .white,
                                          dice: hybrid(4), maxPoints: maxPoints)
        XCTAssertLessThanOrEqual(bBeta, 0, "mirrored: bent towards bad rolls")
        bobSession.handicapUniform = uniforms([0.52, 0.12])
        bobSession.roll()
        await bobSession.awaitDiceForTesting()
        let bExpected = HandicapDice.weightedFaces(u1: 0.52, u2: 0.12, values: bValues, beta: bBeta)
        XCTAssertEqual(bobSession.game.dice.die1.value, bExpected.0)
        XCTAssertEqual(bobSession.game.dice.die2.value, bExpected.1)
    }

    func testChangeAfterTheRollCountsFromTheNextRoll() async {
        await startMatch()
        alice.controller.setDiceHandicap(levelTowardsMe: 2)
        await drain()
        aliceSession.roll()
        await aliceSession.awaitDiceForTesting()
        alice.controller.setDiceHandicap(levelTowardsMe: 0)   // mid-turn
        await drain()
        XCTAssertEqual(serverPayload?.dice.whiteLevel, 0)
        XCTAssertEqual(bob.controller.diceHandicap.whiteLevel, 0, "seen at once, mid-turn")
        while aliceSession.record.plies.isEmpty, let hop = anyHop(aliceSession) {
            aliceSession.commitHalfMove(from: hop.0, to: hop.1)
        }
        await drain()
        XCTAssertEqual(aliceSession.record.plies.last?.weighted, 2, "this roll was drawn at +2")

        // 0 = fair: Bob's roll is not rated at all and carries no stamp.
        bobSession.roll()
        XCTAssertFalse(bobSession.preparingDice)
        while bobSession.record.plies.count == 1, let hop = anyHop(bobSession) {
            bobSession.commitHalfMove(from: hop.0, to: hop.1)
        }
        await drain()
        XCTAssertNil(bobSession.record.plies.last?.weighted)
    }

    // MARK: - Reopen, no model

    func testReopeningRestoresTheValue() async {
        await startMatch()
        bob.controller.setDiceHandicap(levelTowardsMe: 2)
        await drain()
        bob.controller.close()
        XCTAssertEqual(bob.controller.diceHandicap, .fair)
        bob.controller.open(server.snapshot(matchID))
        XCTAssertEqual(bob.controller.diceHandicap.level(towards: .black), 2)
        XCTAssertEqual(bobSession.handicap?.setup.black.weightedDice, hybrid(2))
    }

    func testWithoutAValueNetTheSliderIsUnavailable() async {
        alice.controller.close()
        alice = FakeDevice("alice", server: server)
        await startMatch()
        XCTAssertFalse(alice.controller.canChangeDice)
        alice.controller.setDiceHandicap(levelTowardsMe: 2)
        XCTAssertEqual(alice.controller.diceHandicap, .fair)
        await drain()
        XCTAssertNil(serverPayload?.diceHandicap)
    }
}
