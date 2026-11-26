import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Mid-game handicap changes (#236): weighted dice, rerolls left and hints left can be
/// changed during a game for either side; the next roll (human, computer, computer
/// reroll) uses the new values, the change persists through save/resume, carries into
/// the next game of a match, and marks the game "adjusted" (old records still load).
/// Also the handicap button's favoured side.
@MainActor
final class HandicapAdjustTests: XCTestCase {

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

    private func uniforms(_ values: [Double]) -> () -> Double {
        var i = 0
        return { defer { i += 1 }; return values[i % values.count] }
    }

    /// Uniforms whose draw under `beta` differs from the fair draw, so a test tells a
    /// weighted roll from a fair one (the first such pair on a 1/12 grid).
    private func discriminatingUniforms(values: [Float], beta: Double) -> (Double, Double)? {
        let grid = (0..<12).map { (Double($0) + 0.5) / 12 }
        for u1 in grid {
            for u2 in grid {
                let w = HandicapDice.weightedFaces(u1: u1, u2: u2, values: values, beta: beta)
                let f = HandicapDice.weightedFaces(u1: u1, u2: u2, values: values, beta: 0)
                if HandicapDice.outcomeIndex(w.0, w.1) != HandicapDice.outcomeIndex(f.0, f.1) {
                    return (u1, u2)
                }
            }
        }
        return nil
    }

    private func roundTrip(_ save: GameSave) throws -> GameSave {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(GameSave.self, from: e.encode(save))
    }

    // MARK: - Tokens and marks

    func testAdjustingChangesTokensSetupAndMarksTheGame() {
        let setup = HandicapSetup(white: HandicapItems(headStart: 2, rerolls: 1, hints: 1))
        let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: setup)
        XCTAssertFalse(s.record.handicap?.adjusted ?? true)

        // Unchanged values are a no-op: not adjusted.
        s.adjustHandicap(for: .white, rerollsLeft: 1)
        XCTAssertEqual(s.handicap?.setup.adjusted, false)

        s.adjustHandicap(for: .white, rerollsLeft: 3, hintsLeft: 4)
        XCTAssertEqual(s.rerollsLeft(.white), 3)
        XCTAssertEqual(s.hintsLeft(.white), 4)
        XCTAssertEqual(s.handicap?.setup.white.rerolls, 3, "the allowance for later games follows")
        XCTAssertEqual(s.handicap?.setup.white.hints, 4)
        XCTAssertEqual(s.handicap?.setup.white.headStart, 2, "start-only items never change")
        XCTAssertEqual(s.handicap?.setup.adjusted, true)
        XCTAssertEqual(s.record.handicap, s.handicap?.setup, "the record carries the final setup")
        XCTAssertTrue(s.record.handicap?.alteredDiceEarlier == true, "rerolls were on before")

        // Clamped to the builder's ranges; hints never go to the computer.
        s.adjustHandicap(for: .white, rerollsLeft: 99, hintsLeft: -3)
        XCTAssertEqual(s.rerollsLeft(.white), HandicapSetup.maxRerolls)
        XCTAssertEqual(s.hintsLeft(.white), 0)
        s.adjustHandicap(for: .black, rerollsLeft: 2, hintsLeft: 5)
        XCTAssertEqual(s.rerollsLeft(.black), 2, "the computer's rerolls are adjustable")
        XCTAssertEqual(s.hintsLeft(.black), 0, "hints only for a human side")
        XCTAssertTrue(s.isHumanSide(.white))
        XCTAssertFalse(s.isHumanSide(.black))

        // The level is clamped to the steps; any mode.
        s.adjustHandicap(for: .black, weightedDice: WeightedDice(mode: .lean, level: 9))
        XCTAssertEqual(s.handicap?.setup.black.weightedDice, WeightedDice(mode: .lean, level: WeightedDice.levels))
        s.adjustHandicap(for: .black, weightedDice: WeightedDice(mode: .fixedGain, level: 2))
        XCTAssertEqual(s.handicap?.setup.black.weightedDice, WeightedDice(mode: .fixedGain, level: 2))
        XCTAssertTrue(s.record.handicap?.altersDice == true)

        // A human reroll spends from the new count.
        s.handicapUniform = uniforms([0.5, 0.5])
        s.setDice(6, 5)
        XCTAssertTrue(s.canReroll)
        s.reroll()
        XCTAssertEqual(s.rerollsLeft(.white), HandicapSetup.maxRerolls - 1)
        s.adjustHandicap(for: .white, rerollsLeft: 0)
        XCTAssertFalse(s.canReroll)

        // Nothing changes once the game is over.
        let final = s.handicap
        s.surrender()
        s.adjustHandicap(for: .white, rerollsLeft: 2)
        XCTAssertEqual(s.handicap, final)
    }

    func testTwoPlayerHintsForEitherSide() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(headStart: 1)))
        s.adjustHandicap(for: .black, hintsLeft: 2)
        XCTAssertEqual(s.hintsLeft(.black), 2)
        XCTAssertTrue(s.isHumanSide(.black))
    }

    func testDiceMarkStaysWhenWeightedDiceAreSwitchedOff() {
        let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .hybrid, level: 2))))
        s.adjustHandicap(for: .white, weightedDice: .off)
        let final = try! XCTUnwrap(s.record.handicap)
        XCTAssertFalse(final.hasWeightedDice)
        XCTAssertFalse(final.isActive, "every item is off now")
        XCTAssertTrue(final.isKept, "but it stays a handicap game")
        XCTAssertTrue(final.altersDice, "the review's fair-dice note still applies")
        XCTAssertNotNil(s.handicap, "the game keeps its handicap button")

        // Fair from the start, weighted dice switched on mid-game: the final setup says so.
        let t = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(hints: 1)))
        XCTAssertFalse(t.record.handicap!.altersDice)
        t.adjustHandicap(for: .black, weightedDice: WeightedDice(mode: .lean, level: 3))
        XCTAssertTrue(t.record.handicap!.altersDice)
        XCTAssertFalse(t.record.handicap!.alteredDiceEarlier)
    }

    // MARK: - The next roll uses the new setup

    func testHumanRollUsesTheNewBeta() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(headStart: 1)),
                            handicapAgent: agent)
        let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .white)
        let dice = WeightedDice(mode: .lean, level: WeightedDice.levels)
        let beta = HandicapDice.beta(values: values, dice: dice)
        let u = try XCTUnwrap(discriminatingUniforms(values: values, beta: beta),
                              "the tilt must change some draw")
        s.adjustHandicap(for: .white, weightedDice: dice)
        s.handicapUniform = uniforms([u.0, u.1])
        s.roll()
        XCTAssertTrue(s.preparingDice, "a weighted roll is rated first")
        await s.awaitDiceForTesting()
        let expected = HandicapDice.weightedFaces(u1: u.0, u2: u.1, values: values, beta: beta)
        XCTAssertEqual(s.game.dice.die1.value, expected.0)
        XCTAssertEqual(s.game.dice.die2.value, expected.1)

        // Switching it off again makes the next roll fair (no rating at all).
        let t = GameSession(startingPlayer: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(weightedDice: dice)),
                            handicapAgent: agent)
        t.adjustHandicap(for: .white, weightedDice: .off)
        t.roll()
        XCTAssertFalse(t.preparingDice)
        XCTAssertEqual(t.phase, .picking)
    }

    func testComputerRollUsesTheNewBeta() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(hints: 1)))
        let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .black)
        let dice = WeightedDice(mode: .fixedGain, level: WeightedDice.levels)
        let beta = HandicapDice.beta(values: values, dice: dice)
        let u = try XCTUnwrap(discriminatingUniforms(values: values, beta: beta))
        s.adjustHandicap(for: .black, weightedDice: dice)
        s.handicapUniform = uniforms([u.0, u.1])
        s.start()
        while s.history.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let expected = HandicapDice.weightedFaces(u1: u.0, u2: u.1, values: values, beta: beta)
        let ply = s.history[0]
        XCTAssertEqual(HandicapDice.outcomeIndex(ply.die1, ply.die2),
                       HandicapDice.outcomeIndex(expected.0, expected.1))
    }

    // MARK: - Mirrored bend (#271): the opponent's rolls are bent the other way

    /// White holds weighted dice; Black (a human, two-player game) rolls: its roll is rated
    /// too and drawn with the mirrored β_t (≤ 0), so its expected roll value drops.
    func testOpponentRollIsBentTheOtherWay() async throws {
        let agent = try loadAgent()
        for mode in WeightedDiceMode.allCases {
            let dice = WeightedDice(mode: mode, level: WeightedDice.levels)
            let s = GameSession(startingPlayer: .black, animationTimings: .off,
                                handicap: HandicapSetup(white: HandicapItems(weightedDice: dice)),
                                handicapAgent: agent)
            let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .black)
            let beta = HandicapDice.mirroredBeta(values: values, dice: dice)
            XCTAssertLessThan(beta, 0, "\(mode)")
            let q = HandicapDice.tilt(values: values, beta: beta)
            XCTAssertLessThan(HandicapDice.expectedValue(values, probabilities: q),
                              HandicapDice.expectedValue(values), "\(mode)")
            let u = try XCTUnwrap(discriminatingUniforms(values: values, beta: beta), "\(mode)")
            s.handicapUniform = uniforms([u.0, u.1])
            s.roll()
            XCTAssertTrue(s.preparingDice, "the unfavoured side's roll is rated too")
            await s.awaitDiceForTesting()
            let expected = HandicapDice.weightedFaces(u1: u.0, u2: u.1, values: values, beta: beta)
            XCTAssertEqual(s.game.dice.die1.value, expected.0, "\(mode)")
            XCTAssertEqual(s.game.dice.die2.value, expected.1, "\(mode)")
        }
    }

    /// The computer as the unfavoured side (the human holds weighted dice) rolls the mirrored
    /// dice, and its reroll rule sees the same mirrored distribution.
    func testComputerAsUnfavouredSideRollsMirroredDice() async throws {
        let agent = try loadAgent()
        let dice = WeightedDice(mode: .fixedGain, level: WeightedDice.levels)
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(weightedDice: dice)))
        let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .black)
        let beta = HandicapDice.rollBeta(values: values, roller: .black, favoured: .white, dice: dice)
        XCTAssertEqual(beta, HandicapDice.mirroredBeta(values: values, dice: dice))
        let u = try XCTUnwrap(discriminatingUniforms(values: values, beta: beta))
        s.handicapUniform = uniforms([u.0, u.1])
        s.start()
        while s.history.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let expected = HandicapDice.weightedFaces(u1: u.0, u2: u.1, values: values, beta: beta)
        let ply = s.history[0]
        XCTAssertEqual(HandicapDice.outcomeIndex(ply.die1, ply.die2),
                       HandicapDice.outcomeIndex(expected.0, expected.1))
    }

    /// Off on both sides (here: only rerolls) is fair for both sides: no rating, the fair
    /// faces of the uniforms.
    func testNoWeightedDiceIsFairForBothSides() async throws {
        let agent = try loadAgent()
        for starter in Color.allCases {
            let s = GameSession(startingPlayer: starter, animationTimings: .off,
                                handicap: HandicapSetup(white: HandicapItems(rerolls: 2)),
                                handicapAgent: agent)
            s.roll()
            XCTAssertFalse(s.preparingDice, "\(starter)")
            XCTAssertEqual(s.phase, .picking)
        }
    }

    func testComputerRerollsWithTokensAddedMidGame() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(headStart: 1)))
        // The bear-off race of `testComputerRerollsBadRollsWithinItsTokens`.
        let b = s.game.board
        for i in b.points.indices { b.setPoint(i, pieces: []) }
        b.setPoint(0, pieces: Array(repeating: .black, count: 13))
        b.setPoint(6, pieces: [.black])
        b.setPoint(5, pieces: [.black])
        b.setPoint(25, pieces: Array(repeating: .white, count: 14))
        b.setPoint(19, pieces: [.white])
        let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .black)
        let worst = values.indices.min { values[$0] < values[$1] }!
        let best = values.indices.max { values[$0] < values[$1] }!
        func u(_ d: Int) -> Double { (Double(d) - 0.5) / 6 }
        let w = HandicapDice.outcomes[worst], bst = HandicapDice.outcomes[best]
        s.adjustHandicap(for: .black, rerollsLeft: 2)
        s.handicapUniform = uniforms([u(w.d1), u(w.d2), u(bst.d1), u(bst.d2)])
        s.start()
        while s.history.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(s.rerollsLeft(.black), 1, "the computer spent one of the added rerolls")
        XCTAssertEqual(s.lastComputerReroll, .black)
        XCTAssertEqual(HandicapDice.outcomeIndex(s.history[0].die1, s.history[0].die2), best)
    }

    // MARK: - Persistence

    func testSaveResumeRoundTripKeepsTheAdjustedSetup() throws {
        let setup = HandicapSetup(black: HandicapItems(headStart: 2, rerolls: 1))
        let s = GameSession(startingPlayer: .black, aiColor: .white, animationTimings: .off,
                            handicap: setup)
        s.adjustHandicap(for: .black, weightedDice: WeightedDice(mode: .hybrid, level: 2), rerollsLeft: 3, hintsLeft: 2)
        s.adjustHandicap(for: .white, rerollsLeft: 1)
        let back = try roundTrip(s.snapshot(name: "adj"))
        XCTAssertEqual(back.handicap, s.handicap)
        XCTAssertEqual(back.record.handicap?.adjusted, true)
        let r = GameSession.resume(from: back, animationTimings: .off)
        XCTAssertEqual(r.handicap, s.handicap)
        XCTAssertEqual(r.record.handicap, s.record.handicap)
        XCTAssertEqual(r.rerollsLeft(.white), 1)
        XCTAssertEqual(r.hintsLeft(.black), 2)
        XCTAssertEqual(r.game.board.points[18].pieces.count, 2, "the head start is unchanged")

        // An adjusted game with every item switched off still resumes as one.
        let t = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(rerolls: 1)))
        t.adjustHandicap(for: .white, rerollsLeft: 0)
        let tBack = try roundTrip(t.snapshot(name: "off"))
        XCTAssertNotNil(tBack.handicap)
        let tr = GameSession.resume(from: tBack, animationTimings: .off)
        XCTAssertEqual(tr.handicap?.setup.adjusted, true)
        XCTAssertTrue(tr.record.handicap?.altersDice == true)
        // …and the game log entry (built from the record) keeps the marks too.
        let logged = try roundTrip(GameSave(record: t.record, name: "log"))
        XCTAssertEqual(logged.record.handicap?.adjusted, true)
    }

    func testUnadjustedSetupEncodesAsBeforeAndOldJSONDecodes() throws {
        let plain = HandicapSetup(white: HandicapItems(headStart: 2))
        let json = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
        XCTAssertFalse(json.contains("adjusted"))
        XCTAssertFalse(json.contains("alteredDiceEarlier"))

        let old = try JSONDecoder().decode(HandicapSetup.self, from: Data(
            #"{"version":2,"white":{"headStart":2},"black":{}}"#.utf8))
        XCTAssertFalse(old.adjusted)
        XCTAssertFalse(old.alteredDiceEarlier)
        XCTAssertEqual(old, HandicapSetup(white: HandicapItems(headStart: 2), version: 2))

        var marked = plain
        marked.adjusted = true
        marked.alteredDiceEarlier = true
        let back = try JSONDecoder().decode(HandicapSetup.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(back, marked)
        XCTAssertEqual(marked.forNextGame, plain)
    }

    func testMyRecordCountsAdjustedGamesAndLoadsOldRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hadj-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // A pre-#236 log: one handicap record without the marks.
        let old = #"{"schemaVersion":1,"games":[{"date":"2026-06-01T10:00:00Z","humanWon":true,"handicap":{"version":2,"white":{"headStart":2},"black":{}}}]}"#
        try old.write(to: url, atomically: true, encoding: .utf8)
        let store = HumanStatsStore(store: HumanGameLogStore(fileURL: url))
        XCTAssertEqual(store.handicapStats.total, 1)
        XCTAssertEqual(store.adjustedHandicapGames, 0)

        let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(hints: 2)))
        s.adjustHandicap(for: .white, hintsLeft: 0)
        store.record(humanWon: false, handicap: s.record.handicap)
        XCTAssertEqual(store.handicapStats.total, 2)
        XCTAssertEqual(store.adjustedHandicapGames, 1)
        XCTAssertEqual(store.stats.total, 0, "an adjusted game stays out of the vs-Computer record")
        let again = HumanStatsStore(store: HumanGameLogStore(fileURL: url))
        XCTAssertEqual(again.adjustedHandicapGames, 1)
    }

    // MARK: - Next game

    func testNextGameStartsWithTheFinalSetupAndFreshTokens() {
        let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(headStart: 1, rerolls: 1)))
        s.adjustHandicap(for: .white, rerollsLeft: 3)
        s.adjustHandicap(for: .black, weightedDice: WeightedDice(mode: .hybrid, level: 1))
        // The best-of-three's next game (RootView.startNextMatchGame).
        let next = GameSession(startingPlayer: .black, aiColor: .black, animationTimings: .off,
                               handicap: s.record.handicap?.forNextGame)
        XCTAssertEqual(next.rerollsLeft(.white), 3)
        XCTAssertEqual(next.handicap?.setup.black.weightedDice, WeightedDice(mode: .hybrid, level: 1))
        XCTAssertEqual(next.handicap?.setup.adjusted, false, "a fresh game is not adjusted")
        XCTAssertEqual(next.game.board.points[7].pieces.count, 1)

        // `newGame` does the same in place.
        s.handicapUniform = uniforms([0.5, 0.5])
        s.setDice(2, 1)
        s.reroll()
        s.newGame(startingPlayer: .white)
        XCTAssertEqual(s.rerollsLeft(.white), 3)
        XCTAssertEqual(s.record.handicap?.adjusted, false)
        XCTAssertEqual(s.record.handicap?.black.weightedDice, WeightedDice(mode: .hybrid, level: 1))

        // Everything switched off: the next game is a normal one.
        let t = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(rerolls: 1)))
        t.adjustHandicap(for: .white, rerollsLeft: 0)
        t.newGame(startingPlayer: .white)
        XCTAssertNil(t.handicap)
        XCTAssertNil(t.record.handicap)
    }

    // MARK: - Favoured side (the handicap button)

    func testFavouredSide() {
        let table = HandicapTable.unmeasured
        func side(_ s: HandicapSetup, _ e: HandicapEstimate? = nil) -> Color? {
            HandicapEstimator.favouredSide(setup: s, estimate: e, table: table)
        }
        XCTAssertEqual(side(HandicapSetup(white: HandicapItems(headStart: 2))), .white)
        XCTAssertEqual(side(HandicapSetup(black: HandicapItems(hints: 1))), .black)
        XCTAssertEqual(side(HandicapSetup(white: HandicapItems(checkers: 13))), .black,
                       "fewer checkers help the opponent")
        XCTAssertEqual(side(HandicapSetup(black: HandicapItems(homeSize: 4))), .white,
                       "a smaller home helps the opponent")
        XCTAssertNil(side(HandicapSetup()))

        // Both sides helped: the net favourite from the estimate, nil when even.
        let both = HandicapSetup(white: HandicapItems(headStart: 2), black: HandicapItems(rerolls: 1))
        XCTAssertEqual(both.beneficiaries, [.white, .black])
        XCTAssertEqual(side(both, HandicapEstimate(whiteWinChance: 0.43, unmeasured: [], approximate: false)), .black)
        XCTAssertEqual(side(both, HandicapEstimate(whiteWinChance: 0.6, unmeasured: [], approximate: false)), .white)
        XCTAssertNil(side(both, HandicapEstimate(whiteWinChance: 0.505, unmeasured: [], approximate: false)))
        // Without an estimate yet: the table alone (here: nothing measured → even).
        XCTAssertNil(side(both))
    }

    func testFavouredSideFallsBackToTheTable() throws {
        let data = Data(#"{"version":1,"cells":{"rerolls:2":{"logOddsShift":0.32}}}"#.utf8)
        guard let table = HandicapTable.decode(data) else { throw XCTSkip("table format differs") }
        let both = HandicapSetup(white: HandicapItems(hints: 1), black: HandicapItems(rerolls: 2))
        XCTAssertEqual(HandicapEstimator.favouredSide(setup: both, estimate: nil, table: table), .black)
    }
}
