import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color

/// #63 — interactive post-game drill, the iPad analogue of the CLI's `drill`
/// command (`play/loop.py:_handle_drill` / `_drill_inner`). Reuses #62's blunder
/// detection (`GameReview`/`PlyEvaluation`): for each flagged ply it seeds a live
/// board at that position (`GameSession.drill`) and asks the player to find a
/// better move on the real board (the same tap/drag input as play). Each attempt
/// is graded against the AI's best (correct / close / wrong); "Show solution"
/// highlights the best move; "Skip"/"Next" advances; finishing shows a summary.
///
/// Pure presentation — all analysis/scoring lives in `TavliEngine`.
struct DrillView: View {
    let record: GameRecord
    /// Reuse an already-computed review (from the review screen) to skip re-analysis.
    let precomputed: GameReviewResult?
    let agent: Agent?
    let humanColor: TavliEngine.Color

    @StateObject private var model: DrillModel
    @Environment(\.dismiss) private var dismiss

    init(record: GameRecord, precomputed: GameReviewResult?, agent: Agent?,
         humanColor: TavliEngine.Color) {
        self.record = record
        self.precomputed = precomputed
        self.agent = agent
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: DrillModel())
    }

    /// Preview-only: seed a terminal phase so `#Preview`s skip analysis.
    fileprivate init(previewModel: DrillModel, humanColor: TavliEngine.Color = .white) {
        self.record = GameRecord(startingPlayer: .white, aiColor: .black)
        self.precomputed = nil
        self.agent = nil
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: previewModel)
    }

    private var flipped: Bool { humanColor == .black }

    var body: some View {
        GeometryReader { proxy in
            // iPhone landscape (#109): the header moves into the card's rail so the
            // board keeps the full safe height.
            let railHeader = ChromeLayout(proxy).mode == .compactLandscape && isDrilling
            VStack(spacing: 0) {
                if !railHeader {
                    header
                    Divider()
                }
                content(railHeader: railHeader)
            }
        }
        .background(ChromeKit.pageColor)
        .task {
            await model.start(record: record, precomputed: precomputed,
                              agent: agent, humanColor: humanColor)
        }
    }

    private var isDrilling: Bool {
        if case .drilling = model.phase { return true }
        return false
    }

    private var header: some View {
        headerRow
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
    }

    private var headerRow: some View {
        HStack {
            Text("Drill")
                .font(.title3.bold())
                .foregroundStyle(ChromeTheme.ink)
            if case .drilling = model.phase {
                Text("· Mistake \(model.index + 1) of \(model.total)")
                    .font(.callout)
                    .foregroundStyle(ChromeKit.inkDim(0.6))
            }
            Spacer()
            Button("Done") { dismiss() }
                .font(.callout.bold())
                .foregroundStyle(ChromeTheme.ink)
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func content(railHeader: Bool) -> some View {
        switch model.phase {
        case .analyzing:
            centered {
                ProgressView().progressViewStyle(.circular).tint(ChromeTheme.ink)
                Text("Finding your mistakes…")
                    .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
            }
        case .empty:
            centered {
                Text("No mistakes to drill — well played!")
                    .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
            }
        case .drilling:
            if let card = model.session, let eval = model.current {
                DrillCard(session: card, eval: eval, flipped: flipped,
                          feedback: model.feedback, showingSolution: model.showingSolution,
                          lastAttempt: model.lastAttempt, lastAttemptScore: model.lastAttemptScore,
                          awaitingRetry: model.awaitingRetry,
                          solved: model.solvedThisCard, celebrating: model.celebrating,
                          onTryAgain: { model.tryAgain() },
                          onShowSolution: { model.revealSolution() },
                          onAdvance: { model.advance() },
                          railHeader: railHeader ? AnyView(headerRow) : nil)
                .id(model.index)   // fresh card (and board) per blunder
            }
        case .complete(let s):
            completeView(s)
        }
    }

    private func completeView(_ s: DrillModel.Summary) -> some View {
        centered {
            Text("Drill complete")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(ChromeTheme.ink)
            Text(drillSummary(s))
                .font(.title3)
                .foregroundStyle(ChromeKit.inkDim(0.7))
            Button("Done") { dismiss() }
                .font(.title3.bold())
                .padding(.horizontal, 28).padding(.vertical, 12)
                .background(ChromeTheme.doneTint.opacity(0.22))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChromeTheme.doneTint.opacity(0.6), lineWidth: 1))
                .foregroundStyle(ChromeTheme.ink)
                .buttonStyle(.plain)
        }
    }

    private func drillSummary(_ s: DrillModel.Summary) -> String {
        var text = String(localized: "Solved \(s.solved) of \(s.total)")
        if s.skipped > 0 {
            text += String(localized: " · skipped \(s.skipped)")
        }
        return text
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ── Drill controller ──────────────────────────────────────────────────────────

/// Drives the drill: analysis (or a precomputed result), the per-card seeded
/// session, attempt grading off the main actor, and progress. Same `@MainActor`
/// `ObservableObject` pattern as `GameReviewModel`.
@MainActor
final class DrillModel: ObservableObject {
    struct Summary { let solved: Int; let skipped: Int; let total: Int }

    enum Feedback: Equatable {
        case none
        case checking
        case correct(String)
        case close(String)
        case wrong(String)
    }

    enum Phase {
        case analyzing
        case empty
        case drilling
        case complete(Summary)
    }

    @Published var phase: Phase = .analyzing
    @Published private(set) var index = 0
    @Published private(set) var session: GameSession?
    @Published var feedback: Feedback = .none
    @Published private(set) var showingSolution = false
    /// The player's most recent attempt on this card, as `[from, to]` pairs (shown in
    /// writing, and compared with the best move by "Show solution", #232). `nil` until
    /// they move; kept through "Try again" — it is replaced by the next attempt.
    @Published private(set) var lastAttempt: [[Int]]?
    /// Win-probability score of `lastAttempt` (#114), shown alongside it.
    @Published private(set) var lastAttemptScore: Float?
    /// Whether a non-solving attempt is held on the board, awaiting "Try again" (#114).
    @Published private(set) var awaitingRetry = false
    /// Whether the current card has been solved (a correct attempt was made).
    @Published private(set) var solvedThisCard = false
    /// A correct attempt is being confirmed ("Well done ✓"); the drill advances by itself
    /// when it ends (#232).
    @Published private(set) var celebrating = false
    /// The pending auto-advance after a correct attempt.
    private var advanceTask: Task<Void, Never>?

    // `play/loop.py` drill tolerances (drill_correct_floor / drill_correct_relative).
    // Hard-coded for now; candidates for the #77 settings work.
    private let correctFloor = 0.01
    private let correctRelative = 0.03
    private let closeFloor = 0.04
    private let closeRelative = 0.10

    private var blunders: [PlyEvaluation] = []
    private var agent: Agent?
    private var humanColor: TavliEngine.Color = .white
    /// The game's rules (variant + any tier-2 handicap, #148), for the drill positions.
    private var config: GameConfig?
    private var started = false
    private var solvedCount = 0
    private var skippedCount = 0

    var total: Int { blunders.count }
    var current: PlyEvaluation? { index < blunders.count ? blunders[index] : nil }

    init() {}

    /// Preview-only: seed straight into a drilling card or a terminal phase.
    fileprivate init(preview phase: Phase, blunders: [PlyEvaluation] = [], agent: Agent? = nil) {
        self.phase = phase
        self.blunders = blunders
        self.agent = agent
        self.started = true
        if case .drilling = phase, let first = blunders.first {
            session = GameSession.drill(boardStacks: first.boardStacks,
                                        die1: first.die1, die2: first.die2,
                                        mover: first.mover, agent: agent)
        }
    }

    func start(record: GameRecord, precomputed: GameReviewResult?, agent: Agent?,
               humanColor: TavliEngine.Color) async {
        guard !started else { return }
        started = true
        self.agent = agent
        self.humanColor = humanColor
        self.config = record.replayConfig

        let result: GameReviewResult
        if let precomputed {
            result = precomputed
        } else if let agent {
            result = await Task.detached(priority: .userInitiated) {
                GameReview.analyze(record: record, agent: agent, humanColor: humanColor)
            }.value
        } else {
            phase = .empty
            return
        }

        // Only the human's own mistakes and blunders (? and ??) are drillable — opponent
        // plies may be in the result too (#132). The absolute severity scale (#231) puts the
        // old relative 10% line (~5 pp in an even position) between ? and ??, so drilling
        // both keeps the drill's volume while grading every position alike.
        blunders = result.evaluations.filter { $0.mover == humanColor && $0.severity >= .mistake }
        guard !blunders.isEmpty else { phase = .empty; return }
        loadCard(0)
        phase = .drilling
    }

    private func loadCard(_ i: Int) {
        index = i
        feedback = .none
        showingSolution = false
        lastAttempt = nil
        lastAttemptScore = nil
        awaitingRetry = false
        solvedThisCard = false
        let b = blunders[i]
        let s = GameSession.drill(boardStacks: b.boardStacks, die1: b.die1, die2: b.die2,
                                  mover: b.mover, agent: agent, config: config)
        s.onMoveAttempt = { [weak self] move in self?.grade(move) }
        s.holdAttempts = true   // keep the attempt on the board until "Try again" (#114)
        session = s
    }

    /// Grade a player's attempt: score it off the main actor and set feedback.
    private func grade(_ move: Move) {
        guard let b = current, let agent else { return }
        feedback = .checking
        let pairs = move.halfMoves.map { [$0.from.position, $0.to.position] }
        let stacks = b.boardStacks
        let mover = b.mover
        let best = b.bestScore
        let config = config
        Task.detached(priority: .userInitiated) { [weak self] in
            let score = try? agent.scoreCandidate(boardStacks: stacks, move: pairs, mover: mover,
                                                  config: config)
            await MainActor.run { self?.applyFeedback(attempt: pairs, score: score, best: best) }
        }
    }

    private func applyFeedback(attempt: [[Int]], score: Float?, best: Float) {
        // Attempt + score land together, so the "You tried" row swaps in one step.
        lastAttempt = attempt
        lastAttemptScore = score
        guard let score else {
            awaitingRetry = true
            feedback = .wrong(String(localized: "Couldn’t evaluate — try again."))
            return
        }
        let gap = Double(best - score)
        let correctThreshold = max(correctFloor, Double(best) * correctRelative)
        let closeThreshold = max(closeFloor, Double(best) * closeRelative)
        if gap <= correctThreshold {
            // Solved: leave the move on the board (#114), confirm briefly, then move on by
            // itself (#232) — no Next button for a solved card.
            awaitingRetry = false
            if !solvedThisCard { solvedThisCard = true; solvedCount += 1 }
            let message = gap < 0.001 ? String(localized: "Excellent — that’s the best move!")
                                      : String(localized: "Great — very close to optimal.")
            feedback = .correct(message)
            celebrateThenAdvance(announcing: message)
        } else if gap <= closeThreshold {
            awaitingRetry = true
            feedback = .close(String(localized: "Close — there’s a better move. Try again."))
        } else {
            awaitingRetry = true
            feedback = .wrong(String(localized: "Not quite — think a little harder."))
        }
    }

    /// Roll the held attempt back to the start so the player can try again (#114).
    /// The attempt stays in `lastAttempt` (#232: "Show solution" compares your latest).
    func tryAgain() {
        session?.retryAttempt()
        awaitingRetry = false
        feedback = .none
    }

    /// Reveal the best move, compared with your latest attempt (or the game move when
    /// you haven't tried, #232). The highlight is drawn from the pre-move position, so
    /// first put the board back there: roll back a held attempt (#114) and undo any
    /// half-built move / pending pick.
    func revealSolution() {
        if let session {
            if session.heldAttempt != nil { session.retryAttempt() }
            if session.routeChoice != nil { session.cancelRouteChoice() }
            for _ in 0..<4 where !session.moveBuilder.built.isEmpty { session.undo() }
            if session.selectedPoint != nil { session.selectPoint(-1) }
        }
        awaitingRetry = false
        showingSolution = true
    }

    /// How long the "Well done ✓" confirmation stays before the drill moves on (#232).
    static let celebrationSeconds: Double = 1.2
    /// With VoiceOver on, the longest we wait for the announcement to finish.
    private static let voiceOverCelebrationCap: Double = 6

    /// Show the "Well done ✓" confirmation (`celebrating`), announce it to VoiceOver, then
    /// advance to the next blunder (or the summary). With VoiceOver running it waits for
    /// the announcement to finish (capped) instead of the fixed ~1 s.
    private func celebrateThenAdvance(announcing message: String) {
        celebrating = true
        let card = index
        let announcement = String(localized: "Well done ✓") + " " + message
        let voiceOver = UIAccessibility.isVoiceOverRunning
        if voiceOver {
            AccessibilityNotification.Announcement(announcement).post()
        }
        advanceTask?.cancel()
        advanceTask = Task { @MainActor [weak self] in
            if voiceOver {
                await Self.waitForAnnouncement(cap: Self.voiceOverCelebrationCap)
            } else {
                try? await Task.sleep(nanoseconds: UInt64(Self.celebrationSeconds * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.index == card, self.celebrating else { return }
            self.advance()
        }
    }

    /// Resolves when VoiceOver finishes an announcement, or after `cap` seconds.
    private static func waitForAnnouncement(cap: Double) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let finished = NotificationCenter.default.notifications(
                    named: UIAccessibility.announcementDidFinishNotification)
                for await _ in finished { break }
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(cap * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Move to the next blunder (or finish). A card left unsolved counts as skipped.
    func advance() {
        advanceTask?.cancel()
        advanceTask = nil
        celebrating = false
        if !solvedThisCard { skippedCount += 1 }
        if index + 1 < blunders.count {
            loadCard(index + 1)
        } else {
            session = nil
            phase = .complete(Summary(solved: solvedCount, skipped: skippedCount, total: blunders.count))
        }
    }
}

// ── Drill card ────────────────────────────────────────────────────────────────

/// One blunder card: the position the player faced, a feedback line, and the
/// Show-solution / Skip-or-Next controls. The board is the real `PlayableBoardView`
/// bound to the seeded session, so taps/drags drive `onMoveAttempt`.
private struct DrillCard: View {
    @ObservedObject var session: GameSession
    let eval: PlyEvaluation
    let flipped: Bool
    let feedback: DrillModel.Feedback
    let showingSolution: Bool
    /// The player's latest attempt on this card, as `[from, to]` pairs (shown in writing).
    let lastAttempt: [[Int]]?
    let lastAttemptScore: Float?
    let awaitingRetry: Bool
    let solved: Bool
    /// A correct attempt is being confirmed before the drill advances by itself (#232).
    let celebrating: Bool
    let onTryAgain: () -> Void
    let onShowSolution: () -> Void
    let onAdvance: () -> Void
    /// The drill header, when the screen moved it into this card's rail (iPhone
    /// landscape, #109).
    var railHeader: AnyView? = nil

    /// A checker is being dragged on the board (from `PlayableBoardView.onLiftChange`).
    @State private var dragLifted = false

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            let layout = ChromeLayout(proxy)
            if layout.mode == .compactLandscape {
                // Board at full safe height; header, prompt, feedback, scores and
                // the actions in the rail.
                HStack(spacing: ChromeLayout.compactRailGap) {
                    board
                        .frame(width: layout.boardSide, height: layout.boardSide)
                    FitOrScroll {
                        VStack(alignment: .leading, spacing: 10) {
                            if let railHeader { railHeader }
                            Text("Dice \(eval.die1) · \(eval.die2) — find a better move")
                                .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
                            feedbackLine
                            movesPanel
                            Spacer(minLength: 0)
                            controls
                        }
                        .padding(.vertical, 8)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: layout.panelRect.width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else if layout.mode == .compactPortrait {
                // Board edge-to-edge; actions directly under the feedback.
                VStack(spacing: 10) {
                    Text("Dice \(eval.die1) · \(eval.die2) — find a better move")
                        .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
                        .padding(.horizontal, 12)
                    board
                        .frame(width: layout.boardSide, height: layout.boardSide)
                    FitOrScroll {
                        VStack(spacing: 10) {
                            feedbackLine
                            movesPanel
                            controls
                        }
                        .padding(.horizontal, 12)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else if landscape {
                HStack(spacing: 0) {
                    board
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(12)
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Dice \(eval.die1) · \(eval.die2) — find a better move")
                            .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
                        feedbackLine
                        movesPanel
                        Spacer(minLength: 0)
                        controls
                    }
                    .frame(width: 320, alignment: .leading)
                    .padding(.vertical, 16).padding(.trailing, 16)
                }
            } else {
                VStack(spacing: 14) {
                    Text("Dice \(eval.die1) · \(eval.die2) — find a better move")
                        .font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
                    board.layoutPriority(1).padding(.horizontal, 12)
                    feedbackLine
                    movesPanel
                    controls.padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// The move "Show solution" sets against the best (#232): your latest attempt,
    /// or the move you played in the game when you haven't tried yet.
    private var comparedMove: [[Int]] { lastAttempt ?? eval.playedMove }

    /// Whether the board overlays may show (#232). They are drawn from the pre-move
    /// position, so never while it has changed (an attempt held, #114, or half a move
    /// built), and they step aside while a checker is picked (tapped, dragged or
    /// awaiting a route choice) so the live amber play highlight reads on its own.
    private var showsOverlay: Bool {
        session.heldAttempt == nil && session.moveBuilder.built.isEmpty
            && session.selectedPoint == nil && session.routeChoice == nil && !dragLifted
    }

    /// The ghost of the game move is on the board (before an attempt, nothing picked).
    private var ghostDrawn: Bool { showsOverlay && !showingSolution && !solved }
    /// The solution comparison is on the board.
    private var solutionDrawn: Bool { showsOverlay && showingSolution }
    /// Which marks the solution actually draws (your compared move may equal the best,
    /// then only the blue shows).
    private var solutionMarks: (played: Bool, best: Bool) {
        guard solutionDrawn else { return (false, false) }
        return MoveHighlightView.drawnMarks(playedMove: comparedMove, bestMove: eval.bestMove)
    }

    private var board: some View {
        ZStack {
            PlayableBoardView(session: session, flipped: flipped,
                              onLiftChange: { dragLifted = $0 })
            if solutionDrawn {
                // Your latest attempt (amber) against the best (blue); shared points
                // carry both marks (#232).
                MoveHighlightView(playedMove: comparedMove, bestMove: eval.bestMove,
                                  stacks: eval.boardStacks, flipped: flipped,
                                  variant: session.game.variant)
            } else if ghostDrawn {
                // The move you played in the game, as a grey dashed ghost — "you did
                // this; find better" (#114, #232). Your attempt is the live amber.
                MoveHighlightView(playedMove: eval.playedMove, bestMove: nil,
                                  stacks: eval.boardStacks, flipped: flipped,
                                  variant: session.game.variant, playedStyle: .ghost)
            }
            if celebrating {
                // A correct attempt (#232): a brief confirmation over the board, then the
                // drill moves on by itself. VoiceOver hears it via the model's announcement.
                Text("Well done ✓")
                    .font(ChromeType.title2.bold())
                    .foregroundStyle(ChromeKit.onAccent)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(DrillTint.correct, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: celebrating)
        .aspectRatio(1, contentMode: .fit)
        .boardLayoutDirection()   // #185: the physical board never mirrors
    }

    @ViewBuilder
    private var feedbackLine: some View {
        switch feedback {
        case .none:
            // A pending two-dice route choice (#169) asks for the in-between point.
            Text(session.routeChoice != nil ? LocalizedStringKey("Choose where to land in between")
                                            : LocalizedStringKey("Make your move on the board."))
                .font(.callout).foregroundStyle(ChromeKit.inkDim(0.55))
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(ChromeKit.inkDim(0.7))
            }
        case .correct(let msg):
            Text(msg).font(.callout.bold()).foregroundStyle(DrillTint.correct)
        case .close(let msg):
            Text(msg).font(.callout.bold()).foregroundStyle(DrillTint.close)
        case .wrong(let msg):
            Text(msg).font(.callout.bold()).foregroundStyle(DrillTint.wrong)
        }
    }

    /// The scores behind the drill (#114): the move you originally played and its win
    /// chance, your latest attempt and its win chance, and — once revealed — the best
    /// move with the gap. Mirrors the review's number language. A row leads with a
    /// swatch **only while its mark is drawn on the board** (#232), else an empty
    /// swatch-sized gap so the rows stay aligned: the game move grey dashed while its
    /// ghost shows (amber when the solution compares it), your attempt amber while the
    /// solution compares it, the best blue in the solution.
    @ViewBuilder
    private var movesPanel: some View {
        let marks = solutionMarks
        VStack(alignment: .leading, spacing: 6) {
            moveRow(label: "You played", move: notation(eval.playedMove),
                    pct: Double(eval.playedScore),
                    style: ghostDrawn ? .ghost
                        : (lastAttempt == nil && marks.played ? .played : nil))
            if let lastAttempt, let s = lastAttemptScore {
                moveRow(label: "You tried", move: notation(lastAttempt),
                        pct: Double(s), style: marks.played ? .played : nil)
            }
            if showingSolution {
                moveRow(label: "Best move", move: notation(eval.bestMove),
                        pct: Double(eval.bestScore), style: marks.best ? .best : nil)
                gapLine
                    .font(.caption).foregroundStyle(ChromeKit.inkDim(0.55))
            }
        }
    }

    /// How far the best is ahead of the move the board compares it with (#232).
    @ViewBuilder
    private var gapLine: some View {
        if lastAttempt != nil, let tried = lastAttemptScore {
            let gap = scale.gap(Double(eval.bestScore - tried))
            if scale.isEquity {
                Text("−\(gap) equity vs your try")
            } else {
                Text("−\(gap) win chance vs your try")
            }
        } else {
            let gap = scale.gap(Double(eval.bestScore - eval.playedScore))
            if scale.isEquity {
                Text("−\(gap) equity vs your move")
            } else {
                Text("−\(gap) win chance vs your move")
            }
        }
    }

    private func moveRow(label: LocalizedStringKey, move: MoveNotation, pct: Double,
                         style: MoveMarkStyle?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if let style {
                MoveMarkSwatch(style: style)
            } else {
                Color.clear.frame(width: MoveMarkSwatch.size.width, height: MoveMarkSwatch.size.height)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.caption).foregroundStyle(ChromeKit.inkDim(0.55))
                MoveNotationLine(notation: move, font: .callout.bold(), color: ChromeTheme.ink)
                Text("\(percent(pct))").font(.caption.monospacedDigit()).foregroundStyle(ChromeKit.inkDim(0.5))
            }
        }
    }

    /// Win chance vs equity for the drilled game's rules (#143).
    private var scale: EvalScale { EvalScale(variant: session.game.variant) }
    private func percent(_ p: Double) -> String { scale.value(p) }

    /// A move from the drilled position in readable notation (#178).
    private func notation(_ move: [[Int]]) -> MoveNotation {
        MoveNotation.describe(move, die1: eval.die1, die2: eval.die2, mover: eval.mover,
                              stacks: eval.boardStacks, config: session.game.board.config)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 16) {
            if celebrating || solved {
                // Solved (#232): the drill moves on by itself after "Well done ✓" — an
                // invisible button keeps the row's height so nothing jumps meanwhile.
                Button("Next →", action: {})
                    .buttonStyle(DrillButton(tint: ChromeTheme.doneTint))
                    .hidden()
                    .accessibilityHidden(true)
            } else if showingSolution {
                // Nothing more to do on this card — keep the result on the board (#114).
                Button("Next →", action: onAdvance)
                    .buttonStyle(DrillButton(tint: ChromeTheme.doneTint))
            } else if awaitingRetry {
                // An attempt is held on the board: reset to retry, or reveal the answer.
                Button("Try again", action: onTryAgain)
                    .buttonStyle(DrillButton(tint: ChromeTheme.doneTint))
                Button("Show solution", action: onShowSolution)
                    .buttonStyle(DrillButton(tint: ChromeTheme.undoTint))
            } else {
                // Before the first attempt.
                Button("Show solution", action: onShowSolution)
                    .buttonStyle(DrillButton(tint: ChromeTheme.undoTint))
                Button("Skip", action: onAdvance)
                    .buttonStyle(DrillButton(tint: ChromeTheme.undoTint))
            }
        }
    }
}

/// Caramel pill matching the in-game control buttons.
private struct DrillButton: ButtonStyle {
    let tint: SColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.bold())
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(tint.opacity(configuration.isPressed ? 0.45 : 0.22))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(ChromeTheme.ink)
    }
}

private enum DrillTint {
    static let correct = SColor(light: 0x6a8a4a, dark: 0x86c46c)   // olive-green
    static let close = SColor(light: 0xa87a3e, dark: 0xe09a42)     // amber
    static let wrong = SColor(light: 0xa83a2a, dark: 0xff8d72)     // deep red
}

// MARK: - Previews

#Preview("Drilling") {
    let board = GameBoard()
    board.initializeBoard()
    let eval = PlyEvaluation(
        plyNumber: 5, die1: 6, die2: 5,
        boardStacks: board.points.map(\.pieces), mover: .white,
        playedMove: [[1, 7]], playedScore: 0.42,
        bestMove: [[1, 12]], bestScore: 0.58
    )
    return DrillView(previewModel: DrillModel(preview: .drilling, blunders: [eval]))
}

#Preview("No blunders") {
    DrillView(previewModel: DrillModel(preview: .empty))
}

#Preview("Complete") {
    DrillView(previewModel: DrillModel(preview: .complete(.init(solved: 3, skipped: 1, total: 4))))
}
