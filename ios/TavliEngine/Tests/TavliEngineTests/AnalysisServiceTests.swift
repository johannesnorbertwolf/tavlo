import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// The background analysis service (#243): one job per game, fed by the session as the
/// game is played, scoring both sides on its own boards (1-ply → luck → 2-ply → 3-ply),
/// paused while the computer thinks, cancellable, and saved as it goes so a resumed
/// game, a reopened review or a relaunch continues instead of restarting.
@MainActor
final class AnalysisServiceTests: XCTestCase {

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
    private func agent(_ variant: any GameVariant = GameVariants.plakoto) throws -> Agent {
        if let a = Self.agents[variant.id] { return a }
        let a = try VariantAgentParity.agent(for: variant)
        Self.agents[variant.id] = a
        return a
    }

    /// A memory-only service (unless stores are given) that analyses with the fixture
    /// models, to 2-ply by default so the suite stays quick.
    private func makeService(maxDepth: Int = 2, gameLog: GameLogStore? = nil,
                             saveStore: SaveStore? = nil) -> AnalysisService {
        let service = AnalysisService(gameLog: gameLog, saveStore: saveStore) { [weak self] config in
            try? self?.agent(config.variant)
        }
        service.maxDepth = maxDepth
        service.persistDelay = 0
        return service
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-service-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Wait (sleep-polling) until the service has nothing left; fails on timeout.
    private func settle(_ service: AnalysisService, timeout: TimeInterval = 240,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while service.hasPendingWork {
            if Date() > deadline { XCTFail("analysis did not finish", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        service.flush()
    }

    // MARK: - Driving games

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

    /// You (White, seeded dice) vs the computer (1-ply, animations off) until game
    /// over or `maxPlies`; the computer moves off the main actor.
    private func driveVsAI(_ s: GameSession, rng: inout LCG, maxPlies: Int,
                           timeout: TimeInterval = 300) async {
        s.start()
        let deadline = Date().addingTimeInterval(timeout)
        while s.record.plies.count < maxPlies {
            if Date() > deadline { XCTFail("stalled at \(s.record.plies.count), \(s.phase)"); return }
            switch s.phase {
            case .gameOver: return
            case .awaitingRoll:
                if s.currentPlayer == s.aiColor { try? await Task.sleep(nanoseconds: 2_000_000) }
                else { s.setDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng)) }
            case .picking, .moving:
                playTurn(s, rng: &rng)
            case .aiThinking, .animating:
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    /// A two-player game with seeded dice, to game over or `maxPlies`.
    private func driveTwoPlayer(_ s: GameSession, rng: inout LCG, maxPlies: Int) {
        var guardSteps = 0
        while s.record.plies.count < maxPlies, guardSteps < 20_000 {
            guardSteps += 1
            switch s.phase {
            case .gameOver: return
            case .awaitingRoll: s.setDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
            case .picking, .moving: playTurn(s, rng: &rng)
            default: return
            }
        }
    }

    private func movedPlies(_ record: GameRecord) -> [Int] {
        record.plies.indices.filter { !record.plies[$0].halfMoves.isEmpty }.map { $0 + 1 }
    }

    /// Every moved ply evaluated (choice plies at ≥ 2-ply when `minDepth` is 2) and the
    /// luck complete.
    private func assertComplete(_ job: GameAnalysisJob, minDepth: Int = 2, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let evals = Dictionary(job.result.evaluations.map { ($0.plyNumber, $0) }, uniquingKeysWith: { a, _ in a })
        for ply in movedPlies(job.record) {
            guard let e = evals[ply] else { XCTFail("\(what): ply \(ply) not evaluated", file: file, line: line); continue }
            if e.hadChoice { XCTAssertGreaterThanOrEqual(e.depth, minDepth, "\(what): ply \(ply)", file: file, line: line) }
        }
        XCTAssertEqual(job.luck?.count, job.record.plies.count, "\(what): luck incomplete", file: file, line: line)
        XCTAssertTrue(job.isComplete, "\(what): job not complete", file: file, line: line)
    }

    // MARK: - Analysing a game as it is played

    /// The core contract: a game played with the service attached is analysed as it
    /// goes — every ply of both sides at 2-ply with luck — and the results are exactly
    /// what a from-scratch review (`analyzeProgressive`) and luck pass give.
    func testAnalysesTheGameAsItIsPlayed() async throws {
        let agent = try agent()
        let service = makeService()
        var rng = LCG(5)
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off)
        s.analysisService = service
        await driveVsAI(s, rng: &rng, maxPlies: 24)
        // Analysis kept up during play: something already landed before the game stopped.
        XCTAssertFalse(s.inPlayAnalysis.isEmpty, "nothing analysed during play")
        await settle(service)
        let job = try XCTUnwrap(s.analysisJob)
        assertComplete(job, "vs computer")

        let fresh = GameReview.analyzeProgressive(record: s.record, agent: agent, humanColor: .white,
                                                  depths: [1, 2], includeOpponent: true)
        let mine = Dictionary(job.result.evaluations.map { ($0.plyNumber, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(mine.count, fresh.evaluations.count)
        for f in fresh.evaluations {
            guard let m = mine[f.plyNumber] else { XCTFail("ply \(f.plyNumber) missing"); continue }
            XCTAssertEqual(m.depth, f.depth, "ply \(f.plyNumber) depth")
            XCTAssertEqual(m.bestMove, f.bestMove, "ply \(f.plyNumber) best move")
            XCTAssertEqual(Double(m.playedScore), Double(f.playedScore), accuracy: 1e-5)
            XCTAssertEqual(Double(m.bestScore), Double(f.bestScore), accuracy: 1e-5)
        }
        let luck = GameReview.analyzeLuck(record: s.record, agent: agent)
        XCTAssertEqual(job.luck?.map(\.plyNumber), luck.map(\.plyNumber))
        for (a, b) in zip(job.luck ?? [], luck) { XCTAssertEqual(a.luck, b.luck, accuracy: 1e-6) }
        // The summary (accuracy, mistakes, luck) is ready from the job alone.
        let summary = job.result.summary(for: .white, luck: job.luck)
        XCTAssertNotNil(summary.luck)
        XCTAssertNotNil(summary.accuracy)
    }

    /// The 3-ply refinement matches the review's last pass: the human's close calls are
    /// re-ranked at 3-ply (the computer's plies stop at 2-ply), to the same scores.
    func testRefinesCloseCallsLikeTheReview() async throws {
        let agent = try agent()
        var rng = LCG(11)
        let two = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        driveTwoPlayer(two, rng: &rng, maxPlies: 10)
        // Treat it as a game vs the computer (Black), so only White's plies refine.
        let record = GameRecord(startingPlayer: .white, aiColor: .black, plies: two.record.plies)
        let service = makeService(maxDepth: 3)
        let job = service.job(for: record, agent: agent)
        await settle(service, timeout: 600)
        assertComplete(job, "refined")

        let fresh = GameReview.analyzeProgressive(record: record, agent: agent, humanColor: .white,
                                                  includeOpponent: true)
        let mine = Dictionary(job.result.evaluations.map { ($0.plyNumber, $0) }, uniquingKeysWith: { a, _ in a })
        for f in fresh.evaluations {
            guard let m = mine[f.plyNumber] else { XCTFail("ply \(f.plyNumber) missing"); continue }
            XCTAssertEqual(m.depth, f.depth, "ply \(f.plyNumber) depth")
            XCTAssertEqual(Double(m.bestScore), Double(f.bestScore), accuracy: 1e-5)
            XCTAssertEqual(Double(m.playedScore), Double(f.playedScore), accuracy: 1e-5)
            if m.mover == .black { XCTAssertLessThanOrEqual(m.depth, 2, "the computer's plies stop at 2-ply") }
        }
    }

    /// Every variant (equity scaling included) and a handicap game, two-player (the
    /// service makes the model itself) and complete.
    func testEveryVariantAndHandicapGame() async throws {
        let service = makeService()
        let variants: [any GameVariant] = [GameVariants.plakoto, StandardPlakotoVariant(),
                                           FevgaVariant(), PortesVariant()]
        for (i, variant) in variants.enumerated() {
            _ = try agent(variant)
            var rng = LCG(UInt64(100 + i))
            let s = GameSession(startingPlayer: .white, config: GameConfig(variant: variant),
                                aiColor: nil, animationTimings: .off)
            s.analysisService = service
            driveTwoPlayer(s, rng: &rng, maxPlies: 16)
            await settle(service)
            let job = try XCTUnwrap(s.analysisJob)
            assertComplete(job, variant.id)
            XCTAssertEqual(job.result.evaluations.first?.pointScale, variant.maxPoints)
            XCTAssertEqual(job.refineColors, [.white, .black], "two players: both sides refine")
        }
        // Handicap (#148): a head start + extra checker rides on the replay config.
        let setup = HandicapSetup(white: HandicapItems(headStart: 2), black: HandicapItems())
        let agent = try agent()
        var rng = LCG(7)
        let h = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: setup)
        h.analysisService = service
        await driveVsAI(h, rng: &rng, maxPlies: 14)
        await settle(service)
        let job = try XCTUnwrap(h.analysisJob)
        assertComplete(job, "handicap")
        let fresh = GameReview.analyzeProgressive(record: h.record, agent: agent, humanColor: .white,
                                                  depths: [1, 2], includeOpponent: true)
        XCTAssertEqual(job.result.evaluations.map(\.bestScore), fresh.evaluations.map(\.bestScore))
    }

    // MARK: - Priority and cancellation

    /// The session holds the gate while the computer thinks and releases it after.
    func testSessionHoldsTheGateWhileTheComputerThinks() async throws {
        let agent = try agent()
        let service = makeService()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 2), animationTimings: .off)
        s.analysisService = service
        s.start()
        XCTAssertEqual(s.phase, .aiThinking)
        XCTAssertTrue(service.gate.isHeld, "computer thinking: analysis paused")
        let deadline = Date().addingTimeInterval(60)
        while s.phase == .aiThinking, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNotEqual(s.phase, .aiThinking)
        XCTAssertFalse(service.gate.isHeld, "the computer moved: analysis resumes")
    }

    /// While the gate is held no prediction runs: the unit in flight waits at its next
    /// prediction, and continues (to completion) once released.
    func testHeldGatePausesTheWork() async throws {
        let agent = try agent()
        var rng = LCG(3)
        let two = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        driveTwoPlayer(two, rng: &rng, maxPlies: 8)
        let service = makeService()
        let holder = NSObject()
        service.gate.setHeld(true, by: holder)
        let job = service.job(for: two.record, agent: agent)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(service.unitsRun, 0, "nothing lands while the gate is held")
        XCTAssertTrue(service.isBusy, "one unit waits at the gate")
        XCTAssertGreaterThanOrEqual(service.gate.pauseCount, 1)
        XCTAssertTrue(job.result.evaluations.isEmpty)
        service.gate.setHeld(false, by: holder)
        await settle(service)
        assertComplete(job, "after release")
    }

    /// A holder that goes away releases its hold (a session dropped mid-search).
    func testDroppedHolderReleasesTheGate() {
        let gate = AnalysisGate()
        var holder: NSObject? = NSObject()
        gate.setHeld(true, by: holder!)
        XCTAssertTrue(gate.isHeld)
        holder = nil
        XCTAssertFalse(gate.isHeld)
    }

    /// Removing a job cancels its unit at once — also while it waits at a held gate.
    func testRemovingAJobCancelsItsWork() async throws {
        let agent = try agent()
        let service = makeService()
        let holder = NSObject()
        service.gate.setHeld(true, by: holder)
        let record = GameRecord(startingPlayer: .white, aiColor: .black,
                                plies: [PlyRecord(die1: 3, die2: 1, halfMoves: [[1, 4], [1, 2]])])
        _ = service.job(for: record, agent: agent)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(service.isBusy)
        service.remove(gameId: record.gameId)
        let deadline = Date().addingTimeInterval(5)
        while service.isBusy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(service.isBusy, "the cancelled unit returned without the gate opening")
        XCTAssertNil(service.existingJob(for: record.gameId))
        service.gate.setHeld(false, by: holder)
    }

    /// An open review's game goes first among equally urgent work.
    func testFocusedJobGoesFirst() async throws {
        let agent = try agent()
        let service = makeService()
        service.isSuspended = true
        let a = GameRecord(startingPlayer: .white, aiColor: .black,
                           plies: [PlyRecord(die1: 3, die2: 1, halfMoves: [[1, 4], [1, 2]])])
        let b = GameRecord(startingPlayer: .white, aiColor: .black,
                           plies: [PlyRecord(die1: 6, die2: 5, halfMoves: [[1, 7], [1, 6]])])
        _ = service.job(for: a, agent: agent)
        service.job(for: b, agent: agent).focused = true
        let holder = NSObject()
        service.gate.setHeld(true, by: holder)   // freeze the first unit in flight
        service.isSuspended = false
        XCTAssertEqual(service.runningGameId, b.gameId)
        service.gate.setHeld(false, by: holder)
        await settle(service)
    }

    // MARK: - No interference with the live game

    /// A step-back drops the analysis of the undone plies; the re-played line is
    /// analysed afresh and nothing refers to a ply that no longer exists.
    func testStepBackDropsTheUndonePlies() async throws {
        let agent = try agent()
        let service = makeService()
        var rng = LCG(21)
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off)
        s.analysisService = service
        await driveVsAI(s, rng: &rng, maxPlies: 10)
        await settle(service)
        let deadline = Date().addingTimeInterval(30)
        while !(s.phase == .awaitingRoll && s.currentPlayer != s.aiColor) {
            if case .gameOver = s.phase { throw XCTSkip("game ended before a step-back point") }
            if Date() > deadline { XCTFail("never reached a human turn"); return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard s.canUndoLastDecision else { throw XCTSkip("nothing to step back to") }
        let before = s.record.plies.count
        s.undoLastDecision()
        XCTAssertLessThan(s.record.plies.count, before)
        XCTAssertLessThanOrEqual(s.inPlayAnalysis.map(\.plyNumber).max() ?? 0, s.record.plies.count)
        // Undo still works as before: the board replays to the record.
        XCTAssertEqual(s.phase, .picking)
        await driveVsAI(s, rng: &rng, maxPlies: 16)
        await settle(service)
        let job = try XCTUnwrap(s.analysisJob)
        assertComplete(job, "after step-back")
        XCTAssertEqual(GameReview.cachedResult(record: s.record, analysis: s.inPlayAnalysis).evaluations.count,
                       movedPlies(s.record).count, "saved entries all match the replayed line")
    }

    /// Resigning mid-search releases the gate and keeps the analysis of the plies played.
    func testResignReleasesTheGate() async throws {
        let agent = try agent()
        let service = makeService()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off)
        s.analysisService = service
        s.start()
        XCTAssertTrue(service.gate.isHeld)
        s.surrender()
        XCTAssertFalse(service.gate.isHeld)
        XCTAssertTrue(s.history.isEmpty)
    }

    /// A new game gets a new job; the finished one keeps going on its own.
    func testNewGameStartsANewJobAndTheOldOneFinishes() async throws {
        let agent = try agent()
        let service = makeService()
        var rng = LCG(9)
        let s = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        s.analysisService = service
        driveTwoPlayer(s, rng: &rng, maxPlies: 8)
        let old = try XCTUnwrap(s.analysisJob)
        _ = agent
        s.newGame(startingPlayer: .white)
        XCTAssertNotEqual(s.analysisJob?.gameId, old.gameId)
        XCTAssertTrue(s.inPlayAnalysis.isEmpty)
        await settle(service)
        assertComplete(old, "the previous game")
    }

    // MARK: - Incremental persistence

    /// Results land in the autosave as they come (game in progress), and a "relaunch"
    /// (a fresh service, the game resumed from that autosave) continues from them: no
    /// unit is recomputed.
    func testSavesIntoTheAutosaveAndResumesFromIt() async throws {
        let agent = try agent()
        let store = SaveStore(directory: tempDir())
        let service = makeService(saveStore: store)
        service.isSuspended = true   // play first, analyse later
        var rng = LCG(31)
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off)
        s.analysisService = service
        await driveVsAI(s, rng: &rng, maxPlies: 12)
        try store.writeAutosave(s.snapshot(name: "auto"))
        XCTAssertNil(store.loadAutosave()?.analysis, "nothing analysed yet")
        service.isSuspended = false
        await settle(service)
        let saved = try XCTUnwrap(store.loadAutosave()?.analysis)
        XCTAssertEqual(saved, s.inPlayAnalysis, "the autosave holds every landed result")
        XCTAssertNotNil(GameReview.cachedLuck(record: s.record, analysis: saved), "luck saved too")

        // Relaunch: a new service, the game resumed from the autosave.
        let relaunched = makeService(saveStore: store)
        let save = try XCTUnwrap(store.loadAutosave())
        let r = GameSession.resume(from: save, agent: agent, searchConfig: SearchConfig(maxDepth: 1),
                                   animationTimings: .off)
        r.analysisService = relaunched
        XCTAssertEqual(r.record.gameId, save.gameId, "a resumed game keeps its id")
        await settle(relaunched)
        XCTAssertEqual(relaunched.unitsRun, 0, "resumed from the saved depth, nothing redone")
        XCTAssertEqual(r.inPlayAnalysis, saved)

        // Quit half-way through: the next launch finishes the rest **into the autosave**
        // (the resumed game keeps its id, so the service finds its slot), without the app
        // writing it again.
        var half = save
        half.analysis = saved.filter { $0.plyNumber <= 6 }
        try store.writeAutosave(half)
        let third = makeService(saveStore: store)
        let r3 = GameSession.resume(from: try XCTUnwrap(store.loadAutosave()), agent: agent,
                                    searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off)
        r3.analysisService = third
        await settle(third)
        XCTAssertGreaterThan(third.unitsRun, 0)
        XCTAssertEqual(store.loadAutosave()?.analysis, saved, "the rest landed in the autosave")
    }

    /// Mid-way (some plies done) a resume continues: only the missing work runs.
    func testResumeMidAnalysisContinues() async throws {
        let agent = try agent()
        var rng = LCG(41)
        let two = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        driveTwoPlayer(two, rng: &rng, maxPlies: 12)
        let full = makeService()
        let complete = full.job(for: two.record, agent: agent)
        await settle(full)
        let fullUnits = full.unitsRun
        // Half the entries saved (as if the app quit mid-way).
        let half = complete.entries.filter { $0.plyNumber <= 6 }
        let again = makeService()
        let job = again.job(for: two.record, agent: agent, seed: half)
        await settle(again)
        assertComplete(job, "continued")
        XCTAssertLessThan(again.unitsRun, fullUnits, "the saved half was not redone")
        XCTAssertEqual(job.entries, complete.entries)
    }

    /// A finished game's results go into its game-log entry; a relaunch's review job
    /// (seeded from the log) is complete without recomputing.
    func testSavesIntoTheGameLogAfterTheGame() async throws {
        let agent = try agent()
        let log = GameLogStore(directory: tempDir())
        // 1-ply + luck: this is about where results are written, kept quick for a whole game.
        let service = makeService(maxDepth: 1, gameLog: log)
        service.isSuspended = true
        var rng = LCG(51)
        let s = GameSession(startingPlayer: .white, aiColor: nil, animationTimings: .off)
        s.analysisService = service
        driveTwoPlayer(s, rng: &rng, maxPlies: 600)
        XCTAssertTrue(s.isTerminal)
        // The app's game-over write, with whatever had landed (nothing here).
        try log.append(GameSave(record: s.record, name: "g", analysis: s.inPlayAnalysis.isEmpty ? nil : s.inPlayAnalysis))
        service.isSuspended = false
        await settle(service, timeout: 600)
        let saved = try XCTUnwrap(log.analysis(forGameId: s.record.gameId))
        XCTAssertEqual(GameReview.cachedResult(record: s.record, analysis: saved).evaluations.count,
                       movedPlies(s.record).count)
        XCTAssertNotNil(GameReview.cachedLuck(record: s.record, analysis: saved))
        _ = agent

        let relaunched = makeService(maxDepth: 1, gameLog: log)
        let job = relaunched.job(for: s.record)
        await settle(relaunched)
        XCTAssertEqual(relaunched.unitsRun, 0)
        assertComplete(job, minDepth: 1, "from the log")
    }

    /// `AnalysisEntry.merge` never loses depth or luck.
    func testMergeKeepsDepthAndLuck() {
        let a = AnalysisEntry(plyNumber: 1, playedMove: [[1, 4]], playedScore: 0.4, bestMove: [[1, 5]],
                              bestScore: 0.5, depth: 3)
        let b = AnalysisEntry(plyNumber: 1, playedMove: [[1, 4]], playedScore: 0.41, bestMove: [[1, 5]],
                              bestScore: 0.52, depth: 2, luck: 0.03)
        let merged = AnalysisEntry.merge([a], [b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].depth, 3)
        XCTAssertEqual(merged[0].luck, 0.03)
        let other = AnalysisEntry(plyNumber: 1, playedMove: [[1, 3]], playedScore: 0.4, bestMove: [[1, 5]],
                                  bestScore: 0.5, depth: 1)
        XCTAssertEqual(AnalysisEntry.merge([a], [other]), [other], "a replayed line replaces")
    }
}
