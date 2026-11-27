import SwiftUI
import UIKit
import TavliEngine

/// Online play through our own server (#286), behind the developer switch (Settings →
/// Online account → "Play online via the server"): the server lobby — sign-in state, the
/// same variant / match-length pickers as the Game Center lobby, a direct challenge by
/// player id (invite links and auto-match are #287), and the account's games — and the
/// live game, the same `OnlineGameView` as Game Center's.
struct ServerOnlineRootView: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    let onExit: () -> Void

    var body: some View {
        Group {
            if let controller = coordinator.controller {
                ServerOnlineContent(coordinator: coordinator, controller: controller, onExit: onExit)
            } else {
                ServerLobbyView(coordinator: coordinator, controller: nil, onExit: onExit)
            }
        }
        .onAppear { coordinator.activate() }
    }
}

private struct ServerOnlineContent: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    @ObservedObject var controller: OnlineMatchController
    let onExit: () -> Void

    var body: some View {
        if let session = controller.session {
            OnlineGameView(controller: controller, session: session,
                           onClose: { coordinator.closeMatch() }, onForfeit: { coordinator.forfeitMatch() })
        } else {
            ServerLobbyView(coordinator: coordinator, controller: controller, onExit: onExit)
        }
    }
}

private struct ServerLobbyView: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    let controller: OnlineMatchController?
    let onExit: () -> Void

    @AppStorage(SettingsKey.onlineMatchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    @AppStorage(SettingsKey.variant) private var variant: GameVariantSetting = .plakotoStandard
    @AppStorage(SettingsKey.houseRules) private var houseRules = false
    @State private var opponentID = ""
    @State private var showAccount = false

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    HStack {
                        Button(action: onExit) {
                            HStack(spacing: 4) {
                                DirectionalSymbol("chevron.left")
                                Text("Back")
                            }
                        }
                        .buttonStyle(ChromeButton(role: .secondary))
                        Spacer()
                        Button { showAccount = true } label: {
                            Image(systemName: "person.crop.circle")
                        }
                        .buttonStyle(ChromeButton(role: .secondary))
                        .accessibilityLabel(Text("Online account"))
                    }
                    .frame(maxWidth: 392)
                    Text("Play Online")
                        .font(ChromeType.localizedWordmark)
                        .compactSingleLine()
                        .foregroundStyle(CaramelPalette.frameText)
                    if coordinator.isSignedIn {
                        signedIn
                    } else {
                        signInPrompt
                    }
                    Spacer(minLength: 0)
                }
                .compactPadding(40, compact: 16)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showAccount) { AccountView() }
        .onAppear { coordinator.refreshMatches() }
    }

    @ViewBuilder
    private var signedIn: some View {
        VariantPickerView(selection: $variant, showsAIAvailability: false)
            .frame(maxWidth: 392)
            .chromeCard(padding: 20)

        Picker("Match length", selection: $matchLength) {
            ForEach(MatchLengthSetting.onlineCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .tint(ChromeTheme.undoTint)
        .frame(maxWidth: 392)

        VStack(alignment: .leading, spacing: 12) {
            Text("Challenge a player")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
            if let me = coordinator.accountID {
                HStack {
                    Text("Your player ID: \(me)")
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button { UIPasteboard.general.string = me } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Copy"))
                }
            }
            TextField("Player ID", text: $opponentID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button {
                coordinator.challenge(opponentID: opponentID, targetWins: matchLength.targetWins,
                                      variantID: variant.pickerChoice.playing(houseRules: houseRules).rawValue)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                    Text("Challenge")
                }
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            .disabled(opponentID.trimmingCharacters(in: .whitespaces).isEmpty || coordinator.isWorking)
        }
        .frame(maxWidth: 392)
        .chromeCard(padding: 20)

        if let error = coordinator.lobbyError {
            Text(error)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeTheme.surrenderTint)
                .multilineTextAlignment(.center)
        }
        if let controller, let banner = OnlineStatusText.text(controller.status) {
            Text(banner)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        }

        if coordinator.matches.isEmpty {
            Text("No games in progress. Challenge a player to start one.")
                .font(ChromeType.callout)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        } else {
            VStack(spacing: 10) {
                Text("Your games")
                    .font(ChromeType.subheadline.bold())
                    .foregroundStyle(ChromeTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(coordinator.matches, id: \.matchID) { match in
                    ServerMatchRow(match: match) { coordinator.open(match) }
                        .contextMenu {
                            if match.state == .invited {
                                Button(role: .destructive) { coordinator.decline(match) } label: {
                                    Label("Decline", systemImage: "xmark")
                                }
                            }
                        }
                }
            }
            .frame(maxWidth: 440)
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 14) {
            Text("Sign in to your online account to play through the server.")
                .font(ChromeType.callout)
                .foregroundStyle(ChromeTheme.ink)
                .multilineTextAlignment(.center)
            Button("Online account") { showAccount = true }
                .buttonStyle(ChromeButton(role: .primary))
        }
        .chromeCard(padding: ChromeType.isCompact ? 16 : 24)
        .frame(maxWidth: 392)
    }
}

/// One of the account's games: opponent and state, tappable to open.
private struct ServerMatchRow: View {
    let match: ServerAPI.MatchSummary
    let onOpen: () -> Void

    private var stateLabel: String {
        switch match.state {
        case .yourTurn: return String(localized: "Your turn")
        case .theirTurn: return String(localized: "Their turn")
        case .invited: return String(localized: "Invited")
        case .waitingForOpponent: return String(localized: "Waiting for opponent")
        case .ended, .unknown: return String(localized: "Finished")
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                Text(match.opponent.displayName ?? String(localized: "Opponent"))
                Spacer(minLength: 12)
                Text(stateLabel)
                    .foregroundStyle(match.state == .yourTurn ? ChromeTheme.doneTint : ChromeKit.inkSecondary)
                DirectionalSymbol("chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
    }
}
