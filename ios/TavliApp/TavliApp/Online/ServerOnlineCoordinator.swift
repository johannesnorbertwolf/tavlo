import Foundation
import Combine
import UIKit
import TavliEngine

/// Online play through our own server (#286, lobby/invites/push #287), behind the developer
/// switch "Play online via the server" (Settings → Online account, developer tools on); Game
/// Center stays the default path until #288. Invite links and pushes are server-only, so
/// they open this lobby whatever the switch says (`routedHere`).
///
/// The app-side twin of `GameKitCoordinator`: per signed-in account it owns the engine's
/// `ServerMatchService` (HTTPS + WebSocket over the `AuthClient`), an `OnlineMatchController`
/// and a `ServerLobby` (list, invites, auto-match, row actions — all logic in the engine);
/// it keeps the device's push token registered and routes invite links + tapped pushes.
@MainActor
final class ServerOnlineCoordinator: ObservableObject {
    static let switchKey = "debug.onlineViaServer"

    /// The lobby of the signed-in account (nil while signed out).
    @Published private(set) var lobby: ServerLobby?
    /// The controller for the current account's service (rebuilt on sign-in changes).
    @Published private(set) var controller: OnlineMatchController?
    /// #301: the account's people, challenges and search (nil while signed out).
    @Published private(set) var people: ServerPeople?
    /// #301: the local player's challenge was accepted while its sheet wasn't on screen:
    /// the root card offers "Play now".
    @Published var acceptedChallenge: OutgoingChallenge?
    /// #301: the challenge sheet is on screen waiting (an accept then opens the match at once).
    var isWaitingSheetShown = false
    /// #301: a tapped challenge notification: the lobby shows its card.
    @Published var pendingIncomingMatchID: String?
    /// An invite code from a link (or typed elsewhere), waiting for the lobby to show it.
    @Published var pendingJoinCode: String?
    /// An invite link or a tapped push opened the online screen (whatever the switch says).
    @Published private(set) var routedHere = false

    private(set) var service: ServerMatchService?
    private var serviceAccountID: String?
    private var cancellables: Set<AnyCancellable> = []
    private var clientCancellable: AnyCancellable?
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    /// #301: the presence socket (only while the app is in front).
    private var presence: ServerPresenceConnection?
    /// A tapped push's match, opened once signed in.
    private var pendingOpenMatchID: String?
    /// Token last registered for which account (avoid re-sending on every rebuild).
    private var registeredToken: (token: String, account: String)?

    /// Inert (no account observation, no network) until the server lobby first appears or a
    /// link / push routes here.
    init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidBecomeActive() }
        }
        PushRegistrar.shared.$deviceToken
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerPushToken() }
            .store(in: &cancellables)
        PushRegistrar.shared.openMatchID = { [weak self] in self?.controller?.activeMatchID }
        // #301: presence only while the app is in front — no background keep-alive.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.presence?.stop() }
        }
        PushRegistrar.shared.showsChallengesInApp = { [weak self] in self?.people != nil }
        PushRegistrar.shared.onForegroundChallenge = { [weak self] _ in
            guard let people = self?.people else { return }
            Task {
                await people.lobby.refresh()
                await people.refresh()
            }
        }
    }

    /// Start following the signed-in account (the server lobby appeared).
    func activate() {
        guard clientCancellable == nil, accountObservation == nil else { return }
        accountObservation = AccountStore.shared.$client
            .sink { [weak self] client in self?.observe(client) }
    }

    private var accountObservation: AnyCancellable?

    private func observe(_ client: AuthClient?) {
        clientCancellable = client?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] _ in
                guard let self, let client else { return }
                self.rebuild(for: client)
            }
        if client == nil { rebuild(for: nil) }
    }

    /// One service + controller + lobby per signed-in account.
    private func rebuild(for client: AuthClient?) {
        let account = client?.account?.id
        guard account != serviceAccountID || (account != nil && service == nil) else { return }
        controller?.close()
        service?.close()
        presence?.stop()
        presence = nil
        serviceAccountID = account
        guard let client, account != nil else {
            service = nil
            controller = nil
            lobby = nil
            people = nil
            return
        }
        let service = ServerMatchService(client: client, sockets: URLSessionSocketFactory())
        service.describeError = ServerOnlineCopy.message(for:)
        service.onMatchChanged = { [weak self] _ in self?.scheduleListRefresh() }
        // The value net per variant, for the shared weighted dice (#272): the server bends
        // the roll with the roller's 21 values.
        let controller = OnlineMatchController(service: service,
                                               handicapAgent: { GameSession.makeAgent(config: $0) })
        service.controller = controller
        let lobby = ServerLobby(service: service, controller: controller)
        lobby.describeError = ServerOnlineCopy.message(for:)
        // Ask for notifications once, right after the first own match (#287).
        lobby.onMatchStarted = { PushRegistrar.shared.askPermissionIfNeeded() }
        // #301: people + challenges, and the presence socket while in front.
        let people = ServerPeople(service: service, lobby: lobby)
        people.describeError = ServerOnlineCopy.peopleMessage(for:)
        people.onAccepted = { [weak self] challenge in self?.challengeAccepted(challenge) }
        let presence = ServerPresenceConnection(service: service, sockets: URLSessionSocketFactory())
        presence.onMessage = { [weak people] message in people?.handle(message) }
        self.service = service
        self.controller = controller
        self.lobby = lobby
        self.people = people
        self.presence = presence
        if UIApplication.shared.applicationState != .background { presence.start() }
        Task { await people.refresh() }
        refreshMatches()
        registerPushToken()
        if let id = pendingOpenMatchID {
            pendingOpenMatchID = nil
            Task { await lobby.open(matchID: id) }
        }
    }

    var isSignedIn: Bool { service != nil }
    var accountID: String? { serviceAccountID }

    // MARK: Routing (links, pushes)

    /// An invite link (`https://<server>/join/<code>`) was opened: show the lobby's join sheet.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let code = InviteCode.fromLink(url) else { return false }
        pendingJoinCode = code
        routedHere = true
        activate()
        return true
    }

    /// A push was tapped: open its match (after sign-in if needed).
    func openFromPush(matchID: String) {
        routedHere = true
        activate()
        if let lobby {
            Task { await lobby.open(matchID: matchID) }
        } else {
            pendingOpenMatchID = matchID
        }
    }

    /// #301: a challenge notification was tapped (not its buttons): the lobby shows its card.
    func showIncoming(matchID: String) {
        routedHere = true
        pendingIncomingMatchID = matchID
        activate()
        if let people {
            Task {
                await people.lobby.refresh()
                await people.refresh()
            }
        }
    }

    /// #301: the local player's challenge was accepted: open it now when the sheet waits
    /// on it, else offer it on the root card.
    private func challengeAccepted(_ challenge: OutgoingChallenge) {
        guard let people else { return }
        if isWaitingSheetShown, people.waiting?.matchID == challenge.matchID {
            Task { await people.openAccepted() }
        } else {
            acceptedChallenge = challenge
        }
    }

    /// The root card's "Play now".
    func playAccepted() {
        guard let challenge = acceptedChallenge, let id = challenge.matchID else { return }
        acceptedChallenge = nil
        people?.clearWaiting()
        openFromPush(matchID: id)
    }

    /// Accept an incoming challenge from the root card: the online screen opens with the match.
    func acceptIncoming(_ challenge: IncomingChallenge) {
        guard let people else { return }
        routedHere = true
        Task { await people.accept(challenge) }
    }

    /// Show the server lobby whatever the developer switch says (DEBUG launch arguments).
    func showLobby() {
        routedHere = true
        activate()
    }

    /// The online screen closed.
    func didExit() {
        routedHere = false
    }

    // MARK: Lobby

    private var listRefresh: Task<Void, Never>?

    /// Coalesces a burst of match changes into one list reload.
    private func scheduleListRefresh() {
        listRefresh?.cancel()
        listRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshMatches()
        }
    }

    func refreshMatches() {
        guard let lobby else { return }
        Task { await lobby.refresh() }
    }

    func closeMatch() {
        controller?.close()
        service?.watch(nil)
        refreshMatches()
    }

    func forfeitMatch() {
        controller?.forfeit()
        service?.watch(nil)
        refreshMatches()
    }

    private func appDidBecomeActive() {
        guard service != nil else { return }
        presence?.start()
        if let people { Task { await people.refresh() } }
        refreshMatches()
        service?.reconnectNow()
        controller?.refresh()
    }

    // MARK: Push token

    private func registerPushToken() {
        guard let service, let account = serviceAccountID, let token = PushRegistrar.shared.deviceToken else { return }
        if let r = registeredToken, r.token == token, r.account == account { return }
        registeredToken = (token, account)
        let locale = Locale.preferredLanguages.first
        Task { [weak self] in
            do {
                try await service.registerPushToken(token, environment: PushRegistrar.environment, locale: locale)
            } catch {
                self?.registeredToken = nil   // try again with the next rebuild / token
            }
        }
    }
}

/// Player-facing copy for server errors (online play through the server, #286, #287).
enum ServerOnlineCopy {
    static func message(for error: Error) -> String {
        if case .malformedCode? = error as? ServerLobbyError {
            return String(localized: "That doesn’t look like an invite code. Codes have 6 letters and digits.")
        }
        if let e = error as? ServerMatchError, let code = e.code { return message(code: code) }
        if case .server(let code?, _)? = error as? AuthError { return message(code: code) }
        if case .notSignedIn? = error as? AuthError { return String(localized: "Please sign in to your online account again.") }
        if case .invalidHandle? = error as? AuthError {
            return String(localized: "Handles are 3–20 letters, digits or _ (no spaces).")
        }
        return String(localized: "Couldn’t reach the server. Check your connection and try again.")
    }

    private static func message(code: String) -> String {
        switch ServerAPI.ErrorCode(rawValue: code) {
        case .notFound: return String(localized: "That player or game wasn’t found.")
        case .matchEnded: return String(localized: "This game is over.")
        case .inviteUnavailable: return String(localized: "This invite isn’t open any more. Ask your friend for a new one.")
        case .handleTaken: return String(localized: "Someone else has that handle. Try another one.")
        case .forbidden: return String(localized: "You can’t do that in this game.")
        case .upgradeRequired: return String(localized: "Please update the app to play online.")
        case .rateLimited: return String(localized: "Too many requests. Please wait a minute.")
        case .unauthorized, .tokenExpired: return String(localized: "Please sign in to your online account again.")
        default: return String(localized: "Something went wrong. Please try again.")
        }
    }

    /// #301: the people list's copy (a refused challenge, a closed one), else `message(for:)`.
    static func peopleMessage(for error: Error) -> String {
        var code: String?
        if let e = error as? ServerMatchError { code = e.code }
        if case .server(let c?, _)? = error as? AuthError { code = c }
        switch code.flatMap(ServerAPI.ErrorCode.init(rawValue:)) {
        case .forbidden: return String(localized: "This player takes challenges only from people they know.")
        case .inviteUnavailable: return String(localized: "This challenge isn’t open any more.")
        default: return message(for: error)
        }
    }

    /// The server's roll didn't arrive (`GameSession.remoteRollFailed`).
    static var rollFailed: String {
        String(localized: "Couldn’t get your dice from the server. Tap the dice to try again.")
    }
}
