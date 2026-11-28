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

    /// Called from `application(_:didFinishLaunchingWithOptions:)`: become the notification
    /// delegate (so a push that launches the app is routed) and refresh the token if the
    /// player already allowed notifications.
    func start() {
        UNUserNotificationCenter.current().delegate = self
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
        let matchID = PushSupport.matchID(fromUserInfo: userInfo)
        Task { @MainActor in
            let show = PushSupport.shouldPresentInForeground(pushMatchID: matchID, openMatchID: self.openMatchID())
            completionHandler(show ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let matchID = PushSupport.matchID(fromUserInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            if let matchID { self.tappedMatchID = matchID }
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
