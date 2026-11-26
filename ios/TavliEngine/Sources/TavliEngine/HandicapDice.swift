import Foundation

/// Weighted dice and the reroll policy (#148, tier 1). Pure functions over the value
/// net; `GameSession` runs them off the main actor.
///
/// **Keep in sync with the Python harness** (`domain/handicap.py` `roll_spread` /
/// `lean_beta` / `gain_beta` / `hybrid_beta` / `turn_beta` / `tilted_roll_probs` /
/// `mirrored_turn_beta` / `weighted_faces`, `HandicappedPlakotoRules.roll_beta`,
/// `ai/handicap_sweep.py` `wants_reroll`, `ai/agent.py` `roll_values`):
/// the 21 rolls in `diceOutcomes` order (= Python `ROLLS`) with weights 1/36 (doubles)
/// and 2/36; a roll's value is the mover's best 1-ply move value, a roll with no legal
/// move is a pass valued `1 − opponent's static value`; the tilt is
/// `q(r) ∝ p(r)·exp(β_t·v(r))` with the turn's β_t from the `WeightedDice` mode
/// (#261, `beta(values:dice:maxPoints:)`) — **mirrored (#271)**: the favoured side's own
/// roll leans towards rolls good for it (β_t ≥ 0), its opponent's roll towards rolls bad for
/// the opponent by the same per-roll magnitude (`mirroredBeta`, β_t ≤ 0; the roller's values,
/// `rollBeta(values:roller:favoured:dice:maxPoints:)`) — drawn by inverse CDF of
/// `u = (int(6 u1) + u2) / 6` over the 36 ordered outcomes (β_t = 0 is exactly
/// `(face(u1), face(u2))`, the fair dice); the reroll rule is `v(roll) < E_q[v] − 0.02`
/// with `q` the side's own (tilted, same β_t) distribution, repeated while tokens remain.
/// (The Swift has no bear-off database, so its race values are the net's own.)
///
/// The modes (μ = Σ p v, σ² = Σ p (v − μ)², first-order gain E_q[v] − μ ≈ β·σ²):
/// - lean: β_t = κ / max(σ, σ_floor) — a roll 2σ above average e^{2κ}× as likely in every
///   position; gain ≈ κ·σ.
/// - fixed gain: the largest β_t ≥ 0 with E_q[v] − μ ≤ g and max_r q(r)/p(r) ≤ `gainCap`
///   (both monotone in β: one bisection over [0, `betaSpan`/σ], `bisectionSteps` halvings);
///   σ < σ_floor → 0 (fair).
/// - hybrid: min(fixed gain's β_t, `hybridKappaMax` / max(σ, σ_floor)).
/// For a 2-point variant `v` is normalised equity: g and σ_floor are win-chance-equivalent
/// pp (the review's unit) and are divided by `maxPoints`; κ, the cap and κ_max are scale-free.
public enum HandicapDice {
    /// The AI rerolls when its roll's value is this far below a fresh fair roll's
    /// expected value (`rerolls` policy in the harness).
    public static let rerollMargin: Float = 0.02

    /// σ floor in win-chance pp (÷ `maxPoints` for normalised equity): below it the rolls
    /// differ by model noise only (Python `SIGMA_FLOOR`).
    public static let sigmaFloor = 0.01
    /// Fixed gain's cap: no roll more than this many times as likely as fair (`GAIN_CAP`).
    public static let gainCap = 3.0
    /// Hybrid's lean ceiling κ_max (`HYBRID_KAPPA_MAX`): a roll 2σ above average at most
    /// e^{0.6} ≈ 1.8× as likely as an average one.
    public static let hybridKappaMax = 0.3
    /// Fixed gain's bisection: β in [0, betaSpan / σ], `bisectionSteps` halvings.
    public static let betaSpan = 50.0
    public static let bisectionSteps = 60

    /// The 21 distinct rolls (`d1 <= d2`) in the canonical order, with their fair
    /// probabilities (doubles 1/36, the rest 2/36).
    public static var outcomes: [(d1: Int, d2: Int, p: Double)] {
        diceOutcomes.map { ($0.d1, $0.d2, ($0.d1 == $0.d2 ? 1.0 : 2.0) / 36.0) }
    }

    /// Per-roll 1-ply value for `color` to move on `board` (21 entries, `outcomes`
    /// order): the win probability of `color`'s best move, or `1 − value(opponent to
    /// move)` when the roll has no legal move. Leaves `board` unchanged.
    public static func rollValues(agent: Agent, board: GameBoard, color: Color) throws -> [Float] {
        let variant = board.variant
        let dice = Dice(numberOfSides: board.config.dieSides)
        var values: [Float] = []
        values.reserveCapacity(diceOutcomes.count)
        for o in diceOutcomes {
            dice.set(o.d1, o.d2)
            let moves = variant.legalMoves(on: board, color: color, dice: dice)
            if moves.isEmpty {
                values.append(1 - (try agent.winProbability(board, color: color.opponent)))
            } else {
                values.append(try agent.evaluateMoves(board, moves, color: color).max() ?? 0)
            }
        }
        return values
    }

    /// (μ, σ) of the 21 values under the fair roll probabilities (Python `roll_spread`).
    public static func spread(_ values: [Float]) -> (mu: Double, sigma: Double) {
        let fair = outcomes.map(\.p)
        let v = values.map(Double.init)
        let mu = zip(fair, v).reduce(0.0) { $0 + $1.0 * $1.1 }
        let variance = zip(fair, v).reduce(0.0) { $0 + $1.0 * ($1.1 - mu) * ($1.1 - mu) }
        return (mu, max(variance, 0).squareRoot())
    }

    /// Lean: β_t = κ / max(σ, σ_floor / maxPoints).
    public static func leanBeta(values: [Float], kappa: Double, maxPoints: Int = 1) -> Double {
        guard kappa > 0, values.count == diceOutcomes.count else { return 0 }
        return kappa / max(spread(values).sigma, sigmaFloor / Double(maxPoints))
    }

    /// Fixed gain: the largest β ≥ 0 with E_q[v] − μ ≤ g (win-chance pp, ÷ `maxPoints`)
    /// and max_r q(r)/p(r) ≤ `cap`, by bisection (Python `gain_beta`). Reachable g is hit;
    /// otherwise the cap binds. σ < σ_floor → 0.
    public static func gainBeta(values: [Float], gainPP: Double, maxPoints: Int = 1,
                                cap: Double = gainCap) -> Double {
        guard gainPP > 0, values.count == diceOutcomes.count else { return 0 }
        let (mu, sigma) = spread(values)
        guard sigma >= sigmaFloor / Double(maxPoints) else { return 0 }
        let target = gainPP / 100 / Double(maxPoints)
        let fair = outcomes.map(\.p)
        let v = values.map(Double.init)
        let vmax = v.max() ?? 0
        var lo = 0.0, hi = betaSpan / sigma
        for _ in 0..<bisectionSteps {
            let mid = 0.5 * (lo + hi)
            var z = 0.0, ev = 0.0
            for (w, x) in zip(fair, v) {
                let e = w * Foundation.exp(mid * (x - vmax))
                z += e
                ev += e * x
            }
            if ev / z - mu <= target && 1 / z <= cap { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Hybrid: min(fixed gain's β, κ_max / max(σ, σ_floor)).
    public static func hybridBeta(values: [Float], gainPP: Double, maxPoints: Int = 1,
                                  kappaMax: Double = hybridKappaMax) -> Double {
        min(gainBeta(values: values, gainPP: gainPP, maxPoints: maxPoints),
            leanBeta(values: values, kappa: kappaMax, maxPoints: maxPoints))
    }

    /// This turn's β_t for `dice` given the side's 21 roll values (0 when off). Python
    /// `turn_beta`. `maxPoints` = the variant's (2-point variants: normalised equity).
    public static func beta(values: [Float], dice: WeightedDice, maxPoints: Int = 1) -> Double {
        guard dice.isOn else { return 0 }
        switch dice.mode {
        case .lean:      return leanBeta(values: values, kappa: dice.strength, maxPoints: maxPoints)
        case .fixedGain: return gainBeta(values: values, gainPP: dice.strength, maxPoints: maxPoints)
        case .hybrid:    return hybridBeta(values: values, gainPP: dice.strength, maxPoints: maxPoints)
        }
    }

    /// The mirrored bend (#271) on the roll of the favoured side's **opponent**, from the
    /// opponent's own 21 values: `−beta(−v)` ≤ 0 — the mode's rule applied to the negated
    /// values, so the roll leans towards rolls bad for the roller by the same per-roll
    /// magnitude (fixed gain E_q[v] − μ = −g, lean κ/σ, hybrid the smaller; the cap bounds the
    /// boosted bad rolls). 0 when off. Python `mirrored_turn_beta`.
    public static func mirroredBeta(values: [Float], dice: WeightedDice, maxPoints: Int = 1) -> Double {
        let b = beta(values: values.map { -$0 }, dice: dice, maxPoints: maxPoints)
        return b == 0 ? 0 : -b
    }

    /// This turn's β_t for `roller` when `favoured` holds `dice` (#271, the one-favoured-side
    /// API): `beta` for the favoured side's own roll, `mirroredBeta` for its opponent's.
    /// `values` = the roller's 21 roll values.
    public static func rollBeta(values: [Float], roller: Color, favoured: Color, dice: WeightedDice,
                                maxPoints: Int = 1) -> Double {
        roller == favoured
            ? beta(values: values, dice: dice, maxPoints: maxPoints)
            : mirroredBeta(values: values, dice: dice, maxPoints: maxPoints)
    }

    /// This turn's β_t for `roller` in `setup` (both sides may hold weighted dice, #236): the
    /// sum of each side's bend on this roll — its own `beta` when it rolls, its `mirroredBeta`
    /// when the other side rolls (equal setups about cancel, equal lean ones exactly). 0 =
    /// fair. Python `HandicappedPlakotoRules.roll_beta`.
    public static func rollBeta(values: [Float], roller: Color, setup: HandicapSetup,
                                maxPoints: Int = 1) -> Double {
        Color.allCases.reduce(0.0) { sum, side in
            let dice = setup[side].weightedDice
            guard dice.isOn else { return sum }
            return sum + rollBeta(values: values, roller: roller, favoured: side, dice: dice,
                                  maxPoints: maxPoints)
        }
    }

    /// The side's own roll distribution for this turn as the favoured side (21 entries, sums
    /// to 1; fair when off). For the opponent's mirrored roll use
    /// `tilt(values:beta:)` with `mirroredBeta` / `rollBeta`.
    public static func probabilities(values: [Float], dice: WeightedDice, maxPoints: Int = 1) -> [Double] {
        tilt(values: values, beta: beta(values: values, dice: dice, maxPoints: maxPoints))
    }

    /// The tilted roll distribution `q(r) ∝ p(r)·exp(β·v(r))` (21 entries, sums to 1).
    /// `β == 0` returns the fair probabilities exactly.
    public static func tilt(values: [Float], beta: Double) -> [Double] {
        let fair = outcomes.map(\.p)
        guard beta != 0, values.count == fair.count else { return fair }
        // Subtract the max exponent for numerical stability (cancels on normalising).
        let exps = values.map { beta * Double($0) }
        let top = exps.max() ?? 0
        let raw = zip(fair, exps).map { $0 * Foundation.exp($1 - top) }
        let total = raw.reduce(0, +)
        return total > 0 ? raw.map { $0 / total } : fair
    }

    /// A fair die face from a uniform in [0, 1) (`face` in `domain/handicap.py`).
    public static func face(_ u: Double) -> Int { 1 + min(Int(u * 6), 5) }

    /// Ordered dice faces for uniforms `u1`, `u2` in [0, 1) — Python `weighted_faces`:
    /// inverse CDF of `u = (int(6 u1) + u2) / 6` over the 36 ordered outcomes in
    /// lexicographic order, each weighted by its unordered roll's tilt `exp(β·v)`.
    /// `β == 0` (or no values) is the fair path `(face(u1), face(u2))`.
    public static func weightedFaces(u1: Double, u2: Double, values: [Float]?, beta: Double) -> (Int, Int) {
        guard beta != 0, let values, values.count == diceOutcomes.count else {
            return (face(u1), face(u2))
        }
        let vmax = Double(values.max() ?? 0)
        let tilt = values.map { Foundation.exp(beta * (Double($0) - vmax)) }
        var cum: [Double] = []
        cum.reserveCapacity(36)
        var total = 0.0
        for a in 1...6 {
            for b in 1...6 {
                total += tilt[outcomeIndex(a, b)!]
                cum.append(total)
            }
        }
        let target = (Double(Int(u1 * 6)) + u2) / 6 * total
        var k = 35
        for (i, c) in cum.enumerated() where target < c { k = i; break }
        return (1 + k / 6, 1 + k % 6)
    }

    /// The expected value of a fresh roll under `probabilities` (default fair).
    public static func expectedValue(_ values: [Float], probabilities: [Double]? = nil) -> Float {
        let p = probabilities ?? outcomes.map(\.p)
        return Float(zip(p, values).reduce(0.0) { $0 + $1.0 * Double($1.1) })
    }

    /// The index into `outcomes` of the roll `(d1, d2)` (either order).
    public static func outcomeIndex(_ d1: Int, _ d2: Int) -> Int? {
        let lo = min(d1, d2), hi = max(d1, d2)
        return diceOutcomes.firstIndex { $0.d1 == lo && $0.d2 == hi }
    }

    /// The computer's reroll rule (harness `wants_reroll`): reroll when the current
    /// roll's value is below the expectation of a fresh roll under the side's own roll
    /// distribution (tilted by this turn's `beta`, fair at 0) by more than `rerollMargin`.
    public static func shouldReroll(values: [Float], d1: Int, d2: Int, beta: Double = 0) -> Bool {
        guard values.count == diceOutcomes.count, let i = outcomeIndex(d1, d2) else { return false }
        let expected = expectedValue(values, probabilities: tilt(values: values, beta: beta))
        return values[i] < expected - rerollMargin
    }
}

// MARK: - Win-chance estimate (concept §5)

/// How the starter of a handicap game is decided, for the position estimate. Mirrors
/// the app: the opening roll-off is a fair coin (the starter then rolls fresh dice),
/// a forced starter (Settings "First move", two-player house Plakoto's White) is fixed.
public enum HandicapStartRule: Equatable, Sendable {
    case rollOff
    case fixed(Color)
}

/// The measured dice-lever table (`HandicapTable.json`, concept §5): per harness cell
/// label — `rerolls:2`, `weighted_hybrid:0.8` (none measured yet, #261), combos joined with `+` as in
/// `docs/handicap-e1-tier1.json` — the shift in log-odds for the **favoured** side
/// (`logit(favoured win rate)`; the harness reports the handicapped side's rate, and
/// both dice kinds are bonus kinds, so favoured rate = 1 − rate). `nil` = not measured
/// yet. Generated by `ios/scripts/make_handicap_table.py`.
public struct HandicapTable: Codable, Equatable, Sendable {
    public struct Cell: Codable, Equatable, Sendable {
        public var logOddsShift: Double?
        public init(logOddsShift: Double?) { self.logOddsShift = logOddsShift }
    }
    public var version: Int
    public var cells: [String: Cell]

    public init(version: Int = 1, cells: [String: Cell] = [:]) {
        self.version = version
        self.cells = cells
    }

    /// An empty table: every dice lever unmeasured.
    public static let unmeasured = HandicapTable()

    /// The variants the table was measured in (#246): house Plakoto only (the E1/E3
    /// sweeps on gold_v11). Other variants have no entries yet.
    public static let measuredVariantIDs: Set<String> = [HandicapSetup.positionAndRulesVariantID]

    /// This table for a game of `variantID`: itself where it was measured, else
    /// `unmeasured` (every dice lever "not measured yet").
    public func forVariant(_ variantID: String) -> HandicapTable {
        Self.measuredVariantIDs.contains(variantID) ? self : .unmeasured
    }

    public static func decode(_ data: Data) -> HandicapTable? {
        try? JSONDecoder().decode(HandicapTable.self, from: data)
    }

    /// The harness cell label for one lever (`weighted_hybrid:0.8`, `rerolls:2`).
    public static func label(_ kind: String, _ intensity: Double) -> String {
        intensity.rounded() == intensity ? "\(kind):\(Int(intensity))" : "\(kind):\(intensity)"
    }

    /// The measured shift for one side's dice levers: an exact measured cell for the
    /// whole set (a combo, either order), else the sum of the singles, else `nil` when
    /// any single is unmeasured. Also returns the unmeasured lever kinds.
    func shift(for labels: [String]) -> (shift: Double, unmeasured: [String]) {
        guard !labels.isEmpty else { return (0, []) }
        if labels.count > 1 {
            for perm in Self.permutations(labels) {
                if let d = cells[perm.joined(separator: "+")]?.logOddsShift { return (d, []) }
            }
        }
        var total = 0.0
        var missing: [String] = []
        for l in labels {
            if let d = cells[l]?.logOddsShift { total += d }
            else { missing.append(String(l.split(separator: ":")[0])) }
        }
        return (total, missing)
    }

    /// Every ordering of `items` (the harness joins combo labels in its own lever order).
    static func permutations(_ items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        var out: [[String]] = []
        for (i, x) in items.enumerated() {
            var rest = items
            rest.remove(at: i)
            for p in permutations(rest) { out.append([x] + p) }
        }
        return out
    }

    /// The tier-2 cells of `setup` (#148 E3) as harness labels grouped by the sweep's
    /// *handicapped* colour (spec `side`), whose opponent the cell's `logOddsShift`
    /// favours. Mapping from the app's per-side items (each describing its side's own
    /// rules): overshoot / safe point → the side holding it is favoured (spec side =
    /// its opponent); smaller home → the side with it is the spec side; fewer than 15
    /// checkers → that side is the favoured one (`HandicapSpec.target` = −side), more
    /// than 15 → that side is the spec side. (The measured checker shifts are negative:
    /// more checkers is the advantage.)
    public static func tier2Groups(_ setup: HandicapSetup) -> [Color: [String]] {
        let s = setup.normalized
        var groups: [Color: [String]] = [:]
        for side in Color.allCases {
            let items = s[side]
            // Fixed order like the harness: overshoot, safe_point, checkers, smaller_house.
            if items.overshoot { groups[side.opponent, default: []].append("overshoot:1") }
            if items.safePoint > 0 { groups[side.opponent, default: []].append("safe_point:\(items.safePoint)") }
            if items.checkers < HandicapSetup.normalCheckers {
                groups[side.opponent, default: []].append("checkers:\(items.checkers)")
            } else if items.checkers > HandicapSetup.normalCheckers {
                groups[side, default: []].append("checkers:\(items.checkers)")
            }
            if items.homeSize < HandicapSetup.normalHomeSize {
                groups[side, default: []].append("smaller_house:\(items.homeSize)")
            }
        }
        return groups
    }
}

/// The builder's live estimate.
public struct HandicapEstimate: Equatable, Sendable {
    /// White's estimated win chance, combining every lever that has a number.
    public var whiteWinChance: Double
    /// Levers that are active but not measured yet (excluded from the number), by harness
    /// kind: `"weighted_lean"` / `"weighted_gain"` / `"weighted_hybrid"` (none measured since
    /// #261), `"rerolls"`, a tier-2 kind.
    public var unmeasured: [String]
    /// Hints are active (never in the number; the line says "approx.").
    public var approximate: Bool
}

public enum HandicapEstimator {
    /// Whether the builder / card can show a win-chance estimate for `variantID` (#246):
    /// house Plakoto only. Elsewhere the table has no entries yet, and the 2-point
    /// variants' net values are normalized equity, not a win chance — the estimate then
    /// says "not measured yet" instead of a number.
    public static func isMeasured(variantID: String) -> Bool {
        HandicapTable.measuredVariantIDs.contains(variantID)
    }

    /// Per head-start checker, the relative boost to the same side's dice-lever shift
    /// (fitted on E1's head-start × dice combos: ≈ 1.4× at m = 4).
    public static let headStartDiceInteraction = 0.1

    /// The position levers' estimate (head start ± moves first): White's win chance
    /// from the handicap start position, averaging the net's best 1-ply move value over
    /// the starter's 21 opening rolls (weighted). With "moves first" the favoured side
    /// starts; otherwise `rule` decides (the roll-off averages both starters).
    public static func positionWhiteWinChance(setup: HandicapSetup, agent: Agent,
                                              rule: HandicapStartRule) throws -> Double {
        // Tier-2 levers are not in the net's view (its handicap inputs are zero, §11):
        // the position estimate is the normal 15/15 start with the head start only.
        let setup = setup.tier1Only
        let board = GameBoard(config: GameConfig(variant: agent.variant))
        setup.setUpInitialPosition(on: board)
        func white(ifStarts starter: Color) throws -> Double {
            let values = try HandicapDice.rollValues(agent: agent, board: board, color: starter)
            let p = Double(HandicapDice.expectedValue(values))
            return starter == .white ? p : 1 - p
        }
        if let forced = setup.forcedStarter { return try white(ifStarts: forced) }
        switch rule {
        case .fixed(let c): return try white(ifStarts: c)
        case .rollOff: return 0.5 * (try white(ifStarts: .white)) + 0.5 * (try white(ifStarts: .black))
        }
    }

    /// Combine levers by adding log-odds (concept §5): the position estimate plus each
    /// measured dice lever's shift (positive for White's levers, negative for Black's),
    /// plus the tier-2 levers' measured shifts (`HandicapTable.tier2Groups`).
    /// Unmeasured levers are listed, not guessed; the measured ones keep counting (#261:
    /// weighted dice are unmeasured, so a side's rerolls still count beside them); hints
    /// only flag "approx.".
    public static func combine(positionWhite: Double, setup: HandicapSetup,
                               table: HandicapTable) -> HandicapEstimate {
        let s = setup.normalized
        let p0 = max(min(positionWhite, 1 - 1e-6), 1e-6)
        var logit = log(p0 / (1 - p0))
        var unmeasured: [String] = []
        for color in Color.allCases {
            let sign: Double = color == .white ? 1 : -1
            let items = s[color]
            var labels: [String] = []
            if items.weightedDice.isOn {
                labels.append(HandicapTable.label(items.weightedDice.mode.harnessKind,
                                                  items.weightedDice.strength))
            }
            if items.rerolls > 0 { labels.append(HandicapTable.label("rerolls", Double(items.rerolls))) }
            let (shift, missing) = table.shift(for: labels)
            // E1: a head start amplifies the same side's dice levers (combos with
            // m = 4 measured 1.36–1.52× the dice shift on top of the head start).
            logit += sign * shift * (1 + headStartDiceInteraction * Double(items.headStart))
            for kind in missing where !unmeasured.contains(kind) { unmeasured.append(kind) }
        }
        // Tier 2 (#148 E3): one exact measured cell per handicapped colour when the
        // whole group was measured as a combo (any order), else the sum of the singles.
        // Each group shifts toward the spec side's opponent.
        for (specSide, labels) in HandicapTable.tier2Groups(s) {
            let (shift, missing) = table.shift(for: labels)
            logit += (specSide == .black ? 1 : -1) * shift
            for kind in missing where !unmeasured.contains(kind) { unmeasured.append(kind) }
        }
        let p = 1 / (1 + exp(-logit))
        return HandicapEstimate(whiteWinChance: p, unmeasured: unmeasured,
                                approximate: s.white.hints > 0 || s.black.hints > 0)
    }

    /// Within this of an even game, a two-sided setup favours nobody (`favouredSide`).
    public static let balancedMargin = 0.01

    /// The side a setup favours (#236, the in-game handicap button), or `nil` when it
    /// favours nobody. When the items help one side only (`beneficiaries`) that side —
    /// no estimate needed. When they help both, the net favourite: `estimate` (the net's
    /// position estimate combined with the table) when known, else the table alone from an
    /// even position (head start / moves first then count for nothing), plus each side's
    /// weighted dice at their rough calibrated strength (#261: unmeasured, so not in the
    /// estimate; `WeightedDice.approximateLogOddsShift`); `nil` within `balancedMargin` of 50 %.
    public static func favouredSide(setup: HandicapSetup, estimate: HandicapEstimate?,
                                    table: HandicapTable) -> Color? {
        let sides = setup.beneficiaries
        if sides.count < 2 { return sides.first }
        let s = setup.normalized
        let p0 = (estimate ?? combine(positionWhite: 0.5, setup: s, table: table)).whiteWinChance
        let q = max(min(p0, 1 - 1e-6), 1e-6)
        let logit = log(q / (1 - q)) + s.white.weightedDice.approximateLogOddsShift
            - s.black.weightedDice.approximateLogOddsShift
        let p = 1 / (1 + exp(-logit))
        if abs(p - 0.5) < balancedMargin { return nil }
        return p > 0.5 ? .white : .black
    }
}
