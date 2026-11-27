import Foundation
import Combine

// ── The turn-based service seam ─────────────────────────────────────────────────
//
// Everything the online match logic needs from Game Center, expressed as plain values
// so the logic can live (and be tested) in the engine. The app's `GameKitCoordinator`
// adapts `GKTurnBasedMatch` to this; tests use an in-memory fake that simulates two
// devices sharing one server.

/// A participant's state in a turn-based match (mirrors `GKTurnBasedParticipant.Status`).
public enum OnlineParticipantStatus: Equatable, Sendable {
    case invited, declined, matching, active, done, unknown
}

/// A participant's result (mirrors `GKTurnBasedMatch.Outcome`; `.none` = still playing).
public enum OnlineMatchOutcome: Equatable, Sendable {
    case none, quit, won, lost, tied, timeExpired, other
}

public struct OnlineParticipant: Equatable, Sendable {
    /// `gamePlayerID`, or `nil` while the seat is unfilled (auto-match, or an invite
    /// Game Center hasn't resolved to a player yet).
    public var playerID: String?
    public var displayName: String?
    public var status: OnlineParticipantStatus
    public var outcome: OnlineMatchOutcome

    public init(playerID: String?, displayName: String? = nil,
                status: OnlineParticipantStatus = .active, outcome: OnlineMatchOutcome = .none) {
        self.playerID = playerID
        self.displayName = displayName
        self.status = status
        self.outcome = outcome
    }
}

/// A by-value snapshot of a turn-based match as the service last reported it.
public struct OnlineMatchSnapshot: Equatable, Sendable {
    public var matchID: String
    public var data: Data?
    public var participants: [OnlineParticipant]
    /// `gamePlayerID` of the participant whose turn it is (`nil` when ended or unfilled).
    public var currentPlayerID: String?
    public var isEnded: Bool
    /// Who starts game 1 when the service decides it (our server draws it at creation,
    /// #286); `nil` = the creator decides (Game Center).
    public var startingPlayer: Color?
    /// The shared dice as a server holds them (#286: the server is their single writer);
    /// `nil` = they live in the payload (Game Center, #272).
    public var serverDice: OnlineDiceHandicap?

    public init(matchID: String, data: Data?, participants: [OnlineParticipant],
                currentPlayerID: String?, isEnded: Bool = false,
                startingPlayer: Color? = nil, serverDice: OnlineDiceHandicap? = nil) {
        self.matchID = matchID
        self.data = data
        self.participants = participants
        self.currentPlayerID = currentPlayerID
        self.isEnded = isEnded
        self.startingPlayer = startingPlayer
        self.serverDice = serverDice
    }

    public var payload: OnlineMatchPayload? {
        guard let data, !data.isEmpty else { return nil }
        return try? OnlineMatchPayload.decoded(from: data)
    }
}

public typealias OnlineCompletion = @MainActor (Error?) -> Void
public typealias OnlineSnapshotCompletion = @MainActor (OnlineMatchSnapshot?, Error?) -> Void

/// The operations the controller performs on a match. Every call names the match by
/// id; the turn always passes to the other participant(s).
@MainActor
public protocol OnlineMatchService: AnyObject {
    var localPlayerID: String { get }
    /// Write `data` and hand the turn to the opponent.
    func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion)
    /// Write `data` and keep the turn.
    func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion)
    /// End the match in turn: the local player's outcome is won/lost, every other
    /// participant's the opposite (a participant who already quit keeps `.quit`).
    func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion)
    /// Forfeit: quit in turn (handing the turn on with `data`) or out of turn.
    func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion)
    /// Accept a pending invitation to the match.
    func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion)
    /// Reload the match's current state from the server.
    func load(matchID: String, completion: @escaping OnlineSnapshotCompletion)
    /// Send a small request to the other participant **out of turn** (#272: GameKit's
    /// turn-based exchange — the waiting player cannot write the match data). Delivered
    /// to the other device's `OnlineMatchController.receiveRequest(matchID:data:)`.
    func sendRequest(matchID: String, data: Data, completion: @escaping OnlineCompletion)
}

/// A service without an out-of-turn channel: every request fails, so a waiting player's
/// dice change waits for their own turn (`OnlineMatchController`, #272).
public struct OnlineRequestUnsupported: Error {}

/// A service whose **server draws the dice and holds the shared slider** (#286, our own
/// server: `ServerMatchService`). The controller then asks it for every local roll
/// (`GameSession.remoteRoller`) and sends slider changes straight to it — either player,
/// any time; no turn-holder minting and no out-of-turn requests. Snapshots carry the
/// server's value (`OnlineMatchSnapshot.serverDice`).
@MainActor
public protocol OnlineServerDiceService: OnlineMatchService {
    /// The dice for ply `plyIndex` of game `gameIndex` (the same answer when asked again).
    /// `rollValues`: the roller's 21 roll values, needed when the dice are weighted; throws
    /// `OnlineServerDiceError.rollValuesRequired` when the server wanted them.
    func roll(matchID: String, gameIndex: Int, plyIndex: Int,
              rollValues: [Float]?) async throws -> GameSession.RemoteRoll
    /// Change the slider (`OnlineDiceRequest` rule on the server); returns the new value.
    func changeDice(matchID: String, whiteLevel: Int, baseRev: Int) async throws -> OnlineDiceHandicap
    /// Events reach the controller live right now (socket up): the fallback poll rests.
    var deliversEventsLive: Bool { get }
}

public enum OnlineServerDiceError: Error, Equatable {
    /// The dice are weighted: send the 21 roll values.
    case rollValuesRequired
    /// No match open (or the roll was for one that closed).
    case noMatch
}

public extension OnlineMatchService {
    func sendRequest(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        completion(OnlineRequestUnsupported())
    }
}

/// What the online chrome should tell the player. The app maps each case to localized
/// copy; `nil` means nothing to say.
public enum OnlineMatchStatus: Equatable, Sendable {
    /// Joined a match whose creator hasn't written the opening state yet.
    case waitingForOpponentToStart
    /// The opponent forfeited; the local player won the match.
    case opponentLeft
    /// The match is over (shown when it ended without a final move to replay).
    case matchEnded
    /// The local turn couldn't be sent; it's kept and retried automatically.
    case sendFailed
    /// It's the local player's turn in another match (name of that opponent).
    case yourTurnElsewhere(String)
    /// Any other service error, as the service described it.
    case error(String)
}

/// How the live turn (#269) is shared: the mover writes its turn in progress with
/// `saveTurn` (GameKit `saveCurrentTurn`, which raises a turn event on the other
/// participant's device), coalesced so a burst of half-moves costs one write. The roll
/// goes out at once; half-moves / undos after `debounce`, never two writes closer than
/// `minInterval`, at most one write in flight, always the latest state. The waiting
/// side applies every update it gets and, as a fallback for a missed event, reloads
/// the match every `pollInterval` while the opponent is on turn (doubling up to
/// `maxPollInterval` while nothing changes; `nil` = events only).
public struct LiveTurnTiming: Equatable, Sendable {
    public var debounce: TimeInterval
    public var minInterval: TimeInterval
    public var pollInterval: TimeInterval?
    public var maxPollInterval: TimeInterval

    public init(debounce: TimeInterval = 0.6, minInterval: TimeInterval = 1.0,
                pollInterval: TimeInterval? = 5, maxPollInterval: TimeInterval = 60) {
        self.debounce = debounce
        self.minInterval = minInterval
        self.pollInterval = pollInterval
        self.maxPollInterval = maxPollInterval
    }

    public static let standard = LiveTurnTiming()
}

// ── The controller ──────────────────────────────────────────────────────────────

/// Drives one online (Game Center turn-based) match at a time on top of an
/// `OnlineMatchService` (#134, #145, #143). The engine stays network-agnostic: each game
/// is a human-vs-human `GameSession`; the opponent's plies are fed in through
/// `GameSession.applyRemoteMove`, the local player's are pushed when the session's ply
/// log grows by a local move.
///
/// **State model.** The match's entire state is its `OnlineMatchPayload` (each game's
/// ply log + result). Opening, resuming, catching up and recovering are all "decode +
/// replay", never board reconciliation.
///
/// **Robustness rules** (each covered by `OnlineMatchControllerTests`):
/// - A player missing from the colour map takes the colour nobody holds, so a match
///   created before the opponent's seat was filled (auto-match, unresolved invite)
///   still gets one White and one Black. The resolved map is written back with the
///   next turn.
/// - An invitation is accepted before the match is opened.
/// - Events for a match other than the active one never replace the active game.
/// - A finished match (ended with a final move, or by the opponent quitting) is
///   applied and locked; an opponent who quits is detected and the match closed as a
///   local win.
/// - A turn that fails to send is kept: the board is not rolled back, and a stale
///   server snapshot never overwrites it; `refresh()` / the retry resends it.
/// - **Live turn (#269):** the local turn in progress (roll, half-moves, undos) is
///   written as the payload's optional `liveTurn` (see `LiveTurnTiming`); the other
///   device shows it read-only via `GameSession.showRemoteTurn` and the finished ply
///   continues from it. A live write never blocks or replaces a real turn: `endTurn`
///   waits for an in-flight live write, and a failed live write is just dropped.
/// - **Shared weighted dice (#272):** one match-wide `OnlineDiceHandicap` (signed hybrid
///   level relative to White, mirrored) either player may change with
///   `setDiceHandicap(levelTowardsMe:)`, no confirmation. Only the player **holding the
///   Game Center turn** can write the match data, so it is the authority: its change gets
///   the next `rev` and rides on its next write (a live write at once, or the `endTurn`);
///   every write carries the current value. The **waiting** player's change is a
///   `pendingDiceRequest` sent to the turn holder with `sendRequest` (a GameKit exchange),
///   which takes it (`OnlineDiceRequest.isAccepted(over:)`: never over a change by the
///   other player the requester had not seen) and writes it; if the request is lost or
///   refused by the channel, the requester applies it itself as soon as its own turn
///   comes. Each device rolls with the value it holds when it rolls (the roller's view
///   counts) and stamps it into the ply (`PlyRecord.weighted`), so the log records
///   exactly which bend every roll used. The dice need the variant's value net
///   (`handicapAgent`); without one the control is unavailable (`canChangeDice`).
@MainActor
public final class OnlineMatchController: ObservableObject {

    // ── Published view state ────────────────────────────────────────────────────

    /// The current game's session, or `nil` when no match is open.
    @Published public private(set) var session: GameSession?
    /// Id of the open match, or `nil` in the lobby.
    @Published public private(set) var activeMatchID: String?
    @Published public private(set) var localColor: Color = .white
    /// The opponent's display name, or `nil` while unknown (the app shows "Opponent").
    @Published public private(set) var opponentName: String?
    @Published public var status: OnlineMatchStatus?
    @Published public private(set) var matchState = MatchState.single(baseStartingPlayer: .white)
    /// The just-finished game's result while the between-games / match-over overlay
    /// should show. Cleared by `continueToNextGame()`.
    @Published public var pendingGameResult: MatchGameResult?
    /// The match is over (decided, or someone quit): the board is read-only.
    @Published public private(set) var isMatchOver = false
    /// A local turn is written locally but not yet confirmed by the service.
    @Published public private(set) var hasUnsentTurn = false
    /// The shared weighted dice as this device has them (#272): the agreed value, or the
    /// local player's own change while it is on its way (`isDiceChangePending`). On the
    /// local turn it is always the agreed value the session rolls with.
    @Published public private(set) var diceHandicap = OnlineDiceHandicap.fair
    /// The local player changed the dice while waiting and the turn holder has not
    /// written it yet (it applies from the opponent's next roll once received, and from
    /// the local player's own next roll at the latest).
    @Published public private(set) var isDiceChangePending = false

    /// Whether the local player may act on the board right now.
    public var isLocalTurn: Bool {
        guard let session, !isMatchOver else { return false }
        return session.currentPlayer == localColor && !session.isTerminal
    }

    /// Whether the shared dice can be changed: a running match and a value net for its
    /// variant (weighted dice rate every roll with it).
    public var canChangeDice: Bool {
        guard let session, !isMatchOver else { return false }
        return session.handicapAgent != nil
    }

    // ── Private match state ─────────────────────────────────────────────────────

    private let service: OnlineMatchService
    private let animationTimings: AnimationTimings
    /// Seconds before a failed send is retried automatically (`nil` = only on
    /// `refresh()`); doubles per consecutive failure, capped at 5 minutes.
    private let retryDelay: TimeInterval?
    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var colorByPlayerID: [String: Color] = [:]
    private var variantID = GameVariants.defaultID
    private var completedGameLogs: [GameLog] = []
    private var syncedGameIndex = 0
    private var syncedPlyCount = 0
    private var recordCancellable: AnyCancellable?
    private var pendingOp: PendingOp?
    private var currentPlayerID: String?
    /// A real turn write (`endTurn` / `saveTurn` / `endMatch`) is with the service.
    private var realOpInFlight = false

    // Live turn (#269), mover side.
    private let liveTiming: LiveTurnTiming?
    private var sessionChangeCancellable: AnyCancellable?
    private var liveSendTask: Task<Void, Never>?
    private var liveSaveInFlight = false
    /// The last live state the service confirmed.
    private var lastSentLive: LiveTurn?
    private var lastLiveSendAt = Date.distantPast
    private var liveSeq = 0
    private var liveFailures = 0
    /// A real op that waits for the live write in flight (GameKit rejects overlapping
    /// writes to one match with a game-state-version error).
    private var deferredOp: (op: PendingOp, matchID: String)?

    // Live turn (#269), waiting side.
    private var shownLive: LiveTurn?
    private var pollTask: Task<Void, Never>?
    private var pollDelay: TimeInterval = 0
    private var lastSnapshotData: Data?

    // Shared weighted dice (#272).
    /// The newest authoritative value known (minted by a turn holder; revs only grow).
    private var confirmedDice = OnlineDiceHandicap.fair
    /// The local player's change made while not holding the turn, not yet written.
    private var pendingDiceRequest: OnlineDiceRequest?
    private var diceRequestInFlight = false
    /// The last request sent and how far the match was then: a request is sent once per
    /// change and turn (a lost one waits for the local turn instead of retrying).
    private var lastDiceRequestKey: DiceRequestKey?
    /// The highest dice rev a successful write carried.
    private var sentDiceRev = 0
    /// The value net per variant id (loaded once per match).
    private let handicapAgentProvider: (@MainActor (GameConfig) -> Agent?)?
    private var handicapAgents: [String: Agent] = [:]

    private struct DiceRequestKey: Equatable {
        let request: OnlineDiceRequest
        let progress: Progress
    }

    private enum PendingOp {
        case endTurn(Data), saveTurn(Data), endMatch(Data, localWon: Bool)

        var data: Data {
            switch self {
            case .endTurn(let d), .saveTurn(let d), .endMatch(let d, _): return d
            }
        }

        func with(data: Data) -> PendingOp {
            switch self {
            case .endTurn: return .endTurn(data)
            case .saveTurn: return .saveTurn(data)
            case .endMatch(_, let won): return .endMatch(data, localWon: won)
            }
        }
    }

    private var localPlayerID: String { service.localPlayerID }

    /// Our own server (#286): it draws the dice and holds the slider.
    private var serverDice: OnlineServerDiceService? { service as? OnlineServerDiceService }
    /// A slider change on its way to the server (#286), one at a time.
    private var serverDiceInFlight = false

    /// `liveTurns`: how the turn in progress is shared (#269); `nil` turns it off (only
    /// finished turns are sent, as before). `handicapAgent`: the value net for a variant
    /// (#272, the shared weighted dice rate every roll with it); `nil` = no weighted dice.
    public init(service: OnlineMatchService, animationTimings: AnimationTimings = .standard,
                retryDelay: TimeInterval? = 10, liveTurns: LiveTurnTiming? = .standard,
                handicapAgent: (@MainActor (GameConfig) -> Agent?)? = nil) {
        self.service = service
        self.animationTimings = animationTimings
        self.retryDelay = retryDelay
        self.liveTiming = liveTurns
        self.handicapAgentProvider = handicapAgent
    }

    // ── Entry points ────────────────────────────────────────────────────────────

    /// Open a match the player chose (lobby row, notification, or a match the local
    /// player just created). Accepts a pending invitation first. `newMatchTargetWins` /
    /// `newMatchVariantID` are used only if the match has no state yet and it's the
    /// local player's turn — i.e. this device created it.
    public func open(_ snapshot: OnlineMatchSnapshot,
                     newMatchTargetWins: Int = 1,
                     newMatchVariantID: String = GameVariants.defaultID) {
        if let me = participant(localPlayerID, in: snapshot), me.status == .invited {
            service.acceptInvite(matchID: snapshot.matchID) { [weak self] accepted, error in
                guard let self else { return }
                if let error { self.status = .error(error.localizedDescription); return }
                self.open(accepted ?? snapshot, newMatchTargetWins: newMatchTargetWins,
                          newMatchVariantID: newMatchVariantID)
            }
            return
        }
        if activeMatchID != snapshot.matchID { resetMatchState() }
        activeMatchID = snapshot.matchID
        apply(snapshot, newMatchTargetWins: newMatchTargetWins, newMatchVariantID: newMatchVariantID)
    }

    /// A service event (turn taken, match ended, …) for any match. Applies it when it's
    /// the open match and returns `true`; otherwise leaves the open game alone, notes
    /// when it's now the local player's turn there, and returns `false`.
    @discardableResult
    public func receive(_ snapshot: OnlineMatchSnapshot) -> Bool {
        guard snapshot.matchID == activeMatchID else {
            if activeMatchID != nil, !snapshot.isEnded, snapshot.currentPlayerID == localPlayerID {
                status = .yourTurnElsewhere(
                    opponent(in: snapshot)?.displayName ?? "")
            }
            return false
        }
        apply(snapshot)
        return true
    }

    /// Reload the open match from the service (app returned to the foreground, or a
    /// send failed) and apply it — resending an unsent local turn if still needed.
    public func refresh() {
        refresh(quiet: false)
    }

    /// `quiet`: the live-turn poll (#269) — a failed load is not reported (the next
    /// poll or event catches up).
    private func refresh(quiet: Bool) {
        guard let id = activeMatchID else { return }
        service.load(matchID: id) { [weak self] snapshot, error in
            guard let self, self.activeMatchID == id else { return }
            if let snapshot { self.apply(snapshot) }
            else if let error, !quiet { self.status = .error(error.localizedDescription) }
            else if quiet { self.schedulePoll(changed: false) }
        }
    }

    /// Back to the lobby **without** forfeiting: the match stays open on the service.
    public func close() {
        resetMatchState()
    }

    /// Forfeit the open match (the opponent wins), then close it.
    public func forfeit() {
        guard let id = activeMatchID else { return }
        if !isMatchOver {
            let data = (try? currentPayload()?.encoded()) ?? Data()
            service.quit(matchID: id, data: data, inTurn: currentPlayerID == localPlayerID) { _ in }
        }
        resetMatchState()
    }

    /// Dismiss the between-games overlay (the session already advanced behind it).
    public func continueToNextGame() {
        pendingGameResult = nil
    }

    // ── Shared weighted dice (#272) ─────────────────────────────────────────────

    /// Change the shared dice: `level` −4…+4 from the local player's side (positive
    /// favours the local player, negative the opponent, 0 = fair). No confirmation: it
    /// changes for both players, from the next roll. Holding the turn, the value is
    /// minted and written at once; waiting, it goes to the turn holder as a request (and
    /// is applied by this device on its own turn if that request does not land).
    public func setDiceHandicap(levelTowardsMe level: Int) {
        let white = localColor == .white ? level : -level
        setDiceHandicap(whiteLevel: white)
    }

    /// `setDiceHandicap(levelTowardsMe:)` with the level relative to White.
    public func setDiceHandicap(whiteLevel: Int) {
        guard canChangeDice else { return }
        let level = OnlineDiceHandicap.clamp(whiteLevel)
        guard level != diceHandicap.whiteLevel else { return }
        if serverDice != nil {
            // The server is the single writer (#286): any time, from either player.
            let base = pendingDiceRequest?.baseRev ?? confirmedDice.rev
            pendingDiceRequest = OnlineDiceRequest(whiteLevel: level, baseRev: base, by: localColor)
        } else if holdsTurn {
            pendingDiceRequest = nil
            confirmedDice = OnlineDiceHandicap(whiteLevel: level, rev: confirmedDice.rev + 1,
                                               by: localColor)
        } else {
            // Keep the base of a change already on its way, so the holder still takes
            // this newer one after the first (`OnlineDiceRequest.isAccepted`).
            let base = pendingDiceRequest?.baseRev ?? confirmedDice.rev
            pendingDiceRequest = OnlineDiceRequest(whiteLevel: level, baseRev: base, by: localColor)
        }
        reconcileDice()
    }

    /// A request from the other player (`OnlineMatchService.sendRequest`; the app's
    /// GameKit exchange). Taken only while this device holds the turn — the only one that
    /// can write it — and unless it would override a change the requester had not seen;
    /// otherwise ignored (the requester applies it on its own turn, or sees the newer
    /// value). Requests for other matches are ignored.
    public func receiveRequest(matchID: String, data: Data) {
        guard serverDice == nil, matchID == activeMatchID, let request = OnlineDiceRequest.decoded(from: data),
              let requester = request.requester, requester != localColor,
              canChangeDice, holdsTurn, request.isAccepted(over: confirmedDice) else { return }
        confirmedDice = OnlineDiceHandicap(whiteLevel: request.whiteLevel,
                                           rev: confirmedDice.rev + 1, by: requester)
        reconcileDice()
    }

    /// This device holds the Game Center turn with nothing of its own in flight: it may
    /// mint a dice change and write it.
    private var holdsTurn: Bool {
        session != nil && !isMatchOver && currentPlayerID == localPlayerID
            && pendingOp == nil && !realOpInFlight
    }

    /// Take a newer authoritative value from a payload (revs only grow).
    private func adoptDice(_ dice: OnlineDiceHandicap) {
        if dice.rev > confirmedDice.rev { confirmedDice = dice }
        sentDiceRev = max(sentDiceRev, dice.rev)   // it is on the service already
    }

    /// Settle the local change against the newest value, mint it when this device holds
    /// the turn, publish what the board rolls with, and get the change out (a write as
    /// the turn holder, else a request).
    private func reconcileDice() {
        if let p = pendingDiceRequest, confirmedDice.rev > p.baseRev {
            if confirmedDice.changedBy?.rawValue != p.by {
                pendingDiceRequest = nil   // the other player changed it meanwhile: theirs stands
            } else if confirmedDice.whiteLevel == p.whiteLevel {
                pendingDiceRequest = nil   // taken and written
            }
            // else: an earlier change of ours landed, this newer one is still on its way
        }
        if serverDice == nil, let p = pendingDiceRequest, holdsTurn, canChangeDice {
            confirmedDice = OnlineDiceHandicap(whiteLevel: p.whiteLevel, rev: confirmedDice.rev + 1,
                                               by: localColor)
            pendingDiceRequest = nil
        }
        let shown = pendingDiceRequest.map {
            OnlineDiceHandicap(whiteLevel: $0.whiteLevel, rev: confirmedDice.rev, by: localColor)
        } ?? confirmedDice
        if diceHandicap != shown { diceHandicap = shown }
        let pending = pendingDiceRequest != nil
        if isDiceChangePending != pending { isDiceChangePending = pending }
        if let session { applyDice(to: session) }
        if serverDice != nil {
            sendServerDiceIfNeeded()
        } else if holdsTurn, confirmedDice.rev > sentDiceRev {
            scheduleLiveSend(after: 0)
        } else {
            sendDiceRequestIfNeeded()
        }
    }

    /// The session carries the agreed value (a pending change of the waiting player is
    /// only shown: this device does not roll before it is minted on its own turn), so its
    /// `record.handicap` says what the rolls really used.
    private func applyDice(to session: GameSession) {
        session.setSharedWeightedDice(favouring: confirmedDice.favoured, dice: confirmedDice.weightedDice)
    }

    /// Send the pending change to the turn holder: once per change and turn, one at a
    /// time (a newer change made meanwhile follows when the first completes). Not while
    /// this device itself holds the turn (it mints instead once its write is done).
    private func sendDiceRequestIfNeeded() {
        guard let p = pendingDiceRequest, let id = activeMatchID, !diceRequestInFlight,
              !isMatchOver, currentPlayerID != localPlayerID else { return }
        let key = DiceRequestKey(request: p, progress: localProgress())
        guard key != lastDiceRequestKey, let data = try? p.encoded() else { return }
        lastDiceRequestKey = key
        diceRequestInFlight = true
        service.sendRequest(matchID: id, data: data) { [weak self] _ in
            guard let self else { return }
            self.diceRequestInFlight = false
            guard self.activeMatchID == id else { return }
            // A failure leaves the change pending: it is applied on the local turn.
            self.sendDiceRequestIfNeeded()
        }
    }

    /// Our server (#286): send the pending change, one at a time; the server's answer (or,
    /// when it refused a change over the other player's unseen one, a reload) settles it.
    private func sendServerDiceIfNeeded() {
        guard let server = serverDice, let p = pendingDiceRequest, let id = activeMatchID,
              !serverDiceInFlight, !isMatchOver else { return }
        serverDiceInFlight = true
        Task { @MainActor [weak self] in
            let answer = try? await server.changeDice(matchID: id, whiteLevel: p.whiteLevel, baseRev: p.baseRev)
            guard let self else { return }
            self.serverDiceInFlight = false
            guard self.activeMatchID == id else { return }
            if let answer {
                self.adoptDice(answer)
                if self.pendingDiceRequest == p { self.pendingDiceRequest = nil }
                self.reconcileDice()
            } else {
                // Refused (stale) or not sent: drop this change and take the server's value.
                if self.pendingDiceRequest == p { self.pendingDiceRequest = nil }
                self.reconcileDice()
                self.refresh(quiet: true)
            }
        }
    }

    /// Our server's dice for a local roll (#286, `GameSession.remoteRoller`): the 21 roll
    /// values go along when the agreed dice are weighted (or when the server says they are).
    private func serverRoll(_ request: GameSession.RemoteRollRequest) async throws -> GameSession.RemoteRoll {
        guard let server = serverDice, let id = activeMatchID else { throw OnlineServerDiceError.noMatch }
        let gameIndex = syncedGameIndex
        var values = confirmedDice.isFair ? nil : await request.rollValues()
        do {
            return try await server.roll(matchID: id, gameIndex: gameIndex, plyIndex: request.plyIndex,
                                         rollValues: values)
        } catch OnlineServerDiceError.rollValuesRequired where values == nil {
            values = await request.rollValues()
            guard values != nil else { throw OnlineServerDiceError.rollValuesRequired }
            return try await server.roll(matchID: id, gameIndex: gameIndex, plyIndex: request.plyIndex,
                                         rollValues: values)
        }
    }

    /// `data` with the newest dice value (a resent turn may predate a change).
    private func withCurrentDice(_ op: PendingOp) -> PendingOp {
        guard confirmedDice.rev > 0, var p = try? OnlineMatchPayload.decoded(from: op.data),
              p.dice.rev < confirmedDice.rev else { return op }
        p.diceHandicap = confirmedDice
        guard let data = try? p.encoded() else { return op }
        return op.with(data: data)
    }

    private func diceRev(of data: Data) -> Int {
        (try? OnlineMatchPayload.decoded(from: data))?.dice.rev ?? 0
    }

    // ── Applying a snapshot ─────────────────────────────────────────────────────

    private func apply(_ snapshot: OnlineMatchSnapshot,
                       newMatchTargetWins: Int = 1,
                       newMatchVariantID: String = GameVariants.defaultID) {
        currentPlayerID = snapshot.currentPlayerID
        if let name = opponent(in: snapshot)?.displayName { opponentName = name }
        let changed = snapshot.data != lastSnapshotData
        lastSnapshotData = snapshot.data
        defer { schedulePoll(changed: changed) }
        // Our server holds the shared dice (#286): its value is the newest there is.
        if let dice = snapshot.serverDice { adoptDice(dice) }

        guard let payload = snapshot.payload else {
            // No state yet: the creator (holding the opening turn) writes it; anyone
            // else waits for it.
            if snapshot.currentPlayerID == localPlayerID, !snapshot.isEnded {
                initializeNewMatch(snapshot, targetWins: newMatchTargetWins, variantID: newMatchVariantID)
            } else {
                session = nil
                status = snapshot.isEnded ? .matchEnded : .waitingForOpponentToStart
                isMatchOver = snapshot.isEnded
            }
            return
        }
        // The shared dice (#272): newest rev wins, so a stale snapshot never takes it back.
        adoptDice(payload.dice)
        defer { reconcileDice() }

        // The local log is ahead of this snapshot: an unsent local turn (resend it) or
        // a late, stale update (ignore it). The board never goes backwards.
        if session != nil, !snapshot.isEnded, progress(of: payload) < localProgress() {
            if pendingOp != nil { resendPending() }
            return
        }
        if pendingOp != nil, progress(of: payload) >= localProgress() {
            // The service has it after all (the "failure" was only the reply).
            pendingOp = nil
            hasUnsentTurn = false
        }

        resolveColors(payload)
        if session != nil, syncedGameIndex <= payload.currentGameIndex {
            applyIncoming(payload)
        } else {
            rebuild(from: payload)
        }

        handleEnd(of: snapshot)
        if status == .waitingForOpponentToStart || status == .sendFailed, pendingOp == nil {
            status = nil
        }
        if let seq = payload.liveTurn?.seq { liveSeq = max(liveSeq, seq) }
        showLiveTurn(payload.liveTurn)
    }

    // ── Live turn, waiting side (#269) ──────────────────────────────────────────

    /// Show the opponent's turn in progress when the payload carries one for the ply
    /// the board is waiting for and it is newer than what is shown; take a preview off
    /// once the match is over.
    private func showLiveTurn(_ live: LiveTurn?) {
        guard let session else { return }
        if isMatchOver { session.clearRemoteTurn(); return }
        guard let live, live.gameIndex == syncedGameIndex,
              live.plyIndex == syncedPlyCount, live.plyIndex == session.record.plies.count,
              let mover = live.playerColor, mover != localColor,
              session.currentPlayer == mover else { return }
        if let shown = shownLive, shown.gameIndex == live.gameIndex,
           shown.plyIndex == live.plyIndex, live.seq <= shown.seq { return }
        if session.showRemoteTurn(plyIndex: live.plyIndex, die1: live.die1, die2: live.die2,
                                  halfMoves: live.halfMoves) {
            shownLive = live
        }
    }

    /// The fallback poll while the opponent is on turn (`LiveTurnTiming.pollInterval`):
    /// back to the base interval after a change, doubling while nothing changes.
    private func schedulePoll(changed: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard let timing = liveTiming, let base = timing.pollInterval, let id = activeMatchID,
              session != nil, !isMatchOver, !isLocalTurn,
              currentPlayerID != localPlayerID, pendingOp == nil else { pollDelay = 0; return }
        pollDelay = (changed || pollDelay == 0) ? base : min(timing.maxPollInterval, pollDelay * 2)
        let delay = pollDelay
        pollTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.activeMatchID == id else { return }
            // Our server's socket is up (#286): events arrive live, the poll rests.
            if self.serverDice?.deliversEventsLive == true {
                self.schedulePoll(changed: false)
                return
            }
            self.refresh(quiet: true)
        }
    }

    /// Apply everything in `payload` not yet seen, game by game; a finished game with
    /// the match still going advances to the next one behind the result overlay. Any
    /// inconsistency falls back to an exact rebuild from the log.
    private func applyIncoming(_ payload: OnlineMatchPayload) {
        matchState = payload.matchState
        completedGameLogs = payload.games.filter(\.isComplete)

        while let session {
            let plies = payload.games.indices.contains(syncedGameIndex)
                ? payload.games[syncedGameIndex].plies : []
            if plies.count < syncedPlyCount { rebuild(from: payload); return }
            while syncedPlyCount < plies.count {
                guard session.applyRemoteMove(plies[syncedPlyCount]) else {
                    rebuild(from: payload); return
                }
                syncedPlyCount += 1
            }
            let hasNextGame = payload.games.count > syncedGameIndex + 1
            if hasNextGame {
                guard session.isTerminal || payload.games[syncedGameIndex].isComplete else {
                    rebuild(from: payload); return
                }
                pendingGameResult = payload.games[syncedGameIndex].result ?? session.record.result
                startGame(syncedGameIndex + 1, from: payload)
                continue
            }
            break
        }
        if payload.matchState.isComplete {
            pendingGameResult = payload.games.last?.result ?? session?.record.result
            isMatchOver = true
            recordCancellable = nil
        }
    }

    /// Rebuild the current game exactly from the log (first open / reconnection /
    /// recovery). A decided match is shown at its last game, locked.
    private func rebuild(from payload: OnlineMatchPayload) {
        variantID = payload.variant
        matchState = payload.matchState
        completedGameLogs = payload.games.filter(\.isComplete)
        startGame(payload.currentGameIndex, from: payload)
        if matchState.isComplete {
            recordCancellable = nil
            isMatchOver = true
            pendingGameResult = payload.games.last?.result
        } else {
            pendingGameResult = nil
        }
    }

    private func startGame(_ index: Int, from payload: OnlineMatchPayload) {
        let next = GameSession.resume(from: payload.gameSave(forGameIndex: index),
                                      animationTimings: animationTimings,
                                      handicapAgent: handicapAgent(forVariant: payload.variant))
        // The shared dice (#272): every roll is stamped, and the game starts with the
        // match's current value (it is match-wide, so it carries into the next game).
        next.recordsDiceWeighting = true
        applyDice(to: next)
        // Our server draws every local roll (#286); the session tumbles while it asks.
        if serverDice != nil {
            next.remoteRoller = { [weak self] request in
                guard let self else { throw OnlineServerDiceError.noMatch }
                return try await self.serverRoll(request)
            }
        }
        session = next
        syncedGameIndex = index
        syncedPlyCount = next.record.plies.count
        shownLive = nil
        next.start()
        observeLocalTurns(of: next)
    }

    /// Resolve every colour, filling in a player missing from the map (the opponent's
    /// seat wasn't filled when the match was created) with the free colour.
    private func resolveColors(_ payload: OnlineMatchPayload) {
        variantID = payload.variant
        var map = colorByPlayerID
        for (id, raw) in payload.colorByPlayerID {
            if let c = Color(rawValue: raw) { map[id] = c }
        }
        if map[localPlayerID] == nil {
            let taken = Set(map.values)
            map[localPlayerID] = taken.contains(.white) ? .black : .white
        }
        colorByPlayerID = map
        localColor = map[localPlayerID] ?? .white
    }

    /// React to a finished match or a quitting opponent.
    private func handleEnd(of snapshot: OnlineMatchSnapshot) {
        let opponentQuit = snapshot.participants.contains {
            $0.playerID != localPlayerID && $0.outcome == .quit
        }
        if snapshot.isEnded {
            isMatchOver = true
            recordCancellable = nil
            if opponentQuit { status = .opponentLeft }
            else if pendingGameResult == nil { status = .matchEnded }
            return
        }
        guard opponentQuit, !isMatchOver else { return }
        // The opponent forfeited: it's now our turn, so close the match as our win.
        isMatchOver = true
        recordCancellable = nil
        status = .opponentLeft
        if snapshot.currentPlayerID == localPlayerID, let id = activeMatchID {
            let data = (try? currentPayload()?.encoded()) ?? Data()
            send(.endMatch(data, localWon: true), matchID: id)
        }
    }

    // ── Creating a match ────────────────────────────────────────────────────────

    /// First-time setup by the creator: creator = White; game 1's starter per the
    /// variant; persist the opening state (keeping the turn if we start, else handing
    /// it over) and open the local session.
    private func initializeNewMatch(_ snapshot: OnlineMatchSnapshot, targetWins: Int, variantID: String) {
        self.variantID = variantID
        // Our server draws the starter at creation (#286); with Game Center the creator does.
        let starter = snapshot.startingPlayer
            ?? GameConfig(variantID: variantID).variant.startingPlayer(default: .white)
        var colors: [String: Color] = [localPlayerID: .white]
        if let opponentID = opponent(in: snapshot)?.playerID { colors[opponentID] = .black }
        colorByPlayerID = colors
        localColor = .white

        let payload = OnlineMatchPayload(targetWins: targetWins, startingPlayer: starter,
                                         colorByPlayerID: colors, games: [GameLog()],
                                         variant: variantID)
        rebuild(from: payload)
        guard let data = try? payload.encoded() else { return }
        send(starter == localColor ? .saveTurn(data) : .endTurn(data), matchID: snapshot.matchID)
        if starter != localColor { currentPlayerID = opponent(in: snapshot)?.playerID }
    }

    // ── Outgoing: push a completed local turn ───────────────────────────────────

    /// Watch the ply log; a new ply by the local colour is pushed. Handled on the next
    /// main-queue turn: `@Published` fires before the change lands, and a game-ending
    /// move appends its ply *before* the session records the result, so reading the
    /// record afterwards sees the finished game.
    private func observeLocalTurns(of session: GameSession) {
        recordCancellable = session.$record
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session, session === self.session else { return }
                self.handleRecordChange(session.record)
            }
        // Any other change (roll, half-move, undo) may move the live turn on (#269).
        // `objectWillChange` fires before the change lands; read it a turn later.
        sessionChangeCancellable = session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session, session === self.session else { return }
                self.localTurnStateChanged()
            }
    }

    // ── Live turn, mover side (#269) ────────────────────────────────────────────

    /// The local turn in progress (dice rolled, half-moves so far), or `nil` when there
    /// is none to share.
    private func currentLocalLiveTurn() -> LiveTurn? {
        guard liveTiming != nil, let session, isLocalTurn, !session.humanDiceRolling,
              session.phase == .picking || session.phase == .moving else { return nil }
        return LiveTurn(gameIndex: syncedGameIndex, plyIndex: session.record.plies.count,
                        player: localColor,
                        die1: session.game.dice.die1.value, die2: session.game.dice.die2.value,
                        halfMoves: session.moveBuilder.built.map { [$0.from.position, $0.to.position] },
                        seq: 0)
    }

    /// A dice change (#272) minted here that no write has carried yet.
    private var hasUnsentDice: Bool { holdsTurn && confirmedDice.rev > sentDiceRev }

    private func localTurnStateChanged() {
        let live = currentLocalLiveTurn()
        let liveChanged = live.map { !$0.sameState(as: lastSentLive) } ?? false
        guard liveChanged || hasUnsentDice else { return }
        // A new roll and a dice change go out at once; half-moves / undos are coalesced.
        let isNewRoll = liveChanged && (lastSentLive.map {
            $0.gameIndex != live!.gameIndex || $0.plyIndex != live!.plyIndex
                || $0.die1 != live!.die1 || $0.die2 != live!.die2
        } ?? true)
        let urgent = isNewRoll || hasUnsentDice
        scheduleLiveSend(after: urgent ? 0 : (liveTiming?.debounce ?? 0))
    }

    /// Arm the live write (also used for a dice change, #272, with live turns off). A
    /// write already scheduled is kept (it sends whatever the state is when it fires)
    /// unless this one is due sooner (a new roll, a dice change).
    private func scheduleLiveSend(after delay: TimeInterval) {
        let minInterval = liveTiming?.minInterval ?? LiveTurnTiming.standard.minInterval
        if liveSendTask != nil, delay > 0 { return }
        liveSendTask?.cancel()
        let spacing = lastLiveSendAt.addingTimeInterval(minInterval).timeIntervalSinceNow
        let wait = max(delay, spacing)
        liveSendTask = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            self.liveSendTask = nil
            self.flushLiveTurn()
        }
    }

    /// Write the latest live state (and the current dice, #272), unless both are already
    /// on the service or another write is busy (its completion comes back here).
    private func flushLiveTurn() {
        guard let id = activeMatchID, let session,
              !liveSaveInFlight, !realOpInFlight, pendingOp == nil else { return }
        var live = currentLocalLiveTurn()
        let liveChanged = live.map { !$0.sameState(as: lastSentLive) } ?? false
        let dice = confirmedDice
        let diceChanged = hasUnsentDice
        guard liveChanged || diceChanged else { return }
        if liveChanged {
            liveSeq += 1
            live?.seq = liveSeq
        } else if live != nil {
            live = lastSentLive   // unchanged turn: the same state and seq again
        }
        let current = GameLog(plies: session.record.plies, result: nil)
        guard let data = try? payload(games: completedGameLogs + [current], liveTurn: live).encoded()
        else { return }
        liveSaveInFlight = true
        lastLiveSendAt = Date()
        service.saveTurn(matchID: id, data: data) { [weak self] error in
            guard let self else { return }
            self.liveSaveInFlight = false
            guard self.activeMatchID == id else { return }
            if error == nil {
                if let live { self.lastSentLive = live }
                self.sentDiceRev = max(self.sentDiceRev, dice.rev)
                self.liveFailures = 0
            } else {
                self.liveFailures += 1   // a preview only: dropped, never retried as a turn
            }
            if let deferred = self.deferredOp {
                self.deferredOp = nil
                self.performSend(deferred.op, matchID: deferred.matchID)
                return
            }
            if self.liveFailures < 3 { self.localTurnStateChanged() }
        }
    }

    private func handleRecordChange(_ record: GameRecord) {
        let count = record.plies.count
        guard count > syncedPlyCount else { return }
        let mover = (count - 1) % 2 == 0 ? record.startingPlayer : record.startingPlayer.opponent
        syncedPlyCount = count
        if mover == localColor { pushLocalTurn(record) }
    }

    private func pushLocalTurn(_ record: GameRecord) {
        guard let id = activeMatchID else { return }

        if let result = record.result {
            // The local move finished the game (win of 1/2 points, or a draw, #143).
            completedGameLogs.append(GameLog(plies: record.plies, result: result))
            matchState.record(result)
            pendingGameResult = result
            if matchState.isComplete {
                isMatchOver = true
                recordCancellable = nil
                let data = (try? payload(games: completedGameLogs).encoded()) ?? Data()
                send(.endMatch(data, localWon: matchState.matchWinner == localColor), matchID: id)
            } else {
                // Start the next game locally; hand the turn to its starter.
                let nextIndex = completedGameLogs.count
                let starter = matchState.currentStartingPlayer
                let data = (try? payload(games: completedGameLogs + [GameLog()]).encoded()) ?? Data()
                startGame(nextIndex, from: payload(games: completedGameLogs + [GameLog()]))
                send(starter == localColor ? .saveTurn(data) : .endTurn(data), matchID: id)
            }
            return
        }

        let current = GameLog(plies: record.plies, result: nil)
        guard let data = try? payload(games: completedGameLogs + [current]).encoded() else { return }
        send(.endTurn(data), matchID: id)
    }

    private func send(_ op: PendingOp, matchID: String) {
        pendingOp = op
        hasUnsentTurn = true
        // The real turn supersedes any live write still waiting (#269); one in flight
        // is let finish first so the two writes never overlap.
        liveSendTask?.cancel()
        liveSendTask = nil
        if liveSaveInFlight {
            deferredOp = (op, matchID)
            return
        }
        performSend(op, matchID: matchID)
    }

    private func performSend(_ op: PendingOp, matchID: String) {
        // Every write carries the newest dice (#272), a resent one too.
        let op = withCurrentDice(op)
        if pendingOp != nil { pendingOp = op }
        let sentDice = diceRev(of: op.data)
        realOpInFlight = true
        let done: OnlineCompletion = { [weak self] error in
            guard let self else { return }
            self.realOpInFlight = false
            guard self.activeMatchID == matchID else { return }
            if error != nil {
                self.status = .sendFailed
                self.scheduleRetry()
            } else {
                self.pendingOp = nil
                self.hasUnsentTurn = false
                self.consecutiveFailures = 0
                self.retryTask?.cancel()
                self.sentDiceRev = max(self.sentDiceRev, sentDice)
                if self.status == .sendFailed { self.status = nil }
                // A dice change made while the write was out is minted / sent now (#272).
                self.reconcileDice()
                self.localTurnStateChanged()   // a roll made meanwhile can go out now
                self.schedulePoll(changed: true)
            }
        }
        switch op {
        case .endTurn(let data):
            currentPlayerID = nil
            service.endTurn(matchID: matchID, data: data, completion: done)
        case .saveTurn(let data):
            service.saveTurn(matchID: matchID, data: data, completion: done)
        case .endMatch(let data, let localWon):
            service.endMatch(matchID: matchID, data: data, localWon: localWon, completion: done)
        }
    }

    /// Retry a failed send after a growing delay by reloading the match: `apply` then
    /// resends if the service is still behind, or drops it if the turn arrived after all.
    private func scheduleRetry() {
        guard let base = retryDelay, let id = activeMatchID else { return }
        consecutiveFailures += 1
        let delay = min(300, base * pow(2, Double(consecutiveFailures - 1)))
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.activeMatchID == id, self.pendingOp != nil else { return }
            self.refresh()
        }
    }

    private func resendPending() {
        guard let op = pendingOp, let id = activeMatchID else { return }
        send(op, matchID: id)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    /// The variant's value net, loaded once per match (`nil` = no weighted dice).
    private func handicapAgent(forVariant id: String) -> Agent? {
        if let agent = handicapAgents[id] { return agent }
        guard let agent = handicapAgentProvider?(GameConfig(variantID: id)) else { return nil }
        handicapAgents[id] = agent
        return agent
    }

    private func currentPayload() -> OnlineMatchPayload? {
        guard let session else { return nil }
        let current = GameLog(plies: session.record.plies, result: session.record.result)
        return payload(games: completedGameLogs + [current])
    }

    private func payload(games: [GameLog], liveTurn: LiveTurn? = nil) -> OnlineMatchPayload {
        OnlineMatchPayload(targetWins: matchState.targetWins,
                           startingPlayer: matchState.baseStartingPlayer,
                           colorByPlayerID: colorByPlayerID,
                           games: games,
                           variant: variantID,
                           liveTurn: liveTurn,
                           diceHandicap: confirmedDice)
    }

    /// (games, plies in the last game) — how far a log has got.
    private func progress(of payload: OnlineMatchPayload) -> Progress {
        Progress(games: payload.games.count, plies: payload.games.last?.plies.count ?? 0)
    }

    private func localProgress() -> Progress {
        if matchState.isComplete {
            return Progress(games: completedGameLogs.count, plies: completedGameLogs.last?.plies.count ?? 0)
        }
        return Progress(games: completedGameLogs.count + 1, plies: session?.record.plies.count ?? 0)
    }

    private struct Progress: Comparable {
        let games: Int, plies: Int
        static func < (a: Progress, b: Progress) -> Bool {
            (a.games, a.plies) < (b.games, b.plies)
        }
    }

    private func participant(_ id: String, in snapshot: OnlineMatchSnapshot) -> OnlineParticipant? {
        snapshot.participants.first { $0.playerID == id }
    }

    private func opponent(in snapshot: OnlineMatchSnapshot) -> OnlineParticipant? {
        snapshot.participants.first { $0.playerID != localPlayerID }
    }

    private func resetMatchState() {
        retryTask?.cancel()
        retryTask = nil
        consecutiveFailures = 0
        recordCancellable = nil
        sessionChangeCancellable = nil
        liveSendTask?.cancel()
        liveSendTask = nil
        pollTask?.cancel()
        pollTask = nil
        pollDelay = 0
        lastSnapshotData = nil
        // An in-flight live write's completion ignores a closed match (`activeMatchID`).
        liveSaveInFlight = false
        realOpInFlight = false
        deferredOp = nil
        lastSentLive = nil
        liveFailures = 0
        shownLive = nil
        confirmedDice = .fair
        pendingDiceRequest = nil
        diceRequestInFlight = false
        serverDiceInFlight = false
        lastDiceRequestKey = nil
        sentDiceRev = 0
        diceHandicap = .fair
        isDiceChangePending = false
        session = nil
        activeMatchID = nil
        opponentName = nil
        colorByPlayerID = [:]
        variantID = GameVariants.defaultID
        completedGameLogs = []
        syncedGameIndex = 0
        syncedPlyCount = 0
        matchState = .single(baseStartingPlayer: .white)
        pendingGameResult = nil
        isMatchOver = false
        hasUnsentTurn = false
        pendingOp = nil
        currentPlayerID = nil
        status = nil
        localColor = .white
    }
}
