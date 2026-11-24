import Foundation

/// A traditional Greek Tavli session (#144): three consecutive games — Portes, then
/// Fevga, then Plakoto — with a running score across all three. A pure value type
/// like `MatchState`: it only carries the leg sequence and the results between the
/// ordinary `GameSession`s that play each leg — no board state.
///
/// **Scoring.** Each side's total is the sum of the **points** of the legs it won: a
/// double game counts 2 in a variant with `maxPoints > 1` (Portes, Fevga, standard
/// Plakoto), house Plakoto wins count 1, and a drawn leg (standard Plakoto) scores 0
/// for both — the session still advances. After the third leg the higher total wins;
/// equal totals are a drawn session (no tiebreak game).
///
/// **The Plakoto leg** is standard `plakoto_standard`, or house-rules `plakoto` when the
/// House rules switch is on (#258, `init(houseRules:aiColor:handicap:)`,
/// `plakotoLegVariantID(houseRules:)`); it is fixed when the session is created, so a
/// resumed session keeps its own rules whatever the switch says now. A stored session
/// without the field (pre-#144 data) decodes as house Plakoto, the rules it was played under.
///
/// **Persistence.** `Codable` and carried by `GameSave.fullTavli` next to the leg in
/// progress (or the leg just finished, between legs). `resume(savedGame:)` reconciles
/// the two after a relaunch: it decides whether the save is mid-leg or between legs and
/// records a finished leg the session had not yet counted. Colours are stored as raw
/// "W"/"B" strings, like `MatchState` (`Color` itself is not `Codable`).
///
/// **Handicap (#246).** One `handicap` setup runs through all three legs: weighted
/// dice, rerolls, hints and moves first only (the head start and the tier-2 rule
/// changes are off in Full Tavli, `HandicapSetup.restricted(toVariantID:fullTavli:)`).
/// Each leg starts with fresh tokens (`setupForCurrentLeg`), "moves first" makes the
/// favoured side start every leg (`startingPlayer(default:)`), and a leg's mid-game
/// adjustments (#236) carry over to the next leg (`carryHandicap(from:)`), like the
/// games of a best-of-three. Persisted with the session (`GameSave.fullTavli`), so it
/// survives a relaunch between legs; mid-leg the leg's own `GameSave.handicap` holds
/// its tokens left.
public struct FullTavliSession: Codable, Equatable, Sendable {
    /// Number of legs in a session.
    public static let legCount = 3

    /// `GameVariant.id` of the third (Plakoto) leg: `plakoto` or `plakoto_standard`.
    public let plakotoVariantID: String
    /// The AI's side, or `nil` for a two-player (pass-and-play) session. The same
    /// colours are kept for all three legs.
    public let aiColor: Color?
    /// Result of each finished leg, in play order (draws included).
    public private(set) var results: [MatchGameResult]
    /// The handicap every remaining leg is played under (#246), or `nil` for none.
    /// Always restricted to what Full Tavli supports; an inactive setup is stored as nil.
    public private(set) var handicap: HandicapSetup?

    public init(plakotoVariantID: String = GameVariants.plakoto.id,
                aiColor: Color? = nil,
                results: [MatchGameResult] = [],
                handicap: HandicapSetup? = nil) {
        self.plakotoVariantID = Self.plakotoLegVariantID(preferredID: plakotoVariantID)
        self.aiColor = aiColor
        self.results = Array(results.prefix(Self.legCount))
        self.handicap = Self.sessionHandicap(handicap)
    }

    /// A fresh session whose Plakoto leg follows the House rules switch (#258): house
    /// Plakoto when on, standard Plakoto when off.
    public init(houseRules: Bool, aiColor: Color?, handicap: HandicapSetup? = nil) {
        self.init(plakotoVariantID: Self.plakotoLegVariantID(houseRules: houseRules),
                  aiColor: aiColor, handicap: handicap)
    }

    /// `setup` as a Full Tavli session keeps it: normalized, without the head start and
    /// the tier-2 rules, without the mid-game adjustment marks; `nil` when nothing is left.
    static func sessionHandicap(_ setup: HandicapSetup?) -> HandicapSetup? {
        guard let setup else { return nil }
        let s = setup.normalized.restricted(toVariantID: GameVariants.portes.id, fullTavli: true).forNextGame
        return s.isActive ? s : nil
    }

    // ── Handicap (#246) ──────────────────────────────────────────────────────

    /// The setup the current leg starts with (fresh tokens, no adjustment marks), or
    /// `nil` for a normal leg / a complete session.
    public var setupForCurrentLeg: HandicapSetup? {
        guard let variant = currentVariant, let handicap else { return nil }
        let s = handicap.restricted(toVariantID: variant.id, fullTavli: true)
        return s.isActive ? s : nil
    }

    /// The starter of the current leg: the "moves first" side in every leg, else
    /// `defaultStarter` (the opening roll, the First-move setting, or the variant's rule).
    public func startingPlayer(default defaultStarter: Color) -> Color {
        HandicapSetup.startingPlayer(for: handicap, default: defaultStarter)
    }

    /// Carry a finished leg's handicap into the next legs: its final values if it was
    /// adjusted during the leg (#236), so a change counts for the rest of the session like
    /// in a best-of-three; a setup adjusted down to nothing makes the next legs normal.
    /// A leg played without a handicap leaves the session's setup alone.
    public mutating func carryHandicap(from record: GameRecord) {
        guard let played = record.handicap else { return }
        handicap = Self.sessionHandicap(played)
    }

    /// The Plakoto leg's rules for the House rules switch (#258).
    public static func plakotoLegVariantID(houseRules: Bool) -> String {
        houseRules ? GameVariants.plakoto.id : GameVariants.plakotoStandard.id
    }

    /// Normalizes a stored Plakoto-leg id: standard Plakoto stays, anything else (house
    /// `plakoto`, or an unknown id) is house Plakoto — the pre-#258 sessions' default.
    public static func plakotoLegVariantID(preferredID: String?) -> String {
        preferredID == GameVariants.plakotoStandard.id ? GameVariants.plakotoStandard.id
                                                       : GameVariants.plakoto.id
    }

    // ── Legs ─────────────────────────────────────────────────────────────────

    /// Variant ids of the three legs, in play order.
    public var legVariantIDs: [String] {
        [GameVariants.portes.id, GameVariants.fevga.id, plakotoVariantID]
    }

    /// The three legs' rules, in play order.
    public var legVariants: [any GameVariant] {
        legVariantIDs.map { GameVariants.variant(forID: $0) ?? GameVariants.plakoto }
    }

    /// Legs finished so far (0…3).
    public var completedLegs: Int { results.count }

    /// 0-based index of the leg being played (or about to be); `nil` once complete.
    public var currentLegIndex: Int? { isComplete ? nil : results.count }

    /// The current leg's rules; `nil` once the session is complete.
    public var currentVariant: (any GameVariant)? {
        currentLegIndex.map { legVariants[$0] }
    }

    /// 1-based number of the current leg ("Game 2 of 3"), capped at 3.
    public var currentLegNumber: Int { min(results.count + 1, Self.legCount) }

    /// The leg a game of `variantID` belongs to, or `nil` if it is not one of them.
    public func legIndex(ofVariantID variantID: String) -> Int? {
        legVariantIDs.firstIndex(of: variantID)
    }

    // ── Score + outcome ──────────────────────────────────────────────────────

    /// `color`'s running total: the points of every leg it won.
    public func score(for color: Color) -> Int {
        results.filter { $0.winner == color }.reduce(0) { $0 + $1.points }
    }

    /// All three legs have been played.
    public var isComplete: Bool { results.count >= Self.legCount }

    /// The session winner once complete (higher total), or `nil` — while running, or
    /// for a drawn session (`isDrawn`).
    public var winner: Color? {
        guard isComplete else { return nil }
        let w = score(for: .white), b = score(for: .black)
        if w == b { return nil }
        return w > b ? .white : .black
    }

    /// Complete with equal totals — shown as a drawn session (no tiebreak game).
    public var isDrawn: Bool { isComplete && winner == nil }

    // ── Advance ──────────────────────────────────────────────────────────────

    /// Record the current leg's result and advance to the next leg. Points are clamped
    /// to the leg's `maxPoints` (a house-Plakoto win is always 1) and a draw scores 0.
    /// No-op once the session is complete, so a stray extra game never changes it.
    public mutating func record(_ result: MatchGameResult) {
        guard let leg = currentLegIndex else { return }
        guard let winner = result.winner else {
            results.append(.draw)
            return
        }
        let points = min(result.points, legVariants[leg].maxPoints)
        results.append(.win(winner, points: points))
    }

    /// Record the current leg: `winner == nil` is a draw (no points).
    public mutating func recordGame(winner: Color?, points: Int) {
        record(MatchGameResult(winner: winner, points: points))
    }

    // ── AI gating ────────────────────────────────────────────────────────────

    /// Whether every leg has a bundled model, i.e. the whole session can be played
    /// against the AI. A two-player session never needs one.
    public func isAIAvailable(in catalog: ModelCatalog = .main) -> Bool {
        legVariants.allSatisfy(catalog.isAvailable)
    }

    /// The legs whose model is missing ("Computer not available yet"), in play order.
    public func unavailableLegVariantIDs(in catalog: ModelCatalog = .main) -> [String] {
        legVariants.filter { !catalog.isAvailable($0) }.map(\.id)
    }

    // ── Resume ───────────────────────────────────────────────────────────────

    /// Where a resumed session stands.
    public enum ResumePoint: Equatable, Sendable {
        /// Mid-leg: resume the saved game (leg `index`, 0-based).
        case inLeg(index: Int)
        /// Between legs: the saved game was leg `nextIndex - 1` and is finished; show
        /// the transition screen for leg `nextIndex`.
        case betweenLegs(nextIndex: Int)
        /// All three legs are done: show the session result.
        case complete
    }

    /// Reconcile the session with the game saved next to it and say where to resume.
    /// A finished saved game whose leg the session has not yet counted (the app was
    /// killed between the last move's autosave and the result being recorded) is
    /// recorded here, so it can never be lost or counted twice.
    public mutating func resume(savedGame record: GameRecord) -> ResumePoint {
        let finished = record.isDraw || record.outcome != nil
        if finished, let leg = legIndex(ofVariantID: record.variantID), leg == results.count,
           let result = record.result {
            carryHandicap(from: record)   // #246, as the live game-over hook does
            self.record(result)
        }
        if isComplete { return .complete }
        if finished { return .betweenLegs(nextIndex: results.count) }
        return .inLeg(index: results.count)
    }

    // ── Codable (raw "W"/"B" colours) ────────────────────────────────────────

    // `handicap` (#246) is optional and written only when set: a session without one
    // encodes exactly as before, and an older build ignores the key (then plays the
    // remaining legs without the handicap). A malformed one decodes as none.
    private enum CodingKeys: String, CodingKey { case plakotoVariantID, aiColor, results, handicap }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            plakotoVariantID: try c.decodeIfPresent(String.self, forKey: .plakotoVariantID)
                ?? GameVariants.plakoto.id,
            aiColor: try c.decodeIfPresent(String.self, forKey: .aiColor).flatMap(Color.init(rawValue:)),
            results: try c.decodeIfPresent([MatchGameResult].self, forKey: .results) ?? [],
            handicap: (try? c.decodeIfPresent(HandicapSetup.self, forKey: .handicap)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(plakotoVariantID, forKey: .plakotoVariantID)
        try c.encodeIfPresent(aiColor?.rawValue, forKey: .aiColor)
        try c.encode(results, forKey: .results)
        try c.encodeIfPresent(handicap, forKey: .handicap)
    }
}
