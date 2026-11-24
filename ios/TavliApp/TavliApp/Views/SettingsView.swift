import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// In-app settings screen (#77). Presented as a sheet from the start screen and the
/// in-game chrome. Every control binds directly to `@AppStorage`, so changes persist
/// immediately and any view observing the same key updates live. Defaults are the
/// `AppSettings` accessors' (each `@AppStorage` default here must match its accessor).
///
/// Sections (#174): **Game** (play as, auto-roll, House rules #258), **Advanced** (first move, analyze
/// during play), **Display** (appearance, #191). Variant, match length and the AI level live in the
/// new-game sheet only (#189, `NewGameSheet`).
///
/// Styled to the Caramel chrome (background, `ChromeType` fonts, `ChromeTheme` tints)
/// rather than a stock `Form`, to match the rest of the app (cf. `StatsPanelView`).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.preferredColor) private var preferredColor: PreferredColorSetting = .white
    @AppStorage(SettingsKey.startingPlayer) private var startingPlayer: StartingPlayerSetting = .openingRoll
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = true
    @AppStorage(SettingsKey.aiAnimation) private var aiAnimation = true
    @AppStorage(SettingsKey.showWinProbability) private var showWinProbability = false
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceSetting = .system
    @AppStorage(SettingsKey.houseRules) private var houseRules = false

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    section("Game") {
                        choiceRow("Play as",
                                  selection: $preferredColor,
                                  options: PreferredColorSetting.allCases,
                                  label: \.label,
                                  caption: "The colour you play against the computer. Random picks a side for each new game.")
                        toggleRow("Auto-roll",
                                  isOn: $autoRoll,
                                  caption: "Dice roll automatically at the start of your turn.")
                        houseRulesRow
                    }

                    section("Advanced") {
                        choiceRow("First move",
                                  selection: $startingPlayer,
                                  options: StartingPlayerSetting.allCases,
                                  label: \.label,
                                  caption: "The opening roll decides who starts, unless you force a side.")
                    }

                    section("Display") {
                        choiceRow("Appearance",
                                  selection: $appearance,
                                  options: AppearanceSetting.allCases,
                                  label: \.label,
                                  caption: "System follows your device's light or dark mode.")
                        toggleRow("Animate computer moves",
                                  isOn: $aiAnimation,
                                  caption: "Slow dice roll and one-by-one checker hops on the computer's turn.")
                        toggleRow("Win-probability bar",
                                  isOn: $showWinProbability,
                                  caption: "Show your live chance of winning during the game.")
                    }

                    // #148: the one handicap entry, a card of its own at the end
                    // (builder in HandicapSettingsView).
                    HandicapSettingsRow()
                }
                .compactPadding(28, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Settings")
                .font(ChromeType.statsTitle)
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(ChromeType.headline)
                .foregroundStyle(ChromeKit.inkSecondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
    }

    // MARK: - Rows

    /// A titled segmented choice over a set of options, with a caption beneath.
    private func choiceRow<T: Hashable & Identifiable>(_ title: LocalizedStringKey,
                                                       selection: Binding<T>,
                                                       options: [T],
                                                       label: KeyPath<T, String>,
                                                       caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ChromeType.body.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option[keyPath: label]).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(ChromeTheme.undoTint)
            Text(caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }

    /// The House rules switch (#258, default off): every new Plakoto game — single, Best
    /// of 3, Full Tavli's Plakoto leg, vs the computer or two players — uses the family's
    /// house rules. The title carries the wolf tag's head; games already started keep
    /// their own rules.
    private var houseRulesRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $houseRules) {
                HStack(spacing: 8) {
                    Text("House rules")
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    HouseRulesTag(style: .glyph)
                        .accessibilityHidden(true)
                }
            }
            .tint(ChromeTheme.doneTint)
            .accessibilityIdentifier("houseRulesSwitch")
            Text("Only for Plakoto: bear off with exact rolls only, you don't have to use both dice, pinning the mother checker wins at once, and every win counts one point.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A titled on/off toggle with a caption beneath.
    private func toggleRow(_ title: LocalizedStringKey,
                           isOn: Binding<Bool>,
                           caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(ChromeType.body.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
            }
            .tint(ChromeTheme.doneTint)
            Text(caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }
}

#Preview {
    SettingsView()
}
