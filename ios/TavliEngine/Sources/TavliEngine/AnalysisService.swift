import Foundation

// Background game analysis (#243): one job per game, owned by an app-level service
// rather than by the review screen. A job follows its game as it is played (fed by
// `GameSession`), scores every ply of both sides on isolated board copies off the
// main actor — 1-ply, dice luck, 2-ply, then 3-ply for the close calls — keeps
// running when the review is closed, and its results are written back as they land
// (the autosave while the game runs, the game log once it is over). The review and
// the drill only read a job.

// MARK: - Gate

/// The pause switch that keeps background analysis below the computer's own search
/// (#243, the #155 concern). Anything the player waits for — the computer thinking,
/// a hint, weighted dice being prepared, a drill attempt being graded — holds the
/// gate; while any holder is alive and holding, every analysis prediction blocks
/// before it starts (`Agent.throttled(by:)`), so the search has the CPU and the model
/// to itself. Holders are kept weakly: a holder that goes away releases its hold.
///
/// The worker waits on a condition, re-checked every 250 ms (a dropped holder never
/// signals), so a paused analysis costs no CPU.
public final class AnalysisGate: @unchecked Sendable {
    private let condition = NSCondition()
    private struct Holder { weak var object: AnyObject? }
    private var holders: [ObjectIdentifier: Holder] = [:]
    private var waits = 0

    public init() {}

    /// Hold (`true`) or release (`false`) the gate on behalf of `holder`.
    public func setHeld(_ held: Bool, by holder: AnyObject) {
        condition.lock()
        holders[ObjectIdentifier(holder)] = held ? Holder(object: holder) : nil
        condition.broadcast()
        condition.unlock()
    }

    /// Whether any live holder holds the gate.
    public var isHeld: Bool {
        condition.lock()
        defer { condition.unlock() }
        return heldLocked()
    }

    /// How many predictions have had to wait for the gate (testing / diagnostics).
    public var pauseCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return waits
    }

    private func heldLocked() -> Bool {
        holders = holders.filter { $0.value.object != nil }
        return !holders.isEmpty
    }

    /// Block while the gate is held; throw `CancellationError` once `token` is
    /// cancelled (also while waiting).
    func checkpoint(_ token: AnalysisToken) throws {
        condition.lock()
        defer { condition.unlock() }
        var counted = false
        while true {
            if token.isCancelled { throw CancellationError() }
            guard heldLocked() else { return }
            if !counted { counted = true; waits += 1 }
            _ = condition.wait(until: Date().addingTimeInterval(0.25))
        }
    }

    /// Wake every waiting prediction (a token was cancelled).
    func wake() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

/// Cancellation flag of one unit of analysis work.
final class AnalysisToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let gate: AnalysisGate

    init(gate: AnalysisGate) { self.gate = gate }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        gate.wake()
    }
}

// MARK: - Units of work

/// One ply's pre-roll position, captured by replaying the record (model-free).
struct AnalysisPosition: Sendable, Equatable {
    let plyNumber: Int
    let mover: Color
    let die1: Int
    let die2: Int
    let halfMoves: [[Int]]
    let stacks: [[Color]]

    var isPass: Bool { halfMoves.isEmpty }

    func matches(_ ply: PlyRecord) -> Bool {
        ply.die1 == die1 && ply.die2 == die2 && ply.halfMoves == halfMoves
    }
}

/// One unit of background work: rank (a slice of) a ply's legal moves at `depth`, or
/// rate its dice. Small enough that new plies and focused games get their turn soon.
enum AnalysisUnit: Sendable {
    /// Score the legal moves in `range` (`nil` = all) of `position` at `depth`.
    case rank(AnalysisPosition, depth: Int, range: Range<Int>?)
    /// The dice luck of `position` (`DiceLuck`).
    case luck(AnalysisPosition)

    var position: AnalysisPosition {
        switch self {
        case .rank(let p, _, _), .luck(let p): return p
        }
    }

    /// The tier of the work (the scheduling order): 0 = 1-ply, 1 = luck, 2 = 2-ply,
    /// 3 = 3-ply refinement.
    var tier: Int {
        switch self {
        case .luck: return 1
        case .rank(_, let depth, _): return depth <= 1 ? 0 : depth == 2 ? 2 : 3
        }
    }
}

/// A finished unit's result.
enum AnalysisOutput: Sendable {
    /// Scores for the moves in `range`; `movePairs` lists **every** legal move (the
    /// generator's order) and `playedIndex` the recorded move among them.
    case rank(movePairs: [[[Int]]], playedIndex: Int?, range: Range<Int>, scores: [Float])
    case luck(luck: Double, rolledValue: Double)
    /// Could not be scored (no legal move matches the record, a model error): skipped.
    case failed
    /// Cancelled before it finished (the ply was undone, the job dropped).
    case cancelled
}

/// The off-main computation of one unit, on an isolated board rebuilt from the
/// position's stacks. `agent` is the throttled copy, so every prediction honours the
/// gate and the token.
enum AnalysisWork {
    static func run(_ unit: AnalysisUnit, agent: Agent, config: GameConfig,
                    search: SearchConfig, token: AnalysisToken) -> AnalysisOutput {
        if token.isCancelled { return .cancelled }
        let p = unit.position
        let board = GameBoard(config: config)
        for (i, pieces) in p.stacks.enumerated() where i < board.points.count {
            board.setPoint(i, pieces: pieces)
        }
        do {
            switch unit {
            case .luck:
                let rolls = try DiceLuck.rollValues(agent: agent, board: board, mover: p.mover)
                guard let luck = DiceLuck.luck(d1: p.die1, d2: p.die2, in: rolls) else { return .failed }
                return .luck(luck: luck, rolledValue: luck + DiceLuck.expectedValue(rolls))
            case .rank(_, let depth, let range):
                let dice = Dice(numberOfSides: config.dieSides)
                dice.set(p.die1, p.die2)
                let legal = config.variant.legalMoves(on: board, color: p.mover, dice: dice)
                guard !legal.isEmpty else { return .failed }
                let all = 0..<legal.count
                let r = (range ?? all).clamped(to: all)
                guard !r.isEmpty else { return .failed }
                let played = GameReview.matchRecorded(p.halfMoves, legal, on: board, mover: p.mover)
                // Each move's score is independent of the others it is ranked with, so a
                // slice scores exactly as it would inside the full ranking.
                let scores = try agent.evaluateMovesNply(
                    board, Array(legal[r]), color: p.mover, depth: depth,
                    beamThreshold: search.beamThreshold, relativeCutoff: search.relativeCutoff,
                    maxBranch: search.maxBranch, deadline: nil)
                let pairs = legal.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } }
                return .rank(movePairs: pairs, playedIndex: played, range: r, scores: scores)
            }
        } catch {
            return token.isCancelled ? .cancelled : .failed
        }
    }
}

// MARK: - Job

/// The analysis of one game (#243): its plies' positions, the evaluations and dice
/// luck found so far, and what is left to do. Fed by `update(record:)` as the game is
/// played (or once, for a finished game) and filled by its `AnalysisService`. The
/// review and the drill read `result` / `luck` and observe `revision`.
@MainActor
public final class GameAnalysisJob: ObservableObject {
    public let gameId: UUID
    /// The game as last seen.
    public private(set) var record: GameRecord
    /// The rules the game is replayed under (variant + any handicap, #148).
    public let config: GameConfig
    /// The sides whose close calls are refined to 3-ply: the human vs the computer,
    /// both players otherwise (the computer's plies stop at 2-ply, as in the review).
    public let refineColors: Set<Color>
    /// Bumped whenever results land (or the game changes), for observers.
    @Published public private(set) var revision = 0
    /// A review of this game is open: its work goes first.
    public var focused = false {
        didSet { if focused != oldValue { onChange?() } }
    }

    let agent: Agent?
    let order: Int
    /// The deepest pass to run (the service's `maxDepth`).
    var maxDepth = 3
    var onChange: (() -> Void)?
    /// A unit of this job is being computed.
    var isRunning = false

    private(set) var positions: [AnalysisPosition] = []
    private var board: GameBoard
    private var ended = false
    private var evaluations: [Int: PlyEvaluation] = [:]
    private var lucks: [Int: PlyLuck] = [:]
    private var partials: [Int: Partial] = [:]
    private var failed: Set<Int> = []
    private var seeds: [Int: AnalysisEntry] = [:]

    /// A ranking assembled slice by slice (2-ply in chunks, 3-ply one move at a time).
    private struct Partial {
        let depth: Int
        let pairs: [[[Int]]]
        let playedIndex: Int?
        var scores: [Float?]
    }

    init(record: GameRecord, config: GameConfig, agent: Agent?, refineColors: Set<Color>,
         order: Int, seed: [AnalysisEntry]) {
        self.gameId = record.gameId
        self.record = record
        self.config = config
        self.agent = agent
        self.refineColors = refineColors
        self.order = order
        self.board = Self.startBoard(record: record, config: config)
        for e in seed { seeds[e.plyNumber] = e }
        appendPositions()
        applySeeds()
    }

    private static func startBoard(record: GameRecord, config: GameConfig) -> GameBoard {
        let board = GameBoard(config: config)
        record.setUpInitialPosition(on: board)
        return board
    }

    // ── Following the game ────────────────────────────────────────────────────

    /// Follow `record`: new plies are queued; plies that changed (a step-back) drop
    /// their results. Cheap when nothing changed.
    public func update(record: GameRecord) {
        guard record.gameId == gameId else { return }
        let plies = record.plies
        var common = 0
        while common < positions.count, common < plies.count, positions[common].matches(plies[common]) {
            common += 1
        }
        var changed = false
        if common < positions.count {
            truncate(to: common)
            changed = true
        }
        self.record = record
        if positions.count < plies.count && !ended {
            appendPositions()
            applySeeds()
            changed = true
        }
        if changed { bump() }
    }

    /// Add saved analysis (deeper results win, luck is kept).
    public func seed(_ entries: [AnalysisEntry]) {
        guard !entries.isEmpty else { return }
        for e in entries { seeds[e.plyNumber] = e }
        applySeeds()
        bump()
    }

    private func appendPositions() {
        let variant = config.variant
        let upper = board.boardSize + 1
        while positions.count < record.plies.count && !ended {
            let index = positions.count
            let ply = record.plies[index]
            let mover = index % 2 == 0 ? record.startingPlayer : record.startingPlayer.opponent
            positions.append(AnalysisPosition(plyNumber: index + 1, mover: mover,
                                              die1: ply.die1, die2: ply.die2,
                                              halfMoves: ply.halfMoves, stacks: board.captureStacks()))
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                variant.applyHalfMove(HalfMove(from: board.points[from], to: board.points[to], color: mover),
                                      on: board)
            }
            if variant.isOver(on: board) { ended = true }
        }
    }

    private func truncate(to count: Int) {
        positions.removeSubrange(count...)
        evaluations = evaluations.filter { $0.key <= count }
        lucks = lucks.filter { $0.key <= count }
        partials = partials.filter { $0.key <= count }
        failed = failed.filter { $0 / 10 <= count }
        seeds = seeds.filter { $0.key <= count }   // later seeds described the undone line
        ended = false
        // Rebuild the replay board at the end of the kept plies.
        board = Self.startBoard(record: record, config: config)
        let variant = config.variant
        let upper = board.boardSize + 1
        for p in positions {
            for pair in p.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                variant.applyHalfMove(HalfMove(from: board.points[from], to: board.points[to], color: p.mover),
                                      on: board)
            }
        }
    }

    private func applySeeds() {
        for (ply, e) in seeds where ply <= positions.count {
            seeds[ply] = nil
            let p = positions[ply - 1]
            guard e.playedMove == p.halfMoves else { continue }
            if let l = e.luck, lucks[ply] == nil {
                lucks[ply] = PlyLuck(plyNumber: ply, mover: p.mover, die1: p.die1, die2: p.die2, luck: l,
                                     rolledValue: p.isPass ? e.playedScore : nil,
                                     pointScale: config.variant.maxPoints)
            }
            guard !p.isPass, (evaluations[ply]?.depth ?? 0) < e.depth else { continue }
            evaluations[ply] = PlyEvaluation(
                plyNumber: ply, die1: p.die1, die2: p.die2, boardStacks: p.stacks, mover: p.mover,
                playedMove: e.playedMove, playedScore: Float(e.playedScore),
                bestMove: e.bestMove, bestScore: Float(e.bestScore),
                hadChoice: legalMoveCount(p) > 1, depth: e.depth, pointScale: config.variant.maxPoints)
        }
    }

    private func legalMoveCount(_ p: AnalysisPosition) -> Int {
        let b = GameBoard(config: config)
        for (i, pieces) in p.stacks.enumerated() where i < b.points.count { b.setPoint(i, pieces: pieces) }
        let dice = Dice(numberOfSides: config.dieSides)
        dice.set(p.die1, p.die2)
        return config.variant.legalMoves(on: b, color: p.mover, dice: dice).count
    }

    private func bump() {
        revision += 1
        onChange?()
    }

    // ── Scheduling ────────────────────────────────────────────────────────────

    /// The next unit of work, lowest tier first: 1-ply for every unscored ply, the dice
    /// luck of every ply, 2-ply for every ply with a choice, then 3-ply for the close
    /// calls of `refineColors` (`GameReview.shouldRefine`, as the review's last pass).
    func nextUnit() -> AnalysisUnit? {
        guard agent != nil else { return nil }
        for p in positions where !p.isPass && evaluations[p.plyNumber] == nil && !isFailed(p, 0) {
            return .rank(p, depth: 1, range: nil)
        }
        for p in positions where lucks[p.plyNumber] == nil && !isFailed(p, 1) {
            return .luck(p)
        }
        guard maxDepth >= 2 else { return nil }
        for p in positions where !p.isPass && !isFailed(p, 2) {
            guard let e = evaluations[p.plyNumber], e.hadChoice, e.depth < 2 else { continue }
            return .rank(p, depth: 2, range: nextRange(p, depth: 2, chunk: 8))
        }
        guard maxDepth >= 3 else { return nil }
        for p in positions where !p.isPass && refineColors.contains(p.mover) && !isFailed(p, 3) {
            guard let e = evaluations[p.plyNumber], e.depth < 3,
                  GameReview.shouldRefine(e, pass: 2) else { continue }
            return .rank(p, depth: 3, range: nextRange(p, depth: 3, chunk: 1))
        }
        return nil
    }

    private func nextRange(_ p: AnalysisPosition, depth: Int, chunk: Int) -> Range<Int> {
        if let part = partials[p.plyNumber], part.depth == depth,
           let first = part.scores.firstIndex(where: { $0 == nil }) {
            return first..<min(first + chunk, part.scores.count)
        }
        return 0..<chunk
    }

    private func isFailed(_ p: AnalysisPosition, _ tier: Int) -> Bool {
        failed.contains(p.plyNumber * 10 + tier)
    }

    /// Whether `p` still describes the game (not undone since the unit started).
    func isValid(_ p: AnalysisPosition) -> Bool {
        p.plyNumber >= 1 && p.plyNumber <= positions.count && positions[p.plyNumber - 1] == p
    }

    /// Take a finished unit's result. Returns whether anything visible changed (and
    /// the job was bumped).
    @discardableResult
    func apply(_ unit: AnalysisUnit, output: AnalysisOutput) -> Bool {
        let p = unit.position
        guard isValid(p) else { return false }
        let ply = p.plyNumber
        switch output {
        case .cancelled:
            return false
        case .failed:
            failed.insert(ply * 10 + unit.tier)
            partials[ply] = nil
        case .luck(let luck, let rolled):
            lucks[ply] = PlyLuck(plyNumber: ply, mover: p.mover, die1: p.die1, die2: p.die2,
                                 luck: luck, rolledValue: rolled, pointScale: config.variant.maxPoints)
        case .rank(let pairs, let playedIndex, let range, let scores):
            guard case .rank(_, let depth, _) = unit else { return false }
            var part = partials[ply]
            if part == nil || part!.depth != depth || part!.pairs.count != pairs.count {
                part = Partial(depth: depth, pairs: pairs, playedIndex: playedIndex,
                               scores: Array(repeating: nil, count: pairs.count))
            }
            for (k, i) in range.enumerated() where k < scores.count { part!.scores[i] = scores[k] }
            if part!.scores.contains(where: { $0 == nil }) {
                partials[ply] = part
                return false
            }
            partials[ply] = nil
            let all = part!.scores.map { $0 ?? 0 }
            guard let best = GameReview.argmax(all), let played = part!.playedIndex else {
                failed.insert(ply * 10 + unit.tier)
                bump()
                return true
            }
            if (evaluations[ply]?.depth ?? 0) <= depth {
                evaluations[ply] = PlyEvaluation(
                    plyNumber: ply, die1: p.die1, die2: p.die2, boardStacks: p.stacks, mover: p.mover,
                    playedMove: p.halfMoves, playedScore: all[played],
                    bestMove: pairs[best], bestScore: all[best],
                    hadChoice: pairs.count > 1, depth: depth, pointScale: config.variant.maxPoints)
            }
        }
        bump()
        return true
    }

    // ── Results ───────────────────────────────────────────────────────────────

    /// Every evaluated ply so far, both sides, in play order — at the deepest depth
    /// reached (1, 2 or 3).
    public var result: GameReviewResult {
        GameReviewResult(evaluations: evaluations.values.sorted { $0.plyNumber < $1.plyNumber })
    }

    /// The dice luck of every ply, or `nil` until every ply has it (as `cachedLuck`).
    public var luck: [PlyLuck]? {
        guard !positions.isEmpty, positions.allSatisfy({ lucks[$0.plyNumber] != nil }) else { return nil }
        return positions.compactMap { lucks[$0.plyNumber] }
    }

    /// The dice luck found so far (#259), in play order — every ply's once complete
    /// (then equal to `luck`). Lets the review show its per-roll rating live while the
    /// analysis still runs.
    public var partialLuck: [PlyLuck] {
        positions.compactMap { lucks[$0.plyNumber] }
    }

    /// The persisted form: one entry per evaluated ply with its luck, plus luck-only
    /// entries for passes (`[AnalysisEntry].withLuck`).
    public var entries: [AnalysisEntry] {
        [AnalysisEntry](reviewResult: result)
            .withLuck(lucks.values.sorted { $0.plyNumber < $1.plyNumber }, record: record)
    }

    /// Whether there is a model to analyse with (two-player games without a bundled
    /// model have none).
    public var hasModel: Bool { agent != nil }

    /// Nothing left to do (or nothing can be done without a model).
    public var isComplete: Bool { !isRunning && nextUnit() == nil }

    /// Every ply that moved has an evaluation (at least 1-ply): the graph and the
    /// drill are complete from here.
    public var firstPassComplete: Bool {
        positions.allSatisfy { $0.isPass || evaluations[$0.plyNumber] != nil || isFailed($0, 0) }
    }

    /// Plies that moved, and how many of them have an evaluation.
    public var progress: (done: Int, total: Int) {
        let moved = positions.filter { !$0.isPass }
        return (moved.filter { evaluations[$0.plyNumber] != nil }.count, moved.count)
    }

    /// The deepest depth reached for each ply (testing / diagnostics).
    public var depthByPly: [Int: Int] { evaluations.mapValues(\.depth) }
}

// MARK: - Service

/// The owner of every game's analysis (#243): one `GameAnalysisJob` per `gameId`,
/// computed one unit at a time on a single `.utility` queue (bounded to one prediction
/// stream, so it never competes with itself), paused by `gate` while the computer
/// thinks, and idle when nothing is left. Landed results are written back after
/// `persistDelay`: into the game log once the game is logged, else into the autosave
/// when it holds this game. Games in neither (online, samples) stay in memory.
@MainActor
public final class AnalysisService {
    public let gate: AnalysisGate
    /// The beam parameters the analysis ranks with (the review's).
    public var searchConfig: SearchConfig = .standard
    /// How long landed results wait before they are written (writes coalesce).
    public var persistDelay: TimeInterval = 1.0
    /// The deepest pass: 3 (the review's 1 → 2 → 3-ply). Tests lower it to stay quick.
    public var maxDepth = 3 {
        didSet {
            for job in jobs.values { job.maxDepth = maxDepth }
            kick()
        }
    }
    /// Stop starting new work (in-flight work finishes). For tests and app policy.
    public var isSuspended = false {
        didSet { if !isSuspended { kick() } }
    }

    private let gameLog: GameLogStore?
    private let saveStore: SaveStore?
    private let agentProvider: @MainActor (GameConfig) -> Agent?
    private var agents: [String: Agent] = [:]
    private var jobs: [UUID: GameAnalysisJob] = [:]
    private var nextOrder = 0
    private struct Running {
        let job: GameAnalysisJob
        let unit: AnalysisUnit
        let token: AnalysisToken
    }
    private var running: Running?
    private let queue = DispatchQueue(label: "tavlo.analysis", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private var dirty: Set<UUID> = []
    private var flushTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var thermalObserver: NSObjectProtocol?

    /// Units computed so far (testing / diagnostics).
    public private(set) var unitsRun = 0

    /// `gameLog` / `saveStore`: where landed results are written (`nil` = memory only).
    /// `agentProvider` makes the model for a game whose session has none (a two-player
    /// game); it is called once per variant.
    public init(gameLog: GameLogStore? = nil, saveStore: SaveStore? = nil,
                gate: AnalysisGate = AnalysisGate(),
                agentProvider: @escaping @MainActor (GameConfig) -> Agent? = { ModelCatalog.main.makeAgent(config: $0) }) {
        self.gameLog = gameLog
        self.saveStore = saveStore
        self.gate = gate
        self.agentProvider = agentProvider
        // Battery / thermal: no new work while the device is hot; pick up again when it cools.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
    }

    /// The model for `config`'s variant, made once (shared by every job of it).
    public func agent(for config: GameConfig) -> Agent? {
        let id = config.variant.id
        if let a = agents[id] { return a }
        guard let a = agentProvider(GameConfig(variant: config.variant)) else { return nil }
        agents[id] = a
        return a
    }

    /// The job of `record`'s game, made on first use — seeded from `seed`, the game
    /// log and the autosave (whichever has analysis for it), so it continues from the
    /// saved depth. An existing job follows `record` and takes `seed` too.
    @discardableResult
    public func job(for record: GameRecord, agent: Agent? = nil,
                    seed: [AnalysisEntry] = []) -> GameAnalysisJob {
        if let job = jobs[record.gameId] {
            job.update(record: record)
            job.seed(seed)
            return job
        }
        var initial = seed
        if let saved = gameLog?.analysis(forGameId: record.gameId) {
            initial = AnalysisEntry.merge(saved, initial)
        }
        if let auto = saveStore?.loadAutosave(), auto.gameId == record.gameId, let saved = auto.analysis {
            initial = AnalysisEntry.merge(saved, initial)
        }
        let config = record.replayConfig
        let refine: Set<Color> = record.aiColor.map { [$0.opponent] } ?? [.white, .black]
        let job = GameAnalysisJob(record: record, config: config,
                                  agent: agent ?? self.agent(for: config),
                                  refineColors: refine, order: nextOrder, seed: initial)
        job.maxDepth = maxDepth
        nextOrder += 1
        job.onChange = { [weak self, weak job] in
            guard let self, let job else { return }
            self.jobChanged(job)
        }
        jobs[record.gameId] = job
        kick()
        return job
    }

    /// The job of a game, if one exists.
    public func existingJob(for gameId: UUID) -> GameAnalysisJob? { jobs[gameId] }

    /// Stop and forget a game's job (its saved results stay).
    public func remove(gameId: UUID) {
        if let r = running, r.job.gameId == gameId { r.token.cancel() }
        jobs[gameId] = nil
        dirty.remove(gameId)
    }

    /// Return once nothing is running and no job has work left.
    public func waitUntilIdle() async {
        if running == nil && pickNext() == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// Whether a unit is being computed right now.
    public var isBusy: Bool { running != nil }

    /// Whether anything is running or left to do (ignoring suspension and heat).
    public var hasPendingWork: Bool { running != nil || pickNext() != nil }

    /// The game whose unit is being computed (testing / diagnostics).
    public var runningGameId: UUID? { running?.job.gameId }

    // ── Scheduling ────────────────────────────────────────────────────────────

    private func jobChanged(_ job: GameAnalysisJob) {
        // A step-back undid the ply being scored: stop it now.
        if let r = running, r.job === job, !job.isValid(r.unit.position) { r.token.cancel() }
        kick()
    }

    private var tooHot: Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// The most urgent unit over all jobs: lowest tier, then a focused (open) review,
    /// then the oldest job.
    private func pickNext() -> (job: GameAnalysisJob, unit: AnalysisUnit)? {
        var best: (job: GameAnalysisJob, unit: AnalysisUnit)?
        for job in jobs.values {
            guard let unit = job.nextUnit() else { continue }
            if let b = best {
                let a = (unit.tier, job.focused ? 0 : 1, job.order)
                let c = (b.unit.tier, b.job.focused ? 0 : 1, b.job.order)
                if a < c { best = (job, unit) }
            } else {
                best = (job, unit)
            }
        }
        return best
    }

    private func kick() {
        guard running == nil, !isSuspended, !tooHot else { return }
        guard let (job, unit) = pickNext(), let base = job.agent else {
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0.resume() }
            return
        }
        let gate = self.gate
        let token = AnalysisToken(gate: gate)
        let agent = base.throttled { try gate.checkpoint(token) }
        running = Running(job: job, unit: unit, token: token)
        job.isRunning = true
        let config = job.config
        let search = searchConfig
        queue.async { [weak self] in
            let output = AnalysisWork.run(unit, agent: agent, config: config, search: search, token: token)
            Task { @MainActor [weak self] in self?.landed(output, token: token) }
        }
    }

    private func landed(_ output: AnalysisOutput, token: AnalysisToken) {
        guard let r = running, r.token === token else { return }
        running = nil
        r.job.isRunning = false
        unitsRun += 1
        if r.job.apply(r.unit, output: output) { markDirty(r.job) }
        kick()
    }

    // ── Persistence ───────────────────────────────────────────────────────────

    private func markDirty(_ job: GameAnalysisJob) {
        guard gameLog != nil || saveStore != nil else { return }
        dirty.insert(job.gameId)
        guard flushTask == nil else { return }
        let delay = persistDelay
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Write every job's unsaved results now (also called when the app backgrounds).
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        let ids = dirty
        dirty = []
        for id in ids {
            guard let job = jobs[id] else { continue }
            let entries = job.entries
            guard !entries.isEmpty else { continue }
            if let log = gameLog, (try? log.mergeAnalysis(entries, forGameId: id)) == true { continue }
            if let store = saveStore, var save = store.loadAutosave(), save.gameId == id {
                save.analysis = AnalysisEntry.merge(save.analysis ?? [], entries)
                try? store.writeAutosave(save)
            }
        }
    }
}

public extension AnalysisEntry {
    /// `old` and `new` combined per ply (#243): for the same played move the deeper
    /// entry wins (ties: `new`) and luck is kept from either; a different played move
    /// (a replayed line) takes `new`. Sorted by ply.
    static func merge(_ old: [AnalysisEntry], _ new: [AnalysisEntry]) -> [AnalysisEntry] {
        var byPly = Dictionary(old.map { ($0.plyNumber, $0) }, uniquingKeysWith: { a, _ in a })
        for e in new {
            guard let o = byPly[e.plyNumber], o.playedMove == e.playedMove else {
                byPly[e.plyNumber] = e
                continue
            }
            let pick = e.depth >= o.depth ? e : o
            byPly[e.plyNumber] = pick.withLuck(pick.luck ?? e.luck ?? o.luck)
        }
        return byPly.values.sorted { $0.plyNumber < $1.plyNumber }
    }
}
