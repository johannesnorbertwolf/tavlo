import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// T10 — app root. Switches between the caramel mode picker, the opening roll,
/// and a live game. Owns save/load (#61): auto-saves the in-progress game when
/// the app backgrounds, auto-resumes that game on the next cold launch, and lets
/// the player load or delete any saved game from the picker.
///
/// Holds the active `GameSession` in `@State` so the reference stays stable
/// across re-renders; `GameView` observes it. Picking a color goes to the
/// opening roll; the roll result (or manual override) builds the session.
struct RootView: View {
    @StateObject private var statsStore = HumanStatsStore()
    /// Online multiplayer (#134). Lives at the root so its lifetime spans the lobby
    /// and a live match; inert until the player opens the online lobby.
    @StateObject private var online = GameKitCoordinator()
    /// Online play through our own server (#286), behind the developer switch (Settings →
    /// Online account); inert until its lobby appears. Game Center stays the default.
    @StateObject private var serverOnline = ServerOnlineCoordinator()
    @AppStorage(ServerOnlineCoordinator.switchKey) private var onlineViaServer = false
    @AppStorage(SettingsKey.developerTools) private var developerToolsSetting = false
    /// Whether the online lobby/game is on screen (entered from the mode picker).
    @State private var showOnline = false
    @State private var session: GameSession?
    @State private var humanColor: EngineColor = .white
    /// The running best-of-three score (#145), non-nil only while a match is in
    /// progress. In-memory only — a match isn't resumed across app launches (out of
    /// scope per #145); a cold-launch autosave resumes as a standalone single game.
    @State private var match: MatchState?
    /// The running Full Tavli session (#144), non-nil from its first leg until the
    /// player leaves it. Unlike `match` it is persisted: every autosave of one of its
    /// legs carries it (`GameSave.fullTavli`), so a relaunch resumes mid-leg or on the
    /// between-legs screen.
    @State private var fullTavli: FullTavliSession?
    /// Which Full Tavli screen shows while no leg is on the board.
    @State private var fullTavliScreen: FullTavliScreen?
    /// Non-nil while the opening roll screen is showing (between mode picker and game).
    @State private var pendingHumanColor: EngineColor?
    /// The variant the pending (opening-roll) game will be played under (#143).
    @State private var pendingVariant: GameVariantSetting = .plakoto
    /// The current game's display name — a timestamped default ("Game · <date>",
    /// the same convention as a manual save) for a fresh game, or the resumed
    /// game's own name. Written into the auto-save slot on every move (#61).
    @State private var autosaveName: String = ""
    @Environment(\.scenePhase) private var scenePhase

    private let store = SaveStore.default()
    /// Append-only log of every finished game (#104), separate from the autosave slot.
    private let gameLog = GameLogStore.default()

    init() {
        // UI-test hook: start directly in a deterministic human-vs-AI game so the
        // board interaction can be driven without the picker or random dice.
        #if DEBUG
        if let seeded = ScreenshotScenes.gameSession() {
            // `-screenshotGame` (#184, DEBUG only): the App Store mid-game scene.
            _session = State(initialValue: seeded)
            _humanColor = State(initialValue: .white)
            _autosaveName = State(initialValue: RootView.newAutosaveName())
            return
        }
        if let seeded = RootView.debugHandicapSession() {
            // `-debugHandicapBearOff` (#236, DEBUG only): a handicap game with two-digit
            // borne-off counts, for checking the phone's top bar and the handicap card.
            _session = State(initialValue: seeded)
            _humanColor = State(initialValue: .white)
            _autosaveName = State(initialValue: RootView.newAutosaveName())
            return
        }
        if let seeded = RootView.debugFevgaBearOffSession() {
            // `-debugFevgaBearOff[Black]` (#270, DEBUG only): a two-player Fevga bear-off
            // with checkers off on both sides, for checking the split trays.
            let color: EngineColor = ProcessInfo.processInfo.arguments.contains("-debugFevgaBearOffBlack") ? .black : .white
            _session = State(initialValue: seeded)
            _humanColor = State(initialValue: color)
            _autosaveName = State(initialValue: RootView.newAutosaveName())
            return
        }
        #endif
        if ProcessInfo.processInfo.arguments.contains("-uiTestGame") {
            let s = RootView.makeSession(humanColor: .black, startingPlayer: .black)
            s.setDice(3, 5)
            _session = State(initialValue: s)
            _humanColor = State(initialValue: .black)
            _autosaveName = State(initialValue: RootView.newAutosaveName())
        } else if let resumed = RootView.autoResume() {
            // Resume exactly where the last session left off (#61, criterion 1) —
            // including a Full Tavli session mid-leg or between legs (#144).
            _session = State(initialValue: resumed.session)
            _humanColor = State(initialValue: resumed.humanColor)
            _autosaveName = State(initialValue: resumed.name)
            _fullTavli = State(initialValue: resumed.fullTavli)
            _fullTavliScreen = State(initialValue: resumed.screen)
        } else {
            _session = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if showOnline {
                // Online multiplayer (#134) is a self-contained branch: the coordinator
                // owns its own session, so the offline save/resume/stats wiring below is
                // bypassed entirely (online results don't touch the vs-AI record).
                if onlineViaServer && DeveloperTools.isEnabled(setting: developerToolsSetting) {
                    ServerOnlineRootView(coordinator: serverOnline, onExit: { showOnline = false })
                } else {
                    OnlineRootView(coordinator: online, onExit: { showOnline = false })
                }
            } else if let session {
                GameView(
                    session: session,
                    stats: statsStore.stats,
                    humanColor: humanColor,
                    onBack: {
                        persistAutosave()        // never lose progress on the way out
                        self.session = nil
                        self.match = nil
                        self.leaveFullTavli()
                    },
                    onNewGame: {
                        // "Play Again" keeps the same color, mode and variant, and re-runs
                        // the starting-player flow: the opening-roll ceremony, or a forced
                        // starter per Settings (#77). Play as Random (#189) draws a side
                        // for each new game.
                        let variant = GameVariantSetting(variant: session.game.variant)
                        let vsAI = session.aiColor != nil
                        self.session = nil
                        if vsAI {
                            self.beginGame(humanColor: self.newGameColor, variant: variant)
                        } else {
                            self.beginTwoPlayer(variant: variant)
                        }
                    },
                    onSave: { name in
                        _ = try? store.writeManual(session.snapshot(name: name, fullTavli: fullTavli))
                    },
                    onAutosave: persistAutosave,
                    match: match.map { ms in
                        // Best-of-three chrome (#145): scoreboard during play + a match
                        // transition overlay. Offline reads the just-finished winner from
                        // the session and keys the overlay on the game being over.
                        GameView.Match(
                            state: ms,
                            localColor: humanColor,
                            opponentName: String(localized: "Computer"),
                            lastGameResult: nil,
                            showResultOverlay: false,
                            onNextGame: startNextMatchGame,
                            onRematch: startRematch,
                            onExit: {
                                persistAutosave()
                                self.session = nil
                                self.match = nil
                            }
                        )
                    },
                    fullTavli: fullTavli.map { ft in
                        GameView.FullTavli(
                            state: ft,
                            onContinue: {
                                // The between-legs state is already in the autosave
                                // (written when the leg ended), so just switch screens.
                                self.session = nil
                                self.fullTavliScreen = ft.isComplete ? .result : .transition
                            },
                            onExit: {
                                persistAutosave()
                                self.session = nil
                                self.leaveFullTavli()
                            })
                    }
                )
            } else if let pending = pendingHumanColor {
                OpeningRollView(humanColor: pending) { startingPlayer in
                    humanColor = pending
                    pendingHumanColor = nil
                    if fullTavli != nil {
                        // A Full Tavli leg (#144): the session keeps its own name/score.
                        match = nil
                        fullTavliScreen = nil
                    } else {
                        autosaveName = Self.newAutosaveName()
                        match = Self.newMatch(baseStartingPlayer: startingPlayer)
                    }
                    // A handicap (#148) for a single game or every game of a best-of-three;
                    // a Full Tavli leg plays the session's own setup (#246).
                    let handicap = fullTavli.map { $0.setupForCurrentLeg }
                        ?? HandicapPreferences.setupForNewGame(humanColor: pending, variant: pendingVariant)
                    session = Self.makeSession(humanColor: pending, startingPlayer: startingPlayer,
                                               variant: pendingVariant, handicap: handicap)
                } onBack: {
                    pendingHumanColor = nil
                    // Backing out of the first leg's roll cancels the (unplayed) Full
                    // Tavli session; later legs return to the between-legs screen.
                    if let ft = fullTavli {
                        if ft.completedLegs == 0 { leaveFullTavli() } else { fullTavliScreen = .transition }
                    }
                }
            } else if let ft = fullTavli, let screen = fullTavliScreen {
                switch screen {
                case .transition:
                    FullTavliTransitionView(state: ft,
                                            onStartNext: startFullTavliLeg,
                                            onExit: leaveFullTavli)
                case .result:
                    FullTavliResultView(state: ft,
                                        onPlayAgain: {
                                            leaveFullTavli()
                                            beginFullTavli(humanColor: ft.aiColor?.opponent)
                                        },
                                        onExit: leaveFullTavli)
                }
            } else {
                ModePickerView(store: store,
                               stats: statsStore.stats,
                               handicapStats: statsStore.handicapStats,
                               handicapAdjusted: statsStore.adjustedHandicapGames,
                               onPlay: {
                                   // The remembered setup (#189): colour (Random draws a
                                   // side now), variant and length from the new-game sheet.
                                   let color = AppSettings.preferredColor.resolve()
                                   if AppSettings.matchLength == .fullTavli {
                                       beginFullTavli(humanColor: color)
                                   } else {
                                       beginGame(humanColor: color, variant: AppSettings.variant)
                                   }
                               },
                               onTwoPlayer: {
                                   if AppSettings.matchLength == .fullTavli {
                                       beginFullTavli(humanColor: nil)
                                   } else {
                                       beginTwoPlayer(variant: AppSettings.variant)
                                   }
                               },
                               onResume: resume,
                               onPlayOnline: { showOnline = true })
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                persistAutosave()
                AnalysisService.app.flush()   // landed analysis not yet written (#243)
            }
        }
        #if DEBUG
        .debugReviewSample()   // `-debugReviewSample`: straight into a sample review (#232)
        .debugOnlineDice()     // `-debugOnlineDice`: an offline online game with the shared dice (#272)
        .debugAccount()        // `-debugAccount`: the Server v1 account sheet (#285)
        .screenshotScenes()    // `-screenshotReview` / `-screenshotDrill` / `-screenshotHandicap` (#184)
        #endif
        // Online (#134): sign in to Game Center at launch without UI, so a tapped turn
        // notification reaches the listener; the sign-in sheet waits for Play Online.
        .onAppear { online.authenticate(presentUI: false) }
        .onChange(of: online.showOnlineRequested) { _, requested in
            guard requested else { return }
            online.showOnlineRequested = false
            showOnline = true
        }
        // Wire each live session's game-over hook to record the human's W/L (#64).
        // Done here (keyed on session identity) rather than at the static creation
        // sites so it covers every entry point uniformly — opening roll, resume from
        // the picker, and cold-launch auto-resume — while skipping the deterministic
        // UI-test game so test runs never write stats. Runs synchronously (no await)
        // well before any game can end, so the hook is always armed in time.
        .task(id: session.map(ObjectIdentifier.init)) {
            // Background analysis (#243): every offline game is analysed as it is played
            // (both sides, on the service's own boards, paused while the computer
            // thinks), and keeps going after it ends; the review just reads it.
            session?.analysisService = .app
            guard let session,
                  !ProcessInfo.processInfo.arguments.contains("-uiTestGame"),
                  !Self.isDebugSeededGame else { return }
            // `onGameFinished` (#143) fires for every end — wins of 1 or 2 points and
            // draws. The vs-AI W/L record only takes decided vs-AI games (a draw is
            // neither; a two-player game isn't the human's record).
            session.onGameFinished = { [statsStore, humanColor, gameLog, autosaveName, store] winner, points in
                if let winner, session.aiColor != nil {
                    // A handicap game (#148) is logged apart from the vs-Computer record.
                    statsStore.record(humanWon: winner == humanColor, handicap: session.record.handicap)
                }
                // Persist EVERY finished game to the append-only log (#104), regardless
                // of outcome or whether it was ever manually saved. `record.outcome` is
                // already set by the time this hook fires. Synchronous, like the autosave.
                // Carry the background analysis so far (#146, #243) so the review opens on
                // it; later results are merged in by the service as they land. Empty (no
                // model) keeps the file at schema v1.
                let name = autosaveName.isEmpty ? Self.newAutosaveName() : autosaveName
                let entries = session.inPlayAnalysis
                let save = GameSave(record: session.record, name: name,
                                    analysis: entries.isEmpty ? nil : entries)
                try? gameLog.append(save)
                // Advance the best-of-three score (#145), if a match is in progress, so
                // the match scoreboard + transition overlay reflect this game's result.
                // Points count (a double game scores 2); a draw scores nothing.
                self.match?.recordGame(winner: winner, points: points)
                // Advance the Full Tavli session (#144) and persist the between-legs
                // state right away (finished leg + updated score), so quitting on the
                // leg overlay or the transition screen resumes exactly there.
                if var ft = self.fullTavli {
                    // The leg's handicap, as adjusted during it (#236), runs on (#246).
                    ft.carryHandicap(from: session.record)
                    ft.recordGame(winner: winner, points: points)
                    self.fullTavli = ft
                    Self.persist(session: session, fullTavli: ft, name: name, store: store)
                }
            }
        }
    }

    /// Write the current game to the single auto-save slot — on every move (#61),
    /// and when backgrounding or leaving. Overwriting one reserved slot means only
    /// the **last** in-progress game is ever kept. The game is stored under its
    /// timestamped `autosaveName` (the "Continue last game" badge is added by the
    /// picker row, not the name). A finished game is cleared instead (completed
    /// games are never resumed); on the picker (`session == nil`) the prior
    /// auto-save is left intact.
    private func persistAutosave() {
        guard let session, !Self.isDebugSeededGame else { return }
        let name = autosaveName.isEmpty ? Self.newAutosaveName() : autosaveName
        Self.persist(session: session, fullTavli: fullTavli, name: name, store: store)
    }

    /// The autosave write itself. A finished game is cleared — except a finished leg of
    /// an unfinished Full Tavli session (#144), which is kept together with the session
    /// so a relaunch lands on the between-legs screen. A completed session is cleared.
    @MainActor
    private static func persist(session: GameSession, fullTavli: FullTavliSession?,
                                name: String, store: SaveStore) {
        if session.isTerminal && (fullTavli?.isComplete ?? true) {
            store.clearAutosave()
        } else {
            try? store.writeAutosave(session.snapshot(name: name, fullTavli: fullTavli))
        }
    }

    // ── Full Tavli (#144) ────────────────────────────────────────────────────

    /// Start a Full Tavli session: vs the AI as `humanColor`, or two players (`nil`).
    /// Its Plakoto leg follows the variant preference. vs-AI needs every leg's model
    /// (the start screen shows "Computer not available yet" otherwise).
    private func beginFullTavli(humanColor color: EngineColor?) {
        // One handicap for all three legs (#246): dice, rerolls, hints, moves first.
        let ft = AppSettings.newFullTavli(aiColor: color?.opponent,
                                          handicap: HandicapPreferences.setupForFullTavli(humanColor: color))
        if color != nil && !ft.isAIAvailable() { return }
        match = nil
        fullTavli = ft
        autosaveName = Self.newFullTavliName()
        startFullTavliLeg(ft)
    }

    /// Start the session's current leg (from the transition screen).
    private func startFullTavliLeg() {
        guard let ft = fullTavli else { return }
        startFullTavliLeg(ft)
    }

    /// Start `ft`'s current leg with that leg's variant (and its own model vs the AI).
    /// The starter follows the same rules as a single game: vs the AI the
    /// starting-player setting (fixed starter or the opening-roll ceremony); two
    /// players `variant.startingPlayer(default: .white)`. A handicap's "moves first"
    /// side starts every leg (#246), with no opening roll.
    private func startFullTavliLeg(_ ft: FullTavliSession) {
        guard let variant = ft.currentVariant else { return }
        let setting = GameVariantSetting(variant: variant)
        let human = ft.aiColor?.opponent ?? .white
        let handicap = ft.setupForCurrentLeg
        humanColor = human
        if ft.aiColor != nil {
            if let starter = handicap?.forcedStarter
                ?? AppSettings.startingPlayer.startingPlayer(humanColor: human) {
                fullTavliScreen = nil
                session = Self.makeSession(humanColor: human, startingPlayer: starter, variant: setting,
                                           handicap: handicap)
            } else {
                pendingVariant = setting
                pendingHumanColor = human   // the opening-roll ceremony, as for a single game
            }
        } else {
            fullTavliScreen = nil
            session = Self.makeSession(humanColor: .white,
                                       startingPlayer: ft.startingPlayer(default: variant.startingPlayer(default: .white)),
                                       variant: setting, vsAI: false, handicap: handicap)
        }
    }

    /// Leave the Full Tavli screens/state for the menu. The autosave is untouched, so
    /// an unfinished session stays resumable from "Continue last game".
    private func leaveFullTavli() {
        fullTavli = nil
        fullTavliScreen = nil
    }

    /// Start a new vs-AI game (or match) as `color` under `variant` (#143). The
    /// starting-player setting decides whether to run the opening-roll ceremony (#33)
    /// or seed the starter directly (#77). When best-of-three is selected (#145), a
    /// `MatchState` is created at the point the game-1 starter becomes known (here, or
    /// in the opening-roll completion). A variant without a bundled model never gets
    /// here (the start screen disables vs-AI play for it).
    private func beginGame(humanColor color: EngineColor, variant: GameVariantSetting) {
        guard AppSettings.aiAvailable(variant) else { return }
        leaveFullTavli()
        // Handicap (#148, every variant since #246): single game or best-of-three; "moves
        // first" skips the opening roll.
        let handicap = HandicapPreferences.setupForNewGame(humanColor: color, variant: variant)
        if let starter = handicap?.forcedStarter
            ?? AppSettings.startingPlayer.startingPlayer(humanColor: color) {
            humanColor = color
            autosaveName = Self.newAutosaveName()
            match = Self.newMatch(baseStartingPlayer: starter)
            session = Self.makeSession(humanColor: color, startingPlayer: starter, variant: variant,
                                       handicap: handicap)
        } else {
            pendingVariant = variant
            pendingHumanColor = color   // run the opening-roll ceremony
        }
    }

    /// Start a two-player (pass-and-play) game under `variant` (#143) — available for
    /// every variant, model or not. The board faces White; the variant picks the
    /// starter (`startingPlayer(default:)`: random for the bkgm-rules variants, White
    /// for house Plakoto). A single game: no match, no vs-AI record.
    private func beginTwoPlayer(variant: GameVariantSetting) {
        humanColor = .white
        autosaveName = Self.newAutosaveName()
        match = nil
        leaveFullTavli()
        let handicap = HandicapPreferences.setupForNewGame(humanColor: nil, variant: variant)   // #148
        session = Self.makeSession(humanColor: .white,
                                   startingPlayer: handicap?.forcedStarter
                                       ?? variant.variant.startingPlayer(default: .white),
                                   variant: variant, vsAI: false, handicap: handicap)
    }

    /// A fresh best-of-three `MatchState` when match mode is selected (#145), else
    /// `nil` for a single game. The base starter is game 1's starter; later games
    /// alternate from it.
    private static func newMatch(baseStartingPlayer: EngineColor) -> MatchState? {
        AppSettings.matchLength == .bestOfThree
            ? MatchState.bestOfThree(baseStartingPlayer: baseStartingPlayer)
            : nil
    }

    /// The variant of the game on screen (the match's variant), else the setting.
    private var currentVariant: GameVariantSetting {
        session.map { GameVariantSetting(variant: $0.game.variant) } ?? AppSettings.variant
    }

    /// Start the next game of the current match (#145), without an opening-roll
    /// ceremony — the starter alternates deterministically from the match's base.
    private func startNextMatchGame() {
        guard let match else { return }
        // A handicap match (#148) keeps the setup the match started with — its final
        // values if it was adjusted during the game (#236) — every game gets fresh tokens
        // and is not "adjusted" itself, and "moves first" overrides the alternating
        // starter. A setup adjusted down to nothing makes the next game a normal one.
        let handicap = session?.record.handicap?.forNextGame
        autosaveName = Self.newAutosaveName()
        session = Self.makeSession(humanColor: humanColor,
                                   startingPlayer: HandicapSetup.startingPlayer(
                                       for: handicap, default: match.currentStartingPlayer),
                                   variant: currentVariant,
                                   handicap: handicap)
    }

    /// Start a brand-new match after one has finished (#145, the win overlay's
    /// "Rematch"): same colour and variant, re-resolving the starter per Settings.
    private func startRematch() {
        let variant = currentVariant
        session = nil
        match = nil
        beginGame(humanColor: newGameColor, variant: variant)
    }

    /// The colour for a "Play again"/"Rematch": the same colour, unless Play as is
    /// Random (#189), which draws a side for every new game.
    private var newGameColor: EngineColor {
        AppSettings.preferredColor == .random ? AppSettings.preferredColor.resolve() : humanColor
    }

    /// The agent for resuming `save` (its own variant's model), or `.unavailable` when
    /// the save is vs-AI but that model isn't bundled — resuming it would silently play
    /// random moves (#143), so the picker disables such saves.
    private enum ResumeAgent { case agent(Agent?), unavailable }

    private static func resumeAgent(for save: GameSave) -> ResumeAgent {
        guard save.aiColor != nil else { return .agent(nil) }   // two-player save
        let config = GameConfig(variantID: save.variant)
        guard ModelCatalog.main.isAvailable(config.variant) else { return .unavailable }
        // A vs-AI Full Tavli session (#144) needs every leg's model, not just this one.
        if let ft = save.fullTavli, ft.aiColor != nil, !ft.isAIAvailable() { return .unavailable }
        return .agent(GameSession.makeAgent(config: config))
    }

    /// What a save resumes into: a live game (`session`), or — for a Full Tavli save
    /// whose leg is already over (#144) — the between-legs / final screen.
    private struct Resumed {
        var session: GameSession?
        var humanColor: EngineColor
        var name: String
        var fullTavli: FullTavliSession?
        var screen: FullTavliScreen?
    }

    /// Rebuild what `save` resumes into, or `nil` when it can't be (vs-AI model missing).
    @MainActor
    private static func prepareResume(_ save: GameSave) -> Resumed? {
        guard case .agent(let agent) = resumeAgent(for: save) else { return nil }
        let human = save.aiColor.flatMap { EngineColor(rawValue: $0) }?.opponent ?? .white
        var fullTavli = save.fullTavli
        if var ft = fullTavli {
            // Reconcile the session with its saved leg (#144): between legs / complete
            // show the session screens; mid-leg resumes the game below.
            let point = ft.resume(savedGame: save.record)
            fullTavli = ft
            switch point {
            case .betweenLegs:
                return Resumed(session: nil, humanColor: human, name: save.name,
                               fullTavli: ft, screen: .transition)
            case .complete:
                return Resumed(session: nil, humanColor: human, name: save.name,
                               fullTavli: ft, screen: .result)
            case .inLeg:
                break
            }
        }
        // A two-player handicap game (#148) needs the net for its dice/hints — also when
        // they are only switched on mid-game (#236), so any handicap gets one.
        let handicapAgent = agent == nil && save.handicap != nil
            ? GameSession.makeAgent(config: GameConfig(variantID: save.variant)) : nil
        let s = GameSession.resume(from: save, agent: agent,
                                   searchConfig: AppSettings.searchConfig,
                                   animationTimings: AppSettings.animationTimings,
                                   autoRoll: AppSettings.autoRoll,
                                   handicapAgent: handicapAgent)
        return Resumed(session: s, humanColor: human, name: save.name,
                       fullTavli: fullTavli, screen: nil)
    }

    /// Load a saved game (from the picker list) and switch into it, carrying its
    /// name forward so the auto-save keeps the same identity.
    private func resume(_ meta: SaveMetadata) {
        guard var save = try? store.load(filename: meta.filename) else { return }
        // A manual save is a fork point that can be loaded and finished more than once:
        // give each load its own game id, so a second ending gets its own game-log entry
        // instead of overwriting the first (#104). The autosave is the same game resumed,
        // and keeps its id so its background analysis follows it (#243).
        if !meta.isAutosave { save.gameId = UUID() }
        guard let resumed = Self.prepareResume(save) else { return }
        humanColor = resumed.humanColor
        autosaveName = resumed.name
        match = nil   // a resumed single game is standalone (#145); Full Tavli resumes (#144)
        fullTavli = resumed.fullTavli
        fullTavliScreen = resumed.screen
        resumed.session?.start()
        session = resumed.session
    }

    /// The auto-save game to resume on launch, if one exists and is still in
    /// progress. A finished auto-save is discarded so launch lands on the picker —
    /// unless it is a finished leg of a Full Tavli session (#144), which resumes on the
    /// between-legs screen. A vs-AI save whose model is missing stays on disk but isn't
    /// resumed.
    @MainActor
    private static func autoResume() -> Resumed? {
        let store = SaveStore.default()
        guard let save = store.loadAutosave(), let resumed = prepareResume(save) else { return nil }
        if resumed.screen == .result { store.clearAutosave() }   // shown once, then gone
        if let s = resumed.session {
            guard !s.isTerminal else {
                store.clearAutosave()
                return nil
            }
            s.start()
        }
        return resumed
    }

    /// A timestamped game name ("Game · <date>"), the same convention the manual
    /// save dialog defaults to. Generated once per game and kept stable across that
    /// game's per-move auto-saves.
    private static func newAutosaveName() -> String {
        String(localized: "Game · ") + autosaveNameFormatter.string(from: Date())
    }

    /// The name every leg of a Full Tavli session is saved/logged under (#144).
    private static func newFullTavliName() -> String {
        String(localized: "Full Tavli · ") + autosaveNameFormatter.string(from: Date())
    }

    private static let autosaveNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Whether this launch plays a DEBUG-seeded game (`-debugHandicapBearOff`, #236, or
    /// the `-screenshotGame` scene, #184): never autosaved, logged or counted. Always
    /// `false` in a release build.
    private static var isDebugSeededGame: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-debugHandicapBearOff")
            || ProcessInfo.processInfo.arguments.contains("-debugFevgaBearOff")
            || ProcessInfo.processInfo.arguments.contains("-debugFevgaBearOffBlack")
            || ScreenshotScenes.isGame
        #else
        return false
        #endif
    }

    #if DEBUG
    /// `-debugFevgaBearOff` / `-debugFevgaBearOffBlack` (#270): a two-player Fevga game in a
    /// bear-off, 6 White and 4 Black checkers off, the side named by the argument to move
    /// with a 5 + 3 that bears off. For screenshots of the trays beside each home.
    @MainActor
    private static func debugFevgaBearOffSession() -> GameSession? {
        let args = ProcessInfo.processInfo.arguments
        let black = args.contains("-debugFevgaBearOffBlack")
        guard black || args.contains("-debugFevgaBearOff") else { return nil }
        let config = GameVariantSetting.fevga.config
        let session = GameSession(startingPlayer: black ? .black : .white, config: config,
                                  agent: nil, aiColor: nil,
                                  searchConfig: AppSettings.searchConfig,
                                  animationTimings: AppSettings.animationTimings,
                                  autoRoll: false)
        let board = session.game.board
        for i in board.points.indices { board.setPoint(i, pieces: []) }
        board.setPoint(25, pieces: Array(repeating: .white, count: 6))
        board.setPoint(20, pieces: [.white, .white])
        board.setPoint(22, pieces: [.white])
        board.setPoint(24, pieces: [.white, .white, .white, .white, .white, .white])
        board.setPoint(0, pieces: Array(repeating: .black, count: 4))
        board.setPoint(8, pieces: [.black, .black])
        board.setPoint(10, pieces: [.black, .black, .black])
        board.setPoint(12, pieces: [.black, .black, .black, .black, .black, .black])
        session.start()
        session.setDice(5, 3)
        if args.contains("-debugFevgaSelect") { session.selectPoint(black ? 8 : 20) }   // shows the tray target
        return session
    }

    /// `-debugHandicapBearOff` (#236): you (White) vs the computer in a house-Plakoto
    /// handicap game — you: 2 rerolls, 3 hints, a 2-checker head start; the computer:
    /// moderate hybrid weighted dice — seeded straight into a bear-off with 12 White and 10 Red
    /// checkers off, White to roll. For screenshots of the two-digit counters and the
    /// handicap card; `nil` without the argument.
    @MainActor
    private static func debugHandicapSession() -> GameSession? {
        guard ProcessInfo.processInfo.arguments.contains("-debugHandicapBearOff") else { return nil }
        let setup = HandicapSetup(white: HandicapItems(headStart: 2, rerolls: 2, hints: 3),
                                  black: HandicapItems(weightedDice: WeightedDice(mode: .hybrid,
                                                                                  level: HandicapDiceStrength.moderate.rawValue)))
        let config = GameVariantSetting.plakoto.config
        let session = GameSession(startingPlayer: .white, config: config,
                                  agent: GameSession.makeAgent(config: config), aiColor: .black,
                                  searchConfig: AppSettings.searchConfig,
                                  animationTimings: AppSettings.animationTimings,
                                  autoRoll: false, handicap: setup,
                                  aiLevel: AppSettings.aiLevel)
        let board = session.game.board
        for i in board.points.indices { board.setPoint(i, pieces: []) }
        board.setPoint(25, pieces: Array(repeating: .white, count: 12))
        board.setPoint(20, pieces: [.white])
        board.setPoint(22, pieces: [.white, .white])
        board.setPoint(0, pieces: Array(repeating: .black, count: 10))
        for p in 2...6 { board.setPoint(p, pieces: [.black]) }
        session.start()
        return session
    }
    #endif

    /// A new session under `variant` (#143): vs-AI with that variant's model, or a
    /// two-player game (`vsAI: false`, no agent).
    @MainActor
    private static func makeSession(humanColor: EngineColor, startingPlayer: EngineColor,
                                    variant: GameVariantSetting = .plakoto,
                                    vsAI: Bool = true,
                                    handicap: HandicapSetup? = nil) -> GameSession {
        let config = variant.config
        // Two players have no agent; a handicap game gets one (#148) — even if nothing
        // needs the net yet, the handicap card can switch on weighted dice / hints (#236).
        let handicapAgent = !vsAI && handicap?.isActive == true
            ? GameSession.makeAgent(config: config) : nil
        let session = GameSession(
            startingPlayer: startingPlayer,
            config: config,
            agent: vsAI ? GameSession.makeAgent(config: config) : nil,
            aiColor: vsAI ? humanColor.opponent : nil,
            searchConfig: AppSettings.searchConfig,
            animationTimings: AppSettings.animationTimings,
            autoRoll: AppSettings.autoRoll,
            handicap: handicap,
            handicapAgent: handicapAgent,
            aiLevel: vsAI ? AppSettings.aiLevel : nil   // the opponent's strength (#231)
        )
        session.start()
        return session
    }
}

/// Which Full Tavli screen shows between legs (#144).
private enum FullTavliScreen: Equatable {
    case transition, result
}

/// Caramel start screen (#101, slimmed down in #174, quick play in #189). Top to bottom:
/// an icon bar (My Record · Saved games · Settings), the "Tavtav" wordmark, a "Continue
/// last game" card (only while an autosave exists), the play pair — a big "Play the
/// computer" button that starts the remembered setup at once (subtitle "Level 6 ·
/// Plakoto · Best of 3") beside a small square adjust button opening `NewGameSheet` —
/// then Two players / Play Online (same remembered variant + length). Without the model
/// the play button becomes an explanation card; the adjust button stays so another
/// variant can be picked. One column on a phone (fits a 13 mini without scrolling;
/// `FitOrScroll` for big Dynamic Type / landscape), two on iPad (Continue + Play left;
/// the other modes right).
private struct ModePickerView: View {
    let store: SaveStore
    let stats: HumanGameStats
    /// Handicap games' record (#148); its block shows only once one exists.
    var handicapStats: HumanGameStats = .empty
    /// How many of them were adjusted mid-game (#236), tagged in the block.
    var handicapAdjusted = 0
    /// Start a vs-AI game with the remembered setup (#189).
    let onPlay: () -> Void
    /// Start a two-player (pass-and-play) game of the selected variant (#143).
    let onTwoPlayer: () -> Void
    let onResume: (SaveMetadata) -> Void
    /// Enter the online multiplayer lobby (#134).
    let onPlayOnline: () -> Void

    @State private var saves: [SaveMetadata] = []

    @State private var showStats = false
    @State private var showSettings = false
    @State private var showSaves = false
    @State private var showNewGame = false
    /// Set by the sheet's Play: the game starts once the sheet has gone (#189).
    @State private var playAfterSheet = false

    // The remembered new-game setup (#189), edited in `NewGameSheet`. Defaults equal
    // the `AppSettings` accessors.
    @AppStorage(SettingsKey.preferredColor) private var preferredColor: PreferredColorSetting = .white
    @AppStorage(SettingsKey.matchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    @AppStorage(SettingsKey.variant) private var variant: GameVariantSetting = .plakotoStandard
    @AppStorage(SettingsKey.houseRules) private var houseRules = false
    @AppStorage(SettingsKey.aiLevel) private var aiLevel = AILevel.max

    private var isCompact: Bool { ChromeType.isCompact }

    private var setup: NewGameSetup {
        NewGameSetup(variant: variant, level: aiLevel, playAs: preferredColor, length: matchLength,
                     houseRules: houseRules)
    }

    private var autosave: SaveMetadata? { saves.first(where: \.isAutosave) }
    private var manualSaves: [SaveMetadata] { saves.filter { !$0.isAutosave } }

    /// Column width cap: one phone column / each iPad column.
    private var columnWidth: CGFloat { isCompact ? 440 : 380 }
    private var stackSpacing: CGFloat { isCompact ? 14 : 18 }

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                FitOrScroll {
                    VStack(spacing: isCompact ? 16 : 32) {
                        Text(verbatim: "Tavtav")
                            .font(ChromeType.wordmark)
                            .compactSingleLine()
                            .foregroundStyle(CaramelPalette.frameText)
                        if isCompact {
                            VStack(spacing: stackSpacing) {
                                leadColumn
                                trailColumn
                            }
                            .frame(maxWidth: columnWidth)
                        } else {
                            HStack(alignment: .top, spacing: 32) {
                                leadColumn.frame(width: columnWidth)
                                trailColumn.frame(width: columnWidth)
                            }
                        }
                    }
                    .padding(.horizontal, isCompact ? 16 : 40)
                    .padding(.bottom, isCompact ? 12 : 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            reload()
            #if DEBUG
            if ScreenshotScenes.isNewGame { showNewGame = true }   // App Store scene (#184)
            #endif
        }
        .sheet(isPresented: $showStats) { statsSheet }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSaves, onDismiss: reload) {
            SavedGamesSheet(store: store, onResume: { meta in
                showSaves = false
                onResume(meta)
            })
        }
        .sheet(isPresented: $showNewGame, onDismiss: {
            // Start only after the sheet is gone, so it isn't torn down mid-dismissal.
            if playAfterSheet {
                playAfterSheet = false
                onPlay()
            }
        }) {
            NewGameSheet(onPlay: {
                playAfterSheet = true
                showNewGame = false
            })
            .modifier(FormSheetSizing())
        }
    }

    // MARK: - Sections

    /// Continue + Play (the left column on iPad).
    private var leadColumn: some View {
        VStack(spacing: stackSpacing) {
            if let autosave {
                ContinueCard(meta: autosave) { onResume(autosave) }
            }
            if isCompact {
                playPair
            } else {
                // iPad: the play pair sits in its own card.
                playPair
                    .frame(maxWidth: .infinity)
                    .chromeCard(padding: 20)
            }
        }
    }

    /// The other modes (the right column on iPad).
    private var trailColumn: some View {
        VStack(spacing: stackSpacing) {
            twoPlayerButton
            onlineButton
        }
    }

    /// Settings, My Record and Saved games as icon buttons in the top-trailing corner.
    private var topBar: some View {
        HStack(spacing: isCompact ? 4 : 8) {
            Spacer()
            iconButton("chart.bar.fill", label: "My Record") { showStats = true }
            iconButton("tray.full.fill", label: "Saved games") { showSaves = true }
            iconButton("gearshape.fill", label: "Settings") { showSettings = true }
        }
        .padding(.horizontal, isCompact ? 8 : 20)
        .padding(.top, isCompact ? 0 : 12)
    }

    private func iconButton(_ systemName: String, label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(ChromeType.title3)
                .foregroundStyle(ChromeKit.iconInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The play button (or, without the model, its explanation) + the adjust button,
    /// both the same height.
    private var playPair: some View {
        HStack(spacing: isCompact ? 10 : 12) {
            playCard
            adjustButton
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Play the computer" + the remembered setup as a subtitle (#189); starts at once.
    /// Without the model, an explanation in its place (#143) — never a silently random
    /// opponent.
    @ViewBuilder
    private var playCard: some View {
        if !setup.aiAvailable {
            VStack(spacing: 6) {
                Text("Play the computer")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Text(setup.unavailableMessage)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(CompactCard())
        } else {
            Button(action: onPlay) {
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Play the computer")
                            .font(ChromeType.headline.bold())
                        PlayAsChecker(setting: preferredColor, size: isCompact ? 16 : 18)
                    }
                    summaryLine
                }
                .padding(.vertical, isCompact ? 6 : 8)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            .accessibilityIdentifier("playVsComputer")
        }
    }

    /// The play button's subtitle — "Level 6 · Plakoto · Best of 3" — and, with House
    /// rules on for a Plakoto game (or Full Tavli), the wolf tag (#258): beside it when it
    /// fits (iPad), else on a line of its own under it (a phone; the button grows a little).
    @ViewBuilder
    private var summaryLine: some View {
        let text = Text(setup.summary)
            .font(ChromeType.subheadline.weight(.medium))
            .opacity(0.92)
            .lineLimit(1)
        if setup.showsHouseRulesTag {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { text; HouseRulesTag() }
                VStack(spacing: 4) { text.minimumScaleFactor(0.75); HouseRulesTag() }
            }
        } else {
            text.minimumScaleFactor(0.75)
        }
    }

    /// Opens the new-game sheet (#189).
    private var adjustButton: some View {
        Button { showNewGame = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(ChromeType.title3.weight(.semibold))
                .frame(width: isCompact ? 36 : 40)
                .frame(maxHeight: .infinity)
        }
        .buttonStyle(ChromeButton(role: .secondary))
        .accessibilityLabel("Game setup")
        .accessibilityIdentifier("newGameSetup")
    }

    /// Two players on this device (#143) — works for every variant, model or not.
    private var twoPlayerButton: some View {
        secondaryRow(icon: "person.2",
                     // Names the device it runs on (#109).
                     title: UIDevice.current.userInterfaceIdiom == .phone
                        ? String(localized: "Two players on this iPhone")
                        : String(localized: "Two players on this iPad"),
                     action: onTwoPlayer)
    }

    /// Online multiplayer (#134).
    private var onlineButton: some View {
        secondaryRow(icon: "globe", title: String(localized: "Play Online"), action: onPlayOnline)
    }

    private func secondaryRow(icon: String, title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 28)
                Text(title)
                Spacer(minLength: 8)
                DirectionalSymbol("chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
    }

    /// Fitted stats sheet (#101): explicit Done affordance, sized to the card
    /// rather than the near-fullscreen system default.
    private var statsSheet: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            // A phone in landscape (#109) can't fit the 480 pt card; scroll there.
            FitOrScroll(enabled: ChromeType.isCompact) {
                VStack(spacing: 16) {
                    HStack {
                        Text("My Record")
                            .font(ChromeType.title3.bold())
                            .foregroundStyle(ChromeTheme.ink)
                        Spacer()
                        Button("Done") { showStats = false }
                            .buttonStyle(ChromeButton(role: .secondary))
                    }
                    .padding(.horizontal, ChromeType.isCompact ? 16 : 24)
                    .padding(.top, 16)
                    Spacer(minLength: 0)
                    StatsPanelView(stats: stats)
                        .padding(.horizontal, ChromeType.isCompact ? 16 : 24)
                    if handicapStats.total > 0 {
                        HandicapRecordBlock(stats: handicapStats, adjusted: handicapAdjusted)
                            .padding(.horizontal, ChromeType.isCompact ? 16 : 24)
                            .padding(.top, 12)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .presentationDetents([.height(handicapStats.total > 0 ? 680 : 480)])
        .presentationDragIndicator(.visible)
    }

    private func reload() { saves = store.list() }
}

/// The new-game sheet's iPad size (#189): a form-width sheet as tall as its content (so
/// Play is never below the fold) where the system offers
/// it (iOS 18+); the iOS 17 default sheet otherwise. No effect on a phone.
private struct FormSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.form.fitted(horizontal: false, vertical: true))
        } else {
            content
        }
    }
}

/// A `.chromeCard()` on a phone only — on iPad the play section is already a card.
private struct CompactCard: ViewModifier {
    func body(content: Content) -> some View {
        if ChromeType.isCompact { content.chromeCard(padding: 14) } else { content }
    }
}

/// "Continue last game" (#61): the autosave as one tappable card — badge, name and
/// a variant · date · moves line. Disabled (with a badge) when its vs-AI model is
/// missing (#143).
private struct ContinueCard: View {
    let meta: SaveMetadata
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(ChromeType.title2)
                    .foregroundStyle(ChromeTheme.undoTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue last game")
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    Group {
                        Text(SaveCopy.mode(meta))
                        Text(SaveCopy.detail(meta))
                    }
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                if SaveCopy.resumable(meta) {
                    DirectionalSymbol("chevron.right")
                        .font(ChromeType.callout.bold())
                        .foregroundStyle(ChromeKit.inkSecondary)
                } else {
                    AIUnavailableBadge()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chromeCard(padding: ChromeType.isCompact ? 14 : 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!SaveCopy.resumable(meta))
        .accessibilityIdentifier("continueLastGame")
    }
}

/// Shared save-row wording + the resumability gate (#143/#144).
private enum SaveCopy {
    /// A vs-AI save needs its variant's model; a vs-AI Full Tavli save every leg's.
    static func resumable(_ meta: SaveMetadata) -> Bool {
        guard meta.isVsAI else { return true }
        if let ft = meta.fullTavli { return ft.isAIAvailable() }
        return AppSettings.aiAvailable(GameVariantSetting(variantID: meta.variantID))
    }

    /// "Plakoto · House rules", "Fevga · two players", "Full Tavli · Portes" — the save's
    /// own rule set (#258), never the current switch.
    static func mode(_ meta: SaveMetadata) -> String {
        let variant = GameVariantSetting(variantID: meta.variantID)
        let mode = meta.isVsAI ? variant.name
                               : String(localized: "\(variant.name) · two players")
        return meta.fullTavli != nil ? String(localized: "Full Tavli · \(mode)") : mode
    }

    /// "17 Nov 2026 at 10:02 · 12 moves".
    static func detail(_ meta: SaveMetadata) -> String {
        let when = dateFormatter.string(from: meta.savedAt)
        let moves = meta.plyCount == 1 ? String(localized: "1 move")
                                       : String(localized: "\(meta.plyCount) moves")
        return String(localized: "\(when) · \(moves)")
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// The "Saved games" sheet (#174): the manual saves (the autosave is the start
/// screen's Continue card), each resumable by tap and deletable.
private struct SavedGamesSheet: View {
    let store: SaveStore
    let onResume: (SaveMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saves: [SaveMetadata] = []

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("Saved games")
                        .font(ChromeType.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(ChromeButton(role: .secondary))
                }
                if saves.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(ChromeType.title2)
                        Text("No saved games yet")
                            .font(ChromeType.body.weight(.semibold))
                        Text("Save a game from its menu to come back to it later.")
                            .font(ChromeType.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(ChromeKit.inkSecondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(saves) { meta in
                                SavedGameRow(meta: meta,
                                             onResume: { onResume(meta) },
                                             onDelete: { delete(meta) })
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(ChromeType.isCompact ? 16 : 24)
            .frame(maxWidth: 560)
        }
        .presentationDragIndicator(.visible)
        .onAppear(perform: reload)
    }

    private func reload() { saves = store.list().filter { !$0.isAutosave } }

    private func delete(_ meta: SaveMetadata) {
        try? store.delete(filename: meta.filename)
        reload()
    }
}

/// One saved-game row: name + subtitle (variant, when, how many plies) with a
/// trailing delete button. Tapping the body resumes the game.
private struct SavedGameRow: View {
    let meta: SaveMetadata
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onResume) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(ChromeType.title3)
                        .foregroundStyle(ChromeKit.inkDim(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(ChromeType.body.weight(.semibold))
                            .foregroundStyle(CaramelPalette.frameText)
                        Group {
                            Text(SaveCopy.mode(meta))
                            Text(SaveCopy.detail(meta))
                        }
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A vs-AI save of a variant whose model isn't bundled can't be resumed
            // without a silently random opponent (#143).
            .disabled(!SaveCopy.resumable(meta))
            .opacity(SaveCopy.resumable(meta) ? 1 : 0.5)
            if !SaveCopy.resumable(meta) { AIUnavailableBadge() }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(ChromeType.body)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ChromeKit.cardColor)
        .cornerRadius(ChromeKit.buttonRadius)
        .shadow(color: ChromeKit.cardShadow, radius: 5, x: 0, y: 2)
    }
}

#Preview {
    RootView()
}
