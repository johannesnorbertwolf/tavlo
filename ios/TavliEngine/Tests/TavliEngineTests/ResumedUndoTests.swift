import XCTest
@testable import TavliEngine

/// Decision-point undo ("↩ Undo decision" in the debug pane) after resuming from a
/// save. Regression for the report that undo was greyed out in a Full Tavli Plakoto
/// leg: the leg had been resumed from the autosave, and `replay` used to leave
/// `undoHistory` empty, so `canUndoLastDecision` stayed false until the human made a
/// new move — and even then the pre-resume moves could not be taken back.
@MainActor
final class ResumedUndoTests: XCTestCase {

    private struct Decision {
        let stacks: [[Color]]
        let dice: (Int, Int)
    }

    /// Deterministic dice stream (LCG) so every run plays the same game.
    private struct Dice {
        var state: UInt64
        mutating func next() -> (Int, Int) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let a = Int((state >> 33) % 6) + 1
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let b = Int((state >> 33) % 6) + 1
            return (a, b)
        }
    }

    /// Human (White) vs the model-less AI (Black, random legal move, synchronous with
    /// animations off). Plays `turns` human turns and returns the position + dice at
    /// the start of every real human decision (forced passes are not decisions).
    private func playHumanTurns(_ s: GameSession, turns: Int, seed: UInt64) -> [Decision] {
        var dice = Dice(state: seed)
        var decisions: [Decision] = []
        for _ in 0..<turns {
            guard s.phase == .awaitingRoll, s.currentPlayer == .white else { break }
            let before = s.game.board.captureStacks()
            let (d1, d2) = dice.next()
            s.setDice(d1, d2)
            // A forced pass already handed the turn to the AI (which has replied).
            guard s.phase == .picking, s.currentPlayer == .white,
                  let chosen = s.moveBuilder.activeMoves.first else { continue }
            decisions.append(Decision(stacks: before, dice: (d1, d2)))
            while s.phase == .picking || s.phase == .moving {
                guard s.moveBuilder.built.count < chosen.halfMoves.count,
                      let h = nextOfferedHalf(s.moveBuilder, of: chosen) else { break }
                s.selectPoint(h.from.position)
                s.commitHalfMove(from: h.from.position, to: h.to.position)
            }
        }
        return decisions
    }

    private func roundTrip(_ save: GameSave) throws -> GameSave {
        try JSONDecoder().decode(GameSave.self, from: JSONEncoder().encode(save))
    }

    /// Undo after resume walks back through every pre-resume human decision, in every
    /// variant, restoring the exact position and dice each time.
    func testUndoReachesPreResumeDecisionsInEveryVariant() throws {
        for variant in GameVariants.all {
            let a = GameSession(startingPlayer: .white, config: GameConfig(variant: variant),
                                aiColor: .black, animationTimings: .off)
            a.start()
            let decisions = playHumanTurns(a, turns: 6, seed: 0xC0FFEE)
            guard !decisions.isEmpty, !a.isTerminal else { return XCTFail("\(variant.id): no decisions") }

            let b = GameSession.resume(from: try roundTrip(a.snapshot(name: "x")),
                                       animationTimings: .off)
            b.start()
            XCTAssertEqual(b.phase, .awaitingRoll, variant.id)
            XCTAssertTrue(b.canUndoLastDecision, "\(variant.id): undo available right after resume")

            for (i, d) in decisions.enumerated().reversed() {
                XCTAssertTrue(b.canUndoLastDecision, "\(variant.id): decision \(i)")
                b.undoLastDecision()
                XCTAssertEqual(b.game.board.captureStacks(), d.stacks, "\(variant.id): position before decision \(i)")
                XCTAssertEqual(b.currentPlayer, .white, variant.id)
                XCTAssertEqual(b.phase, .picking, variant.id)
                XCTAssertEqual(b.game.dice.die1.value, d.dice.0, variant.id)
                XCTAssertEqual(b.game.dice.die2.value, d.dice.1, variant.id)
            }
            XCTAssertFalse(b.canUndoLastDecision, "\(variant.id): nothing left before the first decision")
        }
    }

    /// The reported case: a Full Tavli session on its Plakoto leg (leg 3), resumed from
    /// the autosave with the human's roll pending (dice shown, no move yet). Undo is
    /// enabled, steps back to the human's previous decision, keeps the history and the
    /// save in step, and the session's leg score is untouched.
    func testResumedFullTavliPlakotoLegCanUndoWithPendingRoll() throws {
        var ft = FullTavliSession(aiColor: .black,
                                  results: [.win(.white, points: 1), .win(.black, points: 2)])
        XCTAssertEqual(ft.currentVariant?.id, "plakoto")

        let a = GameSession(startingPlayer: .black, config: GameConfig(variantID: "plakoto"),
                            aiColor: .black, animationTimings: .off)
        a.start()   // the AI opens
        let decisions = playHumanTurns(a, turns: 4, seed: 0x7A71)
        guard let last = decisions.last else { return XCTFail("no human decision") }
        a.setDice(1, 1)   // the human's roll is on the board when the app is killed
        XCTAssertEqual(a.phase, .picking)
        let pendingBoard = a.game.board.captureStacks()
        let plies = a.history.count

        let save = try roundTrip(a.snapshot(name: "Full Tavli", fullTavli: ft))
        XCTAssertEqual(ft.resume(savedGame: save.record), .inLeg(index: 2))
        let b = GameSession.resume(from: save, animationTimings: .off)
        b.start()
        XCTAssertEqual(b.phase, .picking, "restored roll re-entered")
        XCTAssertEqual(b.game.board.captureStacks(), pendingBoard)
        XCTAssertTrue(b.canUndoLastDecision, "undo decision enabled mid-leg after resume")

        b.undoLastDecision()
        XCTAssertEqual(b.game.board.captureStacks(), last.stacks)
        XCTAssertEqual(b.currentPlayer, .white)
        XCTAssertEqual(b.game.dice.die1.value, last.dice.0)
        XCTAssertEqual(b.game.dice.die2.value, last.dice.1)
        XCTAssertLessThan(b.history.count, plies, "rewound plies dropped from the record")
        let resaved = b.snapshot(name: "x", fullTavli: ft)
        XCTAssertEqual(resaved.record.plies, b.history)
        XCTAssertEqual(resaved.pendingRoll?.die1, last.dice.0)
        XCTAssertEqual(resaved.pendingRoll?.die2, last.dice.1)
        XCTAssertEqual(ft.results.count, 2, "leg score untouched")
    }
}
