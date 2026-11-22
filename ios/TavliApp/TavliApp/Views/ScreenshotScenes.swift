#if DEBUG
import SwiftUI
import TavliEngine

/// DEBUG-only launch arguments that open the app straight into one App Store screenshot
/// scene (#184), driven by `ios/scripts/appstore_screenshots.sh`. Every scene runs on the
/// fixed game in `ScreenshotFixture.swift` (a realistic house-Plakoto game, you = White vs
/// the full-strength computer, generated with its complete analysis), so the shots are
/// identical on every run and no "Analyzing…" spinner ever shows. Nothing is saved,
/// logged or counted in the stats. Compiled out of release builds.
///
/// | Argument | Scene |
/// |---|---|
/// | `-screenshotGame` | the game vs the computer at a mid-game position, your turn, dice rolled; `-screenshotGamePly N` picks the position (before ply N; default `ScreenshotFixture.gamePly`, or `darkGamePly` in dark appearance) |
/// | `-screenshotReview` | the post-game review on your worst move; `-screenshotReviewPly N` picks another ply |
/// | `-screenshotDrill` | the drill on its last card (your last mistake, so not the review's position); add `-screenshotDrillSolution` to show the solution (your move amber vs best blue) |
/// | `-screenshotHandicap` | the handicap builder sheet over the start screen, with a preset handicap |
/// | `-screenshotNewGame` | the new-game sheet over the start screen |
///
/// Every scene also forces (in the volatile argument domain, never persisted) the
/// win-probability bar on, in-play analysis off and the AI level to 8.
enum ScreenshotScenes {
    private static var args: [String] { ProcessInfo.processInfo.arguments }

    static var isGame: Bool { args.contains("-screenshotGame") }
    static var isReview: Bool { args.contains("-screenshotReview") }
    static var isDrill: Bool { args.contains("-screenshotDrill") }
    static var drillSolution: Bool { args.contains("-screenshotDrillSolution") }
    static var isHandicap: Bool { args.contains("-screenshotHandicap") }
    static var isNewGame: Bool { args.contains("-screenshotNewGame") }
    static var isAny: Bool { isGame || isReview || isDrill || isHandicap || isNewGame }

    /// The fixture game's fixed id: the review/drill look its analysis up by it.
    static let gameId = UUID(uuidString: "00000000-0000-0000-0000-000000000184")!

    /// The fixture game as a finished record (you = White).
    static var record: GameRecord {
        GameRecord(startingPlayer: .white, aiColor: .black, plies: ScreenshotFixture.plies,
                   outcome: ScreenshotFixture.youWon ? .white : .black, gameId: gameId,
                   variantID: GameVariants.plakoto.id, aiLevel: AILevel.max)
    }

    /// Scroll target of the phone review scene: the win-chance chart.
    static let chartAnchor = "screenshotChart"

    /// The fixture's precomputed analysis for `id`, or `nil` for any other game. Read by
    /// `GameReviewModel` in place of the game log, so the review opens complete.
    static func analysis(for id: UUID) -> [AnalysisEntry]? {
        id == gameId ? ScreenshotFixture.analysis : nil
    }

    /// The review's first card: `-screenshotReviewPly N`, else your worst move (the drill
    /// scene opens on your last mistake instead, so the two show different positions).
    static var reviewPly: Int? {
        let ply = UserDefaults.standard.integer(forKey: "screenshotReviewPly")
        return ply > 0 ? ply : ScreenshotFixture.worstPlies.first
    }

    /// Settings every scene needs, written to the volatile argument domain (as if passed
    /// on the command line) so nothing on the simulator changes for later launches.
    static func applySettings() {
        guard isAny else { return }
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[SettingsKey.showWinProbability] = true
        domain[SettingsKey.inPlayAnalysis] = false
        domain[SettingsKey.aiLevel] = AILevel.max
        if isHandicap {
            var prefs = HandicapPreferences()
            prefs.enabled = true
            prefs.headStart = 2
            prefs.headStartSide = .a
            prefs.movesFirst = true
            prefs.movesFirstSide = .a
            prefs.rerolls = 2
            prefs.rerollsSide = .a
            prefs.hints = 3
            prefs.hintsSide = .a
            if let data = try? JSONEncoder().encode(prefs), let raw = String(data: data, encoding: .utf8) {
                domain[HandicapPreferences.storageKey] = raw
            }
        }
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    /// `-screenshotGame`: the fixture's mid-game game (`playPlies`) replayed up to (not
    /// including) the chosen ply — one of your turns with both sides pinning — with that
    /// ply's dice already rolled, so the board shows the dice. The ply is
    /// `-screenshotGamePly N`, else `darkGamePly` in dark appearance, else `gamePly`.
    /// `nil` without the argument.
    @MainActor
    static func gameSession() -> GameSession? {
        guard isGame else { return nil }
        let chosen = UserDefaults.standard.integer(forKey: "screenshotGamePly")
        let fallback = AppSettings.appearance == .dark ? ScreenshotFixture.darkGamePly : ScreenshotFixture.gamePly
        let plies = ScreenshotFixture.playPlies
        let ply = min(max(chosen > 0 ? chosen : fallback, 1), plies.count)
        let roll = plies[ply - 1]
        let save = GameSave(gameId: UUID(), name: "Screenshot", savedAt: Date(),
                            startingPlayer: TavliEngine.Color.white.rawValue,
                            aiColor: TavliEngine.Color.black.rawValue,
                            history: Array(plies.prefix(ply - 1)),
                            variant: GameVariants.plakoto.id,
                            pendingRoll: PendingRoll(die1: roll.die1, die2: roll.die2),
                            aiLevel: AILevel.max)
        let config = GameVariantSetting.plakoto.config
        let session = GameSession.resume(from: save, config: config,
                                         agent: GameSession.makeAgent(config: config),
                                         searchConfig: AppSettings.searchConfig,
                                         animationTimings: AppSettings.animationTimings,
                                         autoRoll: false)
        session.start()
        return session
    }
}

/// Presents the review / drill / handicap scenes over the root view.
private struct ScreenshotScenesModifier: ViewModifier {
    /// One full-screen cover for both scenes (SwiftUI presents only one cover per view).
    @State private var cover: Cover? = ScreenshotScenes.isReview ? .review
        : ScreenshotScenes.isDrill ? .drill : nil
    @State private var showHandicap = ScreenshotScenes.isHandicap

    enum Cover: Identifiable {
        case review, drill
        var id: Self { self }
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $cover) { scene in
                let record = ScreenshotScenes.record
                switch scene {
                case .review:
                    GameReviewView(record: record, agent: GameSession.makeAgent(), humanColor: .white)
                case .drill:
                    DrillView(record: record,
                              precomputed: GameReview.cachedResult(record: record,
                                                                   analysis: ScreenshotFixture.analysis),
                              agent: GameSession.makeAgent(), humanColor: .white)
                }
            }
            .sheet(isPresented: $showHandicap) {
                if #available(iOS 18.0, *) {
                    // A page-sized sheet on iPad, so more of the builder is in view.
                    HandicapSettingsView().presentationSizing(.page)
                } else {
                    HandicapSettingsView()
                }
            }
    }
}

extension View {
    /// DEBUG: open the App Store screenshot scene named by the launch arguments (#184).
    func screenshotScenes() -> some View { modifier(ScreenshotScenesModifier()) }
}
#endif
