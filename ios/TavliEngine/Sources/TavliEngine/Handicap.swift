import Foundation

// Handicap system, tier 1 (#148, spec `docs/handicap-concept.md` §3/§7).
//
// A handicap gives one side (the *favoured* side) a structural advantage while both
// sides keep playing by the normal house-Plakoto rules. Tier 1 needs no retraining:
// head start, moves first, weighted dice, rerolls and hints. `HandicapSetup` is the
// persisted description (per side); `HandicapGameState` adds the per-game tokens
// (rerolls / hints left) that a save carries so a resumed game keeps its counts.
//
// **Off path.** No setup (or an inactive one) means nothing changes: `GameSession`
// only consults any of this when `handicap != nil`, saves omit the key, and the
// position/dice/turn order are exactly the unhandicapped ones.

/// How weighted dice pick this turn's tilt (#261). Every mode draws from
/// `q(r) ∝ p(r)·exp(β_t·v(r))` over the 21 rolls (`v` = the roller's best 1-ply move value).
/// **Mirrored (#271):** the favoured side's own rolls lean towards rolls good for it, its
/// opponent's rolls towards rolls bad for the opponent, by the same per-roll magnitude
/// (`HandicapDice.mirroredBeta`). The modes differ in β_t (μ, σ = mean and spread of `v`
/// under fair dice; see `HandicapDice`):
/// - `lean`: β_t = κ / max(σ, σ_floor) — the same bend in every position.
/// - `fixedGain`: β_t solved so the expected luck E_q[v] − μ = g per roll, capped at
///   `HandicapDice.gainCap`× fair; σ < σ_floor → fair dice.
/// - `hybrid`: min(fixed gain's β, κ_max / max(σ, σ_floor)).
/// Mirrors the Python kinds `weighted_lean` / `weighted_gain` / `weighted_hybrid`.
public enum WeightedDiceMode: String, Codable, CaseIterable, Sendable {
    case lean, fixedGain, hybrid

    /// The harness kind (`domain/handicap.py`, table labels).
    public var harnessKind: String {
        switch self {
        case .lean:      return "weighted_lean"
        case .fixedGain: return "weighted_gain"
        case .hybrid:    return "weighted_hybrid"
        }
    }

    /// The strength per level (1…`WeightedDice.levels`): κ for lean, g in win-chance pp per
    /// roll (each side's roll, #271) for fixed gain and hybrid. **The one place the grids
    /// live** (Python `LEAN_KAPPAS` / `GAIN_STEPS_PP` / `HYBRID_STEPS_PP`). Recalibrated for
    /// the mirrored bend (#271, gold_v11 1-ply self-play, `scripts/weighted_dice_calibration.py`)
    /// so each level's total gain per game (own + mirrored rolls) is about the one-sided #261
    /// level's or a little more: see `firstOrderGainPerGame`.
    public var strengths: [Double] {
        switch self {
        case .lean:      return [0.025, 0.045, 0.085, 0.15]
        case .fixedGain: return [0.1, 0.2, 0.4, 0.7]
        case .hybrid:    return [0.1, 0.2, 0.35, 0.5]
        }
    }

    /// Each level's calibrated first-order gain per game in house Plakoto (pp; the sum over
    /// the favoured side's rolls of E_q[v] − μ plus, mirrored (#271), over the opponent's rolls
    /// of μ − E_q[v]; `scripts/weighted_dice_calibration.py`). Not a measured win rate: used
    /// only to migrate old β settings and to tell which side a two-sided setup favours
    /// (`WeightedDice.approximateLogOddsShift`), never shown.
    public var firstOrderGainPerGame: [Double] {
        switch self {
        case .lean:      return [8, 15, 28, 50]
        case .fixedGain: return [7, 15, 30, 51]
        case .hybrid:    return [7, 15, 26, 35]
        }
    }
}

/// One side's weighted dice (#261): a mode and a level (0 = off, 1…`levels` = Slight …
/// Very strong). Every "off" value is equal whatever its mode, so an off side is still
/// `HandicapItems.none`.
public struct WeightedDice: Codable, Hashable, Sendable {
    public var mode: WeightedDiceMode
    public var level: Int

    /// Strength levels per mode (Slight, Moderate, Strong, Very strong).
    public static let levels = 4
    public static let off = WeightedDice(mode: .hybrid, level: 0)

    public init(mode: WeightedDiceMode, level: Int) {
        self.mode = mode
        self.level = level
    }

    public var isOn: Bool { level > 0 }

    /// κ (lean) or g in win-chance pp per roll (fixed gain, hybrid); 0 when off.
    public var strength: Double {
        guard isOn else { return 0 }
        let steps = mode.strengths
        return steps[min(level, steps.count) - 1]
    }

    /// Level clamped to 0…`levels`; off normalises to `.off`.
    public var clamped: WeightedDice {
        let l = min(max(level, 0), Self.levels)
        return l == 0 ? .off : WeightedDice(mode: mode, level: l)
    }

    /// An old fixed-β setting (before #261, `HandicapItems.diceTilt`) as hybrid dice of a
    /// comparable strength: the old β's first-order gain per game (≈ 13.5 pp per unit β,
    /// E1) matched to the nearest hybrid level's total gain (+7 / +15 / +26 / +35 pp, mirrored
    /// since #271). The old app steps β 0.3 / 0.6 / 1.2 / 2.0 become levels 1 / 1 / 2 / 3;
    /// β ≤ 0 is off.
    public static func migrating(beta: Double) -> WeightedDice {
        guard beta.isFinite, beta > 0 else { return .off }
        let gain = 13.5 * beta
        let perLevel = WeightedDiceMode.hybrid.firstOrderGainPerGame
        let level = perLevel.indices.min { abs(perLevel[$0] - gain) < abs(perLevel[$1] - gain) }! + 1
        return WeightedDice(mode: .hybrid, level: level)
    }

    /// A rough log-odds shift for the favoured side, for `HandicapEstimator.favouredSide`
    /// only (weighted dice have no measured estimate, #261): the level's first-order gain
    /// per game × 0.8 (E1 measured ≈ 0.8–0.9× the first-order sum for the old fixed β) as
    /// a win rate above 50 %, capped at 95 %. 0 when off.
    public var approximateLogOddsShift: Double {
        guard isOn else { return 0 }
        let gains = mode.firstOrderGainPerGame
        let p = min(0.5 + 0.8 * gains[min(level, gains.count) - 1] / 100, 0.95)
        return log(p / (1 - p))
    }

    public static func == (a: WeightedDice, b: WeightedDice) -> Bool {
        (!a.isOn && !b.isOn) || (a.mode == b.mode && a.level == b.level)
    }

    public func hash(into h: inout Hasher) {
        if isOn { h.combine(mode); h.combine(level) } else { h.combine(0) }
    }

    private enum CodingKeys: String, CodingKey { case mode, level }

    /// Tolerant: an unknown mode (a later build) reads as hybrid.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(WeightedDiceMode.self, forKey: .mode)) ?? .hybrid
        level = (try? c.decodeIfPresent(Int.self, forKey: .level)) ?? 0
    }
}

/// One side's tier-1 handicaps. All defaults = no handicap for that side.
public struct HandicapItems: Codable, Equatable, Hashable, Sendable {
    /// Checkers that start 6 pips advanced (0…8). Mirrors `pip_headstart` in
    /// `domain/handicap.py` (there given as a bonus kind on the opponent's spec).
    public var headStart: Int
    /// This side always starts; no opening roll-off.
    public var movesFirst: Bool
    /// Weighted dice (#261: mode + level; `.off` = fair). Before this side rolls, each of
    /// the 21 distinct rolls is tilted by `exp(β_t · v(roll))`, `v` = the side's best 1-ply
    /// move value, β_t chosen per turn by the mode. See `HandicapDice`.
    public var weightedDice: WeightedDice
    /// Rerolls per game (0…4).
    public var rerolls: Int
    /// Hints per game (0…5); only meaningful for a human side.
    public var hints: Int

    // ── Tier 2 (#148 P3b): this side's own rules (`SideRules`), defaults = normal. ──

    /// This side may bear off with a higher die (only from its farthest occupied point).
    public var overshoot: Bool
    /// This side's safe point (own numbering, one of `HandicapSetup.safePointCandidates`;
    /// 0 = none): a lone checker of this side there cannot be pinned.
    public var safePoint: Int
    /// This side's checker count (13…17, default 15). More checkers is the advantage.
    public var checkers: Int
    /// This side bears off only from its last `homeSize` points (6 default, 5/4/3).
    public var homeSize: Int

    public init(headStart: Int = 0, movesFirst: Bool = false, weightedDice: WeightedDice = .off,
                rerolls: Int = 0, hints: Int = 0, overshoot: Bool = false, safePoint: Int = 0,
                checkers: Int = HandicapSetup.normalCheckers, homeSize: Int = HandicapSetup.normalHomeSize) {
        self.headStart = headStart
        self.movesFirst = movesFirst
        self.weightedDice = weightedDice
        self.rerolls = rerolls
        self.hints = hints
        self.overshoot = overshoot
        self.safePoint = safePoint
        self.checkers = checkers
        self.homeSize = homeSize
    }

    public static let none = HandicapItems()

    /// No handicap on this side.
    public var isEmpty: Bool { self == .none }

    /// Any tier-2 (rule) item on this side.
    public var hasTier2: Bool { sideRules != .normal }

    /// This side's tier-2 rules.
    public var sideRules: SideRules {
        SideRules(overshoot: overshoot, safePoint: safePoint, checkers: checkers, homeSize: homeSize)
    }

    /// The same side with every tier-2 item off.
    public var tier1Only: HandicapItems {
        var t = self
        t.overshoot = false
        t.safePoint = 0
        t.checkers = HandicapSetup.normalCheckers
        t.homeSize = HandicapSetup.normalHomeSize
        return t
    }

    // Decode tolerantly: a missing key is "off" (a later version may add items, and a
    // version-1 setup has no tier-2 keys). An older build ignores the tier-2 keys.
    // `diceTilt` is the pre-#261 fixed β: read (migrated to hybrid), never written.
    private enum CodingKeys: String, CodingKey {
        case headStart, movesFirst, weightedDice, diceTilt, rerolls, hints, overshoot, safePoint, checkers, homeSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headStart = try c.decodeIfPresent(Int.self, forKey: .headStart) ?? 0
        movesFirst = try c.decodeIfPresent(Bool.self, forKey: .movesFirst) ?? false
        if let dice = try c.decodeIfPresent(WeightedDice.self, forKey: .weightedDice) {
            weightedDice = dice.clamped
        } else {
            weightedDice = .migrating(beta: (try? c.decodeIfPresent(Double.self, forKey: .diceTilt)) ?? 0)
        }
        rerolls = try c.decodeIfPresent(Int.self, forKey: .rerolls) ?? 0
        hints = try c.decodeIfPresent(Int.self, forKey: .hints) ?? 0
        overshoot = try c.decodeIfPresent(Bool.self, forKey: .overshoot) ?? false
        safePoint = try c.decodeIfPresent(Int.self, forKey: .safePoint) ?? 0
        checkers = try c.decodeIfPresent(Int.self, forKey: .checkers) ?? HandicapSetup.normalCheckers
        homeSize = try c.decodeIfPresent(Int.self, forKey: .homeSize) ?? HandicapSetup.normalHomeSize
    }

    /// Weighted dice are written only when on (an older build reading this sees fair dice).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(headStart, forKey: .headStart)
        try c.encode(movesFirst, forKey: .movesFirst)
        if weightedDice.isOn { try c.encode(weightedDice, forKey: .weightedDice) }
        try c.encode(rerolls, forKey: .rerolls)
        try c.encode(hints, forKey: .hints)
        try c.encode(overshoot, forKey: .overshoot)
        try c.encode(safePoint, forKey: .safePoint)
        try c.encode(checkers, forKey: .checkers)
        try c.encode(homeSize, forKey: .homeSize)
    }

    /// Clamped into the supported ranges (an unknown safe point is dropped).
    public var clamped: HandicapItems {
        HandicapItems(headStart: min(max(headStart, 0), HandicapSetup.maxHeadStart),
                      movesFirst: movesFirst,
                      weightedDice: weightedDice.clamped,
                      rerolls: min(max(rerolls, 0), HandicapSetup.maxRerolls),
                      hints: min(max(hints, 0), HandicapSetup.maxHints),
                      overshoot: overshoot,
                      safePoint: HandicapSetup.safePointCandidates.contains(safePoint) ? safePoint : 0,
                      checkers: min(max(checkers, HandicapSetup.checkerRange.lowerBound),
                                    HandicapSetup.checkerRange.upperBound),
                      homeSize: min(max(homeSize, HandicapSetup.homeSizes.last!), HandicapSetup.normalHomeSize))
    }
}

/// A complete tier-1 handicap description, per side. Codable + versioned; persisted in
/// `GameSave.handicap` (inside `HandicapGameState`) and `HumanGameRecord.handicap`.
public struct HandicapSetup: Codable, Equatable, Hashable, Sendable {
    /// The schema this build writes. A newer version still decodes (unknown items are
    /// ignored), so an old reader plays the items it knows. Version 2 (#148 P3b) adds the
    /// tier-2 items (overshoot, safe point, checkers, home size); a version-1 build ignores
    /// them and would replay such a game under the normal rules. Version 3 (#261) replaces the
    /// fixed-β `diceTilt` with `weightedDice` (mode + level); an older build reads such a side
    /// as fair dice, and this build migrates an old `diceTilt` to hybrid dice
    /// (`WeightedDice.migrating(beta:)`).
    public static let currentVersion = 3

    /// Capped at 4 by E1 (docs/handicap-e1-tier1.md): the head start's effect saturates
    /// (m = 4: +8.0 pp, 6: +9.2, 8: +7.6) and the net's start-position estimate is within
    /// 1 pp up to m = 4 but 3–5 pp off beyond.
    public static let maxHeadStart = 4
    public static let maxRerolls = 4
    public static let maxHints = 5
    /// Pips a head-start checker starts ahead (`pip_headstart`: 6).
    public static let headStartPips = 6
    /// Tier 2: safe-point candidates in the side's own numbering (`SAFE_POINT_CANDIDATES`:
    /// the opponent's home and the near outer board; 1 would be mother protection).
    public static let safePointCandidates = [2, 4, 6, 8, 10, 12]
    /// Tier 2: checker counts a side may play with (`MIN_CHECKERS…MAX_CHECKERS`).
    public static let checkerRange = 13...17
    public static let normalCheckers = 15
    /// Tier 2: home sizes, normal first.
    public static let homeSizes = [6, 5, 4, 3]
    public static let normalHomeSize = 6
    /// The variant the head start and the tier-2 rule changes are defined for (house
    /// Plakoto, #148): its start stacks and move generator. Every other item — weighted
    /// dice, rerolls, hints, moves first — works in every variant (#246).
    public static let positionAndRulesVariantID = "plakoto"

    public var version: Int
    public var white: HandicapItems
    public var black: HandicapItems
    /// The weighted dice, rerolls or hints were changed during the game (#236). The setup
    /// then holds the **final** values; head start, moves first and the tier-2 rules never
    /// change mid-game, so replays and the review still start from the same position under
    /// the same rules. Written only when true (an unadjusted setup encodes as before).
    public var adjusted: Bool
    /// An adjusted game had weighted dice or rerolls at some point before its final setup
    /// (#236), so its dice were not fair even if the final setup's are (`altersDice`).
    /// Written only when true.
    public var alteredDiceEarlier: Bool

    public init(white: HandicapItems = .none, black: HandicapItems = .none,
                version: Int = HandicapSetup.currentVersion,
                adjusted: Bool = false, alteredDiceEarlier: Bool = false) {
        self.version = version
        self.white = white
        self.black = black
        self.adjusted = adjusted
        self.alteredDiceEarlier = alteredDiceEarlier
    }

    public subscript(color: Color) -> HandicapItems {
        get { color == .white ? white : black }
        set { if color == .white { white = newValue } else { black = newValue } }
    }

    /// Any handicap on either side.
    public var isActive: Bool { !white.isEmpty || !black.isEmpty }

    /// Clamped ranges; "moves first" on both sides cancels out (the normal start rule
    /// applies), so it is dropped from both.
    public var normalized: HandicapSetup {
        var s = HandicapSetup(white: white.clamped, black: black.clamped, version: version,
                              adjusted: adjusted, alteredDiceEarlier: alteredDiceEarlier)
        if s.white.movesFirst && s.black.movesFirst {
            s.white.movesFirst = false
            s.black.movesFirst = false
        }
        return s
    }

    /// The side that must start ("moves first"), or `nil` for the normal start rule.
    public var forcedStarter: Color? {
        let n = normalized
        if n.white.movesFirst { return .white }
        if n.black.movesFirst { return .black }
        return nil
    }

    /// The starter of a game under `setup`: the "moves first" side, else `defaultStarter`
    /// (the opening roll's winner, a forced first move, or a best-of-three game's
    /// alternating starter — "moves first" overrides the alternation every game).
    public static func startingPlayer(for setup: HandicapSetup?, default defaultStarter: Color) -> Color {
        setup?.forcedStarter ?? defaultStarter
    }

    /// Any tier-2 (rule) item on either side.
    public var hasTier2: Bool { white.hasTier2 || black.hasTier2 }

    /// The tier-2 rules the game is played under, or `nil` when there are none (the
    /// normal rules and move generator).
    public var rules: HandicapRules? {
        let n = normalized
        guard n.hasTier2 else { return nil }
        return HandicapRules(white: n.white.sideRules, black: n.black.sideRules)
    }

    /// The same setup with every tier-2 item off (the net's position estimate, which
    /// must not see the tier-2 rules: §11).
    public var tier1Only: HandicapSetup {
        HandicapSetup(white: white.tier1Only, black: black.tier1Only, version: version,
                      adjusted: adjusted, alteredDiceEarlier: alteredDiceEarlier)
    }

    /// The setup the next game of a match (or a "new game") starts with (#236): the same
    /// items, without the mid-game adjustment marks (a fresh game is not adjusted).
    public var forNextGame: HandicapSetup {
        HandicapSetup(white: white, black: black, version: version)
    }

    /// Whether a game holds on to this setup: any item, or an adjusted game whose items
    /// were all switched off mid-game (#236; it stays a handicap game, tagged adjusted).
    public var isKept: Bool { isActive || adjusted }

    /// The colours this setup helps (#236): a side's own head start, moves first, weighted
    /// dice, rerolls, hints, overshoot, safe point or extra checkers help it; fewer checkers
    /// or a smaller home help its opponent.
    public var beneficiaries: Set<Color> {
        var out: Set<Color> = []
        let n = normalized
        for c in Color.allCases {
            let i = n[c]
            if i.headStart > 0 || i.movesFirst || i.weightedDice.isOn || i.rerolls > 0 || i.hints > 0
                || i.overshoot || i.safePoint > 0 || i.checkers > Self.normalCheckers {
                out.insert(c)
            }
            if i.checkers < Self.normalCheckers || i.homeSize < Self.normalHomeSize {
                out.insert(c.opponent)
            }
        }
        return out
    }

    /// Whether either side's dice are tilted.
    public var hasWeightedDice: Bool { white.weightedDice.isOn || black.weightedDice.isOn }
    /// The weighted-dice levels as one signed number relative to White (White's level
    /// minus Black's; the online stamp, #272, where only one side ever holds them).
    public var whiteWeightedLevel: Int {
        (white.weightedDice.isOn ? white.weightedDice.level : 0)
            - (black.weightedDice.isOn ? black.weightedDice.level : 0)
    }
    /// Whether either side has rerolls.
    public var hasRerolls: Bool { white.rerolls > 0 || black.rerolls > 0 }
    /// Whether the dice were not fair for the whole game (weighted dice or rerolls):
    /// the review's win chances, which assume fair dice, then carry a note.
    /// An adjusted game (#236) counts its earlier weighted dice / rerolls too.
    public var altersDice: Bool { hasWeightedDice || hasRerolls || alteredDiceEarlier }
    /// Whether any item needs the value net during play (dice, rerolls, hints).
    public var needsEvaluator: Bool {
        hasWeightedDice || hasRerolls || white.hints > 0 || black.hints > 0
    }

    /// Whether a game of `variantID` can be a handicap game at all: every registered
    /// variant (#246) — weighted dice, rerolls, hints and moves first need only the
    /// variant's own value net and rules.
    public static func supports(variantID: String) -> Bool { GameVariants.variant(forID: variantID) != nil }

    /// Whether the head start and the tier-2 rule changes are defined for `variantID`
    /// (house Plakoto only). Full Tavli never uses them, not even in its Plakoto leg
    /// (`availability(_:variantID:fullTavli:)`).
    public static func supportsHeadStartAndRules(variantID: String) -> Bool {
        variantID == positionAndRulesVariantID
    }

    /// Whether `item` can be used in a game of `variantID` (#246); `fullTavli` = a leg of
    /// a Full Tavli session. The builder shows an unavailable item disabled with the
    /// reason; a game never applies it.
    public static func availability(_ item: HandicapItemKind, variantID: String,
                                    fullTavli: Bool = false) -> HandicapAvailability {
        guard item.needsHouseRules else { return .available }
        if fullTavli { return .notInFullTavli }
        return supportsHeadStartAndRules(variantID: variantID) ? .available : .houseRulesOnly
    }

    /// The setup a game of `variantID` is played under (#246): unchanged in house
    /// Plakoto; elsewhere — and in every Full Tavli leg — the head start and the tier-2
    /// rule changes are dropped (weighted dice, rerolls, hints and moves first stay).
    /// May come out inactive (only dropped items were set): then it is a normal game.
    public func restricted(toVariantID variantID: String, fullTavli: Bool = false) -> HandicapSetup {
        guard fullTavli || !Self.supportsHeadStartAndRules(variantID: variantID) else { return self }
        var s = self
        for c in Color.allCases {
            s[c] = s[c].tier1Only
            s[c].headStart = 0
        }
        return s
    }

    /// Lay out the handicapped starting position: each side's start stack holds its
    /// checker count (15, or its tier-2 count), then its head-start checkers move 6 pips
    /// forward. Reproduces `HandicappedPlakotoRules.initial_board` (`domain/handicap.py`,
    /// `pip_headstart` + `checkers`): White's start point 1 → point 7, Black's 24 → 18.
    /// The board's config must carry `rules` (`GameConfig.applying(_:)`) for the game to
    /// be played under them. **Keep in sync with the Python** (pinned by `HandicapTests`).
    public func setUpInitialPosition(on board: GameBoard) {
        board.variant.setUpInitialPosition(on: board)
        // Only house Plakoto has a head start / tier-2 checker count (#246): every other
        // variant keeps its own start position (its stacks are not on points 1 / 24).
        guard Self.supportsHeadStartAndRules(variantID: board.variant.id) else { return }
        let n = normalized
        let size = board.boardSize
        for color in Color.allCases {
            let count = n[color].checkers
            let m = min(n[color].headStart, count - 1)
            let start = color == .white ? 1 : size
            board.setPoint(start, pieces: Array(repeating: color, count: count - m))
            guard m > 0 else { continue }
            let ahead = color == .white ? start + Self.headStartPips : start - Self.headStartPips
            board.setPoint(ahead, pieces: Array(repeating: color, count: m))
        }
    }

    // Tolerant decode: items default to "off"; version defaults to 1; the #236
    // adjustment marks default to false (every pre-#236 setup).
    private enum CodingKeys: String, CodingKey { case version, white, black, adjusted, alteredDiceEarlier }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        white = try c.decodeIfPresent(HandicapItems.self, forKey: .white) ?? .none
        black = try c.decodeIfPresent(HandicapItems.self, forKey: .black) ?? .none
        adjusted = (try? c.decodeIfPresent(Bool.self, forKey: .adjusted)) ?? false
        alteredDiceEarlier = (try? c.decodeIfPresent(Bool.self, forKey: .alteredDiceEarlier)) ?? false
    }

    /// The marks are written only when set, so an unadjusted setup encodes exactly as
    /// before #236 (and an older reader just ignores them).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(white, forKey: .white)
        try c.encode(black, forKey: .black)
        if adjusted { try c.encode(true, forKey: .adjusted) }
        if alteredDiceEarlier { try c.encode(true, forKey: .alteredDiceEarlier) }
    }
}

/// The handicap items as the builder lists them (#246), for per-variant availability.
public enum HandicapItemKind: String, CaseIterable, Sendable {
    case headStart, movesFirst, weightedDice, rerolls, hints
    /// Tier 2: overshoot bear-off, safe point, checkers, home size.
    case ruleChanges

    /// Defined only for house Plakoto's start position / move generator.
    public var needsHouseRules: Bool { self == .headStart || self == .ruleChanges }
}

/// Whether a handicap item can be used in a kind of game (#246).
public enum HandicapAvailability: Equatable, Sendable {
    case available
    /// Only in house Plakoto (another variant's start position / rules). Since #258 house
    /// Plakoto is Plakoto with the House rules switch on (`VariantPreference`).
    case houseRulesOnly
    /// Not in Full Tavli (one setup runs through all three legs).
    case notInFullTavli

    public var isAvailable: Bool { self == .available }
}

/// A count per side (tokens left).
public struct SideCounts: Codable, Equatable, Hashable, Sendable {
    public var white: Int
    public var black: Int

    public init(white: Int = 0, black: Int = 0) {
        self.white = white
        self.black = black
    }

    public subscript(color: Color) -> Int {
        get { color == .white ? white : black }
        set { if color == .white { white = newValue } else { black = newValue } }
    }
}

/// A live handicap game: the setup plus the tokens left. This is what `GameSave`
/// persists under the optional `handicap` key (no schema bump: an old reader ignores
/// the key and loads the game unhandicapped; a save without it is byte-identical to
/// before).
public struct HandicapGameState: Codable, Equatable, Sendable {
    public var setup: HandicapSetup
    public var rerollsLeft: SideCounts
    public var hintsLeft: SideCounts

    /// A fresh game: every token available.
    public init(setup: HandicapSetup) {
        let s = setup.normalized
        self.setup = s
        self.rerollsLeft = SideCounts(white: s.white.rerolls, black: s.black.rerolls)
        self.hintsLeft = SideCounts(white: s.white.hints, black: s.black.hints)
    }

    public init(setup: HandicapSetup, rerollsLeft: SideCounts, hintsLeft: SideCounts) {
        self.setup = setup.normalized
        self.rerollsLeft = rerollsLeft
        self.hintsLeft = hintsLeft
    }

    private enum CodingKeys: String, CodingKey { case setup, rerollsLeft, hintsLeft }

    /// Tolerant: missing token counts mean "all left"; counts are clamped to the setup.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = HandicapGameState(setup: try c.decode(HandicapSetup.self, forKey: .setup))
        setup = fresh.setup
        let r = try c.decodeIfPresent(SideCounts.self, forKey: .rerollsLeft) ?? fresh.rerollsLeft
        let h = try c.decodeIfPresent(SideCounts.self, forKey: .hintsLeft) ?? fresh.hintsLeft
        rerollsLeft = SideCounts(white: min(max(r.white, 0), fresh.rerollsLeft.white),
                                 black: min(max(r.black, 0), fresh.rerollsLeft.black))
        hintsLeft = SideCounts(white: min(max(h.white, 0), fresh.hintsLeft.white),
                               black: min(max(h.black, 0), fresh.hintsLeft.black))
    }
}

public extension GameRecord {
    /// The config this game is replayed under: its variant plus any tier-2 rules (#148).
    var replayConfig: GameConfig { GameConfig(variantID: variantID).applying(handicap) }

    /// Lay out this game's starting position: the variant's, plus any handicap head
    /// start (#148). Every replay from the start (review, notation, resume) goes
    /// through this so a head-start game reconstructs exactly.
    func setUpInitialPosition(on board: GameBoard) {
        if let handicap {
            handicap.setUpInitialPosition(on: board)
        } else {
            board.variant.setUpInitialPosition(on: board)
        }
    }
}
