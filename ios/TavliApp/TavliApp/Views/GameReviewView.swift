import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color

/// #62 — post-game review, the iPad analogue of the CLI's `review` command. A
/// **full-screen, board-centric** mode: the position faced fills the screen, with a
/// panel showing what was played vs the AI's best and the cost, and Prev/Next (or
/// swipe) to page through the moves. Evaluations **stream in** as they're found, so the
/// first move shows immediately while the rest analyze in the background.
///
/// #233 — built around your own moves: a summary card (accuracy, mistake counts, dice
/// luck vs decisions) heads the detail; the board always compares your move (amber)
/// with the best (blue); a "My moves · Mistakes · All moves" filter scopes Prev/Next,
/// the swipe and the chart scrub; cards are numbered by turn like the Moves sheet; a
/// move's level (`MoveSeverity` ?! / ? / ??, #231) shows as a neutral badge.
///
/// #259 — on an iPhone in portrait the review is two pages, switched by a small
/// "Game · Moves" control at the top and opening on Game: the win-chance graph, the
/// summary, "Drill mistakes" and the list of your mistakes and blunders (a row or a
/// graph tap opens Moves at that ply); Moves = the board, Prev/Next, the move card and
/// the filter. iPad and iPhone landscape keep one page. Every layout draws the ply's
/// dice on the board, and the summary's rating line is live while the analysis runs.
/// Pure presentation — all analysis lives in `TavliEngine`.
struct GameReviewView: View {
    let record: GameRecord
    let agent: Agent?
    let humanColor: TavliEngine.Color
    /// The online opponent's display name (#233), so an online review reads "You" vs
    /// that name. `nil` offline: vs the computer the opponent is "Computer"; a
    /// two-player game (no AI side) names both sides White / Red.
    let opponentName: String?

    @StateObject private var model: GameReviewModel
    @Environment(\.dismiss) private var dismiss
    /// #185: under RTL the Prev/Next row mirrors (Next on the left), so a swipe to the
    /// right pages forward, like turning a right-to-left book.
    @Environment(\.layoutDirection) private var layoutDirection

    /// `plyNumber` of the move shown, or `nil` for the filter's first move. Keyed by
    /// ply (not index) so streamed-in plies never shift the card under you.
    @State private var selectedPly: Int?
    /// Drives the drill, launched full-screen from the review (#63).
    @State private var showDrill = false
    /// Which moves Prev/Next/swipe/scrub step through (#233); default your own choices.
    @State private var filter: ReviewFilter = .mine
    /// The page shown on an iPhone in portrait (#259); opens on the game overview.
    @State private var page: ReviewPage = .game

    /// #233: the navigation scope. `.mine` = your plies with a choice (forced skipped),
    /// `.mistakes` = your ? and ?? plies, `.all` = every evaluated ply, both sides.
    enum ReviewFilter: Hashable { case mine, mistakes, all }

    /// #259: the iPhone portrait pages — the whole game, or move by move.
    enum ReviewPage: Hashable { case game, moves }

    init(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color,
         opponentName: String? = nil) {
        self.record = record
        self.agent = agent
        self.humanColor = humanColor
        self.opponentName = opponentName
        _model = StateObject(wrappedValue: GameReviewModel())
        #if DEBUG
        // App Store screenshot scene (#184): open on the chosen move.
        if ScreenshotScenes.analysis(for: record.gameId) != nil {
            _selectedPly = State(initialValue: ScreenshotScenes.reviewPly)
            if ScreenshotScenes.isReviewMoves { _page = State(initialValue: .moves) }
        }
        #endif
    }

    /// Preview-only: seed a terminal phase so `#Preview`s skip analysis. `trajectory`
    /// seeds the full chart data set (#105).
    fileprivate init(previewPhase: GameReviewModel.Phase, humanColor: TavliEngine.Color = .white,
                     trajectory: [PlyEvaluation] = []) {
        self.record = GameRecord(startingPlayer: .white, aiColor: humanColor.opponent)
        self.agent = nil
        self.humanColor = humanColor
        self.opponentName = nil
        _model = StateObject(wrappedValue: GameReviewModel(preview: previewPhase, trajectory: trajectory))
    }

    private var flipped: Bool { humanColor == .black }
    /// The game's rules (#143): board layout (Portes bar) + win chance vs equity.
    private var variant: any GameVariant { GameConfig(variantID: record.variantID).variant }
    private var scale: EvalScale { EvalScale(variant: variant) }

    // ── Who's who (#233) ───────────────────────────────────────────────────────

    /// The local player: you vs the computer or online; `nil` in a two-player game.
    private var localColor: TavliEngine.Color? {
        record.aiColor != nil || opponentName != nil ? humanColor : nil
    }
    /// The same naming as the game chrome and the Moves sheet: You / Computer / the
    /// online name, or White / Red in a two-player game.
    private var naming: WinnerNaming {
        WinnerNaming(localColor: localColor,
                     opponentName: opponentName ?? String(localized: "Computer"))
    }
    /// The side drawn on top of the chart and in the Moves sheet's left column: you,
    /// or White in a two-player game.
    private var leadingColor: TavliEngine.Color { localColor ?? .white }
    /// Whether the opponent's mistakes are worth marking (#231): a human, or a
    /// computer below full strength.
    private var opponentCanErr: Bool { record.opponentCanErr(of: humanColor) }

    /// The turn number of a ply as the Moves sheet numbers it (#190): one row per
    /// full turn, the leading side's move first; when the other side started, its
    /// first move is turn 1 on its own.
    private func turnNumber(_ ply: Int) -> Int {
        record.startingPlayer == leadingColor ? (ply + 1) / 2 : ply / 2 + 1
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = ChromeLayout(proxy).isCompact
            ZStack {
                ChromeKit.pageColor.ignoresSafeArea()
                content
                // Floating Close while analysing / on a message screen. The review
                // itself lays Close out as part of its chrome on every layout (#193),
                // so it can never float over the board, chart or panel.
                if !isReviewing {
                    CloseButton { dismiss() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(compact ? 12 : 20)
                }
            }
        }
        .task { await model.run(record: record, agent: agent, humanColor: humanColor) }
        // Keep the card inside the filter: switching scope snaps to the nearest move
        // it contains (#132, #233).
        .onChange(of: filter) { _, _ in snapIntoFilter() }
        .fullScreenCover(isPresented: $showDrill) {
            DrillView(record: record, precomputed: model.result,
                      agent: agent, humanColor: humanColor)
        }
    }

    private var isReviewing: Bool {
        if case .reviewing = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .analyzing(let done, let total):
            centered {
                ProgressView().progressViewStyle(.circular).tint(ChromeTheme.ink)
                if total > 0 {
                    Text("Analyzing move \(done) of \(total)…")
                        .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
                } else {
                    Text("Analyzing your moves…")
                        .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
                }
            }
        case .unavailable:
            centered {
                Text("Review needs the AI model, which isn’t available.")
                    .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
            }
        case .nothingToReview:
            centered {
                Text("No moves to review.")
                    .font(.title3).foregroundStyle(ChromeTheme.ink.opacity(0.8))
            }
        case .reviewing(let finished):
            if model.chartEvaluations.isEmpty {
                centered { ProgressView().tint(ChromeTheme.ink) }
            } else {
                reviewMode(model.chartEvaluations, finished: finished)
            }
        }
    }

    // ── Filter + navigation (#233) ─────────────────────────────────────────────

    /// Whether you made any ? / ?? move — the Mistakes segment shows only then.
    private var hasMistakes: Bool {
        model.chartEvaluations.contains { $0.mover == humanColor && $0.severity >= .mistake }
    }
    /// The filter in force: Mistakes falls back to My moves once there are none
    /// (e.g. a deeper pass cleared the last one).
    private var activeFilter: ReviewFilter {
        filter == .mistakes && !hasMistakes ? .mine : filter
    }

    private func inFilter(_ e: PlyEvaluation) -> Bool {
        switch activeFilter {
        case .mine: return e.mover == humanColor && e.hadChoice
        case .mistakes: return e.mover == humanColor && e.severity >= .mistake
        case .all: return true
        }
    }

    /// Indices of the plies the filter steps through; every ply when it holds none
    /// (e.g. the streamed set has none of your moves yet).
    private func navigable(_ plies: [PlyEvaluation]) -> [Int] {
        let pool = plies.indices.filter { inFilter(plies[$0]) }
        return pool.isEmpty ? Array(plies.indices) : pool
    }

    /// Index of the move shown: the selected ply, else the filter's first move.
    private func currentIndex(_ plies: [PlyEvaluation]) -> Int {
        if let selectedPly, let i = plies.firstIndex(where: { $0.plyNumber == selectedPly }) {
            return i
        }
        return navigable(plies).first ?? 0
    }

    private func select(_ i: Int, in plies: [PlyEvaluation]) {
        guard plies.indices.contains(i) else { return }
        selectedPly = plies[i].plyNumber
    }

    /// Move to the filter's move nearest the current one, if it isn't in it already.
    private func snapIntoFilter() {
        let plies = model.chartEvaluations
        guard !plies.isEmpty else { return }
        let i = currentIndex(plies)
        let pool = navigable(plies)
        guard !pool.contains(i),
              let nearest = pool.min(by: { abs($0 - i) < abs($1 - i) }) else { return }
        select(nearest, in: plies)
    }

    /// Next index in `dir` (+1/−1) within the filter, or `i` when there's nowhere to
    /// go (so callers can disable the button).
    private func navIndex(from i: Int, dir: Int, in plies: [PlyEvaluation]) -> Int {
        let pool = navigable(plies)
        let next = dir > 0 ? pool.first(where: { $0 > i }) : pool.last(where: { $0 < i })
        return next ?? i
    }

    // ── Board-centric review mode ──────────────────────────────────────────────

    private func reviewMode(_ plies: [PlyEvaluation], finished: Bool) -> some View {
        let i = min(max(currentIndex(plies), 0), plies.count - 1)
        let eval = plies[i]
        // Scrubbing the chart lands on the filter's move nearest the tapped ply.
        let scrub: (Int) -> Void = { ply in
            guard let nearest = navigable(plies).min(by: {
                abs(plies[$0].plyNumber - ply) < abs(plies[$1].plyNumber - ply)
            }) else { return }
            select(nearest, in: plies)
        }
        return GeometryReader { proxy in
            let layout = ChromeLayout(proxy)
            Group {
                if layout.isCompact {
                    compactReviewMode(layout, eval: eval, i: i, plies: plies,
                                      finished: finished, onScrub: scrub)
                } else if layout.isLandscape {
                    // Board at full height; Close/Drill bar, the scrollable detail and
                    // Prev/Next in a 320 pt rail beside it.
                    HStack(alignment: .top, spacing: 0) {
                        boardArea(eval)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(12)
                        VStack(alignment: .leading, spacing: 16) {
                            topBar
                            ScrollView {
                                panelInfo(eval: eval, finished: finished, onScrub: scrub)
                                    .padding(.bottom, 8)
                            }
                            navRow(i: i, plies: plies)
                        }
                        .padding(.vertical, 16)
                        .frame(width: 320)
                        .padding(.trailing, 16)
                    }
                } else {
                    regularPortraitMode(proxy.size, eval: eval, i: i, plies: plies,
                                        finished: finished, onScrub: scrub)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // The swipe pages through moves wherever a board shows — not on the
            // iPhone's Game page (#259), which has none.
            .gesture(pagingGesture(current: i, plies: plies),
                     including: layout.mode == .compactPortrait && page == .game ? .subviews : .all)
        }
    }

    /// The best move the board draws: on your own plies with a choice, always (#233,
    /// no Compare toggle); never on the opponent's, where amber is just the move played.
    private func boardBestMove(_ eval: PlyEvaluation) -> [[Int]]? {
        eval.mover == humanColor && eval.hadChoice ? eval.bestMove : nil
    }

    /// The full board at the move's position with the move (and best) drawn on it.
    private func boardArea(_ eval: PlyEvaluation) -> some View {
        ZStack {
            BoardView(flipped: flipped)
            HandicapBoardCuesView(rules: record.replayConfig.handicapRules, flipped: flipped)   // #148 tier 2
            CheckersView(stacks: eval.boardStacks, flipped: flipped, variant: variant)
            // The move played in amber; on your moves the best in blue too, both marks on
            // shared points, blue alone when you played the best (#133, #232, #233).
            MoveHighlightView(playedMove: eval.playedMove, bestMove: boardBestMove(eval),
                              stacks: eval.boardStacks, flipped: flipped, variant: variant)
            // The ply's roll where it sits during play (#259).
            ReviewBoardDice(die1: eval.die1, die2: eval.die2)
        }
        .aspectRatio(1, contentMode: .fit)
        .boardLayoutDirection()   // #185: the physical board never mirrors
    }

    // ── Regular portrait (iPad, #193) ──────────────────────────────────────────

    /// Below this width the portrait detail is one column; above it, two.
    private static let portraitTwoColumnWidth: CGFloat = 700

    /// Close/Drill bar, the board as large as fits, Prev/Next pinned under it, then
    /// the detail in a scroll view — on a wide screen the move + filter column first,
    /// chart + summary beside it. Same pieces and order as the iPhone portrait review.
    private func regularPortraitMode(_ size: CGSize, eval: PlyEvaluation, i: Int,
                                     plies: [PlyEvaluation], finished: Bool,
                                     onScrub: @escaping (Int) -> Void) -> some View {
        let twoColumn = size.width >= Self.portraitTwoColumnWidth
        let side = Self.portraitBoardSide(size, twoColumn: twoColumn)
        return VStack(spacing: 14) {
            topBar
                .frame(width: side)
                .padding(.top, 12)
            boardArea(eval)
                .frame(width: side, height: side)
            navRow(i: i, plies: plies)
                .frame(width: side)
            ScrollView {
                Group {
                    if twoColumn {
                        HStack(alignment: .top, spacing: 28) {
                            VStack(alignment: .leading, spacing: 18) {
                                moveSection(eval: eval, finished: finished)
                                filterPicker
                            }
                            overviewSection(eval: eval, finished: finished, onScrub: onScrub)
                        }
                    } else {
                        panelInfo(eval: eval, finished: finished, onScrub: onScrub)
                    }
                }
                .frame(width: side)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The portrait board side: full width minus the gutters, shrunk only as far as
    /// needed to leave the bar, Prev/Next and a readable slice of the detail on
    /// screen (the rest scrolls).
    private static func portraitBoardSide(_ size: CGSize, twoColumn: Bool) -> CGFloat {
        let chrome: CGFloat = 12 + 48 + 44 + 3 * 14       // bar + Prev/Next + gaps
        let detail: CGFloat = twoColumn ? 250 : 340        // visible detail before scrolling
        let byHeight = size.height - chrome - detail
        let byWidth = size.width - 2 * 24
        return max(280, min(byWidth, byHeight))
    }

    // Navigation: Prev / Next, within the filter.
    private func navRow(i: Int, plies: [PlyEvaluation]) -> some View {
        let prev = navIndex(from: i, dir: -1, in: plies)
        let next = navIndex(from: i, dir: 1, in: plies)
        return HStack(spacing: 12) {
            Button { select(prev, in: plies) } label: {
                Label { Text("Prev") } icon: { DirectionalSymbol("chevron.left") }
            }
            .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            .disabled(prev == i).opacity(prev == i ? 0.4 : 1)
            Button { select(next, in: plies) } label: {
                Label { Text("Next") } icon: { DirectionalSymbol("chevron.right") }
            }
            .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            .disabled(next == i).opacity(next == i ? 0.4 : 1)
        }
    }

    /// Close + Drill on one bar (the drill button sized to its label; drilling is
    /// offered whenever you made a ? or ?? move). Every review layout leads with it.
    @ViewBuilder
    private var topBar: some View {
        if record.handicap?.altersDice == true {
            // Weighted dice / rerolls (#148): the review's chances assume fair dice.
            VStack(alignment: .leading, spacing: 6) {
                closeDrillBar
                HandicapReviewNote()
            }
        } else {
            closeDrillBar
        }
    }

    private var closeDrillBar: some View {
        HStack(spacing: 12) {
            CloseButton { dismiss() }
            Spacer(minLength: 0)
            if hasMistakes {
                Button("Drill mistakes") { showDrill = true }
                    .buttonStyle(ChromeButton(role: .secondary))
                    .fixedSize()
            }
        }
    }

    // ── Compact (iPhone, #109) ──────────────────────────────────────────────────

    /// Portrait: Close/Drill bar, the board edge-to-edge, Prev/Next pinned under it,
    /// and the detail in a scrollable column below.
    /// Landscape: the board at full safe height; Close/Drill, the scrollable detail
    /// and Prev/Next in a rail beside it.
    @ViewBuilder
    private func compactReviewMode(_ layout: ChromeLayout, eval: PlyEvaluation, i: Int,
                                   plies: [PlyEvaluation], finished: Bool,
                                   onScrub: @escaping (Int) -> Void) -> some View {
        if layout.mode == .compactLandscape {
            HStack(alignment: .top, spacing: ChromeLayout.compactRailGap) {
                boardArea(eval)
                    .frame(width: layout.boardSide, height: layout.boardSide)
                VStack(alignment: .leading, spacing: 10) {
                    topBar
                    ScrollView {
                        panelInfo(eval: eval, finished: finished, onScrub: onScrub)
                            .padding(.bottom, 8)
                    }
                    navRow(i: i, plies: plies)
                }
                .padding(.vertical, 8)
                .frame(width: layout.panelRect.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if page == .game {
            VStack(spacing: 8) {
                compactTopBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                ScrollView {
                    gamePage(plies: plies, selectedPly: eval.plyNumber, finished: finished,
                             width: layout.boardSide - 32, onScrub: onScrub)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(spacing: 8) {
                compactTopBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                boardArea(eval)
                    .frame(width: layout.boardSide, height: layout.boardSide)
                navRow(i: i, plies: plies)
                    .padding(.horizontal, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        moveSection(eval: eval, finished: finished)
                        filterPicker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // ── iPhone portrait pages (#259) ───────────────────────────────────────────

    /// Close, then the "Game · Moves" switch centred on the bar (+ the fair-dice note).
    @ViewBuilder
    private var compactTopBar: some View {
        let bar = ZStack {
            HStack {
                CloseButton { dismiss() }
                Spacer(minLength: 0)
            }
            ReviewPageSwitch(page: $page)
                .frame(maxWidth: 220)
                .padding(.horizontal, 52)   // clear of Close on a narrow phone
        }
        if record.handicap?.altersDice == true {
            VStack(alignment: .leading, spacing: 6) {
                bar
                HandicapReviewNote()
            }
        } else {
            bar
        }
    }

    /// Open the Moves page on `ply` (from the mistakes list or a graph tap).
    private func openMoves(at ply: Int) {
        selectedPly = ply
        withAnimation(.easeInOut(duration: 0.2)) { page = .moves }
    }

    /// The Game page: the graph full width and taller, the summary, "Drill mistakes",
    /// then your mistakes and blunders. A graph tap opens Moves at the nearest move
    /// of the filter; a row opens that move.
    private func gamePage(plies: [PlyEvaluation], selectedPly: Int, finished: Bool,
                          width: CGFloat, onScrub: @escaping (Int) -> Void) -> some View {
        let chartHeight = min(240, max(150, width * 0.5))
        let mistakes = plies.filter { $0.mover == humanColor && $0.severity >= .mistake }
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                chartTitle
                if model.firstPassComplete, plies.count >= 2 {
                    chart(selectedPly: self.selectedPly == nil ? nil : selectedPly,
                          height: chartHeight, tapOnly: true) { ply in
                        onScrub(ply)
                        withAnimation(.easeInOut(duration: 0.2)) { page = .moves }
                    }
                } else {
                    // The first pass is still running: the graph's place, quietly busy.
                    RoundedRectangle(cornerRadius: 10)
                        .fill(ChromeKit.secondaryFill)
                        .frame(height: chartHeight)
                        .overlay(ProgressView().tint(ChromeTheme.ink))
                }
            }
            summaryCard(finished: finished)
            if hasMistakes {
                Button("Drill mistakes") { showDrill = true }
                    .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            }
            if !mistakes.isEmpty {
                mistakeList(mistakes)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Mistakes", then one row per ? / ?? of yours: "Turn 14  ?? Blunder  −12% win
    /// chance ›". Where a row doesn't fit, every row drops the loss's unit, then the
    /// badge its name — the whole list steps down together, so the rows stay alike.
    private func mistakeList(_ mistakes: [PlyEvaluation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mistakes")
                .font(.caption).foregroundStyle(ChromeKit.inkDim(0.55))
            ViewThatFits(in: .horizontal) {
                mistakeRows(mistakes, badgeName: true, lossUnit: true)
                mistakeRows(mistakes, badgeName: true, lossUnit: false)
                mistakeRows(mistakes, badgeName: false, lossUnit: false)
            }
            .background(ChromeKit.cardColor, in: RoundedRectangle(cornerRadius: ChromeKit.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                        .stroke(ChromeKit.cardEdge, lineWidth: 1))
        }
    }

    private func mistakeRows(_ mistakes: [PlyEvaluation], badgeName: Bool,
                             lossUnit: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(mistakes.enumerated()), id: \.element.plyNumber) { k, e in
                if k > 0 { Divider().overlay(ChromeTheme.ink.opacity(0.08)) }
                Button { openMoves(at: e.plyNumber) } label: {
                    HStack(spacing: 8) {
                        mistakeRow(e, badgeName: badgeName, lossUnit: lossUnit)
                        DirectionalSymbol("chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ChromeKit.inkDim(0.45))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Turn \(turnNumber(e.plyNumber))") + Text(verbatim: ", "
                    + e.severity.localizedName + ", " + scale.lossLabel(e.absoluteGap)))
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func mistakeRow(_ e: PlyEvaluation, badgeName: Bool, lossUnit: Bool) -> some View {
        HStack(spacing: 8) {
            Text("Turn \(turnNumber(e.plyNumber))")
                .font(.callout.bold())
                .foregroundStyle(ChromeTheme.ink)
            SeverityBadge(severity: e.severity, showsName: badgeName)
            Spacer(minLength: 8)
            Text(verbatim: lossUnit ? scale.lossLabel(e.absoluteGap) : scale.lossGap(e.absoluteGap))
                .font(.callout.monospacedDigit())
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .lineLimit(1)
    }

    /// The detail, what changes as you page first: the move, the step filter, then the
    /// whole-game chart and the summary card.
    private func panelInfo(eval: PlyEvaluation, finished: Bool,
                           onScrub: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            moveSection(eval: eval, finished: finished)
            filterPicker
            overviewSection(eval: eval, finished: finished, onScrub: onScrub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The whole-game chart, then the summary card.
    private func overviewSection(eval: PlyEvaluation, finished: Bool,
                                 onScrub: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // Win-probability trajectory across the whole game, your side up (#233),
            // mistakes marked (#105). Shown once the 1-ply base pass is in (#103) — the
            // deeper passes refine it in place (needs ≥2 points to trace a line).
            if model.firstPassComplete, model.chartEvaluations.count >= 2 {
                VStack(alignment: .leading, spacing: 6) {
                    chartTitle
                    chart(selectedPly: eval.plyNumber, height: 96, tapOnly: false, onScrub: onScrub)
                }
            }

            summaryCard(finished: finished)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chartTitle: some View {
        Text(scale.isEquity ? LocalizedStringKey("Expected points through the game") : LocalizedStringKey("Win chance through the game"))
            .font(.caption).foregroundStyle(ChromeKit.inkDim(0.55))
    }

    /// The whole-game chart: scrubbed by drag beside the board, tapped on the iPhone's
    /// Game page (#259) — where a tap opens the move, and a drag still scrolls the page.
    private func chart(selectedPly: Int?, height: CGFloat, tapOnly: Bool,
                       onScrub: @escaping (Int) -> Void) -> some View {
        WinProbabilityChart(evaluations: model.chartEvaluations,
                            selectedPly: selectedPly,
                            marks: chartMarks,
                            topColor: leadingColor,
                            topLabel: naming.name(leadingColor),
                            bottomLabel: naming.name(leadingColor.opponent),
                            height: height,
                            tapOnly: tapOnly,
                            onScrub: onScrub)
    }

    /// Chart markers (#233): your ? / ?? by size + symbol; the opponent's quietly, and
    /// only when it can err.
    private var chartMarks: [Int: WinProbabilityChart.Mark] {
        var marks: [Int: WinProbabilityChart.Mark] = [:]
        for e in model.chartEvaluations where e.severity >= .mistake {
            if e.mover == humanColor {
                marks[e.plyNumber] = .mine(e.severity)
            } else if opponentCanErr {
                marks[e.plyNumber] = .opponent
            }
        }
        return marks
    }

    // ── Summary card (#233) ────────────────────────────────────────────────────

    /// "Accuracy 91% · 2 mistakes · 1 blunder" (counts only when > 0; inaccuracies are
    /// left out, #257 — nothing filters or drills them), then one dice-vs-decisions line
    /// (per-roll / per-move averages). #259: live — from the plies analysed so far, with
    /// a small spinner while the analysis runs; the numbers update in place. "No
    /// mistakes" waits for the finished analysis.
    @ViewBuilder
    private func summaryCard(finished: Bool) -> some View {
        let s = model.result.summary(for: humanColor, luck: model.partialLuck)
        let luckLine = luckText(s, finished: finished)
        if s.accuracy != nil || luckLine != nil || !finished {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    if let accuracy = s.accuracy {
                        accuracyText(accuracy, s)
                            .font(.callout)
                            .foregroundStyle(ChromeTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if finished, s.mistakes == 0, s.blunders == 0 {
                            Text("No mistakes — nicely played!")
                                .font(.callout.bold())
                                .foregroundStyle(ChromeTheme.ink)
                        }
                    }
                    if let luckLine {
                        Text(luckLine)
                            .font(.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !finished {
                    // Quiet: the analysis is still running; the numbers beside it update.
                    ProgressView()
                        .controlSize(.small)
                        .tint(ChromeKit.inkDim(0.45))
                        .accessibilityLabel("Analysis still running")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .chromeCard(padding: 14)
        }
    }

    /// " · " between summary items; Persian uses its comma, since a "·" next to a
    /// Persian digit reads like a zero (#185).
    private var separator: String { ChromeDigits.listSeparator }

    private func accuracyText(_ accuracy: Double, _ s: GameReviewSummary) -> Text {
        let pct = ChromeDigits.localized("\(Int(accuracy.rounded()))%")
        var text = Text("Accuracy \(pct)").bold()
        if s.mistakes > 0 {
            text = text + Text(verbatim: separator) + Text("\(s.mistakes) mistakes")
        }
        if s.blunders > 0 {
            text = text + Text(verbatim: separator) + Text("\(s.blunders) blunders")
        }
        return text
    }

    /// "Dice: +0.5% per roll for you · Your moves: −2.1% per move" — averages, so a
    /// long or wild game never reads past 100 %: the dice term is your mean luck per
    /// roll minus the opponent's (`GameReviewSummary.netLuckPerRoll`, passes included),
    /// the moves term your mean decision loss over your plies with a choice. Win
    /// chance, or equity for a 2-point variant, to one decimal (`EvalScale.points`).
    /// #259: from what is analysed so far — the dice term once both sides have a
    /// measured roll (or the analysis is done), the moves term once one of your moves
    /// is in; `nil` while neither is.
    private func luckText(_ s: GameReviewSummary, finished: Bool) -> String? {
        var parts: [String] = []
        if let net = s.netLuckPerRoll, finished || s.luckCoversBothSides {
            if abs(net) < 0.05 {
                parts.append(String(localized: "Dice: even"))
            } else {
                let favoured = net > 0 ? humanColor : humanColor.opponent
                let amount = scale.points(abs(net), signed: true, decimals: 1)
                parts.append(favoured == localColor
                    ? String(localized: "Dice: \(amount) per roll for you")
                    : String(localized: "Dice: \(amount) per roll for \(naming.name(favoured))"))
            }
        }
        if let perMove = s.decisionLossPerMove {
            let loss = scale.points(-perMove, signed: true, decimals: 1)
            parts.append(localColor != nil
                ? String(localized: "Your moves: \(loss) per move")
                : String(localized: "Moves by \(naming.name(humanColor)): \(loss) per move"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    // ── The move ───────────────────────────────────────────────────────────────

    /// Turn, mover, dice + level badge, then played vs best with the legend swatches.
    private func moveSection(eval: PlyEvaluation, finished: Bool) -> some View {
        let isMine = eval.mover == humanColor
        let showsSeverity = eval.severity != .none && (isMine || opponentCanErr)
        // The swatches are the legend: one only while its mark is on the board (#232).
        let drawn = MoveHighlightView.drawnMarks(playedMove: eval.playedMove,
                                                 bestMove: boardBestMove(eval))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    // Numbered like the Moves sheet (#190, #233).
                    Text("Turn \(turnNumber(eval.plyNumber))")
                        .font(.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                        .lineLimit(1)
                        .fixedSize()
                    MoverChip(name: naming.name(eval.mover), color: eval.mover)
                    // The dice are on the board (#259); the level sits on this line,
                    // down to its mark alone where the name doesn't fit.
                    if showsSeverity {
                        ViewThatFits(in: .horizontal) {
                            SeverityBadge(severity: eval.severity)
                            SeverityBadge(severity: eval.severity, showsName: false)
                        }
                    }
                    if !finished {
                        // Deeper passes still refining in the background (#103).
                        ProgressView().controlSize(.small)
                    }
                }
            }

            // Played vs best. For a ply with a choice we ALWAYS show the played line,
            // the best line, and a status line — so (a) the panel height is constant as
            // you page, keeping the controls below from jumping (#105/#132), and (b) the
            // text agrees with the board: "best move played" shows only when the moves
            // are actually identical, never just close in score (#103).
            VStack(alignment: .leading, spacing: 10) {
                moveLine(label: playedLabel(eval.mover), move: notation(eval, eval.playedMove),
                         pct: Double(eval.playedScore), swatch: drawn.played ? .played : nil)
                if eval.hadChoice {
                    moveLine(label: Text("Best move"), move: notation(eval, eval.bestMove),
                             pct: Double(eval.bestScore), swatch: drawn.best ? .best : nil)
                    Group {
                        if sameMove(eval.playedMove, eval.bestMove) {
                            Text(eval.mover == record.aiColor ? "Computer played the best ✓"
                                                              : "Best move played ✓")
                                .foregroundStyle(ChromeTheme.ink)
                        } else {
                            Text(scale.lossLabel(eval.absoluteGap))
                                .foregroundStyle(eval.severity >= .mistake ? ChromeTheme.ink
                                                                          : ChromeKit.inkSecondary)
                        }
                    }
                    .font(.callout.bold())
                    .padding(.leading, MoveMarkSwatch.size.width + 8)
                } else {
                    // Forced ply: a single legal move, nothing to choose (#131).
                    Text("Only move available")
                        .font(.callout.bold())
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .padding(.leading, MoveMarkSwatch.size.width + 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "You played" / "Computer played" / "Red played" (online: the opponent's name).
    private func playedLabel(_ mover: TavliEngine.Color) -> Text {
        if mover == localColor { return Text("You played") }
        if mover == record.aiColor { return Text("Computer played") }
        return Text("\(naming.name(mover)) played")
    }

    /// One move row: the label, then the legend swatch (or a same-size gap) beside the
    /// notation it keys.
    private func moveLine(label: Text, move: MoveNotation, pct: Double,
                          swatch: MoveMarkStyle?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label.font(.caption).foregroundStyle(ChromeKit.inkDim(0.55))
                .padding(.leading, MoveMarkSwatch.size.width + 8)
            HStack(alignment: .center, spacing: 8) {
                if let swatch {
                    MoveMarkSwatch(style: swatch)
                } else {
                    SColor.clear.frame(width: MoveMarkSwatch.size.width, height: MoveMarkSwatch.size.height)
                        .accessibilityHidden(true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    MoveNotationLine(notation: move, font: .body.bold(), color: ChromeTheme.ink)
                    Text("\(percent(pct))").font(.caption.monospacedDigit()).foregroundStyle(ChromeKit.inkDim(0.55))
                }
            }
        }
    }

    /// "My moves · Mistakes · All moves" (#233); Mistakes only while you have any.
    private var filterPicker: some View {
        Picker("Step through", selection: $filter) {
            Text("My moves").tag(ReviewFilter.mine)
            if hasMistakes { Text("Mistakes").tag(ReviewFilter.mistakes) }
            Text("All moves").tag(ReviewFilter.all)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
    }

    /// Left/right swipe pages through moves (honoring the filter).
    private func pagingGesture(current i: Int, plies: [PlyEvaluation]) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let forward = layoutDirection == .rightToLeft ? value.translation.width > 0
                                                              : value.translation.width < 0
                select(navIndex(from: i, dir: forward ? 1 : -1, in: plies), in: plies)
            }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Formatting ────────────────────────────────────────────────────────────

    /// "63%" — or equity ("+0.52") for a 2-point variant (#143).
    private func percent(_ p: Double) -> String { scale.value(p) }
    /// Whether two moves are the *same* move (order-independent), so the panel claims
    /// "best move played" only when they genuinely match — not merely scoring alike,
    /// which let the text disagree with the highlighted board move (#103).
    private func sameMove(_ a: [[Int]], _ b: [[Int]]) -> Bool {
        func norm(_ m: [[Int]]) -> [[Int]] {
            m.filter { $0.count == 2 }.sorted { $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] < $1[1] }
        }
        return norm(a) == norm(b)
    }
    /// A move from this ply's position in readable notation (#178): mover-relative
    /// points, hits/pins derived from the pre-move board, highest point first.
    private func notation(_ eval: PlyEvaluation, _ move: [[Int]]) -> MoveNotation {
        MoveNotation.describe(move, die1: eval.die1, die2: eval.die2, mover: eval.mover,
                              stacks: eval.boardStacks, config: record.replayConfig)
    }
}

// ── Controller (subscribes to the background analysis) ─────────────────────────

/// Shows the game's background analysis (#243): the review owns no analysis of its own.
/// It takes the game's job from `AnalysisService.app` — the one that ran during play, or
/// a new one seeded from the game log — and mirrors it: instant from whatever is
/// already done, live as more lands. While open it marks the job focused (its work goes
/// first); closing it changes nothing else — the job keeps going and saves as it goes,
/// so a reopened review (or a relaunch) continues where it was, never from zero.
@MainActor
final class GameReviewModel: ObservableObject {
    enum Phase {
        case analyzing(done: Int, total: Int)        // before the first scored move
        case reviewing(finished: Bool)               // ≥1 scored move; all-moves pager
        case nothingToReview                         // finished, no scored moves
        case unavailable
    }

    @Published var phase: Phase = .analyzing(done: 0, total: 0)
    /// True once every move has at least its 1-ply evaluation (#103) — the
    /// win-probability graph and the drill are complete from here, while 2-/3-ply refine
    /// in place.
    @Published private(set) var firstPassComplete = false

    /// The human under review — only this side's plies count as blunders (#132).
    private var humanColor: TavliEngine.Color = .white
    /// Every evaluated ply, both sides, in play order — the chart's data source (#105).
    private var allEvaluations: [PlyEvaluation] = []
    /// A preview / screenshot fixture: shown as is, never subscribed.
    private var fixed = false

    /// The evaluated plies found so far, as a result the drill can consume directly
    /// (it re-filters to its own blunders).
    var result: GameReviewResult { GameReviewResult(evaluations: allEvaluations) }

    /// The full win-probability trajectory for the chart (#105): every evaluated ply.
    var chartEvaluations: [PlyEvaluation] { allEvaluations }

    /// Per-ply dice luck for both sides (#231): `nil` until every ply has it.
    @Published private(set) var luck: [PlyLuck]?
    /// The luck found so far (#259), in play order — feeds the summary's live
    /// per-roll line through `result.summary(for:luck:)`.
    @Published private(set) var partialLuck: [PlyLuck] = []

    init() {}

    /// Preview-only: start in a terminal phase so analysis never runs. `trajectory`
    /// seeds the full chart data set.
    fileprivate init(preview phase: Phase, trajectory: [PlyEvaluation] = []) {
        self.phase = phase
        self.fixed = true
        self.allEvaluations = trajectory
        self.firstPassComplete = true
    }

    /// Follow the game's analysis while the review is open (`.task`; returns when it
    /// is dismissed).
    func run(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) async {
        guard !fixed else { return }
        self.humanColor = humanColor
        #if DEBUG
        // App Store screenshot fixture (#184): its analysis (+ luck) is complete — show it
        // as is, with no background job and so no spinner.
        if let fixture = ScreenshotScenes.analysis(for: record.gameId) {
            fixed = true
            luck = GameReview.cachedLuck(record: record, analysis: fixture)
            partialLuck = luck ?? []
            allEvaluations = GameReview.cachedResult(record: record, analysis: fixture).evaluations
            firstPassComplete = true
            phase = allEvaluations.isEmpty ? .nothingToReview : .reviewing(finished: true)
            return
        }
        #endif
        let job = AnalysisService.app.job(for: record, agent: agent)
        job.focused = true
        defer { job.focused = false }
        sync(job)
        for await _ in job.$revision.values {
            sync(job)
        }
    }

    /// Mirror the job's current state.
    private func sync(_ job: GameAnalysisJob) {
        allEvaluations = job.result.evaluations
        luck = job.luck
        partialLuck = job.partialLuck
        firstPassComplete = job.firstPassComplete
        if allEvaluations.isEmpty {
            if !job.hasModel {
                phase = .unavailable
            } else if job.isComplete {
                phase = .nothingToReview
            } else {
                let p = job.progress
                phase = .analyzing(done: p.done, total: p.total)
            }
        } else {
            phase = .reviewing(finished: job.isComplete)
        }
    }
}

// ── Shared chrome ─────────────────────────────────────────────────────────────

/// A round, neutral Close button for the full-screen review (#233: no amber).
private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(ChromeType.callout.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
                .frame(width: 44, height: 44)
                .background(ChromeKit.secondaryFill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// The iPhone portrait review's "Game · Moves" switch (#259): the Caramel segmented look
/// of the new-game sheet (recessed track, the selected page raised), a size smaller.
private struct ReviewPageSwitch: View {
    @Binding var page: GameReviewView.ReviewPage

    var body: some View {
        HStack(spacing: 2) {
            segment(.game, Text("Game"))
            segment(.moves, Text("Moves"))
        }
        .padding(3)
        .background(ChromeKit.trackColor, in: RoundedRectangle(cornerRadius: ChromeKit.buttonRadius))
    }

    private func segment(_ value: GameReviewView.ReviewPage, _ label: Text) -> some View {
        let selected = page == value
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { page = value }
        } label: {
            label
                .font(ChromeType.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(ChromeTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    RoundedRectangle(cornerRadius: ChromeKit.buttonRadius - 3)
                        .fill(selected ? ChromeKit.selectedSegmentColor : SColor.clear)
                        .shadow(color: selected ? ChromeKit.cardShadow : .clear, radius: 2, x: 0, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The reviewed ply's roll on the board's centre bar (#259), placed like the live
/// `BoardDiceView` (same `BoardGeometry` centres and size): two dice, four for a pasch.
/// Display only — the roll as it was shown before the move, nothing greyed.
struct ReviewBoardDice: View {
    let die1: Int
    let die2: Int

    private var values: [Int] {
        guard die1 > 0, die2 > 0 else { return [] }
        return die1 == die2 ? Array(repeating: die1, count: 4) : [die1, die2]
    }

    var body: some View {
        GeometryReader { proxy in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: proxy.size))
            let centers = geo.diceCenters(count: values.count)
            ZStack {
                ForEach(Array(values.enumerated()), id: \.offset) { idx, value in
                    DieFace(value: value, size: geo.diceSize)
                        .position(centers[idx])
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: values.map(String.init).joined(separator: " ")))
    }
}

extension MoveSeverity {
    /// The level's name for the review badge (#233): Inaccuracy / Mistake / Blunder.
    var localizedName: String {
        switch self {
        case .none: return ""
        case .inaccuracy: return String(localized: "Inaccuracy")
        case .mistake: return String(localized: "Mistake")
        case .blunder: return String(localized: "Blunder")
        }
    }
}

/// A move's level (#231, #233): the annotation mark + its name in a neutral capsule —
/// amber and blue are reserved for your move and the best move. Also on each drill card
/// (#256); `showsName: false` is its narrow form, the mark alone ("??").
struct SeverityBadge: View {
    let severity: MoveSeverity
    var showsName = true
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        HStack(spacing: 5) {
            // "?!" is two bidi-neutral marks; isolate it so RTL doesn't flip it to "!?".
            Text(verbatim: layoutDirection == .rightToLeft
                 ? BidiText.isolatedLeftToRight(severity.symbol ?? "")
                 : (severity.symbol ?? ""))
            if showsName { Text(severity.localizedName) }
        }
        .font(.caption.bold())
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(ChromeTheme.ink)
        .background(ChromeTheme.ink.opacity(severity == .blunder ? 0.14 : 0.07), in: Capsule())
        .overlay(Capsule().stroke(ChromeTheme.ink.opacity(severity == .blunder ? 0.45 : 0.25),
                                  lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(severity.localizedName)
    }
}

/// Whose move a review card is (#132, #233): the checker-colour dot + the name
/// (You / Computer / the online name / White / Red), neutral.
private struct MoverChip: View {
    let name: String
    let color: TavliEngine.Color
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ChromeTheme.checkerColor(color))
                .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                .frame(width: 11, height: 11)
            Text(name)
                .font(.caption.bold())
                .foregroundStyle(ChromeTheme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(ChromeTheme.ink.opacity(0.06), in: Capsule())
    }
}

// ── Win-probability chart (#105) ──────────────────────────────────────────────

/// Win-probability trajectory across the reviewed game, drawn as a little **window
/// of the board**: the mahogany play surface gives the ivory-White trace the same
/// contrast it has as a checker (cream-on-cream was invisible). Time runs left→right
/// (evaluated plies in order); win probability runs bottom→top **from `topColor`'s
/// perspective** — your side up (#233), White in a two-player game. Labelled
/// reference lines bound the scale (top = a certain win for `topColor`, bottom = for
/// the other side, dashed centre = even). The band between the centre and the trace
/// is filled with a soft tint of the leading side's checker colour (#105 note); the
/// trace uses the full checker colour over a dark casing, switching colour wherever it
/// crosses the centre. Colours come from `CaramelPalette`, so a future theme change
/// propagates. Mistakes are marked by **size + symbol** in a neutral ivory (#233):
/// your ? and ?? rings with the mark beside them, the opponent's as small faint rings.
/// Tapping or dragging scrubs to the nearest move (the caller snaps within its filter).
private struct WinProbabilityChart: View {
    /// A marked ply (#233).
    enum Mark: Equatable {
        /// One of your moves at this level (`.mistake` or `.blunder`).
        case mine(MoveSeverity)
        /// An opponent mistake or blunder (marked quietly).
        case opponent
    }

    let evaluations: [PlyEvaluation]
    /// `plyNumber` of the move currently shown — marked with a solid dot (none when nil).
    let selectedPly: Int?
    /// Marked plies by `plyNumber`.
    let marks: [Int: Mark]
    /// The side whose win chance runs up.
    let topColor: TavliEngine.Color
    /// Names on the top / bottom reference lines (You / Computer, White / Red).
    let topLabel: String
    let bottomLabel: String
    /// The chart's height: 96 beside the board, taller on the iPhone's Game page (#259).
    var height: CGFloat = 96
    /// Tap only (#259, Game page): a tap picks a move, a drag scrolls the page.
    var tapOnly = false
    /// Called with a tapped/scrubbed `plyNumber`; the caller snaps to the nearest move.
    let onScrub: (Int) -> Void

    /// Soft band fill: the checker colour at low opacity over the mahogany surface.
    /// Tune here if the bands feel too strong or too faint.
    private static let fillOpacity = 0.32
    private static let insetX: CGFloat = 10
    private static let insetY: CGFloat = 14
    private static let corner: CGFloat = 10
    /// The window's border: a dark edge on the light page; in dark mode (#191) the
    /// walnut window would vanish into the card, so it gets the board's caramel edge.
    private static let windowEdge = SColor(light: 0x000000, lightOpacity: 0.35, dark: 0xc8904e, darkOpacity: 0.55)
    /// Mistake markers: the board's ivory — no new colour, and neither amber nor blue.
    private static let markInk = CaramelPalette.triangleFill

    var body: some View {
        GeometryReader { geo in
            let canvas = Canvas { ctx, size in draw(into: ctx, size: size) }
                .contentShape(Rectangle())
            if tapOnly {
                canvas.onTapGesture { scrub(atX: $0.x, width: geo.size.width) }
            } else {
                canvas.highPriorityGesture(            // beat the ancestor paging swipe
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrub(atX: $0.location.x, width: geo.size.width) }
                )
            }
        }
        .frame(height: height)
        .boardLayoutDirection()   // #185: time runs left→right like the board's geometry
        .accessibilityLabel("Win chance through the game")
    }

    // ── Drawing ──────────────────────────────────────────────────────────────

    private func draw(into ctx: GraphicsContext, size: CGSize) {
        let n = evaluations.count

        // Mahogany "board window" surface + framed border (fixes White contrast and
        // gives the scale a visible ceiling/floor).
        let card = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Self.corner)
        ctx.fill(card, with: .linearGradient(
            Gradient(colors: [CaramelPalette.playTop, CaramelPalette.playBot]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(card, with: .color(Self.windowEdge), lineWidth: 1.5)

        let left = Self.insetX, right = size.width - Self.insetX
        let top = Self.insetY, bottom = size.height - Self.insetY
        let yc = (top + bottom) / 2

        func x(_ i: Int) -> CGFloat {
            n <= 1 ? size.width / 2 : left + (right - left) * CGFloat(i) / CGFloat(n - 1)
        }
        func y(_ wp: Double) -> CGFloat { top + (1 - wp) * (bottom - top) }   // top = wp 1

        // Scale references: certain win for the top side, even (dashed), for the other.
        rule(ctx, from: left, to: right, y: top, color: ruleColor(topColor))
        rule(ctx, from: left, to: right, y: bottom, color: ruleColor(topColor.opponent))
        rule(ctx, from: left, to: right, y: yc, color: CaramelPalette.triangleFill.opacity(0.22),
             dash: [3, 3])
        label(ctx, topLabel, at: CGPoint(x: left + 1, y: top + 1), anchor: .topLeading,
              color: labelColor(topColor))
        label(ctx, bottomLabel, at: CGPoint(x: left + 1, y: bottom - 1), anchor: .bottomLeading,
              color: labelColor(topColor.opponent))

        guard n >= 2 else {
            if let e = evaluations.first {
                let p = CGPoint(x: x(0), y: y(topProb(e)))
                if let mark = marks[e.plyNumber] { drawMark(ctx, mark, at: p, top: top) }
                drawDot(ctx, at: p, above: topProb(e) > 0.5)
            }
            return
        }

        let pts = evaluations.enumerated().map { i, e in
            (CGPoint(x: x(i), y: y(topProb(e))), topProb(e) > 0.5)
        }

        // Soft bands, split wherever the line crosses centre so each side keeps its
        // colour (no bow-tie at a crossing).
        for k in 0..<(pts.count - 1) {
            for (s, e, above) in segments(pts[k].0, pts[k].1, pts[k + 1].0, pts[k + 1].1, yc: yc) {
                var band = Path()
                band.move(to: CGPoint(x: s.x, y: yc))
                band.addLine(to: s)
                band.addLine(to: e)
                band.addLine(to: CGPoint(x: e.x, y: yc))
                band.closeSubpath()
                ctx.fill(band, with: .color(fillColor(above: above)))
            }
        }

        // Dark casing under the whole trace, then the checker-coloured segments on top.
        var trace = Path()
        trace.move(to: pts[0].0)
        for k in 1..<pts.count { trace.addLine(to: pts[k].0) }
        ctx.stroke(trace, with: .color(.black.opacity(0.40)),
                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        for k in 0..<(pts.count - 1) {
            for (s, e, above) in segments(pts[k].0, pts[k].1, pts[k + 1].0, pts[k + 1].1, yc: yc) {
                var line = Path(); line.move(to: s); line.addLine(to: e)
                ctx.stroke(line, with: .color(lineColor(above: above)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }

        // Mistake markers (drawn under the selected dot, so a selected mistake shows
        // the dot inside its ring). The opponent's first, so yours sit on top.
        for (idx, e) in evaluations.enumerated() where marks[e.plyNumber] == .opponent {
            drawMark(ctx, .opponent, at: pts[idx].0, top: top)
        }
        for (idx, e) in evaluations.enumerated() {
            if let mark = marks[e.plyNumber], mark != .opponent {
                drawMark(ctx, mark, at: pts[idx].0, top: top)
            }
        }

        // Selected-move dot.
        if let sel = evaluations.firstIndex(where: { $0.plyNumber == selectedPly }) {
            drawDot(ctx, at: pts[sel].0, above: pts[sel].1)
        }
    }

    /// Win probability from **`topColor`'s** perspective for an evaluated ply.
    private func topProb(_ e: PlyEvaluation) -> Double {
        let s = Double(e.playedScore)
        return e.mover == topColor ? s : 1 - s
    }

    /// Split a segment at the centre line so each part lies entirely on one side.
    /// Returns `(start, end, above)` tuples (`above` = the top side ahead).
    private func segments(_ a: CGPoint, _ aboveA: Bool, _ b: CGPoint, _ aboveB: Bool,
                          yc: CGFloat) -> [(CGPoint, CGPoint, Bool)] {
        guard aboveA != aboveB, b.y != a.y else { return [(a, b, aboveA)] }
        let t = (yc - a.y) / (b.y - a.y)
        let cross = CGPoint(x: a.x + t * (b.x - a.x), y: yc)
        return [(a, cross, aboveA), (cross, b, aboveB)]
    }

    private func rule(_ ctx: GraphicsContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat,
                      color: SColor, dash: [CGFloat] = []) {
        var p = Path(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func label(_ ctx: GraphicsContext, _ s: String, at p: CGPoint, anchor: UnitPoint,
                       color: SColor) {
        ctx.draw(Text(s).font(.system(size: 9, weight: .semibold)).foregroundColor(color),
                 at: p, anchor: anchor)
    }

    private func drawDot(_ ctx: GraphicsContext, at p: CGPoint, above: Bool) {
        let r: CGFloat = 4.5
        let disc = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(disc, with: .color(lineColor(above: above)))
        ctx.stroke(disc, with: .color(.black.opacity(0.55)), lineWidth: 1.5)
    }

    /// A mistake marker: a hollow ivory ring sized by level — ? small, ?? larger and
    /// heavier, each with its mark beside it — or a small faint ring for the opponent.
    private func drawMark(_ ctx: GraphicsContext, _ mark: Mark, at p: CGPoint, top: CGFloat) {
        func ring(_ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        switch mark {
        case .opponent:
            ctx.stroke(ring(3.5), with: .color(Self.markInk.opacity(0.5)), lineWidth: 1)
        case .mine(let severity):
            let blunder = severity == .blunder
            let r: CGFloat = blunder ? 7 : 5
            ctx.stroke(ring(r), with: .color(.black.opacity(0.4)), lineWidth: blunder ? 4 : 3)   // casing
            ctx.stroke(ring(r), with: .color(Self.markInk), lineWidth: blunder ? 2.2 : 1.4)
            // The mark above the ring, or below it near the top edge.
            let up = p.y - r - 1 > top + 2
            let at = CGPoint(x: p.x, y: up ? p.y - r - 1 : p.y + r + 1)
            ctx.draw(Text(verbatim: severity.symbol ?? "")
                        .font(.system(size: blunder ? 10 : 9, weight: .heavy))
                        .foregroundColor(Self.markInk),
                     at: at, anchor: up ? .bottom : .top)
        }
    }

    private func checker(_ c: TavliEngine.Color) -> SColor {
        c == .white ? CaramelPalette.whiteFill : CaramelPalette.redFill
    }
    private func ruleColor(_ c: TavliEngine.Color) -> SColor {
        c == .white ? CaramelPalette.whiteFill.opacity(0.30) : CaramelPalette.redFill.opacity(0.45)
    }
    private func labelColor(_ c: TavliEngine.Color) -> SColor {
        c == .white ? CaramelPalette.whiteFill.opacity(0.85) : CaramelPalette.redHi.opacity(0.9)
    }
    private func fillColor(above: Bool) -> SColor {
        checker(above ? topColor : topColor.opponent).opacity(Self.fillOpacity)
    }
    private func lineColor(above: Bool) -> SColor {
        checker(above ? topColor : topColor.opponent)
    }

    // ── Interaction ──────────────────────────────────────────────────────────

    private func scrub(atX gx: CGFloat, width: CGFloat) {
        guard !evaluations.isEmpty else { return }
        let n = evaluations.count
        let plotW = max(1, width - 2 * Self.insetX)
        let frac = Double((gx - Self.insetX) / plotW)
        let i = min(n - 1, max(0, Int((frac * Double(n - 1)).rounded())))
        onScrub(evaluations[i].plyNumber)
    }
}

// MARK: - Previews

#Preview("Review — with blunders") {
    let board = GameBoard()
    board.initializeBoard()
    let stacks = board.points.map(\.pieces)
    func ev(_ ply: Int, _ played: Float, _ best: Float) -> PlyEvaluation {
        PlyEvaluation(plyNumber: ply, die1: 4, die2: 2, boardStacks: stacks,
                      mover: .white, playedMove: [[1, 5]], playedScore: played,
                      bestMove: [[1, 3]], bestScore: best)
    }
    // A trajectory that swings across the centre a few times, with a few blunders.
    let traj = [ev(1, 0.52, 0.55), ev(3, 0.60, 0.62), ev(5, 0.48, 0.66), ev(7, 0.43, 0.50),
                ev(9, 0.55, 0.58), ev(11, 0.62, 0.64), ev(13, 0.70, 0.72), ev(15, 0.40, 0.68),
                ev(17, 0.58, 0.60), ev(19, 0.66, 0.69)]
    return GameReviewView(previewPhase: .reviewing(finished: true), trajectory: traj)
}

#Preview("Review — no blunders") {
    let board = GameBoard()
    board.initializeBoard()
    let stacks = board.points.map(\.pieces)
    func ev(_ ply: Int, _ played: Float, _ best: Float) -> PlyEvaluation {
        PlyEvaluation(plyNumber: ply, die1: 4, die2: 2, boardStacks: stacks,
                      mover: .white, playedMove: [[1, 5]], playedScore: played,
                      bestMove: [[1, 3]], bestScore: best)
    }
    // Every move within a hair of best → no blunders, but still reviewable.
    let traj = [ev(1, 0.52, 0.53), ev(3, 0.58, 0.59), ev(5, 0.50, 0.50),
                ev(7, 0.55, 0.56), ev(9, 0.61, 0.62), ev(11, 0.57, 0.58)]
    return GameReviewView(previewPhase: .reviewing(finished: true), trajectory: traj)
}

#Preview("Nothing to review") {
    GameReviewView(previewPhase: .nothingToReview)
}

#Preview("Analyzing") {
    GameReviewView(previewPhase: .analyzing(done: 7, total: 18))
}
