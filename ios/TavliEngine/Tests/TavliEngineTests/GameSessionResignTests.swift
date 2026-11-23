import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Resigning is always possible while a game is in progress (#74 follow-up): in a
/// two-player game (the side on move gives up) and while the computer is thinking or
/// animating (its turn is cancelled cleanly — nothing lands afterwards and the record
/// still replays to the board shown).
@MainActor
final class GameSessionResignTests: XCTestCase {

    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else {
            throw XCTSkip("PlakotoValue.mlpackage not found — run ios/scripts/convert_to_coreml.py")
        }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiled, configuration: cfg)
        return Agent(model: model, encoder: BoardEncoder(config: .standard))
    }

    private func stacks(_ s: GameSession) -> [[Color]] { s.game.board.captureStacks() }

    private func startStacks(_ config: GameConfig = .standard) -> [[Color]] {
        let b = GameBoard(config: config)
        config.variant.setUpInitialPosition(on: b)
        return b.captureStacks()
    }

    /// The board a save of `s` replays to.
    private func replayedStacks(_ s: GameSession) -> [[Color]] {
        let resumed = GameSession.resume(from: s.snapshot(name: "t"), animationTimings: .off)
        return resumed.game.board.captureStacks()
    }

    /// Play the human turn by replaying the first surviving legal move.
    private func playHumanTurn(_ s: GameSession) {
        guard let chosen = s.moveBuilder.activeMoves.first else { return }
        while s.phase == .picking || s.phase == .moving {
            guard s.moveBuilder.built.count < chosen.halfMoves.count else { break }
            guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else { XCTFail("no legal play order"); break }
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    // MARK: - Two players

    /// In a two-player game the side on move gives up and the other side wins 1 point.
    func testTwoPlayerResignAwardsWinToTheOtherSide() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off)
        var over: [Color] = []
        var finished: [(Color?, Int)] = []
        s.onGameOver = { over.append($0) }
        s.onGameFinished = { finished.append(($0, $1)) }

        s.setDice(3, 1)
        playHumanTurn(s)                                       // White moves, Black on move
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertTrue(s.canSurrender)
        XCTAssertEqual(s.surrenderingColor, .black)

        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .white))
        XCTAssertEqual(s.record.outcome, .white)
        XCTAssertFalse(s.record.isDraw)
        XCTAssertEqual(over, [.white])
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished.first?.0, .white)
        XCTAssertEqual(finished.first?.1, 1)
        XCTAssertFalse(s.canSurrender)
        XCTAssertNil(s.surrenderingColor)
        s.surrender()                                          // guarded once over
        XCTAssertEqual(over.count, 1)
    }

    /// The view passes the side its confirmation named; that side resigns even if the
    /// turn moved on meanwhile.
    func testTwoPlayerResignAsNamedSide() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off)
        s.surrender(as: .black)                                // White on move, Black named
        XCTAssertEqual(s.phase, .gameOver(winner: .white))
    }

    /// Mid-move: the half-built move is taken back before the game ends.
    func testTwoPlayerResignDiscardsHalfBuiltMove() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off)
        let start = stacks(s)
        s.setDice(6, 5)
        let first = try! XCTUnwrap(nextOfferedHalf(s.moveBuilder, of: s.moveBuilder.activeMoves[0]))
        s.selectPoint(first.from.position)
        s.commitHalfMove(from: first.from.position, to: first.to.position)
        XCTAssertFalse(s.moveBuilder.built.isEmpty)

        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertEqual(stacks(s), start)
        XCTAssertNil(s.pendingRoll)
        XCTAssertEqual(replayedStacks(s), stacks(s))
    }

    /// A 2-point variant scores a resignation as 1 point, as vs the computer.
    func testTwoPlayerResignInTwoPointVariantScoresOnePoint() {
        let s = GameSession(startingPlayer: .black, config: GameConfig(variantID: "portes"),
                            animationTimings: .off)
        var points: [Int] = []
        s.onGameFinished = { _, p in points.append(p) }
        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .white))
        XCTAssertEqual(s.record.points, 1)
        XCTAssertEqual(points, [1])
        XCTAssertEqual(s.record.result, MatchGameResult(winner: .white, points: 1))
    }

    /// Vs the computer only the human can resign: naming the computer's side is ignored.
    func testVsComputerTheHumanAlwaysResigns() {
        let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off)
        XCTAssertEqual(s.surrenderingColor, .white)
        s.surrender(as: .black)
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
    }

    /// The drill (attempt mode) has no game to resign.
    func testDrillCannotResign() {
        let s = GameSession.drill(boardStacks: startStacks(), die1: 3, die2: 1, mover: .white)
        s.onMoveAttempt = { _ in }
        XCTAssertFalse(s.canSurrender)
        s.surrender()
        XCTAssertEqual(s.phase, .picking)
    }

    // MARK: - While the computer moves

    /// Resigning mid-animation, after some of the computer's hops landed: the hops are
    /// taken back (board = start of the computer's turn), the animation stops, no ply is
    /// recorded, nothing lands afterwards and the record replays to the board shown.
    func testResignWhileAnimatingRollsBackTheComputersTurn() async throws {
        // With no model the computer plays a random legal move; when that is a single
        // hop its turn ends as the hop lands, leaving no moment with a hop landed and
        // the turn still running. Retry with a fresh game until the move has two hops
        // (each try fails about one time in three, so ten tries all failing is ~1e-5).
        var found: (s: GameSession, beforeAI: [[Color]], over: () -> [Color])?
        for _ in 0..<10 where found == nil {
            let s = GameSession(startingPlayer: .white, agent: nil, aiColor: .black,
                                animationTimings: AnimationTimings(aiDiceRollDuration: 0.01,
                                                                   aiMoveAnimationDuration: 0.08))
            var over: [Color] = []
            s.onGameOver = { over.append($0) }
            s.setDice(3, 1)
            playHumanTurn(s)                                   // human ply recorded, AI animating
            XCTAssertEqual(s.phase, .animating)
            XCTAssertEqual(s.history.count, 1)
            let beforeAI = stacks(s)

            // Wait until at least one hop has landed and the next is in flight.
            let deadline = Date().addingTimeInterval(5)
            while s.moveBuilder.built.isEmpty, s.phase == .animating, Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if s.phase == .animating, !s.moveBuilder.built.isEmpty {
                found = (s, beforeAI, { over })
            }
        }
        guard let (s, beforeAI, overList) = found else {
            return XCTFail("the computer never played a two-hop move in ten tries")
        }
        var over: [Color] { overList() }
        XCTAssertEqual(s.phase, .animating)
        XCTAssertFalse(s.moveBuilder.built.isEmpty, "a hop landed before the resign")
        XCTAssertNotEqual(stacks(s), beforeAI)
        XCTAssertTrue(s.canSurrender)
        XCTAssertEqual(s.surrenderingColor, .white)

        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertNil(s.aiHopInFlight)
        XCTAssertFalse(s.aiDiceRolling)
        XCTAssertNil(s.pendingRoll)
        XCTAssertEqual(stacks(s), beforeAI, "landed hops taken back")
        XCTAssertEqual(s.history.count, 1, "no partial computer ply recorded")
        XCTAssertEqual(over, [.black])

        try await Task.sleep(nanoseconds: 400_000_000)         // any survivor would have fired
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertEqual(stacks(s), beforeAI, "nothing lands after the resign")
        XCTAssertEqual(s.history.count, 1)
        XCTAssertNil(s.aiHopInFlight)
        XCTAssertEqual(over.count, 1)
        XCTAssertEqual(replayedStacks(s), stacks(s), "the record replays to the board shown")
    }

    /// Resigning while the dice still tumble (nothing landed yet).
    func testResignDuringComputerDiceTumble() async throws {
        let s = GameSession(startingPlayer: .black, agent: nil, aiColor: .black,
                            animationTimings: AnimationTimings(aiDiceRollDuration: 0.1,
                                                               aiMoveAnimationDuration: 0.05))
        s.start()
        XCTAssertEqual(s.phase, .animating)
        XCTAssertTrue(s.aiDiceRolling)
        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertFalse(s.aiDiceRolling)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertEqual(stacks(s), startStacks())
        XCTAssertTrue(s.history.isEmpty)
    }

    /// Resigning while the computer searches off the main actor: the search result is
    /// discarded when it arrives — no move is played or recorded.
    func testResignWhileComputerThinkingDiscardsTheSearch() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off)
        let service = AnalysisService()
        s.analysisService = service
        s.start()
        XCTAssertEqual(s.phase, .aiThinking)
        XCTAssertTrue(service.gate.isHeld, "background analysis paused while the computer thinks")
        XCTAssertTrue(s.canSurrender)
        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertFalse(service.gate.isHeld, "resigning releases the analysis gate")

        try await Task.sleep(nanoseconds: 1_500_000_000)       // the 1-ply search is long done
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertTrue(s.history.isEmpty, "the discarded search played nothing")
        XCTAssertEqual(stacks(s), startStacks())
        XCTAssertEqual(replayedStacks(s), stacks(s))
    }

    /// Handicap game: resigning while the computer's weighted roll is being prepared
    /// drops the roll; nothing is drawn or played afterwards.
    func testResignWhileComputerPreparesWeightedRoll() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: HandicapSetup(black: HandicapItems(diceTilt: 4, rerolls: 2)))
        let start = stacks(s)
        s.start()
        XCTAssertEqual(s.phase, .aiThinking)
        XCTAssertTrue(s.preparingDice)
        s.surrender()
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertFalse(s.preparingDice)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertNil(s.pendingRoll)
        XCTAssertEqual(stacks(s), start)
    }

    /// Auto-roll: resigning while the human's dice tumble (or a forced pass counts
    /// down) cancels that timer, so the turn never resumes on a finished game.
    func testResignDuringAutoRollTumbleCancelsIt() async throws {
        let s = GameSession(startingPlayer: .white, aiColor: .black,
                            animationTimings: AnimationTimings(aiDiceRollDuration: 0.1,
                                                               aiMoveAnimationDuration: 0.05),
                            autoRoll: true)
        s.start()
        try await Task.sleep(nanoseconds: 20_000_000)          // the tumble is under way
        XCTAssertTrue(s.humanDiceRolling)
        s.surrender()
        XCTAssertFalse(s.humanDiceRolling)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(s.phase, .gameOver(winner: .black))
        XCTAssertTrue(s.legalMoves.isEmpty)
        XCTAssertTrue(s.selectableSources.isEmpty)
        XCTAssertNil(s.pendingRoll)
    }
}
