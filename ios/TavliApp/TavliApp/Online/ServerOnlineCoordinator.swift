import Foundation
import Combine
import UIKit
import TavliEngine

/// Online play through our own server (#286), behind the developer switch "Play online via
/// the server" (Settings → Online account, developer tools on); Game Center stays the
/// default path until #287/#288. The app-side twin of `GameKitCoordinator`: it owns the
/// engine's `ServerMatchService` (HTTPS + WebSocket over the signed-in `AuthClient`) and an
/// `OnlineMatchController`, keeps the lobby list (`GET /v1/matches`), opens / creates
/// matches and keeps the open match's socket. All match logic stays in the engine.
/// Invites / auto-match / push are #287: this lobby challenges an account id directly.
@MainActor
final class ServerOnlineCoordinator: ObservableObject {
    static let switchKey = "debug.onlineViaServer"

    /// The signed-in account's matches, newest first.
    @Published private(set) var matches: [ServerAPI.MatchSummary] = []
    /// A lobby action failed (shown under the buttons).
    @Published var lobbyError: String?
    @Published private(set) var isWorking = false
    /// The controller for the current account's service (rebuilt on sign-in changes).
    @Published private(set) var controller: OnlineMatchController?

    private(set) var service: ServerMatchService?
    private var serviceAccountID: String?
    private var cancellables: Set<AnyCancellable> = []
    private var foregroundObserver: NSObjectProtocol?

    /// Inert (no account observation, no network) until the server lobby first appears.
    init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidBecomeActive() }
        }
    }

    private var clientCancellable: AnyCancellable?

    /// Start following the signed-in account (called when the server lobby appears).
    func activate() {
        guard cancellables.isEmpty else { return }
        AccountStore.shared.$client
            .sink { [weak self] client in self?.observe(client) }
            .store(in: &cancellables)
    }

    private func observe(_ client: AuthClient?) {
        clientCancellable = client?.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] _ in
                guard let self, let client else { return }
                self.rebuild(for: client)
            }
        if client == nil { rebuild(for: nil) }
    }

    /// One service + controller per signed-in account.
    private func rebuild(for client: AuthClient?) {
        let account = client?.account?.id
        guard account != serviceAccountID || (account != nil && service == nil) else { return }
        controller?.close()
        service?.close()
        serviceAccountID = account
        matches = []
        guard let client, account != nil else {
            service = nil
            controller = nil
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
        self.service = service
        self.controller = controller
        refreshMatches()
    }

    var isSignedIn: Bool { service != nil }
    var accountID: String? { serviceAccountID }

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
        guard let service else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.matches = try await service.listMatches().matches
            } catch {
                self.lobbyError = ServerOnlineCopy.message(for: error)
            }
        }
    }

    /// Challenge `opponentID` (an account id) to a new match and open it.
    func challenge(opponentID: String, targetWins: Int, variantID: String) {
        guard let service, let controller else { return }
        let opponent = opponentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opponent.isEmpty else { return }
        isWorking = true
        lobbyError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false }
            do {
                let snap = try await service.createMatch(variant: variantID, targetWins: targetWins,
                                                         opponentID: opponent)
                controller.open(snap.onlineSnapshot, newMatchTargetWins: targetWins, newMatchVariantID: variantID)
                service.watch(snap.matchID)
                self.refreshMatches()
            } catch {
                self.lobbyError = ServerOnlineCopy.message(for: error)
            }
        }
    }

    func open(_ summary: ServerAPI.MatchSummary) {
        guard let service, let controller else { return }
        lobbyError = nil
        Task { @MainActor [weak self] in
            do {
                let snap = try await service.loadSnapshot(matchID: summary.matchID)
                controller.open(snap.onlineSnapshot, newMatchTargetWins: summary.targetWins,
                                newMatchVariantID: summary.variant)
                service.watch(snap.matchID)
            } catch {
                self?.lobbyError = ServerOnlineCopy.message(for: error)
            }
        }
    }

    func decline(_ summary: ServerAPI.MatchSummary) {
        guard let service else { return }
        Task { @MainActor [weak self] in
            try? await service.decline(matchID: summary.matchID)
            self?.refreshMatches()
        }
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
}

/// Player-facing copy for server errors (online play through the server, #286).
enum ServerOnlineCopy {
    static func message(for error: Error) -> String {
        if let e = error as? ServerMatchError, let code = e.code { return message(code: code) }
        if case .server(let code?, _)? = error as? AuthError { return message(code: code) }
        if case .notSignedIn? = error as? AuthError { return String(localized: "Please sign in to your online account again.") }
        return String(localized: "Couldn’t reach the server. Check your connection and try again.")
    }

    private static func message(code: String) -> String {
        switch ServerAPI.ErrorCode(rawValue: code) {
        case .notFound: return String(localized: "That player or game wasn’t found.")
        case .matchEnded: return String(localized: "This game is over.")
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
