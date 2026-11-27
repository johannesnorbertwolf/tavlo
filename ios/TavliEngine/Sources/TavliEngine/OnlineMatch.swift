import Foundation

/// Errors decoding an online match payload.
public enum OnlineMatchError: Error, Equatable {
    /// The payload was written by a newer build than this one understands.
    case unsupportedSchemaVersion(Int)
}

/// One game within an online match (#145): its ordered ply log and, once the game is
/// over, its result. Storing the result explicitly lets every device read the match
/// score without re-running the engine; the plies stay so the opponent can replay and
/// animate the game (including its final move) and so reconnection is exact.
///
/// #143 adds `drawn` and `points` for the new variants (a standard-Plakoto draw, a
/// 2-point win). Both are optional keys written only when meaningful (synthesized
/// `Codable` skips `nil`), so a Plakoto payload is byte-identical to before and an
/// older payload decodes as 1-point wins.
public struct GameLog: Codable, Equatable, Sendable {
    public var plies: [PlyRecord]
    /// Raw `Color` value ("W"/"B") of the winner once the game is over, else `nil`.
    public var winnerRaw: String?
    /// `true` when the game ended in a draw (absent otherwise).
    public var drawn: Bool?
    /// Points the win was worth, written only for 2-point results (absent = 1).
    public var points: Int?

    public init(plies: [PlyRecord] = [], winner: Color? = nil) {
        self.plies = plies
        self.winnerRaw = winner?.rawValue
    }

    /// A game log carrying a finished game's `result` (`nil` = still in progress).
    public init(plies: [PlyRecord], result: MatchGameResult?) {
        self.init(plies: plies, winner: result?.winner)
        if result?.isDraw == true { drawn = true }
        if let p = result?.points, p > 1 { points = p }
    }

    public var winner: Color? { winnerRaw.flatMap(Color.init(rawValue:)) }
    public var isDraw: Bool { drawn == true && winner == nil }
    public var isComplete: Bool { winner != nil || isDraw }

    /// The finished game's result, or `nil` while it is in progress.
    public var result: MatchGameResult? {
        if isDraw { return .draw }
        return winner.map { .win($0, points: points ?? 1) }
    }
}

/// The mover's **turn in progress** (#269), written with `saveCurrentTurn` after the
/// roll and after each half-move / undo so the waiting player sees it live. Purely a
/// preview: the authoritative ply still arrives in `games` with `endTurn`, whose payload
/// carries no `liveTurn`. Older builds ignore the key.
public struct LiveTurn: Codable, Equatable, Sendable {
    /// Index of the game (into `games`) and of the ply in it that this turn will become
    /// (= that game's `plies.count` when written).
    public var gameIndex: Int
    public var plyIndex: Int
    /// Raw `Color` ("W"/"B") of the side on move.
    public var player: String
    public var die1: Int
    public var die2: Int
    /// The half-moves played so far, `[from, to]` single-die hops in play order.
    public var halfMoves: [[Int]]
    /// Increases with every update the mover writes, so a late (stale) update for the
    /// same ply never replaces a newer one.
    public var seq: Int

    public init(gameIndex: Int, plyIndex: Int, player: Color, die1: Int, die2: Int,
                halfMoves: [[Int]], seq: Int) {
        self.gameIndex = gameIndex
        self.plyIndex = plyIndex
        self.player = player.rawValue
        self.die1 = die1
        self.die2 = die2
        self.halfMoves = halfMoves
        self.seq = seq
    }

    public var playerColor: Color? { Color(rawValue: player) }

    /// Same turn state, ignoring `seq` (what the mover compares to skip no-op writes).
    public func sameState(as other: LiveTurn?) -> Bool {
        guard let other else { return false }
        return gameIndex == other.gameIndex && plyIndex == other.plyIndex
            && player == other.player && die1 == other.die1 && die2 == other.die2
            && halfMoves == other.halfMoves
    }
}

/// The match's **shared weighted-dice slider** (#272): one value both players see and
/// either may change, mirrored (#271: dice that lean towards good rolls for the favoured
/// side lean towards bad rolls for its opponent). Hybrid mode, the four `WeightedDice`
/// levels, stored as a **signed level relative to White** so each device shows it from
/// its own side ("favours you" / "favours <opponent>"). Match-wide: it carries over into
/// the next game of a best-of-three.
///
/// Every change gets the next `rev`; only the device **holding the Game Center turn**
/// mints a rev (it is the only one that can write the match data), so the revs of the
/// payloads form one sequence. The waiting player's change travels as an
/// `OnlineDiceRequest` (a GameKit exchange) and is minted by the turn holder, or by the
/// requester itself when its own turn comes (`OnlineMatchController`).
public struct OnlineDiceHandicap: Codable, Equatable, Sendable {
    /// The one mode used online (no mode picker online).
    public static let mode: WeightedDiceMode = .hybrid
    /// Fair dice, never changed (an absent key decodes as this).
    public static let fair = OnlineDiceHandicap()

    /// +n favours White at level n, −n favours Black, 0 = fair (|n| ≤ `WeightedDice.levels`).
    public var whiteLevel: Int
    /// Grows by one with every change, so devices agree which value is newest.
    public var rev: Int
    /// Raw colour ("W"/"B") of the player who made the latest change (`nil` = never).
    public var by: String?

    public init(whiteLevel: Int = 0, rev: Int = 0, by: Color? = nil) {
        self.whiteLevel = Self.clamp(whiteLevel)
        self.rev = max(0, rev)
        self.by = by?.rawValue
    }

    /// `level` (0…4) in favour of `favoured` (`nil` = fair).
    public init(favouring favoured: Color?, level: Int, rev: Int = 0, by: Color? = nil) {
        let l = favoured == nil ? 0 : Self.clamp(abs(level))
        self.init(whiteLevel: favoured == .black ? -l : l, rev: rev, by: by)
    }

    public static func clamp(_ level: Int) -> Int {
        min(max(level, -WeightedDice.levels), WeightedDice.levels)
    }

    /// The side the dice favour, or `nil` for fair dice.
    public var favoured: Color? { whiteLevel > 0 ? .white : (whiteLevel < 0 ? .black : nil) }
    /// The strength (0 = fair … 4 = very strong).
    public var level: Int { abs(whiteLevel) }
    public var isFair: Bool { whiteLevel == 0 }
    /// The level seen from `color`'s side: positive = favours `color`.
    public func level(towards color: Color) -> Int { color == .white ? whiteLevel : -whiteLevel }
    /// The favoured side's weighted dice (hybrid; off when fair).
    public var weightedDice: WeightedDice { WeightedDice(mode: Self.mode, level: level) }
    /// The player who made the latest change, if any.
    public var changedBy: Color? { by.flatMap(Color.init(rawValue:)) }

    private enum CodingKeys: String, CodingKey { case whiteLevel, rev, by }

    /// Tolerant: a missing field is fair / 0, an out-of-range level is clamped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whiteLevel = Self.clamp((try? c.decodeIfPresent(Int.self, forKey: .whiteLevel)) ?? 0)
        rev = max(0, (try? c.decodeIfPresent(Int.self, forKey: .rev)) ?? 0)
        by = (try? c.decodeIfPresent(String.self, forKey: .by)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(whiteLevel, forKey: .whiteLevel)
        try c.encode(rev, forKey: .rev)
        try c.encodeIfPresent(by, forKey: .by)
    }
}

/// A change to the shared dice made by the player **not** on turn (#272), sent to the
/// turn holder as a GameKit exchange (the waiting participant cannot write the match
/// data). `baseRev` = the newest rev the requester knew when it started changing; the
/// turn holder takes it unless it has a newer change by someone else (`accepts`).
public struct OnlineDiceRequest: Codable, Equatable, Sendable {
    /// Kind tag, so a later build can send other requests over the same channel.
    public static let kind = "dice"

    public var whiteLevel: Int
    public var baseRev: Int
    /// Raw colour of the requester.
    public var by: String

    public init(whiteLevel: Int, baseRev: Int, by: Color) {
        self.whiteLevel = OnlineDiceHandicap.clamp(whiteLevel)
        self.baseRev = baseRev
        self.by = by.rawValue
    }

    public var requester: Color? { Color(rawValue: by) }

    private enum CodingKeys: String, CodingKey { case kind, whiteLevel, baseRev, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .kind) == Self.kind else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "not a dice request")
        }
        whiteLevel = OnlineDiceHandicap.clamp(try c.decode(Int.self, forKey: .whiteLevel))
        baseRev = try c.decode(Int.self, forKey: .baseRev)
        by = try c.decode(String.self, forKey: .by)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.kind, forKey: .kind)
        try c.encode(whiteLevel, forKey: .whiteLevel)
        try c.encode(baseRev, forKey: .baseRev)
        try c.encode(by, forKey: .by)
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// `nil` for anything that is not a dice request.
    public static func decoded(from data: Data) -> OnlineDiceRequest? {
        try? JSONDecoder().decode(OnlineDiceRequest.self, from: data)
    }

    /// The turn holder's rule: take the request unless the value has changed since the
    /// requester last saw it **by someone else** (last writer wins, but never over a change
    /// the requester had not seen). The requester's own changes never block it, so a
    /// quick second request still lands after its first.
    public func isAccepted(over current: OnlineDiceHandicap) -> Bool {
        baseRev >= current.rev || current.by == by
    }
}

/// The wire payload stored in a Game Center turn-based match's `matchData` (#134, #145).
///
/// The authoritative state of an online match is simply the **list of its games'
/// ply logs** (plus each finished game's winner): replaying a game's `plies` from the
/// initial position reproduces its exact board, model-independent, exactly as a
/// `GameSave` does (`GameSession.replay`). Game Center persists, syncs, and reloads
/// this blob, so sync, resume, and reconnection all reduce to "decode + replay": there
/// is no board state to reconcile.
///
/// A single game is just a match with `targetWins == 1` and one `GameLog`, so both the
/// single-game (#134) and best-of-three (#145) paths share one shape. The last element
/// of `games` is the current (in-progress or just-finished) game; every earlier game
/// is complete (has a `winner`). The match score derives from the games' winners.
///
/// Colour assignment is carried explicitly (`colorByPlayerID`) rather than inferred
/// from turn order, so each device computes its own side from its Game Center
/// `gamePlayerID` no matter who created the match or who is currently active. The
/// per-game starting player alternates from `startingPlayer` (the game-1 starter), so
/// both devices agree without an opening-roll ceremony for games 2+.
public struct OnlineMatchPayload: Codable, Equatable, Sendable {
    /// Bump when the wire shape changes; decoding rejects anything newer than this.
    /// v2 (#145) replaced the single `plies` field with `games` + `targetWins`; a v1
    /// payload still decodes (its `plies` map to a single game, `targetWins` 1).
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    /// Games a side must win to take the match (1 = single game, 2 = best-of-three).
    public var targetWins: Int
    /// Raw `Color` value ("W"/"B") of the side that starts game 1, resolved once by the
    /// match creator. Stored raw to match `GameSave`'s wire convention. Later games
    /// alternate from this.
    public var startingPlayer: String
    /// Maps each participant's Game Center `gamePlayerID` to the raw `Color` value
    /// ("W"/"B") they play for the whole match.
    public var colorByPlayerID: [String: String]
    /// The match's games in order; the last is the current/just-finished game.
    public var games: [GameLog]
    /// `GameVariant.id` of the rules every game in the match is played under (#136).
    /// Absent in older payloads, which decode as `"plakoto"`; the key is additive, so
    /// the schema version is unchanged.
    public var variant: String
    /// The mover's turn in progress (#269), only in `saveCurrentTurn` writes; `nil`
    /// otherwise. An optional, additive key (no schema bump): older builds ignore it,
    /// and an unreadable one decodes as `nil` instead of failing the payload. New
    /// optional match-wide keys (the shared dice, #272) follow the same pattern.
    public var liveTurn: LiveTurn?
    /// The shared weighted-dice slider (#272). Optional and additive like `liveTurn` (no
    /// schema bump; older builds ignore it, an unreadable one decodes as `nil`). Absent =
    /// fair dice (`dice`); written only once someone has changed it (`rev > 0`), so a
    /// match that never used it encodes exactly as before. Unlike `liveTurn` it is in
    /// **every** write (it is match state, not a preview).
    public var diceHandicap: OnlineDiceHandicap?

    public init(schemaVersion: Int = OnlineMatchPayload.currentSchemaVersion,
                targetWins: Int = 1,
                startingPlayer: Color,
                colorByPlayerID: [String: Color],
                games: [GameLog] = [GameLog()],
                variant: String = GameVariants.defaultID,
                liveTurn: LiveTurn? = nil,
                diceHandicap: OnlineDiceHandicap? = nil) {
        self.schemaVersion = schemaVersion
        self.variant = variant
        self.liveTurn = liveTurn
        self.diceHandicap = (diceHandicap?.rev ?? 0) > 0 ? diceHandicap : nil
        self.targetWins = max(1, targetWins)
        self.startingPlayer = startingPlayer.rawValue
        self.colorByPlayerID = colorByPlayerID.mapValues(\.rawValue)
        self.games = games.isEmpty ? [GameLog()] : games
    }

    /// Convenience for a single game expressed as a flat ply list (the #134 shape).
    public init(startingPlayer: Color,
                colorByPlayerID: [String: Color],
                plies: [PlyRecord]) {
        self.init(targetWins: 1,
                  startingPlayer: startingPlayer,
                  colorByPlayerID: colorByPlayerID,
                  games: [GameLog(plies: plies)])
    }

    // ── Codable (back-compatible with the v1 flat-`plies` shape) ──────────────────

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, targetWins, startingPlayer, colorByPlayerID, games, plies, variant, liveTurn
        case diceHandicap
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        startingPlayer = try c.decode(String.self, forKey: .startingPlayer)
        colorByPlayerID = try c.decode([String: String].self, forKey: .colorByPlayerID)
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? GameVariants.defaultID
        liveTurn = (try? c.decodeIfPresent(LiveTurn.self, forKey: .liveTurn)) ?? nil
        diceHandicap = (try? c.decodeIfPresent(OnlineDiceHandicap.self, forKey: .diceHandicap)) ?? nil
        if let games = try c.decodeIfPresent([GameLog].self, forKey: .games) {
            self.games = games.isEmpty ? [GameLog()] : games
            self.targetWins = max(1, try c.decodeIfPresent(Int.self, forKey: .targetWins) ?? 1)
        } else {
            // v1: a flat ply log is a single game.
            let plies = try c.decodeIfPresent([PlyRecord].self, forKey: .plies) ?? []
            self.games = [GameLog(plies: plies)]
            self.targetWins = 1
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(targetWins, forKey: .targetWins)
        try c.encode(startingPlayer, forKey: .startingPlayer)
        try c.encode(colorByPlayerID, forKey: .colorByPlayerID)
        try c.encode(games, forKey: .games)
        try c.encode(variant, forKey: .variant)
        try c.encodeIfPresent(liveTurn, forKey: .liveTurn)
        try c.encodeIfPresent(diceHandicap, forKey: .diceHandicap)
    }
}

public extension OnlineMatchPayload {
    /// Encode for storage in `GKTurnBasedMatch.matchData`.
    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// Decode from `matchData`, rejecting payloads from a newer schema so a stale
    /// build fails loudly instead of silently mishandling unknown fields.
    static func decoded(from data: Data) throws -> OnlineMatchPayload {
        let payload = try JSONDecoder().decode(OnlineMatchPayload.self, from: data)
        guard payload.schemaVersion <= currentSchemaVersion else {
            throw OnlineMatchError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload
    }

    /// The shared dice (#272); fair when the key is absent.
    var dice: OnlineDiceHandicap { diceHandicap ?? .fair }

    /// The side that starts game 1, as a `Color` (defaults to `.black` if malformed).
    var startingColor: Color { Color(rawValue: startingPlayer) ?? .black }

    /// The colour a given Game Center player plays, if assigned.
    func color(forPlayerID id: String) -> Color? {
        colorByPlayerID[id].flatMap(Color.init(rawValue:))
    }

    /// Winners of the completed games, in order — the match score.
    var completedGameWinners: [Color] { games.compactMap(\.winner) }

    /// Results (wins with points, draws) of the completed games, in order.
    var completedGameResults: [MatchGameResult] { games.compactMap(\.result) }

    /// The match score as a `MatchState`.
    var matchState: MatchState {
        MatchState(targetWins: targetWins,
                   baseStartingPlayer: startingColor,
                   results: completedGameResults)
    }

    /// 0-based index of the current (in-progress or last) game.
    var currentGameIndex: Int { max(0, games.count - 1) }

    /// The starting player for game `index`, alternating from the game-1 starter.
    func startingPlayer(forGameIndex index: Int) -> Color {
        index % 2 == 0 ? startingColor : startingColor.opponent
    }

    /// A `GameSave` view of one game's plies (human-vs-human, no AI side), so a device
    /// can rebuild that game's session from the authoritative log via `GameSession.resume`.
    func gameSave(forGameIndex index: Int, name: String = "Online match") -> GameSave {
        let plies = games.indices.contains(index) ? games[index].plies : []
        return GameSave(name: name,
                        savedAt: Date(),
                        startingPlayer: startingPlayer(forGameIndex: index).rawValue,
                        aiColor: nil,
                        history: plies,
                        variant: variant)
    }

    /// A `GameSave` view of the current game — the reconnection / first-open path.
    func gameSave(name: String = "Online match") -> GameSave {
        gameSave(forGameIndex: currentGameIndex, name: name)
    }

    /// Ordered `(gameIndex, ply)` updates a device that has applied `plyCount` plies of
    /// game `gameIndex` has not yet seen. Crossing into a later game means the earlier
    /// game finished; this lets a receiver apply the opponent's newest turn even when it
    /// finishes the current game and continues into the next one.
    func pendingPlies(fromGameIndex gameIndex: Int,
                      plyCount: Int) -> [(gameIndex: Int, ply: PlyRecord)] {
        var out: [(gameIndex: Int, ply: PlyRecord)] = []
        guard gameIndex < games.count else { return out }
        for gi in gameIndex..<games.count {
            let plies = games[gi].plies
            let start = (gi == gameIndex) ? max(0, plyCount) : 0
            guard start < plies.count else { continue }
            for ply in plies[start...] { out.append((gameIndex: gi, ply: ply)) }
        }
        return out
    }
}
