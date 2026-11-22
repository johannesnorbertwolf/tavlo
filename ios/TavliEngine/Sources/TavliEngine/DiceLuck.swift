import Foundation

/// Dice luck (#231): how much better or worse the rolled dice were than an average
/// roll, from the mover's perspective, at **1-ply**.
///
/// For a pre-roll position with `mover` to play, every distinct roll `r` (21 for six
/// sides: doubles weight 1/36, the rest 2/36) gets a value `v(r)` — the mover's best
/// legal move's 1-ply afterstate value, or `1 − value(opponent to move)` when `r` has
/// no legal move (a pass). The luck of the rolled dice is `v(rolled) − E[v]`, so the
/// probability-weighted luck over all 36 rolls is exactly zero. Values are the network's
/// `v ∈ [0, 1]` (win probability, or normalized equity for 2-point variants); `PlyLuck`
/// converts to win-chance-equivalent percentage points like `PlyEvaluation.decisionLoss`.
///
/// The roll distribution is always the **fair** one, even in a weighted-dice handicap
/// game: luck measures the dice against a fair roll, so a tilted side shows up as lucky.
/// The rules (variant, tier-2 handicap levers, head start) come from the game config,
/// exactly as the review applies them. Every prediction goes through `Agent.value`, so
/// each drains its own autorelease pool (see `AnalysisMemoryTests`).
public enum DiceLuck {
    /// One distinct roll's value at a position.
    public struct Roll: Equatable, Sendable {
        /// The roll, `d1 <= d2`.
        public let d1: Int
        public let d2: Int
        /// Fair probability (1/36 for a double, 2/36 otherwise for six sides).
        public let probability: Double
        /// The mover's best 1-ply value with this roll (a pass: `1 − opponent's value`).
        public let value: Double

        public init(d1: Int, d2: Int, probability: Double, value: Double) {
            self.d1 = d1
            self.d2 = d2
            self.probability = probability
            self.value = value
        }
    }

    /// The distinct rolls of two `sides`-sided dice (`d1 <= d2`, lexicographic) and
    /// their fair probabilities. For six sides this is `HandicapDice.outcomes`' order.
    public static func distinctRolls(sides: Int = 6) -> [(d1: Int, d2: Int, probability: Double)] {
        let n = max(1, sides)
        var out: [(Int, Int, Double)] = []
        for a in 1...n {
            for b in a...n {
                out.append((a, b, Double(a == b ? 1 : 2) / Double(n * n)))
            }
        }
        return out
    }

    /// Every distinct roll's value for `mover` to play on `board` (pre-roll). Leaves
    /// `board` unchanged (`evaluateMoves` restores it). `board`'s config supplies the
    /// rules and the dice sides.
    public static func rollValues(agent: Agent, board: GameBoard, mover: Color) throws -> [Roll] {
        let variant = board.variant
        let dice = Dice(numberOfSides: board.config.dieSides)
        var passValue: Double?   // the pass value is the same for every moveless roll
        return try distinctRolls(sides: board.config.dieSides).map { r in
            dice.set(r.d1, r.d2)
            let moves = variant.legalMoves(on: board, color: mover, dice: dice)
            let v: Double
            if moves.isEmpty {
                if passValue == nil {
                    passValue = 1 - Double(try agent.winProbability(board, color: mover.opponent))
                }
                v = passValue!
            } else {
                v = Double(try agent.evaluateMoves(board, moves, color: mover).max() ?? 0)
            }
            return Roll(d1: r.d1, d2: r.d2, probability: r.probability, value: v)
        }
    }

    /// The probability-weighted mean value of a fresh roll.
    public static func expectedValue(_ rolls: [Roll]) -> Double {
        rolls.reduce(0) { $0 + $1.probability * $1.value }
    }

    /// The luck of rolling `(d1, d2)` (either order) in raw value units, or `nil` when
    /// the roll isn't in `rolls`.
    public static func luck(d1: Int, d2: Int, in rolls: [Roll]) -> Double? {
        let lo = min(d1, d2), hi = max(d1, d2)
        guard let r = rolls.first(where: { $0.d1 == lo && $0.d2 == hi }) else { return nil }
        return r.value - expectedValue(rolls)
    }
}

/// The dice luck of one ply (#231), from its mover's perspective. Covers **every**
/// ply with dice, both sides, including forced passes (a dance is unlucky too).
public struct PlyLuck: Equatable, Sendable {
    /// 1-based index of the ply within `record.plies`.
    public let plyNumber: Int
    public let mover: Color
    public let die1: Int
    public let die2: Int
    /// `v(rolled) − E[v]` in raw network units (the same units as the scores).
    public let luck: Double
    /// `v(rolled)`, the 1-ply value of the rolled dice — known when freshly computed
    /// by `analyzeLuck`, and for pass plies rebuilt from cache; `nil` for a moved ply
    /// rebuilt by `cachedLuck` (only `luck` is persisted for those).
    public let rolledValue: Double?
    /// The variant's `maxPoints` (see `PlyEvaluation.pointScale`).
    public let pointScale: Int

    public init(plyNumber: Int, mover: Color, die1: Int, die2: Int, luck: Double,
                rolledValue: Double? = nil, pointScale: Int = 1) {
        self.plyNumber = plyNumber
        self.mover = mover
        self.die1 = die1
        self.die2 = die2
        self.luck = luck
        self.rolledValue = rolledValue
        self.pointScale = max(1, pointScale)
    }

    /// The luck in win-chance-equivalent percentage points (positive = lucky for `mover`).
    public var luckPoints: Double { luck * 100 * Double(pointScale) }
}

public extension GameReview {
    /// The dice-luck pass (#231): replay `record` and, at each ply's pre-roll position,
    /// rate the rolled dice against all 36 (`DiceLuck`). Both sides, every ply with
    /// dice — passes included — in play order. Run it **after** the main analysis, off
    /// the main actor (it is synchronous); it adds no predictions to the review passes.
    ///
    /// Cost: one 1-ply ranking of every legal move for each of the 21 distinct rolls,
    /// per ply — roughly `21 × (legal moves)` predictions a ply.
    ///
    /// Stops early (returning the plies done so far) when the calling task is cancelled.
    /// - Parameter onLuck: called per ply as soon as it's rated (streaming).
    /// - Parameter progress: `(done, total)` plies.
    static func analyzeLuck(
        record: GameRecord,
        agent: Agent,
        config: GameConfig? = nil,
        onLuck: (@Sendable (PlyLuck) -> Void)? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> [PlyLuck] {
        let config = (config ?? GameConfig(variantID: record.variantID)).applying(record.handicap)
        let positions = prerollPositions(record: record, config: config)
        let scale = config.variant.maxPoints
        var out: [PlyLuck] = []
        out.reserveCapacity(positions.count)
        for (i, p) in positions.enumerated() {
            if Task.isCancelled { break }
            let board = GameBoard(config: config)
            for (j, pieces) in p.stacks.enumerated() where j < board.points.count {
                board.setPoint(j, pieces: pieces)
            }
            guard let rolls = try? DiceLuck.rollValues(agent: agent, board: board, mover: p.mover),
                  let luck = DiceLuck.luck(d1: p.die1, d2: p.die2, in: rolls) else { continue }
            let entry = PlyLuck(plyNumber: p.plyNumber, mover: p.mover,
                                die1: p.die1, die2: p.die2, luck: luck,
                                rolledValue: luck + DiceLuck.expectedValue(rolls), pointScale: scale)
            out.append(entry)
            onLuck?(entry)
            progress?(i + 1, positions.count)
        }
        return out
    }

    /// The game's luck rebuilt from **saved** analysis (#231), model-free — or `nil`
    /// unless every ply of `record` has a stored `luck` (so `nil` means "run
    /// `analyzeLuck`"). Pass plies are stored as entries with an empty `playedMove`
    /// (see `AnalysisEntry.luck`).
    static func cachedLuck(record: GameRecord, analysis: [AnalysisEntry],
                           config: GameConfig? = nil) -> [PlyLuck]? {
        let config = (config ?? GameConfig(variantID: record.variantID)).applying(record.handicap)
        let positions = prerollPositions(record: record, config: config, captureBoards: false)
        var byPly: [Int: AnalysisEntry] = [:]
        for e in analysis where e.luck != nil { byPly[e.plyNumber] = e }
        var out: [PlyLuck] = []
        for p in positions {
            guard let e = byPly[p.plyNumber], let luck = e.luck, e.playedMove == p.halfMoves else { return nil }
            out.append(PlyLuck(plyNumber: p.plyNumber, mover: p.mover, die1: p.die1, die2: p.die2,
                               luck: luck, rolledValue: e.playedMove.isEmpty ? e.playedScore : nil,
                               pointScale: config.variant.maxPoints))
        }
        return out
    }

    /// One ply's pre-roll position, captured during a single model-free replay.
    private struct PrerollPosition {
        let plyNumber: Int
        let mover: Color
        let die1: Int
        let die2: Int
        let halfMoves: [[Int]]
        let stacks: [[Color]]
    }

    /// Replay `record` (as `GameSession.replay` does), capturing every ply up to the
    /// game's end — passes included.
    private static func prerollPositions(record: GameRecord, config: GameConfig,
                                         captureBoards: Bool = true) -> [PrerollPosition] {
        let variant = config.variant
        let board = GameBoard(config: config)
        record.setUpInitialPosition(on: board)
        let upper = board.boardSize + 1
        var out: [PrerollPosition] = []
        var mover = record.startingPlayer
        for (index, ply) in record.plies.enumerated() {
            out.append(PrerollPosition(plyNumber: index + 1, mover: mover, die1: ply.die1, die2: ply.die2,
                                       halfMoves: ply.halfMoves,
                                       stacks: captureBoards ? board.captureStacks() : []))
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                variant.applyHalfMove(
                    HalfMove(from: board.points[from], to: board.points[to], color: mover),
                    on: board)
            }
            if variant.isOver(on: board) { break }
            mover = mover.opponent
        }
        return out
    }
}

public extension Array where Element == AnalysisEntry {
    /// These entries with `luck` attached (#231): a moved ply's entry gains its
    /// `luck`; a **pass** ply (empty half-moves), which the move analysis never scores,
    /// is added as a luck-only entry (`playedMove == bestMove == []`, both scores the
    /// pass's 1-ply value `rolledValue`, `depth` 1). Luck for a moved ply with no entry is dropped
    /// (nothing to attach it to). Sorted by `plyNumber`.
    func withLuck(_ luck: [PlyLuck], record: GameRecord) -> [AnalysisEntry] {
        let byPly = Dictionary(luck.map { ($0.plyNumber, $0) }, uniquingKeysWith: { a, _ in a })
        var out = self.map { e -> AnalysisEntry in
            guard let l = byPly[e.plyNumber] else { return e }
            return e.withLuck(l.luck)
        }
        let present = Set(out.map(\.plyNumber))
        for l in luck where !present.contains(l.plyNumber) {
            let index = l.plyNumber - 1
            guard record.plies.indices.contains(index), record.plies[index].halfMoves.isEmpty else { continue }
            out.append(AnalysisEntry(plyNumber: l.plyNumber, playedMove: [], playedScore: l.rolledValue ?? 0.5,
                                     bestMove: [], bestScore: l.rolledValue ?? 0.5, depth: 1, luck: l.luck))
        }
        return out.sorted { $0.plyNumber < $1.plyNumber }
    }
}
