#if DEBUG
import SwiftUI
import TavliEngine

/// DEBUG launch arguments for checking the server lobby (#287) against `wrangler dev`:
///   `-debugServerLobby`                    open Play Online → the server lobby at launch
///                                          (whatever the developer switch says)
///   `-debugAccountSignOut`                 sign out first (to switch dev accounts)
///   `-debugAccountDevSubject <id>`         development sign-in as `<id>` first (local server)
///   `-debugAccountName <name>`             and that display name
///   `-debugServerLobbySheet newMatch|join|invite`  then show that sheet (`invite` makes a
///                                          real invite on the server)
///   `-debugJoinURL <https://…/join/CODE>`  as if that universal link was opened
enum DebugServerLobby {
    static var isRequested: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-debugServerLobby") || value(after: "-debugJoinURL") != nil
    }

    static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The dev sign-in (as `-debugAccount` does, without its sheet).
    @MainActor
    static func prepare() async {
        guard let client = AccountStore.shared.client else { return }
        if ProcessInfo.processInfo.arguments.contains("-debugAccountSignOut") { await client.signOut() }
        if client.state.account == nil, let subject = value(after: "-debugAccountDevSubject") {
            try? await client.developmentSignIn(subject: subject)
        }
        if let name = value(after: "-debugAccountName"), client.needsDisplayName {
            try? await client.updateDisplayName(name)
        }
    }

    private static var sheetShown = false

    /// `-debugServerLobbySheet`: once per launch, when the lobby is there.
    @MainActor
    static func showSheet(lobby: ServerLobby?, show: @escaping (ServerLobbySheet) -> Void) {
        guard !sheetShown, let lobby, let which = value(after: "-debugServerLobbySheet") else { return }
        sheetShown = true
        switch which {
        case "newMatch": show(.newMatch)
        case "join": show(.join(code: value(after: "-debugJoinCode")))
        case "invite":
            Task {
                let variant = value(after: "-debugInviteVariant") ?? "plakoto_standard"
                if let invite = await lobby.createInvite(variant: variant, targetWins: 2) {
                    show(.invite(InviteShare(invite)))
                }
            }
        default: break
        }
    }
}
#endif
