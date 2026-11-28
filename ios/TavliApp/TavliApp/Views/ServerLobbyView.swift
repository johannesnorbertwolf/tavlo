import SwiftUI
import UIKit
import TavliEngine

private typealias SColor = SwiftUI.Color

/// Online play through our own server (#286; the real lobby #287), behind the developer
/// switch (Settings → Online account → "Play online via the server"), and wherever an
/// invite link or a tapped push leads. Presentation only over `ServerOnlineCoordinator` and
/// the engine's `ServerLobby` (sections, row states + actions, invites, auto-match): the
/// lobby (Your turn / Their turn / Finished, swipe or long-press actions), "New game"
/// (variant + length + Invite a friend / Random opponent), the invite sheet (code + link +
/// share sheet), "Join with a code", and the live game (the shared `OnlineGameView`).
struct ServerOnlineRootView: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    let onExit: () -> Void

    var body: some View {
        Group {
            if let controller = coordinator.controller, let lobby = coordinator.lobby {
                ServerOnlineContent(coordinator: coordinator, lobby: lobby, controller: controller, onExit: onExit)
            } else {
                ServerLobbyPage(coordinator: coordinator, lobby: nil, onExit: onExit)
            }
        }
        .onAppear { coordinator.activate() }
    }
}

private struct ServerOnlineContent: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    let lobby: ServerLobby
    @ObservedObject var controller: OnlineMatchController
    let onExit: () -> Void

    var body: some View {
        if let session = controller.session {
            OnlineGameView(controller: controller, session: session,
                           onClose: { coordinator.closeMatch() }, onForfeit: { coordinator.forfeitMatch() })
        } else {
            ServerLobbyPage(coordinator: coordinator, lobby: lobby, onExit: onExit)
        }
    }
}

/// The sheet the lobby shows (one at a time).
enum ServerLobbySheet: Identifiable {
    case account, newMatch, join(code: String?), invite(InviteShare)

    var id: String {
        switch self {
        case .account: return "account"
        case .newMatch: return "new"
        case .join(let code): return "join-\(code ?? "")"
        case .invite(let invite): return "invite-\(invite.code)"
        }
    }
}

/// The page: header, wordmark, signed-in lobby or the sign-in prompt, and its sheets.
private struct ServerLobbyPage: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    let lobby: ServerLobby?
    let onExit: () -> Void

    @State private var sheet: ServerLobbySheet?

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            if let lobby {
                ServerLobbyList(lobby: lobby, header: AnyView(header), sheet: $sheet)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        header
                        signInPrompt
                    }
                    .compactPadding(40, compact: 16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $sheet) { which in
            sheetContent(which)
        }
        .onAppear { showPendingJoin() }
        .onChange(of: coordinator.pendingJoinCode) { _, _ in showPendingJoin() }
        .onChange(of: lobby == nil) { _, _ in showPendingJoin() }
        #if DEBUG
        .task(id: lobby == nil) { DebugServerLobby.showSheet(lobby: lobby) { sheet = $0 } }
        #endif
    }

    /// An invite link waits for the join sheet (after sign-in if needed).
    private func showPendingJoin() {
        guard lobby != nil, let code = coordinator.pendingJoinCode else { return }
        coordinator.pendingJoinCode = nil
        sheet = .join(code: code)
    }

    private var header: some View {
        VStack(spacing: ChromeType.isCompact ? 14 : 20) {
            HStack {
                Button(action: onExit) {
                    HStack(spacing: 4) {
                        DirectionalSymbol("chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(ChromeButton(role: .secondary))
                Spacer()
                Button { sheet = .account } label: {
                    Image(systemName: "person.crop.circle")
                }
                .buttonStyle(ChromeButton(role: .secondary))
                .accessibilityLabel(Text("Online account"))
            }
            Text("Play Online")
                .font(ChromeType.localizedWordmark)
                .compactSingleLine()
                .fixedSize(horizontal: !ChromeType.isCompact, vertical: false)
                .foregroundStyle(CaramelPalette.frameText)
        }
        .frame(maxWidth: ServerLobbyMetrics.column)
    }

    private var signInPrompt: some View {
        VStack(spacing: 14) {
            Text(coordinator.pendingJoinCode == nil
                 ? String(localized: "Sign in to your online account to play through the server.")
                 : String(localized: "Sign in to your online account to join your friend’s game."))
                .font(ChromeType.callout)
                .foregroundStyle(ChromeTheme.ink)
                .multilineTextAlignment(.center)
            Button("Online account") { sheet = .account }
                .buttonStyle(ChromeButton(role: .primary))
        }
        .chromeCard(padding: ChromeType.isCompact ? 16 : 24)
        .frame(maxWidth: ServerLobbyMetrics.column)
    }

    @ViewBuilder
    private func sheetContent(_ which: ServerLobbySheet) -> some View {
        switch which {
        case .account:
            AccountView()
        case .newMatch:
            if let lobby {
                NewOnlineMatchSheet(lobby: lobby) { invite in
                    sheet = nil
                    // Present the invite sheet after the new-game sheet is gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { sheet = .invite(InviteShare(invite)) }
                }
            }
        case .join(let code):
            if let lobby { JoinCodeSheet(lobby: lobby, initialCode: code ?? "") }
        case .invite(let invite):
            if let lobby {
                InviteSheet(invite: invite, onStart: {
                    sheet = nil
                    Task { await lobby.open(matchID: invite.matchID) }
                })
            }
        }
    }
}

enum ServerLobbyMetrics {
    /// The column every card and row lines up in (as the Game Center lobby's 392 / 440 pt).
    static var column: CGFloat { 460 }
}

/// The signed-in lobby: a List (for swipe actions) styled as Caramel cards.
private struct ServerLobbyList: View {
    @ObservedObject var lobby: ServerLobby
    let header: AnyView
    @Binding var sheet: ServerLobbySheet?

    var body: some View {
        List {
            centered(header)
                .padding(.top, ChromeType.isCompact ? 8 : 28)
            centered(actions)
            if let error = lobby.error {
                centered(
                    Text(error)
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeTheme.surrenderTint)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                )
            }
            if let banner = OnlineStatusText.text(lobby.controller.status) {
                centered(
                    Text(banner)
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                )
            }
            if lobby.matches.isEmpty {
                centered(emptyState)
            }
            ForEach(lobby.sections, id: \.kind) { section in
                Section {
                    ForEach(section.rows, id: \.matchID) { row in
                        centered(
                            ServerMatchRow(match: row) { Task { await lobby.open(matchID: row.matchID) } }
                                .contextMenu { rowMenu(row) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: row.lobbyActions == [.remove]) {
                            swipeButtons(row)
                        }
                    }
                } header: {
                    centered(
                        Text(ServerLobbyCopy.sectionTitle(section.kind))
                            .font(ChromeType.subheadline.bold())
                            .foregroundStyle(ChromeTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                    )
                    .textCase(nil)
                }
            }
            SColor.clear.frame(height: 24).listRowBackground(SColor.clear).listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable { await lobby.refresh() }
        // While the lobby is on screen it follows the other players (a friend joining, a
        // turn played elsewhere): one list read every 20 s; pull to refresh at once.
        .task {
            while !Task.isCancelled {
                await lobby.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    /// One centred column, transparent row chrome.
    private func centered<V: View>(_ content: V) -> some View {
        HStack {
            Spacer(minLength: 0)
            content.frame(maxWidth: ServerLobbyMetrics.column)
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 5, leading: ChromeType.isCompact ? 16 : 24,
                                  bottom: 5, trailing: ChromeType.isCompact ? 16 : 24))
        .listRowBackground(SColor.clear)
        .listRowSeparator(.hidden)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { sheet = .newMatch } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("New game")
                }
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            .accessibilityIdentifier("serverNewGame")
            Button { sheet = .join(code: nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "number")
                    Text("Join with a code")
                }
            }
            .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            .accessibilityIdentifier("serverJoinCode")
        }
        .disabled(lobby.isWorking)
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        Group {
            if lobby.hasLoaded {
                Text("No games yet. Invite a friend or play a random opponent.")
            } else {
                ProgressView()
            }
        }
        .font(ChromeType.callout)
        .foregroundStyle(ChromeKit.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func rowMenu(_ row: ServerAPI.MatchSummary) -> some View {
        ForEach(row.lobbyActions, id: \.self) { action in
            switch action {
            case .shareInvite:
                if let invite = row.invite {
                    ShareLink(item: invite.url, message: Text(ServerLobbyCopy.shareMessage(
                        variant: row.variant, targetWins: row.targetWins, code: invite.code))) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                }
            case .cancel:
                Button(role: .destructive) { Task { await lobby.cancel(row) } } label: {
                    Label(row.invite != nil ? "Cancel invite" : "Stop looking", systemImage: "xmark.circle")
                }
            case .decline:
                Button(role: .destructive) { Task { await lobby.decline(row) } } label: {
                    Label("Decline", systemImage: "xmark")
                }
            case .remove:
                Button(role: .destructive) { Task { await lobby.remove(row) } } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func swipeButtons(_ row: ServerAPI.MatchSummary) -> some View {
        ForEach(row.lobbyActions.reversed(), id: \.self) { action in
            switch action {
            case .shareInvite:
                if let invite = InviteShare(row: row) {
                    Button {
                        sheet = .invite(invite)
                    } label: {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                    .tint(ChromeTheme.undoTint)
                }
            case .cancel:
                Button(role: .destructive) { Task { await lobby.cancel(row) } } label: {
                    Label(row.invite != nil ? "Cancel invite" : "Stop looking", systemImage: "xmark.circle")
                }
            case .decline:
                Button(role: .destructive) { Task { await lobby.decline(row) } } label: {
                    Label("Decline", systemImage: "xmark")
                }
            case .remove:
                Button(role: .destructive) { Task { await lobby.remove(row) } } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}

/// One game in the lobby: who (or who it waits for), variant + length, and the state.
struct ServerMatchRow: View {
    let match: ServerAPI.MatchSummary
    let onOpen: () -> Void

    private var status: LobbyRowStatus { match.lobbyStatus }

    private var title: String {
        if let name = match.opponent.displayName { return name }
        switch status {
        case .waitingForFriend: return String(localized: "Waiting for a friend")
        case .lookingForOpponent, .yourTurn: return match.hasOpenSeat ? String(localized: "Random opponent")
                                                                       : String(localized: "Opponent")
        default: return String(localized: "Opponent")
        }
    }

    private var detail: String {
        [GameVariantSetting(variantID: match.variant).shortLabel, ServerLobbyCopy.lengthLabel(match.targetWins)]
            .joined(separator: ChromeDigits.listSeparator)
    }

    private var isHouseRules: Bool { GameVariantSetting(variantID: match.variant).isHouseRules }

    private var statusColor: SColor {
        switch status {
        case .yourTurn, .invitedToYou: return ChromeTheme.doneTint
        default: return ChromeKit.inkSecondary
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                OpponentBadge(name: match.opponent.displayName, openSeat: match.hasOpenSeat,
                              finished: match.lobbySection == .finished)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(ChromeType.callout.bold())
                        .foregroundStyle(ChromeTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        Text(detail)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if isHouseRules { HouseRulesTag(style: .glyph) }
                    }
                }
                Spacer(minLength: 8)
                if case .waitingForFriend(let code) = status {
                    // The code itself: what the friend needs (no room for it under the title).
                    Text(verbatim: code)
                        .font(ChromeType.caption.weight(.semibold).monospaced())
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .fixedSize()
                        .environment(\.layoutDirection, .leftToRight)
                } else {
                    Text(ServerLobbyCopy.status(status))
                        .font(ChromeType.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                DirectionalSymbol("chevron.right")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .background(
                RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                    .fill(ChromeKit.cardColor)
                    .shadow(color: ChromeKit.cardShadow, radius: 4, x: 0, y: 2)
            )
            .overlay(RoundedRectangle(cornerRadius: ChromeKit.cardRadius).stroke(ChromeKit.cardEdge, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: ChromeKit.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(ServerLobbyCopy.status(status)))
    }
}

/// The opponent's initial in a caramel disc; a person-plus glyph while the seat is open.
private struct OpponentBadge: View {
    let name: String?
    let openSeat: Bool
    let finished: Bool

    private var size: CGFloat { ChromeType.isCompact ? 38 : 44 }

    var body: some View {
        ZStack {
            Circle().fill(finished ? ChromeKit.secondaryFill : ChromeTheme.undoTint.opacity(0.22))
            if let initial = name?.first, !openSeat {
                Text(String(initial).uppercased())
                    .font(ChromeType.callout.bold())
                    .foregroundStyle(ChromeTheme.ink)
            } else {
                Image(systemName: openSeat ? "person.badge.plus" : "person.fill")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.iconInk)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - New game

/// "New online game": variant + length (remembered, as the Game Center lobby's), then
/// Invite a friend (code + link to share) or Random opponent (auto-match).
struct NewOnlineMatchSheet: View {
    @ObservedObject var lobby: ServerLobby
    /// The invite was made: the caller shows the invite sheet.
    let onInvite: (ServerAPI.Invite) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.onlineMatchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    @AppStorage(SettingsKey.variant) private var variant: GameVariantSetting = .plakotoStandard
    @AppStorage(SettingsKey.houseRules) private var houseRules = false

    private var isCompact: Bool { ChromeType.isCompact }

    private var pickedVariant: Binding<GameVariantSetting> {
        Binding(get: { variant.pickerChoice }, set: { variant = $0 })
    }

    private var played: GameVariantSetting { variant.pickerChoice.playing(houseRules: houseRules) }

    var body: some View {
        ZStack {
            ChromeKit.cardColor.ignoresSafeArea()
            FitOrScroll {
                VStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
                    SheetHeader(title: String(localized: "New online game")) { dismiss() }
                    SheetSection("Variant") {
                        SegmentedChoice(options: GameVariantSetting.pickerCases, selection: pickedVariant,
                                        label: \.shortLabel)
                        if houseRules && played.isHouseRules { HouseRulesTag() }
                        Text(played.rulesReminder)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SheetSection("Length") {
                        SegmentedChoice(options: MatchLengthSetting.onlineCases, selection: $matchLength, label: \.label)
                    }
                    SheetSection("Opponent") {
                        VStack(spacing: 12) {
                            OpponentChoice(icon: "person.2.fill", title: String(localized: "Invite a friend"),
                                           caption: String(localized: "Send a link or a code. You can make your first move while you wait."),
                                           primary: true) {
                                Task {
                                    if let invite = await lobby.createInvite(variant: played.rawValue,
                                                                             targetWins: matchLength.targetWins) {
                                        onInvite(invite)
                                    }
                                }
                            }
                            .accessibilityIdentifier("serverInviteFriend")
                            OpponentChoice(icon: "shuffle", title: String(localized: "Random opponent"),
                                           caption: String(localized: "Play someone who is looking for the same game."),
                                           primary: false) {
                                Task {
                                    if await lobby.autoMatch(variant: played.rawValue,
                                                             targetWins: matchLength.targetWins) != nil {
                                        dismiss()
                                    }
                                }
                            }
                            .accessibilityIdentifier("serverRandomOpponent")
                        }
                        .disabled(lobby.isWorking)
                    }
                    if lobby.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let error = lobby.error {
                        Text(error)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeTheme.surrenderTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.top, isCompact ? 20 : 28)
                .padding(.bottom, isCompact ? 12 : 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear { lobby.error = nil }
    }
}

/// A big two-line choice tile (icon, title, caption) in the primary or secondary role.
private struct OpponentChoice: View {
    let icon: String
    let title: String
    let caption: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(ChromeType.title3)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(ChromeType.callout.bold())
                    Text(caption)
                        .font(ChromeType.caption)
                        .opacity(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                DirectionalSymbol("chevron.right").font(ChromeType.caption)
            }
            .foregroundStyle(primary ? ChromeKit.onAccent : ChromeTheme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ChromeKit.buttonRadius)
                    .fill(primary ? ChromeTheme.undoTint : ChromeKit.secondaryFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: ChromeKit.buttonRadius))
        }
        .buttonStyle(.plain)
    }
}

/// Title + close button of the lobby's sheets.
private struct SheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(ChromeType.title2.bold())
                .foregroundStyle(ChromeTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(ChromeType.title3.weight(.medium))
                    .foregroundStyle(ChromeTheme.ink.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Invite sheet

/// The invite to send: the code (big, to read out or type), the link, the system share
/// sheet (Messages, WhatsApp, …), copy, and "Start playing" (the creator may move first).
struct InviteSheet: View {
    let invite: InviteShare
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var isCompact: Bool { ChromeType.isCompact }

    private var message: String {
        ServerLobbyCopy.shareMessage(variant: invite.variant, targetWins: invite.targetWins, code: invite.code)
    }

    private var expiry: String {
        let date = ServerAPI.date(invite.expiresAt)
        return String(localized: "Open until \(date.formatted(date: .abbreviated, time: .omitted)) · one friend can join.")
    }

    var body: some View {
        ZStack {
            ChromeKit.cardColor.ignoresSafeArea()
            FitOrScroll {
                VStack(alignment: .leading, spacing: isCompact ? 16 : 22) {
                    SheetHeader(title: String(localized: "Invite a friend")) { dismiss() }
                    Text("Send this link to your friend. It opens Tavtav, or the App Store if they don’t have it yet. They can also type the code in Play Online → Join with a code.")
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 8) {
                        Text(verbatim: InviteCodeStyle.spaced(invite.code))
                            .font(.system(size: (isCompact ? 40 : 48) * ChromeType.scale, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ChromeTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .textSelection(.enabled)
                            .accessibilityLabel(Text("Invite code \(InviteCodeStyle.spokenCharacters(invite.code))"))
                            .accessibilityIdentifier("inviteCode")
                        Text(verbatim: invite.url.absoluteString)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCompact ? 16 : 22)
                    .background(RoundedRectangle(cornerRadius: ChromeKit.cardRadius).fill(ChromeKit.trackColor))
                    ShareLink(item: invite.url, subject: Text("Play tavli with me"), message: Text(message)) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share invite link")
                        }
                    }
                    .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                    .accessibilityIdentifier("inviteShare")
                    AdaptiveButtons {
                        Button {
                            UIPasteboard.general.string = invite.code
                            copied = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy code")
                            }
                        }
                        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
                        Button(action: onStart) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("Start playing")
                            }
                        }
                        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
                        .accessibilityIdentifier("inviteStart")
                    }
                    Text(expiry)
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.top, isCompact ? 20 : 28)
                .padding(.bottom, isCompact ? 12 : 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// Two buttons side by side where they fit, else stacked.
private struct AdaptiveButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(spacing: 10) { content }
        }
    }
}

enum InviteCodeStyle {
    /// "K7Q 4MZ": two groups of three, easier to read out.
    static func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    /// "K, 7, Q, 4, M, Z" for VoiceOver.
    static func spokenCharacters(_ code: String) -> String {
        code.map(String.init).joined(separator: ", ")
    }
}

// MARK: - Join with a code

/// Type (or paste) a code or link → who invites to what → Join / Decline. Opened by a link
/// with the code filled in (and looked up at once).
struct JoinCodeSheet: View {
    @ObservedObject var lobby: ServerLobby
    let initialCode: String

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var preview: ServerAPI.InvitePreview?
    @FocusState private var focused: Bool

    private var isCompact: Bool { ChromeType.isCompact }
    private var canLookUp: Bool { InviteCode.normalize(code) != nil && !lobby.isWorking }

    var body: some View {
        ZStack {
            ChromeKit.cardColor.ignoresSafeArea()
            FitOrScroll {
                VStack(alignment: .leading, spacing: isCompact ? 16 : 22) {
                    SheetHeader(title: String(localized: "Join with a code")) { dismiss() }
                    Text("Type the 6-character code your friend sent you, or paste the invite link.")
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(String(localized: "Code"), text: $code)
                        .font(.system(size: 30 * ChromeType.scale, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: ChromeKit.buttonRadius).fill(ChromeKit.trackColor))
                        .environment(\.layoutDirection, .leftToRight)
                        .onSubmit { lookUp() }
                        .onChange(of: code) { _, _ in preview = nil }
                        .accessibilityIdentifier("joinCodeField")
                    if let preview {
                        previewCard(preview)
                    } else {
                        Button(action: lookUp) {
                            Text("Find game").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                        .disabled(!canLookUp)
                        .accessibilityIdentifier("joinFind")
                    }
                    if lobby.isWorking { ProgressView().frame(maxWidth: .infinity) }
                    if let error = lobby.error {
                        Text(error)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeTheme.surrenderTint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.top, isCompact ? 20 : 28)
                .padding(.bottom, isCompact ? 12 : 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            lobby.error = nil
            code = initialCode
            if InviteCode.normalize(initialCode) != nil { lookUp() } else { focused = true }
        }
    }

    private func lookUp() {
        guard canLookUp else { return }
        let typed = code
        Task {
            let found = await lobby.preview(code: typed)
            if typed == code { preview = found }
        }
    }

    private func previewCard(_ p: ServerAPI.InvitePreview) -> some View {
        let open = p.status == "open"
        let variant = GameVariantSetting(variantID: p.variant)
        return VStack(alignment: .leading, spacing: 12) {
            Text(open ? String(localized: "\(p.from.displayName) invites you to play.")
                      : String(localized: "This invite isn’t open any more. Ask your friend for a new one."))
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text([variant.shortLabel, ServerLobbyCopy.lengthLabel(p.targetWins)].joined(separator: ChromeDigits.listSeparator))
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                if variant.isHouseRules { HouseRulesTag() }
            }
            if open {
                Button {
                    Task {
                        if await lobby.join(code: p.code) != nil { dismiss() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Join game")
                    }
                }
                .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                .disabled(lobby.isWorking)
                .accessibilityIdentifier("joinAccept")
                Button {
                    Task {
                        await lobby.declineInvite(code: p.code)
                        dismiss()
                    }
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .quiet, fullWidth: true))
                .disabled(lobby.isWorking)
            }
        }
        .chromeCard(padding: isCompact ? 16 : 20)
    }
}

// MARK: - Copy

enum ServerLobbyCopy {
    static func sectionTitle(_ kind: LobbySectionKind) -> String {
        switch kind {
        case .yourTurn: return String(localized: "Your turn")
        case .theirTurn: return String(localized: "Their turn")
        case .finished: return String(localized: "Finished")
        }
    }

    static func status(_ status: LobbyRowStatus) -> String {
        switch status {
        case .yourTurn: return String(localized: "Your turn")
        case .invitedToYou: return String(localized: "Invites you")
        case .theirTurn: return String(localized: "Their turn")
        case .waitingForAccept: return String(localized: "Waiting for opponent")
        // The code itself: what the friend needs (the row's subtitle is too narrow on a phone).
        case .waitingForFriend(let code): return String(localized: "Code \(code)")
        case .lookingForOpponent: return String(localized: "Looking for an opponent…")
        case .finished(let outcome):
            switch outcome {
            case .won: return String(localized: "You won")
            case .lost: return String(localized: "You lost")
            case .tied: return String(localized: "Draw")
            case .quit: return String(localized: "You left")
            default: return String(localized: "Finished")
            }
        }
    }

    static func lengthLabel(_ targetWins: Int) -> String {
        (targetWins >= 2 ? MatchLengthSetting.bestOfThree : MatchLengthSetting.single).label
    }

    /// The text that goes with the link in Messages / WhatsApp.
    static func shareMessage(variant: String, targetWins: Int, code: String) -> String {
        let game = GameVariantSetting(variantID: variant).shortLabel
        return String(localized: "Play \(game) with me on Tavtav! Tap the link, or type the code \(code) in Play Online → Join with a code.")
    }
}

/// What the invite sheet shows: a fresh invite, or a lobby row's open invite.
struct InviteShare: Equatable {
    var code: String
    var url: URL
    var expiresAt: Int64
    var matchID: String
    var variant: String
    var targetWins: Int

    init(_ invite: ServerAPI.Invite) {
        self.init(code: invite.code, url: invite.url, expiresAt: invite.expiresAt, matchID: invite.match.matchID,
                  variant: invite.match.variant, targetWins: invite.match.targetWins)
    }

    init?(row: ServerAPI.MatchSummary) {
        guard let ref = row.invite else { return nil }
        self.init(code: ref.code, url: ref.url, expiresAt: ref.expiresAt, matchID: row.matchID,
                  variant: row.variant, targetWins: row.targetWins)
    }

    init(code: String, url: URL, expiresAt: Int64, matchID: String, variant: String, targetWins: Int) {
        self.code = code
        self.url = url
        self.expiresAt = expiresAt
        self.matchID = matchID
        self.variant = variant
        self.targetWins = targetWins
    }
}
