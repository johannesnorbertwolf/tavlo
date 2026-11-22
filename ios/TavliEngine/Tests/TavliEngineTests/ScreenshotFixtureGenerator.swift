import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Generates the App Store screenshot fixture (#184): a realistic house-Plakoto game,
/// you (White) vs the full-strength computer, plus its complete review analysis (the
/// app's `analyzeProgressive` at 1→2-ply for both sides + `analyzeLuck`), written out as Swift
/// source for `ios/TavliApp/TavliApp/Views/ScreenshotFixture.swift`.
///
/// Skipped unless `TAVLO_FIXTURE_MODEL_DIR` (a directory holding `PlakotoValue.mlpackage`,
/// e.g. the app's `Resources`) and `TAVLO_FIXTURE_OUT` (the Swift file to write) are set:
///
///     cd ios/TavliEngine
///     TAVLO_FIXTURE_MODEL_DIR=$PWD/../TavliApp/TavliApp/Resources \
///     TAVLO_FIXTURE_OUT=$PWD/../TavliApp/TavliApp/Views/ScreenshotFixture.swift \
///       swift test -c release -Xswiftc -enable-testing --filter ScreenshotFixtureGenerator
///
/// "You" play 1-ply with some selection noise (σ 0.05 by default, `TAVLO_FIXTURE_SIGMA`: a
/// decent club player); the computer plays 2-ply. Seeds (from `TAVLO_FIXTURE_SEED`, default
/// 1) are tried in order until the game reads like a real one: 50–130 plies, accuracy
/// 84–94 %, one to three mistakes/blunders (at least one blunder). A cheap 1-ply review
/// screens each game first; only promising ones get the full 1→2-ply analysis.
final class ScreenshotFixtureGenerator: XCTestCase {
    func testGenerateScreenshotFixture() throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelDir = env["TAVLO_FIXTURE_MODEL_DIR"], let out = env["TAVLO_FIXTURE_OUT"] else {
            throw XCTSkip("set TAVLO_FIXTURE_MODEL_DIR and TAVLO_FIXTURE_OUT to generate the fixture")
        }
        let config = GameConfig.standard
        // CPU only: far faster than the ANE for one-board-at-a-time predictions.
        let url = URL(fileURLWithPath: modelDir).appendingPathComponent("PlakotoValue.mlpackage")
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let agent = Agent(model: try MLModel(contentsOf: try MLModel.compileModel(at: url), configuration: cfg),
                          config: config)
        let sigma = Float(env["TAVLO_FIXTURE_SIGMA"].flatMap(Double.init) ?? 0.05)
        let firstSeed = UInt64(env["TAVLO_FIXTURE_SEED"].flatMap(Int.init) ?? 1)
        let maxErrors = env["TAVLO_FIXTURE_MAX_ERRORS"].flatMap(Int.init) ?? 3
        for seed in firstSeed..<(firstSeed + 200) {
            let record = try play(seed: seed, sigma: sigma, agent: agent, config: config)
            guard record.outcome != nil, (50...130).contains(record.plies.count) else {
                log("seed \(seed): outcome \(String(describing: record.outcome)) plies \(record.plies.count) — skip")
                continue
            }
            let quick = GameReview.analyzeProgressive(record: record, agent: agent, humanColor: .white,
                                                      depths: [1]).summary(for: .white)
            let errors = quick.mistakes + quick.blunders
            guard (70...97).contains(quick.accuracy ?? 0), (1...6).contains(errors) else {
                log("seed \(seed): 1-ply accuracy \(quick.accuracy ?? 0) errors \(errors) — skip")
                continue
            }
            // 1- then 2-ply, both sides — the in-play analysis depth. The 3-ply pass can take
            // hours on some positions; the screenshot review shows the fixture as is.
            let result = GameReview.analyzeProgressive(record: record, agent: agent, humanColor: .white,
                                                       depths: [1, 2], includeOpponent: true)
            let s = result.summary(for: .white)
            let acc = s.accuracy ?? 0
            log("seed \(seed): plies \(record.plies.count) accuracy \(acc) mistakes \(s.mistakes) blunders \(s.blunders) inacc \(s.inaccuracies)")
            guard (84...94).contains(acc), s.blunders >= 1, (1...maxErrors).contains(s.mistakes + s.blunders)
            else { continue }
            let luck = GameReview.analyzeLuck(record: record, agent: agent)
            let entries = [AnalysisEntry](reviewResult: result).withLuck(luck, record: record)
            let play = try playPositions(first: record, sigma: sigma, agent: agent, config: config)
            try source(seed: seed, record: record, entries: entries, result: result, play: play)
                .write(toFile: out, atomically: true, encoding: .utf8)
            log("wrote \(out)")
            return
        }
        XCTFail("no seed met the criteria")
    }

    /// The mid-game scenes' game: the review game if it has two good positions, else the
    /// first such game from seeds 1000 on. A good position is one of your turns (White)
    /// away from the opening and the bear-off, with both sides pinning (≥ 3 pinned points)
    /// and a live game (your win chance 40–62 %). Returns the game and two such plies at
    /// least 8 plies apart (light and dark scenes).
    private func playPositions(first: GameRecord, sigma: Float, agent: Agent,
                               config: GameConfig) throws -> (record: GameRecord, seed: UInt64?, plies: [Int]) {
        var candidate = first
        var seed: UInt64? = nil
        for next in UInt64(1000)..<1200 {
            var good: [Int] = []
            let board = GameBoard(config: config)
            candidate.setUpInitialPosition(on: board)
            var mover = candidate.startingPlayer
            for (i, ply) in candidate.plies.enumerated() {
                if mover == .white, !ply.halfMoves.isEmpty, i >= 12, i < candidate.plies.count - 16 {
                    let pinned = board.points.filter { Set($0.pieces).count > 1 }
                    let byWhite = pinned.filter { $0.pieces.last == .white }.count
                    let p = try agent.winProbability(board, color: .white)
                    if pinned.count >= 3, byWhite >= 1, byWhite < pinned.count, (0.40...0.62).contains(p),
                       good.last.map({ i + 1 - $0 >= 8 }) ?? true {
                        good.append(i + 1)
                    }
                }
                for pair in ply.halfMoves {
                    config.variant.applyHalfMove(
                        HalfMove(from: board.points[pair[0]], to: board.points[pair[1]], color: mover), on: board)
                }
                mover = mover.opponent
            }
            log("play scene: seed \(seed.map(String.init) ?? "review") good plies \(good)")
            if good.count >= 2 { return (candidate, seed, Array(good.prefix(2))) }
            seed = next
            candidate = try play(seed: next, sigma: sigma, agent: agent, config: config)
        }
        XCTFail("no game with two good mid-game positions")
        return (first, nil, [1, 1])
    }

    private func play(seed: UInt64, sigma: Float, agent: Agent, config: GameConfig) throws -> GameRecord {
        var rng = SplitMix(state: seed)
        let variant = config.variant
        let board = GameBoard(config: config)
        variant.setUpInitialPosition(on: board)
        let dice = Dice(numberOfSides: config.dieSides)
        var record = GameRecord(startingPlayer: .white, aiColor: .black, variantID: variant.id, aiLevel: 8)
        var mover = Color.white
        for _ in 0..<200 {
            let d1 = Int(rng.next() % 6) + 1, d2 = Int(rng.next() % 6) + 1
            dice.set(d1, d2)
            let legal = variant.legalMoves(on: board, color: mover, dice: dice)
            var pairs: [[Int]] = []
            if !legal.isEmpty {
                let pick = mover == .white
                    ? try agent.getBestMove(board, legal, color: mover, timeBudget: 60, maxDepth: 1,
                                            selectionNoise: sigma, noiseSeed: rng.next())
                    : try agent.getBestMove(board, legal, color: mover, timeBudget: 60, maxDepth: 2)
                let move = pick?.move ?? legal[0]
                pairs = move.halfMoves.map { [$0.from.position, $0.to.position] }
                variant.apply(move, on: board)
            }
            record.plies.append(PlyRecord(die1: d1, die2: d2, halfMoves: pairs))
            if variant.isOver(on: board) {
                record.outcome = variant.winner(on: board)
                break
            }
            mover = mover.opponent
        }
        return record
    }

    /// The fixture as Swift literals (no JSON parsing in the app).
    private func source(seed: UInt64, record: GameRecord, entries: [AnalysisEntry],
                        result: GameReviewResult,
                        play: (record: GameRecord, seed: UInt64?, plies: [Int])) -> String {
        func pairs(_ p: [[Int]]) -> String { "[" + p.map { "[\($0[0]), \($0[1])]" }.joined(separator: ", ") + "]" }
        func num(_ d: Double) -> String { String(format: "%.6f", d) }
        func plyList(_ plies: [PlyRecord]) -> String {
            plies.map { "        PlyRecord(die1: \($0.die1), die2: \($0.die2), halfMoves: \(pairs($0.halfMoves))),\n" }
                .joined()
        }
        // Your plies sorted by severity (worst first), for picking the review/drill card.
        let worst = result.evaluations.filter { $0.mover == .white && $0.severity >= .mistake }
            .sorted { $0.decisionLoss > $1.decisionLoss }.map(\.plyNumber)
        let playSource = play.seed.map { "seed \($0)" } ?? "the review game"
        var s = """
        #if DEBUG
        // GENERATED by ios/TavliEngine/Tests/TavliEngineTests/ScreenshotFixtureGenerator.swift
        // (seed \(seed)) — do not edit by hand. A realistic house-Plakoto game, you (White) vs
        // the full-strength computer, with its complete review analysis (#184, App Store
        // screenshots). Your mistakes/blunders, worst first: plies \(worst).
        import TavliEngine

        enum ScreenshotFixture {
            static let worstPlies: [Int] = \(worst)
            /// Whether you (White) won the review game.
            static let youWon = \(record.outcome == .white)

            /// The mid-game scenes' game (\(playSource)) and two of your turns in it with
            /// both sides pinning and the game still open: the light scene's and the dark one's.
            static let gamePly = \(play.plies[0])
            static let darkGamePly = \(play.plies[1])
            static let playPlies: [PlyRecord] = [

        """
        s += plyList(play.record.plies)
        s += "    ]\n\n    /// The review game.\n    static let plies: [PlyRecord] = [\n"
        s += plyList(record.plies)
        s += "    ]\n\n    static let analysis: [AnalysisEntry] = [\n"
        for e in entries {
            let luck = e.luck.map { ", luck: \(num($0))" } ?? ""
            s += "        AnalysisEntry(plyNumber: \(e.plyNumber), playedMove: \(pairs(e.playedMove)), "
                + "playedScore: \(num(e.playedScore)), bestMove: \(pairs(e.bestMove)), "
                + "bestScore: \(num(e.bestScore)), depth: \(e.depth)\(luck)),\n"
        }
        s += "    ]\n}\n#endif\n"
        return s
    }

    /// Progress on stderr (unbuffered, unlike `print` into a pipe).
    private func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
