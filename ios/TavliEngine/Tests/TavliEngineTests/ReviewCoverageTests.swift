import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// The post-game review must cover the **whole** game: every ply that moved gets an
/// evaluation — for every variant and however the game was played: hops recorded through
/// the move builder, resumed from a save mid-game, later games of a match / Full Tavli
/// sequence, and seeded with in-play analysis (#146).
///
/// The user-facing bug: a review that opened with only the plies the in-play analysis
/// had captured — "it only started at move 11" after a resumed game (nothing before the
/// resume was captured), and "it left out the last few moves" (plies committed before
/// their background ranking finished, e.g. quick bear-offs, were never captured). The
/// review's own pass fills those in only later, so the saved analysis itself must be
/// complete.
@MainActor
final class ReviewCoverageTests: XCTestCase {

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

    private static var agents: [String: Agent] = [:]
    private func agent(_ variant: any GameVariant) throws -> Agent {
        if let a = Self.agents[variant.id] { return a }
        let a = try VariantAgentParity.agent(for: variant)
        Self.agents[variant.id] = a
        return a
    }

    private static let variants: [any GameVariant] = [
        GameVariants.plakoto, StandardPlakotoVariant(), FevgaVariant(), PortesVariant(),
    ]

    // MARK: - Driving games

    /// Play the side on move's turn through the UI path: a random legal move entered hop
    /// by hop via the move builder (route choices resolved), as a player taps it.
    private func playTurn(_ s: GameSession, rng: inout LCG) {
        let options = s.moveBuilder.activeMoves
        guard !options.isEmpty else { XCTFail("no active moves"); return }
        let chosen = options[Int.random(in: 0..<options.count, using: &rng)]
        let before = s.record.plies.count
        var steps = 0
        while s.phase == .picking || s.phase == .moving, s.record.plies.count == before, steps < 50 {
            steps += 1
            if let rc = s.routeChoice, let via = rc.routes.keys.sorted().first {
                s.chooseRoute(via: via); continue
            }
            guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else {
                XCTFail("no legal play order for \(chosen)"); return
            }
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    private func roll(_ s: GameSession, rng: inout LCG) {
        s.setDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
    }

    /// A two-player session played to the end (or `maxPlies`) with seeded dice.
    private func driveTwoPlayer(_ s: GameSession, rng: inout LCG, maxPlies: Int = 600) {
        var guardSteps = 0
        while s.record.plies.count < maxPlies, guardSteps < 20_000 {
            guardSteps += 1
            switch s.phase {
            case .gameOver: return
            case .awaitingRoll: roll(s, rng: &rng)
            case .picking, .moving: playTurn(s, rng: &rng)
            default: return
            }
        }
    }

    /// You (White) vs the computer (Black, 1-ply, animations off), with seeded dice for
    /// your turns. You commit **at once** — never waiting for the in-play ranking — and
    /// the computer commits as soon as its 1-ply search returns, so most rankings are
    /// still running at commit time.
    private func driveVsAI(_ s: GameSession, rng: inout LCG, maxPlies: Int,
                           awaitRanking: Bool = false, timeout: TimeInterval = 300) async {
        s.start()
        let deadline = Date().addingTimeInterval(timeout)
        while s.record.plies.count < maxPlies {
            if Date() > deadline { XCTFail("stalled at \(s.record.plies.count), \(s.phase)"); return }
            switch s.phase {
            case .gameOver: return
            case .awaitingRoll:
                if s.currentPlayer == s.aiColor { try? await Task.sleep(nanoseconds: 2_000_000) }
                else { roll(s, rng: &rng) }
            case .picking, .moving:
                if awaitRanking { await s.awaitInPlayAnalysisForTesting() }
                playTurn(s, rng: &rng)
            case .aiThinking, .animating:
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    /// Let the background rankings of the plies just played finish (they run detached
    /// at utility priority), so their captures land.
    private func settle(_ s: GameSession) async {
        await s.awaitInPlayAnalysisForTesting()
        await s.awaitPendingCapturesForTesting()
    }

    private func movedPlies(_ record: GameRecord) -> [Int] {
        record.plies.indices.filter { !record.plies[$0].halfMoves.isEmpty }.map { $0 + 1 }
    }

    private func assertCovers(_ result: GameReviewResult, _ record: GameRecord, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let got = Set(result.evaluations.map(\.plyNumber))
        let missing = movedPlies(record).filter { !got.contains($0) }
        XCTAssert(missing.isEmpty,
                  "\(what): \(missing.count) of \(movedPlies(record).count) moved plies have no evaluation: \(missing.prefix(12))",
                  file: file, line: line)
    }

    // MARK: - The review's own analysis covers every ply

    /// Every variant, games entered hop by hop through the move builder: the review
    /// evaluates every ply that moved, both sides, to the last one.
    func testReviewEvaluatesEveryPlyInEveryVariant() throws {
        for variant in Self.variants {
            let agent = try agent(variant)
            for seed in UInt64(1)...4 {
                var rng = LCG(seed &* 31 &+ UInt64(variant.id.count))
                let s = GameSession(startingPlayer: seed % 2 == 0 ? .white : .black,
                                    config: GameConfig(variant: variant), agent: nil, aiColor: nil,
                                    animationTimings: .off)
                driveTwoPlayer(s, rng: &rng)
                XCTAssertTrue(s.isTerminal, "\(variant.id) seed \(seed) did not finish")
                let result = GameReview.analyzeProgressive(
                    record: s.record, agent: agent, humanColor: .white, depths: [1],
                    includeOpponent: true)
                assertCovers(result, s.record, "\(variant.id) seed \(seed)")
                // Every one of your choice plies is a stop of the "My moves" filter.
                for e in result.evaluations where e.mover == .white {
                    let legal = legalCount(e, variant: variant)
                    XCTAssertEqual(e.hadChoice, legal > 1, "\(variant.id) ply \(e.plyNumber)")
                }
            }
        }
    }

    private func legalCount(_ e: PlyEvaluation, variant: any GameVariant) -> Int {
        let config = GameConfig(variant: variant)
        let board = GameBoard(config: config)
        board.restoreStacks(e.boardStacks)
        let dice = Dice(numberOfSides: config.dieSides)
        dice.set(e.die1, e.die2)
        return variant.legalMoves(on: board, color: e.mover, dice: dice).count
    }

    /// A game resumed from its save mid-way, and the later games of a match played on
    /// in one session (`newGame`): each game's review covers it from ply 1.
    func testResumedAndFollowUpGamesAreCoveredFromTheFirstPly() throws {
        for variant in Self.variants {
            let agent = try agent(variant)
            var rng = LCG(UInt64(variant.id.count) &* 977)
            let config = GameConfig(variant: variant)
            let first = GameSession(startingPlayer: .white, config: config, aiColor: nil,
                                    animationTimings: .off)
            driveTwoPlayer(first, rng: &rng, maxPlies: 20)
            let resumed = GameSession.resume(from: first.snapshot(name: "mid"),
                                             animationTimings: .off)
            XCTAssertEqual(resumed.record.plies, first.record.plies)
            driveTwoPlayer(resumed, rng: &rng)
            assertCovers(GameReview.analyzeProgressive(record: resumed.record, agent: agent,
                                                       humanColor: .white, depths: [1],
                                                       includeOpponent: true),
                         resumed.record, "\(variant.id) resumed")

            // Game 2 of a match in the same session, the other side starting.
            resumed.newGame(startingPlayer: .black)
            driveTwoPlayer(resumed, rng: &rng)
            assertCovers(GameReview.analyzeProgressive(record: resumed.record, agent: agent,
                                                       humanColor: .white, depths: [1],
                                                       includeOpponent: true),
                         resumed.record, "\(variant.id) game 2")
        }
    }

    // MARK: - In-play analysis covers every ply (#146)

    /// Committing before the in-play ranking finished used to drop that ply from the
    /// in-play analysis — the review then opened without it ("left out the last few
    /// moves"). Every ply, both sides, must be captured, and each capture must equal a
    /// from-scratch 2-ply review of that ply.
    func testInPlayAnalysisCapturesPliesCommittedBeforeTheirRanking() async throws {
        for variant in [GameVariants.plakoto, StandardPlakotoVariant()] as [any GameVariant] {
            let agent = try agent(variant)
            var rng = LCG(UInt64(variant.id.count) &* 13)
            let s = GameSession(startingPlayer: .white, config: GameConfig(variant: variant),
                                agent: agent, aiColor: .black,
                                searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                                inPlayAnalysis: true)
            await driveVsAI(s, rng: &rng, maxPlies: 600)
            XCTAssertTrue(s.isTerminal, "\(variant.id) game did not finish")
            await settle(s)

            let record = s.record
            let cached = GameReview.cachedResult(record: record, analysis: s.inPlayAnalysis)
            assertCovers(cached, record, "\(variant.id) in-play analysis")

            // Captures are exact: identical to a from-scratch 2-ply review (checked on the
            // opening plies, to keep the test quick).
            var opening = record
            opening.plies = Array(record.plies.prefix(12))
            let fresh = GameReview.analyzeProgressive(record: opening, agent: agent, humanColor: .white,
                                                      depths: [2], includeOpponent: true)
            let freshByPly = Dictionary(fresh.evaluations.map { ($0.plyNumber, $0) },
                                        uniquingKeysWith: { a, _ in a })
            for e in cached.evaluations {
                guard let f = freshByPly[e.plyNumber] else { continue }
                XCTAssertEqual(Double(e.playedScore), Double(f.playedScore), accuracy: 1e-4,
                               "\(variant.id) ply \(e.plyNumber) played score")
                XCTAssertEqual(Double(e.bestScore), Double(f.bestScore), accuracy: 1e-4,
                               "\(variant.id) ply \(e.plyNumber) best score")
            }
        }
    }

    /// A game resumed from its autosave used to lose everything the in-play analysis had
    /// captured before the resume — the review then opened at the first ply played after
    /// it ("it only started at move 11"). The save carries the analysis and the resumed
    /// session keeps it.
    func testResumeKeepsInPlayAnalysisFromBeforeTheSave() async throws {
        for variant in [GameVariants.plakoto, StandardPlakotoVariant()] as [any GameVariant] {
            let agent = try agent(variant)
            var rng = LCG(UInt64(variant.id.count) &* 7)
            let config = GameConfig(variant: variant)
            let s = GameSession(startingPlayer: .white, config: config, agent: agent, aiColor: .black,
                                searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                                inPlayAnalysis: true)
            // Wait for your rankings, so the analysis before the save is not empty for
            // the other reason (quick commits, covered above).
            await driveVsAI(s, rng: &rng, maxPlies: 20, awaitRanking: true)
            await settle(s)
            let beforeResume = s.inPlayAnalysis
            XCTAssertFalse(beforeResume.isEmpty)

            // Round-trip through the wire format, as the autosave does.
            let data = try JSONEncoder().encode(s.snapshot(name: "auto"))
            let save = try JSONDecoder().decode(GameSave.self, from: data)
            let r = GameSession.resume(from: save, agent: agent, searchConfig: SearchConfig(maxDepth: 1),
                                       animationTimings: .off, inPlayAnalysis: true)
            XCTAssertEqual(r.inPlayAnalysis, beforeResume, "\(variant.id): analysis lost on resume")
            XCTAssertEqual(save.analysis ?? [], beforeResume, "\(variant.id): the save carries the analysis")

            await driveVsAI(r, rng: &rng, maxPlies: 50)   // the game's end is covered above
            await settle(r)
            assertCovers(GameReview.cachedResult(record: r.record, analysis: r.inPlayAnalysis),
                         r.record, "\(variant.id) resumed in-play analysis")
        }
    }

    // MARK: - Cancellation

    /// A review closed mid-analysis stops: a cancelled `analyzeProgressive` returns at
    /// once with what it has (here: the seed), instead of running its 2-/3-ply passes on
    /// in the background and competing with the next review for the CPU.
    func testCancelledProgressiveAnalysisStopsAndKeepsTheSeed() async throws {
        let variant = GameVariants.plakoto
        let agent = try agent(variant)
        var rng = LCG(42)
        let s = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        driveTwoPlayer(s, rng: &rng, maxPlies: 30)
        let record = s.record
        let seed = [AnalysisEntry](reviewResult: GameReview.analyzeProgressive(
            record: record, agent: agent, humanColor: .white, depths: [1], includeOpponent: true))
            .filter { $0.plyNumber <= 10 }
        let task = Task.detached { () -> (Int, Int) in
            withUnsafeCurrentTask { $0?.cancel() }
            let counter = Counter()
            let r = GameReview.analyzeProgressive(record: record, agent: agent, humanColor: .white,
                                                  includeOpponent: true, seed: seed,
                                                  onEvaluation: { _ in counter.increment() })
            return (r.evaluations.count, counter.value)
        }
        let (count, emitted) = await task.value
        XCTAssertEqual(emitted, 0, "a cancelled analysis scores nothing more")
        XCTAssertEqual(count, seed.count, "a cancelled analysis returns its seed")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

