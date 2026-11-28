import SwiftUI
import UIKit
import TavliEngine

private typealias SColor = SwiftUI.Color

// People, presence, one-tap challenges (#301), presentation only over the engine's
// `ServerPeople` (owned by `ServerOnlineCoordinator`): the lobby's People rows (pinned first,
// green dot "Online now" / "Active 2 h ago" / "Wants to play" / "Waiting for answer…"), the
// challenge sheet (variant + length remembered → Play → "Waiting for Alex…"), Find player
// (search by handle → challenge or ⭐ add), the incoming-challenge card (lobby + root
// overlay) and the root's "Alex accepted" card.

// MARK: - People rows

/// One person: initial + green dot when online, name + @handle, status, ⭐.
struct PersonRow: View {
    let person: ServerAPI.Person
    let onOpen: () -> Void

    private var status: PersonStatus { person.status() }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                PersonBadge(name: person.displayName, online: person.isOnline)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(person.displayName)
                            .font(ChromeType.callout.bold())
                            .foregroundStyle(ChromeTheme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if person.pinned {
                            Image(systemName: "star.fill")
                                .font(ChromeType.caption)
                                .foregroundStyle(ChromeTheme.undoTint)
                                .accessibilityLabel(Text("Pinned"))
                        }
                    }
                    Text(verbatim: "@\(person.handle)")
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Spacer(minLength: 8)
                if let text = PeopleCopy.status(status) {
                    Text(text)
                        .font(ChromeType.caption.weight(.semibold))
                        .foregroundStyle(PeopleCopy.statusColor(status))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                DirectionalSymbol("chevron.right")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 60)
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
        .accessibilityIdentifier("person-\(person.handle)")
    }
}

/// The initial in a caramel disc, with the green "online" dot.
struct PersonBadge: View {
    let name: String
    var online = false

    private var size: CGFloat { ChromeType.isCompact ? 38 : 44 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(ChromeTheme.undoTint.opacity(0.22))
                Text(String(name.first.map(String.init) ?? "?").uppercased())
                    .font(ChromeType.callout.bold())
                    .foregroundStyle(ChromeTheme.ink)
            }
            .frame(width: size, height: size)
            if online {
                Circle()
                    .fill(PeopleCopy.onlineGreen)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().stroke(ChromeKit.cardColor, lineWidth: 2))
                    .accessibilityLabel(Text("Online now"))
            }
        }
        .accessibilityHidden(!online)
    }
}

// MARK: - Challenge sheet

/// Who the challenge sheet is for (a person of the list or a search result).
struct ChallengeTarget: Identifiable, Equatable {
    var playerID: String
    var name: String
    var handle: String
    var canChallenge = true
    /// They challenged you: the sheet answers instead.
    var incoming: IncomingChallenge?
    var id: String { playerID }

    init(person: ServerAPI.Person, incoming: IncomingChallenge?) {
        playerID = person.playerID
        name = person.displayName
        handle = person.handle
        self.incoming = incoming
    }

    init(result: ServerAPI.PlayerResult) {
        playerID = result.playerID
        name = result.displayName
        handle = result.handle
        canChallenge = result.canChallenge
    }
}

/// Tap a person → variant + length (remembered from last time) → Play → "Waiting for …"
/// until the answer (an accept opens the match at once).
struct ChallengeSheet: View {
    @ObservedObject var people: ServerPeople
    let coordinator: ServerOnlineCoordinator
    let target: ChallengeTarget

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.houseRules) private var houseRules = false
    @State private var variant: GameVariantSetting = .plakotoStandard
    @State private var length: MatchLengthSetting = .bestOfThree

    private var isCompact: Bool { ChromeType.isCompact }

    /// The sheet's challenge, once Play was tapped.
    private var waiting: OutgoingChallenge? {
        guard let w = people.waiting, w.playerID == target.playerID else { return nil }
        return w
    }

    private var played: GameVariantSetting { variant.playing(houseRules: houseRules) }

    var body: some View {
        ZStack {
            ChromeKit.cardColor.ignoresSafeArea()
            FitOrScroll {
                VStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
                    SheetHeader(title: String(localized: "Play with \(target.name)")) { dismiss() }
                    if let incoming = target.incoming {
                        IncomingChallengeCard(challenge: incoming, people: people, embedded: true) { dismiss() }
                    } else if let waiting {
                        waitingView(waiting)
                    } else {
                        chooser
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
        .presentationDetents(isCompact ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            people.error = nil
            let choice = ChallengeChoice.load(from: .standard, fallback: ChallengeChoice(
                variant: AppSettings.variant.pickerChoice.rawValue, targetWins: 2))
            variant = GameVariantSetting(variantID: choice.variant).pickerChoice
            length = choice.targetWins >= 2 ? .bestOfThree : .single
            coordinator.isWaitingSheetShown = true
        }
        .onDisappear {
            coordinator.isWaitingSheetShown = false
            // Closing stops following; a pending challenge stays (the row says "Waiting…").
            if let w = waiting, w.state != .waiting, w.state != .sending { people.clearWaiting() }
        }
        .onChange(of: waiting?.state) { _, state in
            if state == .accepted { dismiss() }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
            Text(verbatim: "@\(target.handle)")
                .font(ChromeType.callout)
                .foregroundStyle(ChromeKit.inkSecondary)
                .environment(\.layoutDirection, .leftToRight)
            SheetSection("Variant") {
                SegmentedChoice(options: GameVariantSetting.pickerCases, selection: $variant, label: \.shortLabel)
                if houseRules && played.isHouseRules { HouseRulesTag() }
                Text(played.rulesReminder)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SheetSection("Length") {
                SegmentedChoice(options: MatchLengthSetting.onlineCases, selection: $length, label: \.label)
            }
            if target.canChallenge {
                Button {
                    ChallengeChoice(variant: variant.rawValue, targetWins: length.targetWins).save(to: .standard)
                    Task {
                        await people.challenge(playerID: target.playerID, name: target.name,
                                               variant: played.rawValue, targetWins: length.targetWins)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                }
                .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                .accessibilityIdentifier("challengePlay")
                Text("\(target.name) gets a notification and can accept or decline.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This player takes challenges only from people they know.")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func waitingView(_ w: OutgoingChallenge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PersonBadge(name: w.name, online: people.person(w.playerID)?.isOnline ?? false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(PeopleCopy.waitingTitle(w))
                        .font(ChromeType.headline)
                        .foregroundStyle(ChromeTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PeopleCopy.game(variant: w.variant, targetWins: w.targetWins))
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
                Spacer(minLength: 0)
                if w.state == .waiting || w.state == .sending { ProgressView() }
            }
            .chromeCard(padding: isCompact ? 16 : 20)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("challengeWaiting")
            switch w.state {
            case .sending, .waiting:
                Text("You can close this. When \(w.name) answers, you get a notification.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    Task { await people.cancelWaiting() }
                } label: {
                    Text("Cancel challenge").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
                .disabled(w.matchID == nil)
            case .accepted:
                Button {
                    Task { await people.openAccepted() }
                } label: {
                    Text("Play now").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            case .declined, .expired, .cancelled, .failed:
                Button {
                    people.clearWaiting()
                } label: {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            }
            if let error = people.error {
                Text(error)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Find player

/// Search by handle (≥ 3 characters): handle + display name; tap → challenge, ⭐ → add.
struct FindPlayerSheet: View {
    @ObservedObject var people: ServerPeople
    /// A result was picked: the caller shows the challenge sheet.
    let onPick: (ChallengeTarget) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var isCompact: Bool { ChromeType.isCompact }

    var body: some View {
        ZStack {
            ChromeKit.cardColor.ignoresSafeArea()
            VStack(alignment: .leading, spacing: isCompact ? 14 : 20) {
                SheetHeader(title: String(localized: "Find player")) { dismiss() }
                Text("Type at least 3 letters of their handle, like @alex. Ask them for it — it’s on their account page.")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ChromeKit.inkSecondary)
                    TextField(String(localized: "Handle"), text: $query)
                        .font(ChromeType.body)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .focused($focused)
                        .accessibilityIdentifier("findPlayerField")
                    if people.isSearching { ProgressView() }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: ChromeKit.buttonRadius).fill(ChromeKit.trackColor))
                .environment(\.layoutDirection, .leftToRight)
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(people.searchResults, id: \.playerID) { result in
                            resultRow(result)
                        }
                        if HandleRule.searchQuery(query) != nil, !people.isSearching, people.searchResults.isEmpty {
                            Text("Nobody with that handle.")
                                .font(ChromeType.callout)
                                .foregroundStyle(ChromeKit.inkSecondary)
                                .padding(.top, 8)
                        }
                        if let error = people.error {
                            Text(error)
                                .font(ChromeType.caption)
                                .foregroundStyle(ChromeTheme.surrenderTint)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, isCompact ? 20 : 32)
            .padding(.top, isCompact ? 20 : 28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            people.error = nil
            people.clearSearch()
            focused = true
        }
        .task(id: query) {
            // Debounce: one search after typing pauses.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await people.search(query)
        }
    }

    private func resultRow(_ r: ServerAPI.PlayerResult) -> some View {
        HStack(spacing: 12) {
            Button {
                onPick(ChallengeTarget(result: r))
            } label: {
                HStack(spacing: 12) {
                    PersonBadge(name: r.displayName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "@\(r.handle)")
                            .font(ChromeType.callout.bold())
                            .foregroundStyle(ChromeTheme.ink)
                            .environment(\.layoutDirection, .leftToRight)
                        Text(r.displayName)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Task { await people.setPinned(true, playerID: r.playerID) }
            } label: {
                Image(systemName: r.isPerson ? "star.fill" : "star")
                    .font(ChromeType.title3)
                    .foregroundStyle(ChromeTheme.undoTint)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(r.isPerson)
            .accessibilityLabel(Text(r.isPerson ? "In your people" : "Add to people"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: ChromeKit.cardRadius).fill(ChromeKit.secondaryFill))
    }
}

// MARK: - Incoming challenge

/// "Alex wants to play" · "Fevga · Best of 3" · Accept / Decline (+ Block in the menu).
struct IncomingChallengeCard: View {
    let challenge: IncomingChallenge
    @ObservedObject var people: ServerPeople
    /// Inside the challenge sheet (no close button; `onDone` dismisses it).
    var embedded = false
    var onAccept: (() -> Void)?
    var onDone: () -> Void = {}

    init(challenge: IncomingChallenge, people: ServerPeople, embedded: Bool = false,
         onAccept: (() -> Void)? = nil, onDone: @escaping () -> Void = {}) {
        self.challenge = challenge
        self.people = people
        self.embedded = embedded
        self.onAccept = onAccept
        self.onDone = onDone
    }

    @State private var confirmBlock = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                PersonBadge(name: challenge.fromName,
                            online: challenge.fromID.flatMap { people.person($0)?.isOnline } ?? false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(challenge.fromName) wants to play")
                        .font(ChromeType.headline)
                        .foregroundStyle(ChromeTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PeopleCopy.game(variant: challenge.variant, targetWins: challenge.targetWins))
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
                Spacer(minLength: 0)
                Menu {
                    if !embedded {
                        Button { people.dismiss(challenge) } label: { Label("Later", systemImage: "clock") }
                    }
                    if challenge.fromID != nil {
                        Button(role: .destructive) { confirmBlock = true } label: {
                            Label("Block \(challenge.fromName)", systemImage: "hand.raised")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(ChromeType.title3)
                        .foregroundStyle(ChromeKit.iconInk)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("More"))
            }
            HStack(spacing: 10) {
                Button {
                    PushRegistrar.removeDelivered(matchID: challenge.matchID)
                    Task {
                        await people.decline(challenge)
                        onDone()
                    }
                } label: {
                    Text("Decline").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
                .accessibilityIdentifier("challengeDecline")
                Button {
                    PushRegistrar.removeDelivered(matchID: challenge.matchID)
                    if let onAccept {
                        onAccept()
                    } else {
                        Task { await people.accept(challenge) }
                    }
                    onDone()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Accept")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                .accessibilityIdentifier("challengeAccept")
            }
        }
        .padding(ChromeType.isCompact ? 14 : 18)
        .background(
            RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                .fill(ChromeKit.cardColor)
                .shadow(color: ChromeKit.cardShadow, radius: 8, x: 0, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: ChromeKit.cardRadius).stroke(ChromeTheme.undoTint.opacity(0.6), lineWidth: 1.5))
        .accessibilityIdentifier("incomingChallenge")
        .alert(Text("Block \(challenge.fromName)?"), isPresented: $confirmBlock) {
            Button("Block", role: .destructive) {
                PushRegistrar.removeDelivered(matchID: challenge.matchID)
                if let id = challenge.fromID { Task { await people.block(playerID: id) } }
                onDone()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can’t challenge you, find you or see when you’re online any more. You can unblock them on your account page.")
        }
    }
}

/// The root's overlay (any screen): the newest incoming challenge, or "Alex accepted".
struct ChallengeOverlay: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    /// Show the online screen (the accepted / opened match lives there).
    let onOpenOnline: () -> Void

    var body: some View {
        if let people = coordinator.people {
            ChallengeOverlayContent(coordinator: coordinator, people: people, onOpenOnline: onOpenOnline)
        }
    }
}

private struct ChallengeOverlayContent: View {
    @ObservedObject var coordinator: ServerOnlineCoordinator
    @ObservedObject var people: ServerPeople
    let onOpenOnline: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let challenge = people.incoming.first {
                IncomingChallengeCard(challenge: challenge, people: people, onAccept: {
                    coordinator.acceptIncoming(challenge)
                    onOpenOnline()
                })
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let accepted = coordinator.acceptedChallenge {
                acceptedCard(accepted)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, ChromeType.isCompact ? 12 : 24)
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.25), value: people.incoming.first?.matchID)
        .animation(.easeOut(duration: 0.25), value: coordinator.acceptedChallenge?.matchID)
    }

    private func acceptedCard(_ c: OutgoingChallenge) -> some View {
        HStack(spacing: 12) {
            PersonBadge(name: c.name, online: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(c.name) accepted")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeTheme.ink)
                Text(PeopleCopy.game(variant: c.variant, targetWins: c.targetWins))
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            Spacer(minLength: 4)
            Button {
                coordinator.playAccepted()
                onOpenOnline()
            } label: {
                Text("Play now")
            }
            .buttonStyle(ChromeButton(role: .primary))
            Button { coordinator.acceptedChallenge = nil } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(ChromeKit.iconInk)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(ChromeType.isCompact ? 12 : 16)
        .background(
            RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                .fill(ChromeKit.cardColor)
                .shadow(color: ChromeKit.cardShadow, radius: 8, x: 0, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: ChromeKit.cardRadius).stroke(ChromeKit.cardEdge, lineWidth: 1))
    }
}

// MARK: - Copy

enum PeopleCopy {
    /// The online dot: the chrome's green, a touch brighter so it reads on the caramel disc.
    static let onlineGreen = SwiftUI.Color(light: 0x4f9a3a, dark: 0x7fd36a)

    static func status(_ status: PersonStatus, now: Date = Date()) -> String? {
        switch status {
        case .wantsToPlay: return String(localized: "Wants to play")
        case .waitingForAnswer: return String(localized: "Waiting for answer…")
        case .online: return String(localized: "Online now")
        case .lastSeen(let date):
            let ago = RelativeDateTimeFormatter()
            ago.unitsStyle = .short
            let when = date > now.addingTimeInterval(-60) ? String(localized: "just now") : ago.localizedString(for: date, relativeTo: now)
            return String(localized: "Active \(when)")
        case .none: return nil
        }
    }

    static func statusColor(_ status: PersonStatus) -> SwiftUI.Color {
        switch status {
        case .wantsToPlay: return ChromeTheme.undoTint
        case .online: return PeopleCopy.onlineGreen
        default: return ChromeKit.inkSecondary
        }
    }

    static func game(variant: String, targetWins: Int) -> String {
        [GameVariantSetting(variantID: variant).shortLabel, ServerLobbyCopy.lengthLabel(targetWins)]
            .joined(separator: ChromeDigits.listSeparator)
    }

    static func waitingTitle(_ w: OutgoingChallenge) -> String {
        switch w.state {
        case .sending, .waiting: return String(localized: "Waiting for \(w.name)…")
        case .accepted: return String(localized: "\(w.name) accepted")
        case .declined: return String(localized: "\(w.name) can’t play right now")
        case .expired: return String(localized: "\(w.name) didn’t answer")
        case .cancelled: return String(localized: "Challenge cancelled")
        case .failed(let message): return message
        }
    }
}
