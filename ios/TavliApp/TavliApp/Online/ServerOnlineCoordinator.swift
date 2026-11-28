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
    /// An invite code from a link (or typed elsewhere), waiting for the lobby to show it.
    @Published var pendingJoinCode: String?
    /// An invite link or a tapped push opened the online screen (whatever the switch says).
    @Published private(set) var routedHere = false

    private(set) var service: ServerMatchService?
    private var serviceAccountID: String?
    private var cancellables: Set<AnyCancellable> = []
    private var clientCancellable: AnyCancellable?
    private var foregroundObserver: NSObjectProtocol?
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
        serviceAccountID = account
        guard let client, account != nil else {
            service = nil
            controller = nil
            lobby = nil
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
        self.service = service
        self.controller = controller
        self.lobby = lobby
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
        return String(localized: "Couldn’t reach the server. Check your connection and try again.")
    }

    private static func message(code: String) -> String {
        switch ServerAPI.ErrorCode(rawValue: code) {
        case .notFound: return String(localized: "That player or game wasn’t found.")
        case .matchEnded: return String(localized: "This game is over.")
        case .inviteUnavailable: return String(localized: "This invite isn’t open any more. Ask your friend for a new one.")
        case .forbidden: return String(localized: "You can’t do that in this game.")
        case .upgradeRequired: return String(localized: "Please update the app to play online.")
        case .rateLimited: return String(localized: "Too many requests. Please wait a minute.")
        case .unauthorized, .tokenExpired: return String(localized: "Please sign in to your online account again.")
        default: return String(localized: "Something went wrong. Please try again.")
        }
    }

    /// The server's roll didn't arrive (`GameSession.remoteRollFailed`).
    static var rollFailed: String {
        String(localized: "Couldn’t get your dice from the server. Tap the dice to try again.")
    }
}
