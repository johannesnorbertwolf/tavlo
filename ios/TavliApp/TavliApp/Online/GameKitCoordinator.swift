import Foundation
import Combine
import GameKit
import UIKit
import TavliEngine

/// The Game Center side of online play (#134, #145): sign-in, the matchmaker, the
/// lobby's match list, and the turn-event listener. All match logic lives in the
/// engine's `OnlineMatchController` (unit-tested against a simulated two-device Game
/// Center); this class only adapts `GKTurnBasedMatch` to its `OnlineMatchService` seam
/// and routes events to it.
///
/// **Event routing.**
/// - An event for the open match is applied to it (moves, match end, opponent quitting).
/// - A match this device just created through the matchmaker is opened.
/// - A match the user opened from a notification (`didBecomeActive`) is opened and the
///   online screen requested.
/// - Anything else only refreshes the lobby list (and notes "your turn" elsewhere) —
///   it never replaces the game on screen.
///
/// **Live turn (#269).** The controller also writes the local turn in progress with
/// `saveCurrentTurn` (roll at once, half-moves coalesced, one write in flight); GameKit
/// raises `receivedTurnEventFor` on the opponent's device for each ("a participant saves
/// match data"), which routes here like any event; the controller's poll covers missed
/// ones.
///
/// **Shared weighted dice (#272).** The turn holder writes the value with its normal
/// writes. The waiting player's change goes out with `sendExchange` (any participant may
/// send one out of turn); the turn holder's device applies it from
/// `receivedExchangeRequest` and replies at once. GameKit then hands the completed
/// exchange to the current participant, who must resolve it with `saveMergedMatch` before
/// ending its turn: every write below resolves the completed exchanges first (their data
/// is already in the payload, the controller applied it on receipt).
///
/// Sign-in starts at launch without UI (`authenticate(presentUI: false)`) so the
/// listener is registered before a notification is tapped; the Game Center sign-in
/// sheet is shown only when the player opens Play Online. Returning to the foreground
/// reloads the lobby list and the open match.
@MainActor
final class GameKitCoordinator: NSObject, ObservableObject {

    // ── Published view state ────────────────────────────────────────────────────

    @Published private(set) var isAuthenticated = false
    @Published private(set) var authError: String?
    /// The player's matches for the lobby (ended ones included, shown as finished).
    @Published private(set) var matches: [GKTurnBasedMatch] = []
    /// Set when a notification opened a match: the app should show the online screen.
    @Published var showOnlineRequested = false

    /// The match logic (session, colours, score, status). Views observe it directly.
    private(set) var controller: OnlineMatchController!

    // ── Private state ───────────────────────────────────────────────────────────

    /// Live `GKTurnBasedMatch` objects by id, for the service calls.
    private var liveMatches: [String: GKTurnBasedMatch] = [:]
    /// Match length + variant chosen in the lobby while the matchmaker is up; the next
    /// new match the listener reports is this device's creation.
    private var pendingNewMatch: (targetWins: Int, variantID: String)?
    private weak var matchmaker: UIViewController?
    /// Game Center's sign-in sheet, held until the player opens Play Online.
    private var pendingSignInController: UIViewController?
    private var foregroundObserver: NSObjectProtocol?

    override init() {
        super.init()
        // The value net per variant, for the shared weighted dice (#272).
        controller = OnlineMatchController(service: self,
                                           handicapAgent: { GameSession.makeAgent(config: $0) })
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidBecomeActive() }
        }
    }

    // ── Authentication ──────────────────────────────────────────────────────────

    /// Begin (or resume) Game Center sign-in. At launch call with `presentUI: false`:
    /// a needed sign-in sheet is kept until the lobby asks for it. Safe to call again.
    func authenticate(presentUI: Bool = true) {
        if presentUI, let vc = pendingSignInController {
            pendingSignInController = nil
            present(vc)
            return
        }
        guard GKLocalPlayer.local.authenticateHandler == nil || presentUI else { return }
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    if presentUI { self.present(viewController) }
                    else { self.pendingSignInController = viewController }
                } else if GKLocalPlayer.local.isAuthenticated {
                    self.isAuthenticated = true
                    self.authError = nil
                    GKLocalPlayer.local.unregisterAllListeners()
                    GKLocalPlayer.local.register(self)
                    self.refreshMatches()
                } else {
                    self.isAuthenticated = false
                    self.authError = error?.localizedDescription
                        ?? String(localized: "Sign in to Game Center to play online.")
                }
            }
        }
    }

    // ── Lobby actions ───────────────────────────────────────────────────────────

    /// Show Game Center's matchmaker to invite a friend (or auto-match). The created
    /// match arrives through the listener and is opened there.
    func presentInvite(targetWins: Int, variantID: String = GameVariants.defaultID) {
        guard isAuthenticated else { authenticate(presentUI: true); return }
        pendingNewMatch = (max(1, targetWins), variantID)
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        let vc = GKTurnBasedMatchmakerViewController(matchRequest: request)
        vc.turnBasedMatchmakerDelegate = self
        vc.showExistingMatches = false
        matchmaker = vc
        present(vc)
    }

    func refreshMatches() {
        GKTurnBasedMatch.loadMatches { [weak self] matches, _ in
            Task { @MainActor in
                guard let self else { return }
                for m in matches ?? [] { self.liveMatches[m.matchID] = m }
                self.matches = (matches ?? []).sorted(by: Self.lobbyOrder)
            }
        }
    }

    /// Open a match from the lobby list.
    func open(_ match: GKTurnBasedMatch) {
        liveMatches[match.matchID] = match
        controller.open(snapshot(of: match))
    }

    /// Back to the lobby, keeping the match.
    func closeMatch() {
        controller.close()
        refreshMatches()
    }

    /// Forfeit the open match.
    func forfeitMatch() {
        controller.forfeit()
        refreshMatches()
    }

    /// Remove a finished match from the player's list.
    func remove(_ match: GKTurnBasedMatch) {
        match.remove { [weak self] _ in
            Task { @MainActor in self?.refreshMatches() }
        }
    }

    private func appDidBecomeActive() {
        guard isAuthenticated else { return }
        refreshMatches()
        controller.refresh()
    }

    /// Your turn first, then their turn, then finished; most recent first within each.
    private static func lobbyOrder(_ a: GKTurnBasedMatch, _ b: GKTurnBasedMatch) -> Bool {
        func rank(_ m: GKTurnBasedMatch) -> Int {
            if m.status == .ended { return 2 }
            return m.currentParticipant?.player?.gamePlayerID == GKLocalPlayer.local.gamePlayerID ? 0 : 1
        }
        let (ra, rb) = (rank(a), rank(b))
        if ra != rb { return ra < rb }
        return (a.currentParticipant?.lastTurnDate ?? .distantPast)
             > (b.currentParticipant?.lastTurnDate ?? .distantPast)
    }

    // ── Incoming events ─────────────────────────────────────────────────────────

    private func handleEvent(_ match: GKTurnBasedMatch, didBecomeActive: Bool) {
        liveMatches[match.matchID] = match
        let snap = snapshot(of: match)

        if controller.receive(snap) {
            // The opponent's live-turn writes (#269, `saveCurrentTurn` mid-turn) arrive
            // here several times a turn; the lobby list only changes when the turn
            // passes or the match ends.
            if snap.currentPlayerID == localPlayerID || snap.isEnded { refreshMatches() }
            return
        }
        defer { refreshMatches() }

        // A match this device just created through the matchmaker.
        if let new = pendingNewMatch, match.matchData?.isEmpty ?? true,
           snap.currentPlayerID == GKLocalPlayer.local.gamePlayerID {
            pendingNewMatch = nil
            matchmaker?.dismiss(animated: true)
            controller.open(snap, newMatchTargetWins: new.targetWins, newMatchVariantID: new.variantID)
            return
        }
        // The player tapped a notification for this match.
        if didBecomeActive {
            controller.open(snap)
            showOnlineRequested = true
        }
    }

    // ── Snapshots ───────────────────────────────────────────────────────────────

    private func snapshot(of match: GKTurnBasedMatch) -> OnlineMatchSnapshot {
        OnlineMatchSnapshot(
            matchID: match.matchID,
            data: match.matchData,
            participants: match.participants.map { p in
                OnlineParticipant(playerID: p.player?.gamePlayerID,
                                  displayName: p.player?.displayName,
                                  status: Self.status(p.status),
                                  outcome: Self.outcome(p.matchOutcome))
            },
            currentPlayerID: match.currentParticipant?.player?.gamePlayerID,
            isEnded: match.status == .ended)
    }

    private static func status(_ s: GKTurnBasedParticipant.Status) -> OnlineParticipantStatus {
        switch s {
        case .invited: return .invited
        case .declined: return .declined
        case .matching: return .matching
        case .active: return .active
        case .done: return .done
        default: return .unknown
        }
    }

    private static func outcome(_ o: GKTurnBasedMatch.Outcome) -> OnlineMatchOutcome {
        switch o {
        case .none: return .none
        case .quit: return .quit
        case .won: return .won
        case .lost: return .lost
        case .tied: return .tied
        case .timeExpired: return .timeExpired
        default: return .other
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private func opponents(of match: GKTurnBasedMatch) -> [GKTurnBasedParticipant] {
        match.participants.filter { $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID }
    }

    /// Present a UIKit view controller (sign-in or matchmaker) from the top-most one.
    private func present(_ vc: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }

    private func liveMatch(_ id: String, _ fail: OnlineCompletion) -> GKTurnBasedMatch? {
        if let m = liveMatches[id] { return m }
        fail(GKError(.unknown))
        return nil
    }
}

// ── OnlineMatchService: the controller's operations, on GKTurnBasedMatch ─────────

extension GameKitCoordinator: OnlineMatchService {
    var localPlayerID: String { GKLocalPlayer.local.gamePlayerID }

    func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        resolvingExchanges(match, data: data) {
            match.endTurn(withNextParticipants: self.opponents(of: match),
                          turnTimeout: GKTurnTimeoutDefault, match: data) { error in
                Task { @MainActor in completion(error) }
            }
        }
    }

    func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        resolvingExchanges(match, data: data) {
            match.saveCurrentTurn(withMatch: data) { error in
                Task { @MainActor in completion(error) }
            }
        }
    }

    func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        for p in match.participants where p.matchOutcome != .quit {
            let isLocal = p.player?.gamePlayerID == localPlayerID
            p.matchOutcome = (isLocal == localWon) ? .won : .lost
        }
        resolvingExchanges(match, data: data) {
            match.endMatchInTurn(withMatch: data) { error in
                Task { @MainActor in completion(error) }
            }
        }
    }

    /// The waiting player's dice change (#272) as a turn-based exchange to the opponent.
    /// Fails (the controller then applies the change on the local turn) when there is no
    /// active opponent, the data is too large or the exchange limit is reached.
    func sendRequest(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        let recipients = opponents(of: match).filter { $0.status == .active }
        let mine = (match.exchanges ?? []).filter {
            $0.sender.player?.gamePlayerID == localPlayerID && $0.status == .active
        }
        guard !recipients.isEmpty, data.count <= match.exchangeDataMaximumSize,
              mine.count < match.exchangeMaxInitiatedExchangesPerPlayer else {
            completion(GKError(.invalidParameter))
            return
        }
        // The recipient's push text when the app is in the background (its own strings).
        match.sendExchange(to: recipients, data: data,
                           localizableMessageKey: "%@ changed the shared dice.",
                           arguments: [GKLocalPlayer.local.displayName],
                           timeout: GKExchangeTimeoutDefault) { _, error in
            Task { @MainActor in completion(error) }
        }
    }

    /// Before a write by the current participant: resolve the completed exchanges with
    /// `saveMergedMatch` (GameKit requires it before the turn ends; their data is already
    /// merged into `data`). A failure doesn't hold the write up.
    private func resolvingExchanges(_ match: GKTurnBasedMatch, data: Data,
                                    then write: @escaping @MainActor () -> Void) {
        let completed = match.completedExchanges ?? []
        guard !completed.isEmpty,
              match.currentParticipant?.player?.gamePlayerID == localPlayerID else { write(); return }
        match.saveMergedMatch(data, withResolvedExchanges: completed) { _ in
            Task { @MainActor in write() }
        }
    }

    func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        if inTurn {
            resolvingExchanges(match, data: data) {
                match.participantQuitInTurn(with: .quit, nextParticipants: self.opponents(of: match),
                                            turnTimeout: GKTurnTimeoutDefault, match: data) { error in
                    Task { @MainActor in completion(error) }
                }
            }
        } else {
            match.participantQuitOutOfTurn(with: .quit) { error in
                Task { @MainActor in completion(error) }
            }
        }
    }

    func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        guard let match = liveMatches[matchID] else { completion(nil, GKError(.unknown)); return }
        match.acceptInvite { [weak self] accepted, error in
            Task { @MainActor in
                guard let self else { return }
                if let accepted { self.liveMatches[accepted.matchID] = accepted }
                completion(accepted.map { self.snapshot(of: $0) }, error)
            }
        }
    }

    func load(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        GKTurnBasedMatch.load(withID: matchID) { [weak self] match, error in
            Task { @MainActor in
                guard let self else { return }
                if let match { self.liveMatches[match.matchID] = match }
                completion(match.map { self.snapshot(of: $0) }, error)
            }
        }
    }
}

// ── Turn-based event listener ───────────────────────────────────────────────────

// GameKit calls these off the main thread; hop to the main actor.
extension GameKitCoordinator: GKLocalPlayerListener {
    /// A turn was taken, an invite accepted, a match created, or the player opened the
    /// app from a turn notification (`didBecomeActive`).
    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch,
                            didBecomeActive: Bool) {
        Task { @MainActor in self.handleEvent(match, didBecomeActive: didBecomeActive) }
    }

    /// The match ended. Routed like a turn event so the open match applies the final
    /// move (or the opponent's forfeit) instead of freezing a move early.
    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        Task { @MainActor in self.handleEvent(match, didBecomeActive: false) }
    }

    /// The opponent changed the shared dice while waiting (#272). Applied when this
    /// device holds the turn of the open match (otherwise the opponent applies it on its
    /// own turn); always answered at once so the exchange completes.
    nonisolated func player(_ player: GKPlayer, receivedExchangeRequest exchange: GKTurnBasedExchange,
                            for match: GKTurnBasedMatch) {
        Task { @MainActor in
            self.liveMatches[match.matchID] = match
            if let data = exchange.data {
                self.controller.receiveRequest(matchID: match.matchID, data: data)
            }
            exchange.reply(withLocalizableMessageKey: "The shared dice were updated.",
                           arguments: [], data: Data()) { _ in }
        }
    }

    /// An exchange completed: keep the fresh match so the next write resolves it
    /// (`resolvingExchanges`).
    nonisolated func player(_ player: GKPlayer, receivedExchangeReplies replies: [GKTurnBasedExchangeReply],
                            forCompletedExchange exchange: GKTurnBasedExchange, for match: GKTurnBasedMatch) {
        Task { @MainActor in self.liveMatches[match.matchID] = match }
    }

    /// The **local** player quit this match from Game Center's own interface while it
    /// was their turn: GameKit expects the app to forfeit it in turn.
    nonisolated func player(_ player: GKPlayer, wantsToQuitMatch match: GKTurnBasedMatch) {
        Task { @MainActor in
            self.liveMatches[match.matchID] = match
            if self.controller.activeMatchID == match.matchID {
                self.controller.forfeit()
            } else {
                self.quit(matchID: match.matchID, data: match.matchData ?? Data(), inTurn: true) { _ in }
            }
            self.refreshMatches()
        }
    }
}

// ── Matchmaker delegate ─────────────────────────────────────────────────────────

extension GameKitCoordinator: GKTurnBasedMatchmakerViewControllerDelegate {
    nonisolated func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
        Task { @MainActor in
            self.pendingNewMatch = nil
            viewController.dismiss(animated: true)
        }
    }

    nonisolated func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController,
                                                       didFailWithError error: Error) {
        Task { @MainActor in
            self.pendingNewMatch = nil
            viewController.dismiss(animated: true)
            self.authError = error.localizedDescription
        }
    }
}
