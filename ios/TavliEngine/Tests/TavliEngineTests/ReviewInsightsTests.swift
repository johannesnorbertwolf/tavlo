import Foundation
import XCTest
import CoreML
@testable import TavliEngine

// #231 — mistake levels, dice luck, accuracy and the opponent's level. The first
// classes are synthetic (no Core ML); `DiceLuckModelTests` uses the fixture model.

// ── Severity ────────────────────────────────────────────────────────────────────

final class MoveSeverityTests: XCTestCase {
    private func eval(played: Float, best: Float, hadChoice: Bool = true,
                      pointScale: Int = 1, mover: Color = .white, ply: Int = 1) -> PlyEvaluation {
        PlyEvaluation(plyNumber: ply, die1: 3, die2: 1, boardStacks: [], mover: mover,
                      playedMove: [[1, 4]], playedScore: played, bestMove: [[1, 2]], bestScore: best,
                      hadChoice: hadChoice, pointScale: pointScale)
    }

    func testClassifyBoundariesAreInclusiveLowerBounds() {
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 0), MoveSeverity.none)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 1.99), MoveSeverity.none)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 2.0), .inaccuracy)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 4.99), .inaccuracy)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 5.0), .mistake)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 9.99), .mistake)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 10.0), .blunder)
        XCTAssertEqual(MoveSeverity.classify(lossPoints: 60), .blunder)
    }

    func testPlakotoBoundariesFromFloatScores() {
        // Float scores land on the boundary despite 0.6 − 0.58 = 0.0199999…
        XCTAssertEqual(eval(played: 0.585, best: 0.60).severity, MoveSeverity.none)   // 1.5 pp
        XCTAssertEqual(eval(played: 0.58, best: 0.60).severity, .inaccuracy)          // 2 pp
        XCTAssertEqual(eval(played: 0.55, best: 0.60).severity, .mistake)             // 5 pp
        XCTAssertEqual(eval(played: 0.51, best: 0.60).severity, .mistake)             // 9 pp
        XCTAssertEqual(eval(played: 0.50, best: 0.60).severity, .blunder)             // 10 pp
        XCTAssertEqual(eval(played: 0.50, best: 0.60).decisionLoss, 10, accuracy: 1e-4)
    }

    /// The rule is absolute: a small loss in a lost position is not flagged however
    /// large it is relative to the best (the old relative rule would have).
    func testRuleIsAbsoluteNotRelative() {
        let e = eval(played: 0.05, best: 0.065)       // 23% relative, 1.5 pp absolute
        XCTAssertGreaterThan(e.relativeGap, 0.2)
        XCTAssertEqual(e.severity, MoveSeverity.none)
        let big = eval(played: 0.80, best: 0.90)      // 11% relative, 10 pp absolute
        XCTAssertTrue(big.isBlunder)
    }

    /// 2-point variants: a value gap counts double (win-chance equivalent), so a
    /// blunder is always ≥ 0.2 expected points — `EvalScale` shows the gap as
    /// `gap · 2 · maxPoints` equity, i.e. ≥ 0.20 there.
    func testEquityVariantUsesWinChanceEquivalent() {
        let e = eval(played: 0.55, best: 0.60, pointScale: 2)   // 5 pp of value = 0.2 points
        XCTAssertEqual(e.decisionLoss, 10, accuracy: 1e-4)
        XCTAssertEqual(e.severity, .blunder)
        let equityLabel = e.absoluteGap * 2 * 2                  // EvalScale.gap
        XCTAssertEqual(equityLabel, 0.20, accuracy: 1e-5)
        XCTAssertEqual(eval(played: 0.59, best: 0.60, pointScale: 2).severity, .inaccuracy)  // 2 pp
        XCTAssertEqual(eval(played: 0.575, best: 0.60, pointScale: 2).severity, .mistake)    // 5 pp
        XCTAssertEqual(eval(played: 0.595, best: 0.60, pointScale: 2).severity, MoveSeverity.none) // 1 pp
    }

    /// The review stamps the variant's `maxPoints` onto every evaluation it builds.
    func testReviewStampsVariantPointScale() {
        let config = GameConfig(variantID: "portes")
        let board = GameBoard(config: config)
        let record0 = GameRecord(startingPlayer: .white, variantID: "portes")
        record0.setUpInitialPosition(on: board)
        let dice = Dice(numberOfSides: 6)
        dice.set(6, 5)
        let legal = config.variant.legalMoves(on: board, color: .white, dice: dice)
        let move = legal[0].halfMoves.map { [$0.from.position, $0.to.position] }
        let record = GameRecord(startingPlayer: .white, aiColor: .black,
                                plies: [PlyRecord(die1: 6, die2: 5, halfMoves: move)], variantID: "portes")
        let analysis = [AnalysisEntry(plyNumber: 1, playedMove: move, playedScore: 0.55,
                                      bestMove: move, bestScore: 0.60, depth: 2)]
        let e = GameReview.cachedResult(record: record, analysis: analysis).evaluations[0]
        XCTAssertEqual(e.pointScale, 2)
        XCTAssertEqual(e.severity, .blunder)
    }

    func testForcedPlyIsNeverFlagged() {
        XCTAssertEqual(eval(played: 0.1, best: 0.9, hadChoice: false).severity, MoveSeverity.none)
    }

    func testSymbolsAndOrder() {
        XCTAssertNil(MoveSeverity.none.symbol)
        XCTAssertEqual(MoveSeverity.inaccuracy.symbol, "?!")
        XCTAssertEqual(MoveSeverity.mistake.symbol, "?")
        XCTAssertEqual(MoveSeverity.blunder.symbol, "??")
        XCTAssertTrue(MoveSeverity.blunder > .mistake && MoveSeverity.mistake > .inaccuracy)
    }

    // ── Accuracy + summary ──────────────────────────────────────────────────────

    func testMoveAccuracyFormula() {
        XCTAssertEqual(GameReviewSummary.moveAccuracy(lossPoints: 0), 100, accuracy: 1e-3)
        XCTAssertEqual(GameReviewSummary.moveAccuracy(lossPoints: 10),
                       103.1668 * exp(-0.4354) - 3.1669, accuracy: 1e-9)      // ≈ 63.6
        XCTAssertEqual(GameReviewSummary.moveAccuracy(lossPoints: 5),
                       103.1668 * exp(-0.2177) - 3.1669, accuracy: 1e-9)
        XCTAssertEqual(GameReviewSummary.moveAccuracy(lossPoints: 100), 0)    // clamped
        XCTAssertEqual(GameReviewSummary.moveAccuracy(lossPoints: -3), 100, accuracy: 1e-3)
        XCTAssertEqual(eval(played: 0.5, best: 0.6).accuracy,
                       GameReviewSummary.moveAccuracy(lossPoints: 10), accuracy: 1e-3)
    }

    func testSummaryCountsAccuracyLossAndLuck() {
        let evals = [
            eval(played: 0.60, best: 0.60, ply: 1),                          // none, 100
            eval(played: 0.57, best: 0.60, ply: 3),                          // inaccuracy 3 pp
            eval(played: 0.53, best: 0.60, ply: 5),                          // mistake 7 pp
            eval(played: 0.40, best: 0.60, ply: 7),                          // blunder 20 pp
            eval(played: 0.20, best: 0.60, hadChoice: false, ply: 9),        // forced: skipped
            eval(played: 0.10, best: 0.60, mover: .black, ply: 2),           // opponent
        ]
        let luck = [
            PlyLuck(plyNumber: 1, mover: .white, die1: 6, die2: 6, luck: 0.05),
            PlyLuck(plyNumber: 2, mover: .black, die1: 2, die2: 1, luck: -0.03),
            PlyLuck(plyNumber: 3, mover: .white, die1: 4, die2: 1, luck: -0.01),
        ]
        let result = GameReviewResult(evaluations: evals)
        let s = result.summary(for: .white, luck: luck)
        XCTAssertEqual(s.choicePlies, 4)
        XCTAssertEqual(s.inaccuracies, 1)
        XCTAssertEqual(s.mistakes, 1)
        XCTAssertEqual(s.blunders, 1)
        XCTAssertEqual(s.count(MoveSeverity.none), 1)
        let expected = [0.0, 3, 7, 20].map(GameReviewSummary.moveAccuracy(lossPoints:)).reduce(0, +) / 4
        XCTAssertEqual(try XCTUnwrap(s.accuracy), expected, accuracy: 1e-3)
        XCTAssertEqual(s.decisionLoss, 30, accuracy: 1e-3)   // choice plies only
        XCTAssertEqual(try XCTUnwrap(s.luck), 4, accuracy: 1e-6)            // +5 − 1 pp
        XCTAssertEqual(try XCTUnwrap(s.opponentLuck), -3, accuracy: 1e-6)
        // Without the luck pass the totals are unknown, the rest is unchanged.
        let noLuck = result.summary(for: .white)
        XCTAssertNil(noLuck.luck)
        XCTAssertNil(noLuck.opponentLuck)
        XCTAssertEqual(noLuck.blunders, 1)
        // A side with no choice plies has no accuracy.
        XCTAssertNil(GameReviewResult(evaluations: []).summary(for: .black).accuracy)
    }

    /// #259: the per-roll / per-move averages the review's live rating shows, from
    /// whatever luck and evaluations are in so far.
    func testPerRollAndPerMoveAveragesFromPartialLuck() {
        let evals = [
            eval(played: 0.60, best: 0.60, ply: 1),                          // 0 pp
            eval(played: 0.54, best: 0.60, ply: 3),                          // 6 pp
            eval(played: 0.20, best: 0.60, hadChoice: false, ply: 5),        // forced: skipped
        ]
        let result = GameReviewResult(evaluations: evals)
        // No luck yet: counts 0, no dice average; the moves average is already there.
        let none = result.summary(for: .white)
        XCTAssertEqual(none.luckRolls, 0)
        XCTAssertEqual(none.opponentLuckRolls, 0)
        XCTAssertNil(none.netLuckPerRoll)
        XCTAssertFalse(none.luckCoversBothSides)
        XCTAssertEqual(try XCTUnwrap(none.decisionLossPerMove), 3, accuracy: 1e-3)
        // Empty luck (the pass started, nothing in): still no dice average.
        XCTAssertNil(result.summary(for: .white, luck: []).netLuckPerRoll)
        // Only your rolls so far: an average, but not yet covering both sides.
        let mineOnly = [PlyLuck(plyNumber: 1, mover: .white, die1: 6, die2: 6, luck: 0.04),
                        PlyLuck(plyNumber: 3, mover: .white, die1: 2, die2: 1, luck: -0.02)]
        let partial = result.summary(for: .white, luck: mineOnly)
        XCTAssertEqual(partial.luckRolls, 2)
        XCTAssertEqual(partial.opponentLuckRolls, 0)
        XCTAssertFalse(partial.luckCoversBothSides)
        XCTAssertEqual(try XCTUnwrap(partial.netLuckPerRoll), 1, accuracy: 1e-6)   // (4 − 2) / 2
        // Both sides: your mean per roll minus the opponent's.
        let both = mineOnly + [PlyLuck(plyNumber: 2, mover: .black, die1: 5, die2: 5, luck: 0.06)]
        let s = result.summary(for: .white, luck: both)
        XCTAssertTrue(s.luckCoversBothSides)
        XCTAssertEqual(s.opponentLuckRolls, 1)
        XCTAssertEqual(try XCTUnwrap(s.netLuckPerRoll), 1 - 6, accuracy: 1e-6)
        // The opponent's view is the mirror image.
        XCTAssertEqual(try XCTUnwrap(result.summary(for: .black, luck: both).netLuckPerRoll),
                       5, accuracy: 1e-6)
        // A side with no choice plies has no moves average.
        XCTAssertNil(result.summary(for: .black, luck: both).decisionLossPerMove)
    }

    func testLuckPointsScaleWithVariant() {
        XCTAssertEqual(PlyLuck(plyNumber: 1, mover: .white, die1: 1, die2: 1, luck: 0.05).luckPoints,
                       5, accuracy: 1e-9)
        XCTAssertEqual(PlyLuck(plyNumber: 1, mover: .white, die1: 1, die2: 1, luck: 0.05,
                               pointScale: 2).luckPoints, 10, accuracy: 1e-9)
    }
}

// ── Persistence: AnalysisEntry.luck, aiLevel ────────────────────────────────────

final class ReviewInsightsPersistenceTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func json<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: encoder.encode(value)) as! [String: Any]
    }

    func testAnalysisEntryLuckRoundTripAndOmittedWhenNil() throws {
        let plain = AnalysisEntry(plyNumber: 1, playedMove: [[1, 4]], playedScore: 0.4,
                                  bestMove: [[1, 6]], bestScore: 0.8, depth: 2)
        XCTAssertNil(try json(plain)["luck"])
        XCTAssertEqual(try decoder.decode(AnalysisEntry.self, from: encoder.encode(plain)), plain)

        let lucky = plain.withLuck(-0.031)
        XCTAssertEqual(try json(lucky)["luck"] as? Double, -0.031)
        XCTAssertEqual(try decoder.decode(AnalysisEntry.self, from: encoder.encode(lucky)), lucky)
    }

    /// Literal pre-#231 files — v1 (no analysis) and v2 (analysis without luck, no
    /// aiLevel) — still load, with the new fields nil.
    func testOldV1AndV2FilesStillLoad() throws {
        let v1 = """
        {"schemaVersion":1,"name":"old","savedAt":"2026-01-01T00:00:00Z","aiColor":"B",
         "startingPlayer":"W","history":[{"die1":3,"die2":5,"halfMoves":[[1,4]]}]}
        """
        let s1 = try decoder.decode(GameSave.self, from: Data(v1.utf8))
        XCTAssertNil(s1.aiLevel)
        XCTAssertNil(s1.record.aiLevel)

        let v2 = """
        {"schemaVersion":2,"gameId":"6F1C2B4E-1111-4222-8333-944455556666","name":"g",
         "savedAt":"2026-01-01T00:00:00Z","startingPlayer":"W","aiColor":"B","outcome":"W",
         "history":[{"die1":3,"die2":5,"halfMoves":[[1,4]]}],"variant":"plakoto",
         "analysis":[{"plyNumber":1,"playedMove":[[1,4]],"playedScore":0.4,
                      "bestMove":[[1,6]],"bestScore":0.8,"depth":2}]}
        """
        let s2 = try decoder.decode(GameSave.self, from: Data(v2.utf8))
        XCTAssertNil(s2.aiLevel)
        XCTAssertEqual(s2.analysis?.count, 1)
        XCTAssertNil(s2.analysis?[0].luck)
        XCTAssertEqual(s2.schemaVersion, 2)
    }

    func testAILevelRoundTripsThroughSaveAndRecord() throws {
        var record = GameRecord(startingPlayer: .white, aiColor: .black,
                                plies: [PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4]])])
        record.aiLevel = 5
        let save = GameSave(record: record, name: "g", savedAt: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(save.aiLevel, 5)
        let obj = try json(save)
        XCTAssertEqual(obj["aiLevel"] as? Int, 5)
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)   // no version bump
        let decoded = try decoder.decode(GameSave.self, from: encoder.encode(save))
        XCTAssertEqual(decoded.aiLevel, 5)
        XCTAssertEqual(decoded.record, record)

        // Absent ⇒ omitted; out of range ⇒ clamped.
        XCTAssertNil(try json(GameSave(record: GameRecord(startingPlayer: .white), name: "h"))["aiLevel"])
        let wild = """
        {"schemaVersion":1,"name":"w","savedAt":"2026-01-01T00:00:00Z","startingPlayer":"W",
         "aiColor":"B","aiLevel":42,"history":[]}
        """
        XCTAssertEqual(try decoder.decode(GameSave.self, from: Data(wild.utf8)).aiLevel, 8)
    }

    func testOpponentCanErr() {
        // Two players: the opponent is human.
        XCTAssertTrue(GameRecord(startingPlayer: .white).opponentCanErr(of: .white))
        var vsAI = GameRecord(startingPlayer: .white, aiColor: .black)
        XCTAssertFalse(vsAI.opponentCanErr(of: .white))          // unknown level
        XCTAssertTrue(vsAI.opponentCanErr(of: .black))           // the computer's opponent = human
        vsAI.aiLevel = 8
        XCTAssertFalse(vsAI.opponentCanErr(of: .white))
        vsAI.aiLevel = 7
        XCTAssertTrue(vsAI.opponentCanErr(of: .white))
        vsAI.aiLevel = 1
        XCTAssertTrue(vsAI.opponentCanErr(of: .white))
        XCTAssertFalse(AILevel.canErr(level: nil))
        XCTAssertFalse(AILevel.canErr(level: 8))
        XCTAssertTrue(AILevel.canErr(level: 7))
    }

    // ── withLuck / cachedLuck / GameLogStore ────────────────────────────────────

    /// White moves, Black passes, White moves.
    private let record = GameRecord(startingPlayer: .white, aiColor: .black, plies: [
        PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4], [1, 6]]),
        PlyRecord(die1: 6, die2: 6, halfMoves: []),
        PlyRecord(die1: 2, die2: 1, halfMoves: [[4, 6], [6, 7]]),
    ])
    private var analysis: [AnalysisEntry] {
        [AnalysisEntry(plyNumber: 1, playedMove: [[1, 4], [1, 6]], playedScore: 0.5,
                       bestMove: [[1, 4], [1, 6]], bestScore: 0.5, depth: 2),
         AnalysisEntry(plyNumber: 3, playedMove: [[4, 6], [6, 7]], playedScore: 0.4,
                       bestMove: [[1, 3], [3, 4]], bestScore: 0.5, depth: 2)]
    }
    private let luck = [
        PlyLuck(plyNumber: 1, mover: .white, die1: 3, die2: 5, luck: 0.01, rolledValue: 0.5),
        PlyLuck(plyNumber: 2, mover: .black, die1: 6, die2: 6, luck: -0.2, rolledValue: 0.3),
        PlyLuck(plyNumber: 3, mover: .white, die1: 2, die2: 1, luck: -0.05, rolledValue: 0.45),
    ]

    func testWithLuckAttachesAndAddsPassEntries() throws {
        let merged = analysis.withLuck(luck, record: record)
        XCTAssertEqual(merged.map(\.plyNumber), [1, 2, 3])
        XCTAssertEqual(merged.map(\.luck), [0.01, -0.2, -0.05])
        XCTAssertTrue(merged[1].isPass)
        XCTAssertEqual(merged[1].playedScore, 0.3)
        // The pass entry never becomes a move evaluation.
        XCTAssertEqual(GameReview.cachedResult(record: record, analysis: merged).evaluations.map(\.plyNumber),
                       [1, 3])

        let rebuilt = try XCTUnwrap(GameReview.cachedLuck(record: record, analysis: merged))
        XCTAssertEqual(rebuilt.map(\.luck), [0.01, -0.2, -0.05])
        XCTAssertEqual(rebuilt.map(\.mover), [.white, .black, .white])
        XCTAssertEqual(rebuilt[1].rolledValue, 0.3)
        XCTAssertNil(rebuilt[0].rolledValue)
        // Incomplete luck ⇒ nil (run the pass).
        XCTAssertNil(GameReview.cachedLuck(record: record, analysis: analysis))
        XCTAssertNil(GameReview.cachedLuck(record: record,
                                           analysis: analysis.withLuck(Array(luck.prefix(2)), record: record)))
    }

    func testGameLogKeepsLuckAcrossReattachedAnalysis() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("luck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = GameLogStore(directory: dir)
        try log.append(GameSave(record: record, name: "g"))
        XCTAssertTrue(try log.attachAnalysis(analysis, forGameId: record.gameId))
        XCTAssertTrue(try log.attachLuck(luck, forGameId: record.gameId))
        XCTAssertNotNil(GameReview.cachedLuck(record: record, analysis: log.analysis(forGameId: record.gameId)!))

        // A later review re-attaches luck-free entries (one deepened): luck survives.
        var fresh = analysis
        fresh[1] = AnalysisEntry(plyNumber: 3, playedMove: [[4, 6], [6, 7]], playedScore: 0.38,
                                 bestMove: [[1, 3], [3, 4]], bestScore: 0.5, depth: 3)
        XCTAssertTrue(try log.attachAnalysis(fresh, forGameId: record.gameId))
        let stored = try XCTUnwrap(log.analysis(forGameId: record.gameId))
        XCTAssertEqual(stored.map(\.plyNumber), [1, 2, 3])
        XCTAssertEqual(stored[2].depth, 3)
        XCTAssertEqual(stored.map(\.luck), [0.01, -0.2, -0.05])
        XCTAssertFalse(try log.attachLuck(luck, forGameId: UUID()))
    }
}

// ── GameSession records the computer's level ────────────────────────────────────

@MainActor
final class GameSessionAILevelTests: XCTestCase {
    func testLevelRecordedOnlyWithAComputerSide() {
        XCTAssertEqual(GameSession(aiColor: .black, aiLevel: 5).record.aiLevel, 5)
        XCTAssertNil(GameSession(aiColor: nil, aiLevel: 5).record.aiLevel)
        XCTAssertNil(GameSession(aiColor: .black).record.aiLevel)
        XCTAssertEqual(GameSession(aiColor: .black, aiLevel: 99).record.aiLevel, 8)
    }

    func testNoteAILevelKeepsTheLowest() {
        let s = GameSession(aiColor: .black, aiLevel: 6)
        s.noteAILevel(8)
        XCTAssertEqual(s.record.aiLevel, 6)
        s.noteAILevel(3)
        XCTAssertEqual(s.record.aiLevel, 3)
        let twoPlayer = GameSession()
        twoPlayer.noteAILevel(3)
        XCTAssertNil(twoPlayer.record.aiLevel)
    }

    func testResumeCarriesLevel() {
        let s = GameSession(aiColor: .black, aiLevel: 4)
        let resumed = GameSession.resume(from: s.snapshot(name: "x"))
        XCTAssertEqual(resumed.record.aiLevel, 4)
    }
}

// ── Dice luck with the fixture model ────────────────────────────────────────────

final class DiceLuckModelTests: XCTestCase {
    private static var agent: Agent!
    private static var config: GameConfig!

    override class func setUp() {
        super.setUp()
        let fixtures = try! FixtureLoader.load()
        config = gameConfig(fixtures.config)
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else { fatalError("PlakotoValue.mlpackage not found — run ios/scripts/convert_to_coreml.py") }
        let compiled = try! MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        agent = Agent(model: try! MLModel(contentsOf: compiled, configuration: cfg),
                      encoder: BoardEncoder(config: config))
    }

    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A deterministic full game (first legal move each ply).
    private static func playOut(seed: UInt64, maxPlies: Int = 600) -> GameRecord {
        let board = GameBoard(config: config)
        board.initializeBoard()
        let dice = Dice(numberOfSides: config.dieSides)
        var rng = LCG(seed)
        var plies: [PlyRecord] = []
        var mover: Color = .white
        while plies.count < maxPlies {
            let d1 = Int.random(in: 1...6, using: &rng), d2 = Int.random(in: 1...6, using: &rng)
            dice.set(d1, d2)
            let legal = PossibleMoves(board: board, color: mover, dice: dice).findMoves()
            let chosen = legal.first.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } } ?? []
            plies.append(PlyRecord(die1: d1, die2: d2, halfMoves: chosen))
            for pair in chosen where pair.count == 2 {
                board.points[pair[0]].pop()
                board.points[pair[1]].push(mover)
            }
            if board.hasWon(mover) { break }
            mover = mover.opponent
        }
        return GameRecord(startingPlayer: .white, aiColor: .black, plies: plies)
    }

    /// The board before ply `n` (1-based) of `record`.
    private static func board(before n: Int, of record: GameRecord) -> (GameBoard, Color) {
        let board = GameBoard(config: config)
        record.setUpInitialPosition(on: board)
        var mover = record.startingPlayer
        for ply in record.plies.prefix(n - 1) {
            for p in ply.halfMoves { board.points[p[0]].pop(); board.points[p[1]].push(mover) }
            mover = mover.opponent
        }
        return (board, mover)
    }

    /// Σ over all 36 rolls (21 distinct, weighted) of luck is zero, the weights sum
    /// to one, and the per-roll values equal the handicap dice's (same 1-ply rule).
    func testLuckOverAllRollsSumsToZero() throws {
        let record = Self.playOut(seed: 11, maxPlies: 30)
        let (board, mover) = Self.board(before: 21, of: record)
        let before = board.captureStacks()
        let rolls = try DiceLuck.rollValues(agent: Self.agent, board: board, mover: mover)
        XCTAssertEqual(board.captureStacks(), before, "rating rolls must not move checkers")
        XCTAssertEqual(rolls.count, 21)
        XCTAssertEqual(rolls.reduce(0) { $0 + $1.probability }, 1, accuracy: 1e-12)
        let weighted = rolls.reduce(0.0) { acc, r in
            acc + r.probability * DiceLuck.luck(d1: r.d2, d2: r.d1, in: rolls)!   // either order
        }
        XCTAssertEqual(weighted, 0, accuracy: 1e-9)
        XCTAssertTrue(rolls.contains { abs(DiceLuck.luck(d1: $0.d1, d2: $0.d2, in: rolls)!) > 1e-4 },
                      "a real position has lucky and unlucky rolls")

        let handicap = try HandicapDice.rollValues(agent: Self.agent, board: board, color: mover)
        for (r, h) in zip(rolls, handicap) { XCTAssertEqual(r.value, Double(h), accuracy: 1e-6) }
    }

    /// The pass covers every ply, both sides (passes included), streams in order,
    /// and agrees with the per-position computation. Prints its cost.
    func testAnalyzeLuckCoversEveryPlyAndReportsCost() throws {
        let record = Self.playOut(seed: 3)
        // Predictions it needs: per ply, Σ over the 21 rolls of the legal-move count
        // (one 1-ply afterstate each), or one static eval for a moveless roll.
        var predictions = 0
        let dice = Dice(numberOfSides: 6)
        for n in 1...record.plies.count {
            let (board, mover) = Self.board(before: n, of: record)
            var passCounted = false
            for r in DiceLuck.distinctRolls() {
                dice.set(r.d1, r.d2)
                let count = Self.config.variant.legalMoves(on: board, color: mover, dice: dice).count
                if count > 0 { predictions += count } else if !passCounted { predictions += 1; passCounted = true }
            }
        }

        let streamed = LockedCount()
        let start = Date()
        let luck = GameReview.analyzeLuck(record: record, agent: Self.agent, onLuck: { _ in streamed.add() })
        let seconds = Date().timeIntervalSince(start)
        print("[luck pass] \(record.plies.count) plies, \(predictions) predictions, "
              + String(format: "%.2f s (%.1f µs/prediction)", seconds,
                       seconds * 1e6 / Double(max(1, predictions))))

        XCTAssertEqual(luck.map(\.plyNumber), Array(1...record.plies.count))
        XCTAssertEqual(streamed.value, record.plies.count)
        XCTAssertEqual(luck.first?.mover, .white)
        XCTAssertEqual(luck.dropFirst().first?.mover, .black)
        XCTAssertTrue(luck.allSatisfy { abs($0.luck) <= 1 })

        // One ply checked against the direct per-position computation.
        let k = min(15, record.plies.count)
        let (board, mover) = Self.board(before: k, of: record)
        let rolls = try DiceLuck.rollValues(agent: Self.agent, board: board, mover: mover)
        let ply = record.plies[k - 1]
        XCTAssertEqual(luck[k - 1].luck, DiceLuck.luck(d1: ply.die1, d2: ply.die2, in: rolls)!, accuracy: 1e-9)

        // Stored, passes become luck-only entries.
        let entries = [AnalysisEntry]().withLuck(luck, record: record)
        XCTAssertEqual(entries.count, record.plies.filter(\.halfMoves.isEmpty).count)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
