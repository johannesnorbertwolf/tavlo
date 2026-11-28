import Foundation
import Combine
import UIKit
import UserNotifications
import TavliEngine

/// Push notifications for online play through our server (#287), the app side:
/// - **permission** is asked once, right after the player's first own online match (created
///   or joined: `ServerLobby.onMatchStarted`), never at launch;
/// - with permission the app registers with APNs at every launch; the device token goes to
///   the server (`ServerOnlineCoordinator`, `PUT /v1/push-tokens`) with `sandbox` for debug
///   builds and `production` for TestFlight / App Store builds (the `aps-environment`
///   entitlement per build configuration, `project.yml`);
/// - the text is localized by iOS from the payload's `loc-key` (`PUSH_*` strings in
///   Localizable.xcstrings) — the app does not need to run;
/// - in front, a push for the match on screen is not shown (it updates live); others show
///   as a banner. A tapped push opens its match (`tappedMatchID` → `RootView`).
/// - #301: an incoming challenge has the CHALLENGE category: **Accept** opens the app and the
///   match, **Decline** answers without opening it (handled here in the background), a tap on
///   the notification itself shows the lobby with the challenge card. In front, a challenge
///   shows as the in-app card instead of a banner.
@MainActor
final class PushRegistrar: NSObject, ObservableObject {
    static let shared = PushRegistrar()

    /// APNs environment of this build's token.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private static let askedKey = "push.permissionAsked"

    /// The current APNs device token (hex), once registered.
    @Published private(set) var deviceToken: String?
    /// A tapped push's match (consumed by `RootView`).
    @Published var tappedMatchID: String?
    /// The match on screen (pushes for it are not shown while the app is in front).
    var openMatchID: () -> String? = { nil }
    /// #301: a tapped challenge notification (not a button): the lobby shows its card.
    @Published var tappedChallengeMatchID: String?
    /// #301: the app shows incoming challenges as its own card (the people list is live).
    var showsChallengesInApp: () -> Bool = { false }
    /// #301: a challenge push arrived while in front (the app refreshes its cards).
    var onForegroundChallenge: ((String) -> Void)?

    /// #301: the CHALLENGE category (Accept opens the app; Decline answers in the background,
    /// after unlocking).
    static func registerCategories() {
        let accept = UNNotificationAction(identifier: PushSupport.acceptAction,
                                          title: String(localized: "Accept"), options: [.foreground])
        let decline = UNNotificationAction(identifier: PushSupport.declineAction,
                                           title: String(localized: "Decline"),
                                           options: [.destructive, .authenticationRequired])
        let category = UNNotificationCategory(identifier: ServerAPI.challengeCategory, actions: [accept, decline],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// #301: Decline from the notification: answer the server without opening the app.
    func declineInBackground(matchID: String) async {
        guard let client = AccountStore.shared.client else { return }
        let _: Empty? = try? await client.authorized(method: "POST", path: "/v1/matches/\(matchID)/decline",
                                                     body: Optional<Int>.none)
    }

    /// #301: a challenge was answered (here or elsewhere): its notification goes.
    static func removeDelivered(matchID: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { PushSupport.matchID(fromUserInfo: $0.request.content.userInfo) == matchID }
                .map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Called from `application(_:didFinishLaunchingWithOptions:)`: become the notification
    /// delegate (so a push that launches the app is routed) and refresh the token if the
    /// player already allowed notifications.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        Self.registerCategories()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            guard allowed else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Ask once (the first own online match). Later matches never ask again; the player can
    /// still turn notifications on in the iOS Settings app.
    func askPermissionIfNeeded() {
        let asked = UserDefaults.standard.bool(forKey: Self.askedKey)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let undetermined = settings.authorizationStatus == .notDetermined
            guard PushSupport.shouldAskPermission(isUndetermined: undetermined, askedBefore: asked) else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: Self.askedKey)
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    guard granted else { return }
                    DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
                }
            }
        }
    }

    /// Before signing out: this device stops getting the account's pushes (best effort).
    func unregister(using client: AuthClient) async {
        guard let token = deviceToken else { return }
        let _: Empty? = try? await client.authorized(method: "DELETE", path: "/v1/push-tokens/\(token)",
                                                     body: Optional<Int>.none)
    }

    private struct Empty: Decodable {}

    func didRegister(deviceToken data: Data) {
        deviceToken = PushSupport.hex(data)
    }

    func didFailToRegister(_ error: Error) {
        // Simulators without APNs, no network: pushes just stay off.
        print("push: registration failed: \(error.localizedDescription)")
    }
}

extension PushRegistrar: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let payload = ServerAPI.PushPayload(userInfo: userInfo)
        let matchID = payload?.matchID
        Task { @MainActor in
            let inApp = self.showsChallengesInApp()
            let show = PushSupport.shouldPresentInForeground(kind: payload?.kind, pushMatchID: matchID,
                                                             openMatchID: self.openMatchID(), showsChallengesInApp: inApp)
            if payload?.kind == .challengeReceived, let matchID, inApp { self.onForegroundChallenge?(matchID) }
            completionHandler(show ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let matchID = PushSupport.matchID(fromUserInfo: userInfo)
        let challenge = PushSupport.challengeMatchID(fromUserInfo: userInfo)
        let action = response.actionIdentifier
        Task { @MainActor in
            switch (action, challenge) {
            case (PushSupport.declineAction, let id?):
                await self.declineInBackground(matchID: id)
            case (PushSupport.acceptAction, let id?):
                self.tappedMatchID = id   // opening it accepts the seat first
            case (UNNotificationDefaultActionIdentifier, let id?):
                self.tappedChallengeMatchID = id
            default:
                if let matchID { self.tappedMatchID = matchID }
            }
            completionHandler()
        }
    }
}

/// The UIKit hooks SwiftUI has no modifier for: APNs registration results and becoming the
/// notification delegate before launch finishes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { PushRegistrar.shared.start() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PushRegistrar.shared.didFailToRegister(error) }
    }
}
