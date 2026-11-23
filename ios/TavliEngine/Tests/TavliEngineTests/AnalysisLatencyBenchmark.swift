import Foundation
import XCTest
@testable import TavliEngine

/// How long the computer thinks with the background analysis (#243) running, versus
/// with it off — the #155 concern. Opt-in (`TAVLI_BENCH=1 swift test --filter
/// AnalysisLatencyBenchmark`), as it takes minutes; prints the numbers.
///
/// Three runs of the same games (full-strength 2-ply computer, animations off, you play
/// random moves at once):
/// - **off**: no analysis at all;
/// - **service**: the session attached to a service that always has work (a backlog
///   game being refined at 3-ply), so the gate is the only thing between them;
/// - **ungated**: the same backlog analysed by a service the session does not hold —
///   analysis competing with the search, as the #146 in-play analysis did.
@MainActor
final class AnalysisLatencyBenchmark: XCTestCase {

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

    private enum Mode: String { case off, service, ungated }

    func testComputerMoveLatencyWithAndWithoutAnalysis() async throws {
        guard ProcessInfo.processInfo.environment["TAVLI_BENCH"] == "1" else {
            throw XCTSkip("set TAVLI_BENCH=1 to run the latency benchmark")
        }
        let agent = try VariantAgentParity.agent(for: GameVariants.plakoto)
        let turns = Int(ProcessInfo.processInfo.environment["TAVLI_BENCH_TURNS"] ?? "") ?? 40

        // A long backlog game for the analysis to chew on throughout.
        var rng = LCG(99)
        let backlog = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        while !backlog.isTerminal && backlog.record.plies.count < 120 {
            switch backlog.phase {
            case .awaitingRoll:
                backlog.setDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
            case .picking, .moving:
                guard let m = backlog.moveBuilder.activeMoves.first else { break }
                play(m, on: backlog)
            default: break
            }
        }

        var report: [String] = []
        for mode in [Mode.off, .service, .ungated, .off] {
            let service = AnalysisService { _ in agent }
            service.maxDepth = 3
            if mode != .off { service.job(for: backlog.record, agent: agent) }
            let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                                animationTimings: .off)
            if mode == .service { s.analysisService = service }
            var dice = LCG(7)
            var times: [Double] = []
            var started: Date?
            s.start()
            let deadline = Date().addingTimeInterval(900)
            while times.count < turns && !s.isTerminal && Date() < deadline {
                switch s.phase {
                case .aiThinking:
                    if started == nil { started = Date() }
                    try await Task.sleep(nanoseconds: 200_000)
                case .awaitingRoll where s.currentPlayer == .white:
                    if let t = started { times.append(Date().timeIntervalSince(t)); started = nil }
                    s.setDice(Int.random(in: 1...6, using: &dice), Int.random(in: 1...6, using: &dice))
                case .picking, .moving:
                    if let t = started { times.append(Date().timeIntervalSince(t)); started = nil }
                    if let m = s.moveBuilder.activeMoves.first { play(m, on: s) }
                default:
                    if let t = started { times.append(Date().timeIntervalSince(t)); started = nil }
                    try await Task.sleep(nanoseconds: 200_000)
                }
            }
            let sorted = times.sorted()
            let mean = times.reduce(0, +) / Double(max(1, times.count))
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
            report.append(String(format: "%-8@ turns %3d  mean %6.0f ms  median %6.0f ms  p90 %6.0f ms  analysis units %d  gate pauses %d",
                                 mode.rawValue, times.count, mean * 1000, median * 1000, p90 * 1000,
                                 service.unitsRun, service.gate.pauseCount))
            service.remove(gameId: backlog.record.gameId)
            if let id = s.analysisJob?.gameId { service.remove(gameId: id) }
            while service.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        print("── Computer move latency (#243) ──\n" + report.joined(separator: "\n"))
    }

    /// The same comparison on a **fixed** set of positions (so the three runs search
    /// exactly the same moves): the computer's full-strength search (`getBestMove`, 2-ply)
    /// timed position by position, with no analysis, with the analysis behind the gate
    /// (held for each search, as the session does) and with it ungated.
    func testSearchLatencyOnFixedPositions() async throws {
        guard ProcessInfo.processInfo.environment["TAVLI_BENCH"] == "1" else {
            throw XCTSkip("set TAVLI_BENCH=1 to run the latency benchmark")
        }
        let agent = try VariantAgentParity.agent(for: GameVariants.plakoto)
        var rng = LCG(1234)
        let game = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        var positions: [(stacks: [[Color]], d1: Int, d2: Int, mover: Color)] = []
        while !game.isTerminal && positions.count < 60 {
            switch game.phase {
            case .awaitingRoll:
                game.setDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
            case .picking, .moving:
                let moves = game.moveBuilder.activeMoves
                if moves.count > 1 {
                    positions.append((game.game.board.captureStacks(), game.game.dice.die1.value,
                                      game.game.dice.die2.value, game.currentPlayer))
                }
                play(moves[Int.random(in: 0..<moves.count, using: &rng)], on: game)
            default: break
            }
        }
        var backlogRng = LCG(99)
        let backlog = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        while !backlog.isTerminal && backlog.record.plies.count < 120 {
            switch backlog.phase {
            case .awaitingRoll:
                backlog.setDice(Int.random(in: 1...6, using: &backlogRng), Int.random(in: 1...6, using: &backlogRng))
            case .picking, .moving:
                if let m = backlog.moveBuilder.activeMoves.first { play(m, on: backlog) }
            default: break
            }
        }

        let search = SearchConfig.standard
        var report: [String] = []
        for mode in [Mode.off, .service, .ungated, .off, .service, .ungated] {
            let service = AnalysisService { _ in agent }
            service.maxDepth = 3
            if mode != .off { service.job(for: backlog.record, agent: agent) }
            try await Task.sleep(nanoseconds: 200_000_000)   // let the analysis get going
            let holder = NSObject()
            var times: [Double] = []
            for p in positions {
                if mode == .service { service.gate.setHeld(true, by: holder) }
                let t0 = Date()
                _ = await Task.detached(priority: .userInitiated) { () -> Int? in
                    let board = GameBoard(config: .standard)
                    board.restoreStacks(p.stacks)
                    let dice = Dice()
                    dice.set(p.d1, p.d2)
                    let moves = board.variant.legalMoves(on: board, color: p.mover, dice: dice)
                    return try? agent.getBestMove(board, moves, color: p.mover, timeBudget: search.timeBudget,
                                                  beamThreshold: search.beamThreshold,
                                                  relativeCutoff: search.relativeCutoff,
                                                  maxBranch: search.maxBranch, maxDepth: search.maxDepth)?.index
                }.value
                times.append(Date().timeIntervalSince(t0))
                if mode == .service { service.gate.setHeld(false, by: holder) }
                // The human's turn: give the analysis a moment, as in play.
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let sorted = times.sorted()
            let total = times.reduce(0, +)
            report.append(String(format: "%-8@ positions %3d  total %6.2f s  mean %5.0f ms  median %5.0f ms  p90 %5.0f ms  max %5.0f ms  units %d  pauses %d",
                                 mode.rawValue, times.count, total, total / Double(times.count) * 1000,
                                 sorted[sorted.count / 2] * 1000, sorted[sorted.count * 9 / 10] * 1000,
                                 sorted.last! * 1000, service.unitsRun, service.gate.pauseCount))
            service.remove(gameId: backlog.record.gameId)
            while service.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        print("── Search latency on fixed positions (#243) ──\n" + report.joined(separator: "\n"))
    }

    private func play(_ m: Move, on s: GameSession) {
        let before = s.record.plies.count
        var steps = 0
        while (s.phase == .picking || s.phase == .moving) && s.record.plies.count == before && steps < 50 {
            steps += 1
            if let rc = s.routeChoice, let via = rc.routes.keys.sorted().first { s.chooseRoute(via: via); continue }
            guard let h = nextOfferedHalf(s.moveBuilder, of: m) else { return }
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }
}
