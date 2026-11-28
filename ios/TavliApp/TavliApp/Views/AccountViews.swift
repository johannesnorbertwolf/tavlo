import AuthenticationServices
import UIKit
import SwiftUI
import TavliEngine

// Server v1 accounts (#285): the account sheet — sign-in screen (Sign in with Apple +
// Google), the display-name prompt after the first sign-in, and the account page (name,
// sign out, delete with confirmation). Presentation only over the engine's `AuthClient`
// (`AccountStore.shared`, `Online/AccountService.swift`). Reached from Settings →
// "Online account" while developer tools are on; online play through the server (#286) uses it
// when the developer switch on this sheet is on.

/// The account sheet's root: sign-in, name prompt or account page by the client's state.
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AccountStore.shared

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Online account")
                            .font(ChromeType.statsTitle)
                            .foregroundStyle(ChromeTheme.ink)
                            .compactSingleLine()
                        Spacer()
                        Button("Done") { dismiss() }
                            .buttonStyle(ChromeButton(role: .secondary))
                    }
                    if let client = store.client {
                        AccountContent(client: client)
                    } else {
                        Text("The online server isn't available yet.")
                            .font(ChromeType.body)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .chromeCard(padding: 20)
                    }
                    // #286: online play through the server instead of Game Center (the
                    // sheet itself is reachable only with developer tools on).
                    ServerPlayDeveloperCard()
                    #if DEBUG
                    AccountDeveloperCard(store: store)
                    #endif
                }
                .compactPadding(28, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Switches on the client's state (observed, so sign-in/out re-renders).
private struct AccountContent: View {
    @ObservedObject var client: AuthClient
    @State private var notice: LocalizedStringKey?

    var body: some View {
        switch client.state {
        case .signedOut, .signingIn:
            SignInCard(client: client, notice: $notice)
        case .signedIn(let account):
            if client.needsDisplayName {
                DisplayNamePromptCard(client: client, suggested: account.displayName)
            } else {
                AccountPageCard(client: client, account: account, onDeleted: {
                    notice = "Your account was deleted."
                })
            }
        }
    }
}

// MARK: - Sign-in

private struct SignInCard: View {
    @ObservedObject var client: AuthClient
    @Binding var notice: LocalizedStringKey?
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = AuthNonce()
    @State private var error: LocalizedStringKey?
    @State private var google = GoogleSignIn()

    private var busy: Bool { if case .signingIn = client.state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeTheme.ink)
            }
            Text("Sign in to play online")
                .font(ChromeType.title3.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            Text("Your account keeps your name and your online matches on every device you sign in on.")
                .font(ChromeType.body)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn) { request in
                    nonce = AuthNonce()
                    error = nil
                    notice = nil
                    client.beginSignIn(.apple)
                    AppleSignIn.prepare(request, nonce: nonce)
                } onCompletion: { result in
                    let used = nonce
                    Task { await run { try await AppleSignIn.complete(result, nonce: used, client: client) } }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: ChromeKit.buttonRadius, style: .continuous))
                .accessibilityIdentifier("signInWithApple")

                Button {
                    error = nil
                    notice = nil
                    client.beginSignIn(.google)
                    Task { await run { try await google.signIn(client: client) } }
                } label: {
                    HStack(spacing: 10) {
                        GoogleGlyph()
                        Text("Sign in with Google")
                            .font(ChromeType.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(ChromeButton(role: .secondary))
                .accessibilityIdentifier("signInWithGoogle")
            }
            .disabled(busy)
            .overlay { if busy { ProgressView().tint(ChromeTheme.ink) } }

            if let error {
                Text(error)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("We keep only an account ID and the name you choose — no e-mail address.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
    }

    private func run(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            client.cancelSignIn()
            self.error = AccountCopy.message(for: error)
        }
    }
}

/// Google's "G", drawn (no SDK, no bundled logo): four arcs in Google's colours.
private struct GoogleGlyph: View {
    var body: some View {
        ZStack {
            Circle().fill(SwiftUI.Color.white)
            Text("G")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(SwiftUI.Color(red: 0.26, green: 0.52, blue: 0.96))
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().stroke(SwiftUI.Color.black.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Name prompt

/// After the first sign-in (`needsDisplayName`): pick the name other players see.
private struct DisplayNamePromptCard: View {
    @ObservedObject var client: AuthClient
    let suggested: String
    @State private var name = ""
    @State private var error: LocalizedStringKey?
    /// #301: the handle, suggested from the name until the player edits it.
    @State private var handle = ""
    @State private var handleEdited = false
    @FocusState private var focused: Bool

    private var canSave: Bool {
        DisplayNameRule.normalize(name) != nil && !client.isWorking && (handle.isEmpty || HandleRule.problem(handle) == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your name")
                .font(ChromeType.title3.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            Text("Other players see this name in online games.")
                .font(ChromeType.body)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NameField(text: $name, focused: $focused)
            HandleField(text: Binding(get: { handle }, set: { handle = $0; handleEdited = true }))
            if let error {
                Text(error)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeTheme.surrenderTint)
            }
            Button {
                Task { await save() }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(ChromeButton(role: .primary))
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.4)
            .accessibilityIdentifier("saveDisplayName")
            Button {
                client.keepCurrentDisplayName()
            } label: {
                Text("Skip for now").frame(maxWidth: .infinity)
            }
            .buttonStyle(ChromeButton(role: .quiet))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
        .onAppear {
            // Apple's name (first sign-in) arrives as the account name; the server's
            // "Player 1234" placeholder is not worth suggesting.
            if name.isEmpty, !suggested.hasPrefix("Player ") { name = suggested }
            if handle.isEmpty { handle = HandleRule.suggest(from: name) ?? client.account?.handle ?? "" }
            focused = true
        }
        .onChange(of: name) { _, new in
            if !handleEdited, let s = HandleRule.suggest(from: new) { handle = s }
        }
    }

    private func save() async {
        error = nil
        do {
            // The handle first: a taken one keeps the prompt open (the name is not saved yet).
            if !handle.isEmpty, handle != client.account?.handle, client.account?.handleChangeable != false {
                try await client.updateAccount(handle: handle)
            }
            try await client.updateDisplayName(name)
        } catch {
            self.error = AccountCopy.message(for: error)
        }
    }
}

/// #301: the handle field ("@" prefix, the 3–20 rule as its hint).
private struct HandleField: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text(verbatim: "@").foregroundStyle(ChromeKit.inkSecondary)
                TextField("handle", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier("handleField")
            }
            .font(ChromeType.body)
            .foregroundStyle(ChromeTheme.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(ChromeKit.secondaryFill, in: RoundedRectangle(cornerRadius: ChromeKit.buttonRadius, style: .continuous))
            .environment(\.layoutDirection, .leftToRight)
            Text("Your handle: friends find you by it. 3–20 letters, digits or _.")
                .font(ChromeType.caption)
                .foregroundStyle(HandleRule.problem(text) != nil && !text.isEmpty ? ChromeTheme.surrenderTint : ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// #301: the account page's handle (copy / share / change once), "Show when I'm online",
/// "Who can challenge me" and the blocked players.
private struct PeopleSettingsCard: View {
    @ObservedObject var client: AuthClient
    let account: ServerAPI.Account
    @State private var editing = false
    @State private var newHandle = ""
    @State private var copied = false
    @State private var error: LocalizedStringKey?
    @State private var blocked: [ServerAPI.PlayerCard] = []

    private var handle: String { account.handle ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Handle")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeKit.inkSecondary)
                .textCase(.uppercase)
            if editing {
                HandleField(text: $newHandle)
                Text("You can change your handle once.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                HStack(spacing: 12) {
                    Button("Save") { Task { await saveHandle() } }
                        .buttonStyle(ChromeButton(role: .primary))
                        .disabled(HandleRule.problem(newHandle) != nil || client.isWorking)
                    Button("Cancel") { editing = false }
                        .buttonStyle(ChromeButton(role: .quiet))
                }
            } else {
                HStack(spacing: 10) {
                    Text(verbatim: "@\(handle)")
                        .font(ChromeType.title3.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                        .textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("accountHandle")
                    Spacer(minLength: 4)
                    Button {
                        UIPasteboard.general.string = "@\(handle)"
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(ChromeButton(role: .secondary))
                    .accessibilityLabel(Text("Copy handle"))
                    ShareLink(item: String(localized: "Find me on Tavtav: @\(handle) (Play Online → People → Find player)")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(ChromeButton(role: .secondary))
                    .accessibilityLabel(Text("Share handle"))
                }
                Text("Friends find you by your handle in Play Online → Find player.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if account.handleChangeable == true {
                    Button("Change handle") {
                        newHandle = handle
                        editing = true
                    }
                    .buttonStyle(ChromeButton(role: .quiet))
                }
            }
            Divider().overlay(ChromeKit.inkDim(0.15))
            Toggle(isOn: Binding(get: { account.hidePresence != true },
                                 set: { show in Task { await update { try await client.updateAccount(hidePresence: !show) } } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show when I’m online")
                        .font(ChromeType.callout.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    Text("Only people you’ve played with see it.")
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(ChromeTheme.undoTint)
            .accessibilityIdentifier("showOnlineToggle")
            VStack(alignment: .leading, spacing: 8) {
                Text("Who can challenge me")
                    .font(ChromeType.callout.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
                SegmentedChoice(options: ChallengePolicyChoice.allCases,
                                selection: Binding(get: { ChallengePolicyChoice(account.challengePolicy) },
                                                   set: { choice in Task { await update { try await client.updateAccount(whoCanChallenge: choice.policy) } } }),
                                label: \.label)
            }
            if !blocked.isEmpty {
                Divider().overlay(ChromeKit.inkDim(0.15))
                Text("Blocked")
                    .font(ChromeType.callout.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
                ForEach(blocked, id: \.playerID) { card in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.displayName).font(ChromeType.callout).foregroundStyle(ChromeTheme.ink)
                            Text(verbatim: "@\(card.handle)").font(ChromeType.caption).foregroundStyle(ChromeKit.inkSecondary)
                        }
                        Spacer()
                        Button("Unblock") { Task { await unblock(card) } }
                            .buttonStyle(ChromeButton(role: .quiet))
                    }
                }
            }
            if let error {
                Text(error)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
        .task { await loadBlocked() }
    }

    private struct Empty: Decodable {}

    private func update(_ work: () async throws -> Void) async {
        error = nil
        do { try await work() } catch { self.error = AccountCopy.message(for: error) }
    }

    private func saveHandle() async {
        await update {
            try await client.updateAccount(handle: newHandle)
            editing = false
        }
    }

    private func loadBlocked() async {
        let answer: ServerAPI.PeopleResponse? = try? await client.authorized(method: "GET", path: "/v1/people",
                                                                             body: Optional<Int>.none)
        blocked = answer?.blocked ?? []
    }

    private func unblock(_ card: ServerAPI.PlayerCard) async {
        await update {
            let _: Empty? = try await client.authorized(method: "DELETE", path: "/v1/people/\(card.playerID)/block",
                                                        body: Optional<Int>.none)
            blocked.removeAll { $0.playerID == card.playerID }
        }
    }
}

/// "Who can challenge me" as a segmented choice.
private enum ChallengePolicyChoice: String, CaseIterable, Identifiable {
    case everyone, people
    var id: String { rawValue }
    init(_ policy: ServerAPI.ChallengePolicy) { self = policy == .people ? .people : .everyone }
    var policy: ServerAPI.ChallengePolicy { self == .people ? .people : .everyone }
    var label: String {
        switch self {
        case .everyone: return String(localized: "Everyone")
        case .people: return String(localized: "Only my people")
        }
    }
}

/// The name text field with its 1–24 hint (shared by the prompt and the account page).
private struct NameField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Your name", text: $text)
                .font(ChromeType.body)
                .foregroundStyle(ChromeTheme.ink)
                .textContentType(.nickname)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused(focused)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(ChromeKit.secondaryFill,
                            in: RoundedRectangle(cornerRadius: ChromeKit.buttonRadius, style: .continuous))
                .accessibilityIdentifier("displayNameField")
            Text("1 to 24 characters.")
                .font(ChromeType.caption)
                .foregroundStyle(DisplayNameRule.normalize(text) == nil && !text.isEmpty
                                 ? ChromeTheme.surrenderTint : ChromeKit.inkSecondary)
        }
    }
}

// MARK: - Account page

private struct AccountPageCard: View {
    @ObservedObject var client: AuthClient
    let account: ServerAPI.Account
    let onDeleted: () -> Void
    @State private var name = ""
    @State private var error: LocalizedStringKey?
    @State private var saved = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    private var changed: Bool { DisplayNameRule.normalize(name).map { $0 != account.displayName } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Name")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .textCase(.uppercase)
                NameField(text: $name, focused: $focused)
                HStack(spacing: 12) {
                    Button("Save") { Task { await rename() } }
                        .buttonStyle(ChromeButton(role: .primary))
                        .disabled(!changed || client.isWorking)
                        .opacity(changed && !client.isWorking ? 1 : 0.4)
                        .accessibilityIdentifier("saveName")
                    if saved {
                        Label("Saved", systemImage: "checkmark")
                            .font(ChromeType.callout)
                            .foregroundStyle(ChromeTheme.doneTint)
                    }
                }
                Divider().overlay(ChromeKit.inkDim(0.15))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(account.providers, id: \.self) { provider in
                        if provider == "google" {
                            Label("Signed in with Google", systemImage: "person.crop.circle")
                        } else {
                            Label("Signed in with Apple", systemImage: "apple.logo")
                        }
                    }
                    Text("Member since \(ServerAPI.date(account.createdAt).formatted(date: .long, time: .omitted))")
                }
                .font(ChromeType.callout)
                .foregroundStyle(ChromeKit.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chromeCard(padding: 20)

            PeopleSettingsCard(client: client, account: account)

            if let error {
                Text(error)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Button {
                    Task {
                        await PushRegistrar.shared.unregister(using: client)   // #287: no more pushes here
                        await client.signOut()
                    }
                } label: {
                    Text("Sign out").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .secondary))
                .accessibilityIdentifier("signOut")
                Button {
                    confirmDelete = true
                } label: {
                    Text("Delete account").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .destructive))
                .accessibilityIdentifier("deleteAccount")
                Text("Deleting removes your account and your name from our server, and ends your online matches.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(client.isWorking)
            .frame(maxWidth: .infinity, alignment: .leading)
            .chromeCard(padding: 20)
        }
        .onAppear { name = account.displayName }
        .onChange(of: account.displayName) { _, new in name = new }
        .onChange(of: name) { _, _ in saved = false }
        .task { try? await client.reloadAccount() }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Delete account", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account and your name are removed from our server and your online matches end. This can't be undone.")
        }
    }

    private func rename() async {
        error = nil
        do {
            try await client.updateDisplayName(name)
            focused = false
            saved = true
        } catch {
            self.error = AccountCopy.message(for: error)
        }
    }

    private func delete() async {
        error = nil
        do {
            try await client.deleteAccount()
            onDeleted()
        } catch {
            self.error = AccountCopy.message(for: error)
        }
    }
}

// MARK: - Settings entry

/// Settings card → the account sheet (only while developer tools are on, #285).
struct AccountSettingsRow: View {
    @ObservedObject private var store = AccountStore.shared
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Online account")
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    AccountSummary(client: store.client)
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                DirectionalSymbol("chevron.right")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.iconInk)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chromeCard(padding: 20)
        .accessibilityIdentifier("accountRow")
        .sheet(isPresented: $show) { AccountView() }
    }
}

private struct AccountSummary: View {
    let client: AuthClient?
    var body: some View {
        if let client { Observed(client: client) } else { Text("Not available yet") }
    }

    private struct Observed: View {
        @ObservedObject var client: AuthClient
        var body: some View {
            if let account = client.state.account {
                Text("Signed in as \(account.displayName)")
            } else {
                Text("Not signed in · preview for the new online server")
            }
        }
    }
}

// MARK: - Copy

enum AccountCopy {
    /// Player-facing text for a failed account action; nil for a cancel.
    static func message(for error: Error) -> LocalizedStringKey? {
        guard let auth = error as? AuthError else { return "Something went wrong. Please try again." }
        switch auth {
        case .cancelled:
            return nil
        case .network:
            return "No connection to the server. Check your internet connection and try again."
        case .providerUnavailable:
            return "Sign in with Google isn't available in this version yet."
        case .invalidDisplayName:
            return "1 to 24 characters."
        case .invalidHandle:
            return "Handles are 3–20 letters, digits or _ (no spaces)."
        case .notSignedIn:
            return "You were signed out. Please sign in again."
        case .providerFailed:
            return "Sign-in didn't work. Please try again."
        case .server:
            switch auth.serverCode {
            case .rateLimited: return "Too many attempts. Wait a minute and try again."
            case .unavailable, .internal: return "The server isn't available right now. Please try again later."
            case .unauthorized, .tokenExpired: return "Sign-in didn't work. Please try again."
            case .upgradeRequired: return "Please update the app to play online."
            case .handleTaken: return "Someone else has that handle. Try another one."
            case .forbidden: return "Your handle can be changed only once."
            default: return "Something went wrong. Please try again."
            }
        }
    }
}

/// Developer switch (#286): Play Online runs through our server (the server lobby) instead
/// of Game Center. Off by default; Game Center stays the path until #287/#288.
private struct ServerPlayDeveloperCard: View {
    @AppStorage(ServerOnlineCoordinator.switchKey) private var onlineViaServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $onlineViaServer) {
                Text(verbatim: "Play online via the server")
                    .font(ChromeType.body)
                    .foregroundStyle(ChromeTheme.ink)
            }
            .tint(ChromeTheme.undoTint)
            Text(verbatim: "Developer: Play Online uses this account and the server above instead of Game Center.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
    }
}

// MARK: - DEBUG

#if DEBUG
/// DEBUG: server picker + the development sign-in (`POST /v1/auth/dev`, `wrangler dev` only).
private struct AccountDeveloperCard: View {
    @ObservedObject var store: AccountStore
    @AppStorage(ServerConfig.debugChoiceKey) private var choice: String = ServerConfig.Choice.standard.rawValue
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "DEVELOPER")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeKit.inkSecondary)
            Picker(selection: $choice) {
                ForEach(ServerConfig.Choice.allCases) { c in
                    Text(verbatim: c.label).tag(c.rawValue)
                }
            } label: {
                Text(verbatim: "Server")
            }
            .tint(ChromeTheme.undoTint)
            .onChange(of: choice) { _, _ in store.rebuild() }
            Text(verbatim: store.client?.baseURL.absoluteString ?? "no server URL configured")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
            if let client = store.client, ServerConfig.isLocal(client.baseURL), client.state.account == nil {
                Button {
                    Task {
                        do {
                            try await client.developmentSignIn(subject: "simulator-\(UUID().uuidString.prefix(8))")
                            status = ""
                        } catch {
                            status = "dev sign-in failed: \(error)"
                        }
                    }
                } label: {
                    Text(verbatim: "Development sign-in").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .secondary))
            }
            if !status.isEmpty {
                Text(verbatim: status).font(ChromeType.caption).foregroundStyle(ChromeTheme.surrenderTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
    }
}

/// DEBUG launch arguments for checking the account sheet (#285):
///   `-debugAccount`                 open the sheet at launch
///   `-debugAccountSignOut`          start signed out (clears the stored session)
///   `-debugAccountDevSubject <id>`  development sign-in as `<id>` when signed out (local server)
///   `-debugAccountName <name>`      then submit that display name
enum DebugAccount {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-debugAccount") }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func prepare() async {
        guard isRequested, let client = AccountStore.shared.client else { return }
        if ProcessInfo.processInfo.arguments.contains("-debugAccountSignOut") { await client.signOut() }
        if client.state.account == nil, let subject = value(after: "-debugAccountDevSubject") {
            try? await client.developmentSignIn(subject: subject)
        }
        if let name = value(after: "-debugAccountName"), client.needsDisplayName {
            try? await client.updateDisplayName(name)
        }
    }
}

private struct DebugAccountModifier: ViewModifier {
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $show) { AccountView() }
            .task {
                guard DebugAccount.isRequested else { return }
                await DebugAccount.prepare()
                show = true
            }
    }
}

extension View {
    /// DEBUG: `-debugAccount` opens the account sheet at launch (#285).
    func debugAccount() -> some View { modifier(DebugAccountModifier()) }
}
#endif
