import SwiftUI
import TavliEngine

private typealias EngineColor = TavliEngine.Color

/// The handicap builder (#148, concept §4): a master toggle, one card per tier-1 item
/// (favoured-side picker + slider/toggle + a plain one-line explanation), the tier-2
/// "Rule changes" cards (overshoot, safe point, checkers per side, home size; P3b) and the
/// live win-chance estimate. Edits the persisted `HandicapPreferences` directly. Sides read
/// "You / Computer" or "White / Red" depending on the mode picked at the top.
///
/// **Per variant (#246).** Weighted dice, rerolls, hints and moves first work in every
/// variant and across Full Tavli; the head start and the rule changes only in a house-
/// Plakoto single game or best-of-three. The next game's kind (the remembered variant +
/// length + the House rules switch, #258) decides: items it can't use stay visible but
/// disabled, with the reason (in Plakoto: "Needs House rules: turn them on in
/// Settings."), and the applicability note says what is left out.
struct HandicapSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HandicapPreferences.storageKey) private var raw = ""
    @AppStorage(SettingsKey.matchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    @AppStorage(SettingsKey.variant) private var variantID = GameVariants.plakotoStandard.id
    @AppStorage(SettingsKey.houseRules) private var houseRules = false
    @AppStorage(SettingsKey.startingPlayer) private var startingPlayer: StartingPlayerSetting = .openingRoll

    @State private var vsComputer = true
    @StateObject private var model = HandicapEstimateModel()

    private var prefs: HandicapPreferences { HandicapPreferences.decode(raw) }

    private func binding<T>(_ key: WritableKeyPath<HandicapPreferences, T>) -> Binding<T> {
        Binding(get: { prefs[keyPath: key] },
                set: { var p = prefs; p[keyPath: key] = $0; raw = p.encoded })
    }

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Text("Give one side an advantage so players of different strength get a close game.")
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeKit.inkSecondary)

                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: binding(\.enabled)) {
                            Text("Use handicaps")
                                .font(ChromeType.body.weight(.semibold))
                                .foregroundStyle(ChromeTheme.ink)
                        }
                        .tint(ChromeTheme.doneTint)
                        .accessibilityIdentifier("handicapMaster")
                        Picker("Sides", selection: $vsComputer) {
                            Text("Playing the computer").tag(true)
                            Text("Two players").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .tint(ChromeTheme.undoTint)
                        applicabilityNote
                    }
                    .chromeCard(padding: 20)

                    Group {
                        itemCard(title: "Head start",
                                 caption: "Checkers that start 6 points ahead of the stack.",
                                 side: binding(\.headStartSide),
                                 unavailable: unavailableReason(.headStart)) {
                            stepSlider(value: binding(\.headStart), range: 0...HandicapSetup.maxHeadStart,
                                       label: prefs.headStart == 0 ? String(localized: "Off")
                                         : prefs.headStart == 1 ? String(localized: "1 checker")
                                         : String(localized: "\(prefs.headStart) checkers"))
                        }
                        itemCard(title: "Moves first",
                                 caption: isFullTavli ? "Starts every game of Full Tavli; no opening roll."
                                                      : "Always starts the game; no opening roll.",
                                 side: binding(\.movesFirstSide)) {
                            Toggle(isOn: binding(\.movesFirst)) {
                                Text(prefs.movesFirst ? String(localized: "On") : String(localized: "Off"))
                                    .font(ChromeType.callout)
                                    .foregroundStyle(ChromeTheme.ink)
                            }
                            .tint(ChromeTheme.doneTint)
                        }
                        itemCard(title: "Weighted dice",
                                 caption: "Before each roll the dice lean towards rolls that are good for this side. The game says so in its Handicap tag.",
                                 side: binding(\.diceSide)) {
                            stepSlider(value: binding(\.dice), range: 0...(HandicapDiceStrength.allCases.count - 1),
                                       label: prefs.diceStrength.label)
                        }
                        itemCard(title: "Rerolls",
                                 caption: "Roll again after seeing the dice, this many times per game.",
                                 side: binding(\.rerollsSide)) {
                            stepSlider(value: binding(\.rerolls), range: 0...HandicapSetup.maxRerolls,
                                       label: prefs.rerolls == 0 ? String(localized: "Off")
                                                                 : String(localized: "\(prefs.rerolls) per game"))
                        }
                        itemCard(title: "Hints",
                                 caption: "Show the computer's best move (without playing it), this many times per game.",
                                 side: vsComputer ? nil : binding(\.hintsSide),
                                 fixedSide: vsComputer ? String(localized: "You") : nil) {
                            stepSlider(value: binding(\.hints), range: 0...HandicapSetup.maxHints,
                                       label: prefs.hints == 0 ? String(localized: "Off")
                                                               : String(localized: "\(prefs.hints) per game"))
                        }
                    }
                    .disabled(!prefs.enabled)
                    .opacity(prefs.enabled ? 1 : 0.5)

                    // Tier 2 (#148 P3b): rule changes, each describing a side's own rules.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rule changes")
                            .font(ChromeType.headline)
                            .foregroundStyle(ChromeTheme.ink)
                        if let reason = unavailableReason(.ruleChanges) {
                            unavailableLabel(reason)
                        }
                    }
                    .padding(.top, 4)
                    .opacity(prefs.enabled ? 1 : 0.5)
                    Group {
                        itemCard(title: "Overshoot bear-off",
                                 caption: "May bear off with a higher die than needed, from the farthest checker (as in standard Plakoto). A big advantage.",
                                 side: binding(\.overshootSide)) {
                            Toggle(isOn: binding(\.overshoot)) {
                                Text(prefs.overshoot ? String(localized: "On") : String(localized: "Off"))
                                    .font(ChromeType.callout)
                                    .foregroundStyle(ChromeTheme.ink)
                            }
                            .tint(ChromeTheme.doneTint)
                            .accessibilityIdentifier("handicapOvershoot")
                        }
                        itemCard(title: "Safe point",
                                 caption: "A lone checker of this side on this point can't be pinned. Points count from the side's own start. A small advantage.",
                                 side: binding(\.safePointSide)) {
                            Picker("Safe point", selection: binding(\.safePoint)) {
                                Text("Off").tag(0)
                                ForEach(HandicapSetup.safePointCandidates, id: \.self) { p in
                                    Text(verbatim: "\(p)").tag(p)
                                }
                            }
                            .pickerStyle(.segmented)
                            .tint(ChromeTheme.undoTint)
                            .accessibilityIdentifier("handicapSafePoint")
                        }
                        checkersCard
                        itemCard(title: "Home size",
                                 caption: "Bear off only from the last points of the home board. A smaller home is a disadvantage.",
                                 side: binding(\.homeSizeSide)) {
                            Picker("Home size", selection: binding(\.homeSize)) {
                                ForEach(HandicapSetup.homeSizes, id: \.self) { k in
                                    Text(verbatim: "\(k)").tag(k)
                                }
                            }
                            .pickerStyle(.segmented)
                            .tint(ChromeTheme.undoTint)
                            .accessibilityIdentifier("handicapHomeSize")
                        }
                    }
                    .disabled(!prefs.enabled || unavailableReason(.ruleChanges) != nil)
                    .opacity(!prefs.enabled ? 0.5 : unavailableReason(.ruleChanges) != nil ? 0.45 : 1)
                }
                .compactPadding(28, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            // The estimate stays in view while the cards scroll underneath (pinned to the
            // bottom of the sheet), so every edit's effect is visible without scrolling.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if prefs.isActive { pinnedEstimate }
            }
        }
        .onAppear(perform: refreshEstimate)
        .onChange(of: raw) { _, _ in refreshEstimate() }
        .onChange(of: vsComputer) { _, _ in refreshEstimate() }
        .onChange(of: variantID) { _, _ in refreshEstimate() }
        .onChange(of: houseRules) { _, _ in refreshEstimate() }
        .onChange(of: matchLength) { _, _ in refreshEstimate() }
    }

    // MARK: - Estimate

    /// The live estimate, pinned below the scrolling cards on the page background.
    private var pinnedEstimate: some View {
        HandicapEstimateView(estimate: model.estimate,
                             computing: model.computing,
                             unavailable: model.unavailable,
                             notMeasured: model.notMeasured,
                             aName: HandicapRole.a.label(vsComputer: vsComputer),
                             bName: HandicapRole.b.label(vsComputer: vsComputer),
                             aColor: .white)
            .chromeCard(padding: 16)
            // Same width as the scrolling cards (their column is 560 wide incl. padding).
            .padding(.horizontal, ChromeType.isCompact ? 16 : 28)
            .frame(maxWidth: 560)
            .padding(.top, 10)
            .padding(.bottom, ChromeType.isCompact ? 8 : 16)
            .frame(maxWidth: .infinity)
            .background(ChromeKit.pageColor.ignoresSafeArea(edges: .bottom))
    }

    /// Side A is evaluated as White (house Plakoto is colour-symmetric). The start rule
    /// mirrors the app: two players → White starts; vs the computer → the First-move
    /// setting (opening roll = a fair roll-off).
    private func refreshEstimate() {
        guard prefs.isActive, let setup = prefs.setup(humanColor: vsComputer ? .white : nil) else { return }
        let rule: HandicapStartRule
        if !vsComputer {
            rule = .fixed(.white)
        } else {
            switch startingPlayer {
            case .openingRoll: rule = .rollOff
            case .human:       rule = .fixed(.white)
            case .ai:          rule = .fixed(.black)
            }
        }
        // Only house Plakoto has measured numbers (#246); Full Tavli and the other
        // variants show "not measured yet".
        model.update(setup: setup, rule: rule, variant: isFullTavli ? nil : variant)
    }

    // MARK: - Applicability (concept §7, per variant since #246)

    /// The next game's rules: the picked variant with the House rules switch (#258).
    private var variant: GameVariantSetting {
        GameVariantSetting(choiceID: variantID).playing(houseRules: houseRules)
    }
    private var isFullTavli: Bool { matchLength == .fullTavli }

    /// The next game's name for the notes: the variant, or Full Tavli.
    private var nextGameName: String { isFullTavli ? String(localized: "Full Tavli") : variant.name }

    /// Why `item` is off for the next game, or `nil` when it applies. #258: house Plakoto
    /// is the House rules switch, not a game of its own — the reason says to turn it on.
    private func unavailableReason(_ item: HandicapItemKind) -> String? {
        switch HandicapSetup.availability(item, variantID: variant.rawValue, fullTavli: isFullTavli) {
        case .available:      return nil
        case .notInFullTavli: return String(localized: "Off in Full Tavli: only in a Plakoto single game or Best of 3 with House rules.")
        case .houseRulesOnly:
            return variant.isPlakoto
                ? String(localized: "Needs House rules: turn them on in Settings.")
                : String(localized: "Off in \(variant.name): only in Plakoto with House rules (turn them on in Settings).")
        }
    }

    /// Where the handicaps apply (per variant), plus a warning when the next game leaves
    /// out items that are set.
    private var applicabilityNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                Text("Plakoto with House rules, single game or Best of 3: every item.")
                Text("Every other game and Full Tavli: weighted dice, rerolls, hints and moves first.")
                Text("Offline games only.")
            }
            .foregroundStyle(ChromeKit.inkSecondary)
            if let warning = leftOutWarning {
                Text(warning)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .padding(.top, 2)
                    .accessibilityIdentifier("handicapLeftOut")
            }
        }
        .font(ChromeType.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var leftOutWarning: String? {
        guard prefs.isActive else { return nil }
        let left = prefs.leftOut(variant: variant, fullTavli: isFullTavli)
        guard !left.isEmpty else { return nil }
        let name = nextGameName
        if HandicapItemKind.allCases.allSatisfy({ !prefs.isSet($0) || left.contains($0) }) {
            return isFullTavli
                ? String(localized: "Your next game is Full Tavli, so it will be played without a handicap.")
                : String(localized: "Your next game is \(name), so it will be played without a handicap.")
        }
        return String(localized: "Your next game is \(name): the head start and rule changes are left out.")
    }

    private func unavailableLabel(_ reason: String) -> some View {
        Label(reason, systemImage: "lock")
            .font(ChromeType.caption)
            .foregroundStyle(ChromeKit.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Handicap")
                .font(ChromeType.statsTitle)
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
    }

    /// One item: title, favoured-side picker (or a fixed side), the control, a caption.
    /// `unavailable` (#246): the next game can't use this item — the card stays visible,
    /// its controls disabled and dimmed, with the reason under the caption.
    private func itemCard<Control: View>(title: LocalizedStringKey, caption: LocalizedStringKey,
                                         side: Binding<HandicapRole>?, fixedSide: String? = nil,
                                         unavailable: String? = nil,
                                         @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                if ChromeType.isCompact, let side {
                    // Phone: a long side label (Greek "Υπολογιστής", #225) would truncate in
                    // the shared row, so the picker drops to its own full-width row then.
                    ViewThatFits(in: .horizontal) {
                        itemHeader(title: title, side: side, fixedSide: fixedSide)
                        VStack(alignment: .leading, spacing: 10) {
                            itemTitle(title)
                            sidePicker(side)
                        }
                    }
                } else {
                    itemHeader(title: title, side: side, fixedSide: fixedSide)
                }
                control()
                Text(caption)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            .disabled(unavailable != nil)
            .opacity(unavailable != nil ? 0.45 : 1)
            if let unavailable { unavailableLabel(unavailable) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 16)
    }

    /// An item's title row: the title with the favoured-side picker (or fixed side) trailing.
    private func itemHeader(title: LocalizedStringKey, side: Binding<HandicapRole>?,
                            fixedSide: String?) -> some View {
        HStack(spacing: 12) {
            itemTitle(title)
            Spacer(minLength: 8)
            if let side {
                sidePicker(side)
                    .frame(maxWidth: 210)
            } else if let fixedSide {
                Text(fixedSide)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
    }

    private func itemTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(ChromeType.body.weight(.semibold))
            .foregroundStyle(ChromeTheme.ink)
    }

    private func sidePicker(_ side: Binding<HandicapRole>) -> some View {
        Picker("For", selection: side) {
            ForEach(HandicapRole.allCases) { r in
                Text(r.label(vsComputer: vsComputer)).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .tint(ChromeTheme.undoTint)
    }

    /// Checkers per side (13…17): a stepper row for each side, neutral (no favoured side).
    private var checkersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checkers")
                .font(ChromeType.body.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            checkerStepper(.a, value: binding(\.checkersA))
            checkerStepper(.b, value: binding(\.checkersB))
            Text("How many checkers each side plays with (normally 15). More checkers is the advantage.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 16)
    }

    private func checkerStepper(_ role: HandicapRole, value: Binding<Int>) -> some View {
        Stepper(value: value, in: HandicapSetup.checkerRange) {
            HStack {
                Text(role.label(vsComputer: vsComputer))
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Spacer(minLength: 8)
                Text(verbatim: "\(value.wrappedValue)")
                    .font(ChromeType.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
            }
        }
        .accessibilityIdentifier(role == .a ? "handicapCheckersA" : "handicapCheckersB")
    }

    /// An integer slider with its value label.
    private func stepSlider(value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        HStack(spacing: 12) {
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .tint(ChromeTheme.undoTint)
            Text(label)
                .font(ChromeType.callout.monospacedDigit())
                .foregroundStyle(ChromeTheme.ink)
                .frame(minWidth: ChromeType.isCompact ? 96 : 120, alignment: .trailing)
        }
    }
}

#Preview {
    HandicapSettingsView()
}
