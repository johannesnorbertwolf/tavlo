import SwiftUI
import TavliEngine

/// The online game's shared weighted dice (#272): one value for both players, mirrored
/// (#271), either player changes it, no confirmation. Presentation only over the engine's
/// `OnlineMatchController` (`diceHandicap`, `setDiceHandicap(levelTowardsMe:)`).
///
/// - `OnlineDiceTagButton`: the ⚖ tag in the online game chrome (where the offline
///   `HandicapTagButton` sits) — always there online, so either player can open it; with
///   the favoured side's dot + level when the dice are not fair.
/// - `OnlineDiceSheet`: the half-height card with the two-sided slider (−4 … +4, fair in
///   the middle; towards "You" favours you, towards the opponent favours them).

/// How the shared dice read from the local player's side.
enum OnlineDiceCopy {
    /// "Fair dice" / "Favours you · Strong" / "Favours Bob · Slight".
    static func summary(_ dice: OnlineDiceHandicap, localColor: TavliEngine.Color,
                        opponentName: String) -> String {
        guard let side = dice.favoured else { return String(localized: "Fair dice") }
        let strength = HandicapDiceStrength(level: dice.level).label
        return side == localColor
            ? String(localized: "Favours you · \(strength)")
            : String(localized: "Favours \(opponentName) · \(strength)")
    }

    /// The short tag label: "You · Strong" / "Bob · Slight" / "Fair dice".
    static func tag(_ dice: OnlineDiceHandicap, localColor: TavliEngine.Color,
                    opponentName: String) -> String {
        guard let side = dice.favoured else { return String(localized: "Fair dice") }
        let strength = HandicapDiceStrength(level: dice.level).label
        let who = side == localColor ? String(localized: "You") : opponentName
        return "\(who)\(ChromeDigits.listSeparator)\(strength)"
    }
}

/// The ⚖ tag of an online game: opens the shared-dice card. Fair dice show the scale
/// alone (with "Fair dice" where there is room); otherwise the favoured side's checker dot
/// and the level, so both players always see the current value on the board.
struct OnlineDiceTagButton: View {
    @ObservedObject var controller: OnlineMatchController
    let opponentName: String
    var compact = false
    @State private var showSheet = false

    var body: some View {
        let dice = controller.diceHandicap
        Button { showSheet = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "scalemass")
                if let side = dice.favoured {
                    HandicapSideDot(color: side)
                    if compact {
                        Text(verbatim: ChromeDigits.localized("\(dice.level)"))
                            .monospacedDigit()
                    } else {
                        Text(OnlineDiceCopy.tag(dice, localColor: controller.localColor,
                                                opponentName: opponentName))
                            .lineLimit(1)
                    }
                } else if !compact {
                    Text("Fair dice")
                }
                if controller.isDiceChangePending {
                    Image(systemName: "arrow.up.circle")
                        .accessibilityHidden(true)
                }
            }
            .font(ChromeType.caption.weight(.semibold))
        }
        .buttonStyle(ChromeButton(role: .secondary))
        .accessibilityLabel(Text("Weighted dice: \(OnlineDiceCopy.summary(dice, localColor: controller.localColor, opponentName: opponentName))"))
        .accessibilityIdentifier("onlineDiceTag")
        .sheet(isPresented: $showSheet) {
            OnlineDiceSheet(controller: controller, opponentName: opponentName)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// The shared-dice card: what the dice do now and who changed them last, the two-sided
/// slider (the opponent's end leading, yours trailing; mirrors with the layout in
/// Persian), what "mirrored" means, and — while the local player's own change is on its
/// way — when it takes effect.
struct OnlineDiceSheet: View {
    @ObservedObject var controller: OnlineMatchController
    let opponentName: String
    @Environment(\.dismiss) private var dismiss
    /// The slider while it is dragged; committed when the drag ends (one change, one
    /// message to the opponent, not one per step).
    @State private var draft: Double = 0
    @State private var editing = false

    private var dice: OnlineDiceHandicap { controller.diceHandicap }
    private var mine: Int { dice.level(towards: controller.localColor) }

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            if let side = previewDice.favoured {
                                HandicapSideDot(color: side, size: 16)
                            } else {
                                Image(systemName: "equal.circle")
                                    .foregroundStyle(ChromeKit.iconInk)
                                    .accessibilityHidden(true)
                            }
                            Text(OnlineDiceCopy.summary(previewDice, localColor: controller.localColor,
                                                        opponentName: opponentName))
                                .font(ChromeType.body.weight(.semibold))
                                .foregroundStyle(ChromeTheme.ink)
                        }
                        slider
                        Text("Good rolls for one side are bad rolls for the other. Either of you can change it; it counts for both players from the next roll.")
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let status = statusLine {
                            Text(status)
                                .font(ChromeType.caption.weight(.semibold))
                                .foregroundStyle(ChromeKit.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("onlineDiceStatus")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .chromeCard(padding: 16)
                    .disabled(!controller.canChangeDice)
                    Text("Other handicaps are only for games on this device.")
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
                .compactPadding(24, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { draft = Double(mine) }
        .onChange(of: mine) { _, value in if !editing { draft = Double(value) } }
        .accessibilityIdentifier("onlineDiceCard")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Weighted dice")
                    .font(ChromeType.statsTitle)
                    .foregroundStyle(ChromeTheme.ink)
                Text("Shared with \(opponentName)")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
    }

    /// −4 … +4 from the local side, fair in the middle; the ends are named.
    private var slider: some View {
        VStack(spacing: 4) {
            Slider(value: $draft, in: -Double(WeightedDice.levels)...Double(WeightedDice.levels), step: 1,
                   onEditingChanged: { isEditing in
                       editing = isEditing
                       if !isEditing { commit() }
                   })
                // Two-sided: no fill from the leading end, a tick marks fair in the middle.
                .tint(ChromeKit.trackColor)
                .background {
                    Capsule()
                        .fill(ChromeKit.inkSecondary)
                        .frame(width: 2, height: 16)
                        .accessibilityHidden(true)
                }
                .accessibilityLabel(Text("Weighted dice"))
                .accessibilityValue(Text(OnlineDiceCopy.summary(previewDice, localColor: controller.localColor,
                                                                opponentName: opponentName)))
                .accessibilityIdentifier("onlineDiceSlider")
                // VoiceOver increments arrive without a drag: commit them at once.
                .onChange(of: draft) { _, _ in if !editing { commit() } }
            HStack {
                Text(opponentName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Fair")
                Spacer(minLength: 8)
                Text("You")
            }
            .font(ChromeType.caption)
            .foregroundStyle(ChromeKit.inkSecondary)
            .accessibilityHidden(true)
        }
    }

    /// The value the slider shows (the draft while dragging).
    private var previewDice: OnlineDiceHandicap {
        let level = Int(draft.rounded())
        guard editing || level != mine else { return dice }
        let white = controller.localColor == .white ? level : -level
        return OnlineDiceHandicap(whiteLevel: white)
    }

    private func commit() {
        let level = Int(draft.rounded())
        guard level != mine else { return }
        controller.setDiceHandicap(levelTowardsMe: level)
    }

    /// Unavailable / on its way / who changed it last.
    private var statusLine: String? {
        if !controller.canChangeDice {
            return controller.isMatchOver ? nil
                : String(localized: "Weighted dice need the computer’s model for this variant.")
        }
        if controller.isDiceChangePending {
            return String(localized: "Sent to \(opponentName). It counts from their next roll once it arrives, and from your next roll at the latest.")
        }
        switch dice.changedBy {
        case nil: return nil
        case controller.localColor?: return String(localized: "Last changed by you.")
        default: return String(localized: "Last changed by \(opponentName).")
        }
    }
}
