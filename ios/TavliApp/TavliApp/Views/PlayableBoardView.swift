import SwiftUI
import BoardGeometry
import TavliEngine

/// How a legal target triangle is marked (T7). The design offers two readings;
/// `frame` is the default (preserves the wood/ivory aesthetic), `fill` is the
/// higher-visibility variant. Flip `PlayableBoardView.highlightStyle` to switch.
enum HighlightStyle {
    case frame
    case fill
}

/// The interactive Caramel board (T7): stacks the static board, highlight
/// overlays, and checkers, and translates tap / drag gestures into `GameSession`
/// intents via `BoardGeometry.hitTest`.
///
/// Layer order (bottom → top) so highlights read correctly:
///   1. `BoardView`           — static frame, surface, triangles
///   2. `TargetHighlightView` — gold frame/fill on legal target triangles
///   3. `CheckersView`        — the checker stacks
///   4. `SourceRingView`      — gold ring on every checker of the selected source
///
/// `BoardDiceView` is layered above as a *sibling* of the gesture-bearing stack
/// (not inside it), so its tap-to-roll and the board's tap/drag never contend:
/// the dice claim taps only while awaiting a roll, and pass through otherwise.
///
/// All layers build an identical `BoardGeometry` from the same square, centered
/// fit, so they register exactly; the gesture geometry is computed from the same
/// `GeometryReader` size. No game logic lives here — the view only reads
/// `session`'s published state and calls its intents.

/// State tracked by `@GestureState` during an active drag: which point the checker
/// came from and the current finger position in board-local coordinates.
private struct LiveDrag {
    var sourcePoint: Int
    var location: CGPoint
}

/// Snap-back animation state after a failed drop: the checker animates from its
/// drop position back to its origin on the board.
private struct SnapBack {
    var position: CGPoint        // current (animated) position
    let origin: CGPoint          // destination of the spring animation
    let color: TavliEngine.Color
}

struct PlayableBoardView: View {
    @ObservedObject var session: GameSession

    /// Target marking style. A constant per the design's two-readings spec.
    var highlightStyle: HighlightStyle = .frame

    /// When true the board renders from Black's perspective (180° flip).
    /// Logical point indices are unchanged; only the visual layout rotates.
    var flipped: Bool = false

    /// When false, all board input — tap-to-roll, tap/drag to move — is blocked,
    /// while rendering and incoming-move animation continue. Online play (#134) sets
    /// this to lock the board on the opponent's turn.
    var interactive: Bool = true

    /// Told when a checker is lifted by a drag (`true`) and when it is let go
    /// (`false`). The drag lives in this view's gesture state, not the session, so a
    /// caller that reacts to "a checker is picked" (the drill's ghost, #232) needs this
    /// alongside `session.selectedPoint`. `nil` (the default) = nobody listens.
    var onLiftChange: ((Bool) -> Void)? = nil

    /// Translation (points) past which a press is treated as a drag, not a tap.
    private let dragThreshold: CGFloat = 10

    /// Live drag state — set by `.updating` during an active drag, auto-reset
    /// to `nil` when the gesture ends. Never mutates session (safe in `onChanged`).
    @GestureState private var liveDrag: LiveDrag? = nil

    /// Snap-back checker shown after a failed drop while it animates to origin.
    @State private var snapBack: SnapBack? = nil
    /// Task that clears `snapBack` after the animation completes. Cancelled and
    /// replaced on each new failed drop so overlapping drags don't clobber.
    @State private var snapBackTask: Task<Void, Never>? = nil

    /// Checkers sent to the bar that are still flying there (#143, Portes hits).
    @State private var hitFlights: [HitFlight] = []

    private struct HitFlight: Identifiable {
        let id = UUID()
        let from: Int
        let to: Int
        let color: TavliEngine.Color
        let duration: TimeInterval
    }

    // ── Engine ↔ display slots (#143) ────────────────────────────────────────
    // Board views work in `BoardLayout` display slots: 0…25 as the engine, with
    // each colour's bar checkers split out of the end stacks into slots 26/27. All
    // mapping goes through the session's variant hooks.

    private var variant: any GameVariant { session.game.variant }
    private var boardSize: Int { session.game.board.boardSize }

    /// The live position as display stacks (trays = borne-off only, bars split out).
    private var layoutStacks: [[TavliEngine.Color]] {
        BoardLayout.displayStacks(session.game.board.points.map(\.pieces), variant: variant)
    }

    /// Display slot of an engine move source (a bar position → its bar slot).
    private func displaySlot(_ position: Int) -> Int {
        BoardLayout.displaySlot(forSource: position, variant: variant, boardSize: boardSize)
    }

    /// Engine source position of a display slot (`-1` = never a source).
    private func sourcePosition(_ slot: Int) -> Int {
        BoardLayout.sourcePosition(forDisplaySlot: slot, variant: variant, boardSize: boardSize) ?? -1
    }

    /// Selectable sources as display slots (bar entries pick up from the bar).
    private var sourceSlots: [Int] { session.selectableSources.map(displaySlot) }

    var body: some View {
        GeometryReader { proxy in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: proxy.size),
                                    flipped: flipped)

            // During a drag or an AI flight (#93): show one fewer checker at
            // the source (it's in the air, drawn by the overlay views below).
            let boardStacks = layoutStacks
            let hopFrom = session.aiHopInFlight.map { displaySlot($0.from) }
            let displayStacks: [[TavliEngine.Color]] = {
                var s = boardStacks
                if let drag = liveDrag, drag.sourcePoint != 0, drag.sourcePoint != boardSize + 1,
                   !s[drag.sourcePoint].isEmpty {
                    s[drag.sourcePoint] = Array(s[drag.sourcePoint].dropLast())
                }
                if let from = hopFrom, !s[from].isEmpty {
                    s[from] = Array(s[from].dropLast())
                }
                // A hit checker still in flight hasn't reached the bar yet.
                for f in hitFlights where !s[f.to].isEmpty {
                    s[f.to] = Array(s[f.to].dropLast())
                }
                return s
            }()

            // Highlight targets: drag targets (read-only, no session mutation) while
            // dragging; fall back to the session's selection-driven targets otherwise.
            // A pending route choice (#169) marks the chosen far destination amber and the
            // candidate intermediate points in the distinct route colour.
            let highlightTargets: Set<Int> = {
                if let choice = session.routeChoice { return [choice.destination] }
                guard let drag = liveDrag,
                      session.selectableSources.contains(sourcePosition(drag.sourcePoint)) else {
                    return session.validTargets
                }
                return session.moveBuilder.validDestinations(for: sourcePosition(drag.sourcePoint))
            }()

            // Source ring: drag source while dragging, session selection otherwise.
            let ringPoint: Int? = liveDrag?.sourcePoint ?? session.selectedPoint.map(displaySlot)

            ZStack {
                ZStack {
                    BoardView(flipped: flipped)
                    // Tier-2 handicap cues (#148): safe points, shortened homes.
                    HandicapBoardCuesView(rules: session.game.board.config.handicapRules, flipped: flipped)
                    TargetHighlightView(targets: highlightTargets, style: highlightStyle,
                                        flipped: flipped)
                    if let choice = session.routeChoice {
                        TargetHighlightView(targets: choice.intermediatePoints, style: highlightStyle,
                                            flipped: flipped, tint: CaramelPalette.hlRoute)
                    }
                    CheckersView(stacks: displayStacks, flipped: flipped)
                    SourceRingView(selectedPoint: ringPoint, stacks: displayStacks,
                                   flipped: flipped)
                    if let hint = session.hint {
                        // A handicap hint (#148): the best move in blue, not played.
                        MoveHighlightView(playedMove: [], bestMove: hint, stacks: boardStacks,
                                          flipped: flipped, variant: session.game.variant)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(boardGesture(geo: geo))

                BoardDiceView(session: session)

                // Floating checker follows the finger above all board layers.
                if let drag = liveDrag, let topColor = boardStacks[drag.sourcePoint].last {
                    DraggedCheckerView(geo: geo, location: drag.location, color: topColor)
                }

                // Snap-back ghost animates to the checker's origin after a failed drop.
                if let sb = snapBack {
                    DraggedCheckerView(geo: geo, location: sb.position, color: sb.color)
                }

                // The AI's checker arcs above all layers while a hop is in
                // flight (#93). `.id` forces a fresh view per hop so the flight
                // restarts even when consecutive hops share endpoints (a Pasch
                // moving two checkers along the same route).
                if let hop = session.aiHopInFlight, let from = hopFrom {
                    AIFlightCheckerView(from: from, to: hop.to, color: hop.color,
                                        duration: hop.duration, geo: geo, stacks: boardStacks)
                        .id(hop.id)
                }

                // Hit checkers flying to the bar (#143): from the hit point's base
                // to the next free bar slot.
                ForEach(hitFlights) { f in
                    ArcFlightView(geo: geo, color: f.color,
                                  start: geo.checkerCenter(point: f.from, slot: 0),
                                  end: geo.checkerCenter(point: f.to,
                                                         slot: min(displayStacks[f.to].count, 4)),
                                  duration: f.duration)
                }
            }
            .accessibilityElement()
            .accessibilityIdentifier("board")
            .accessibilityValue(boardSignature)
        }
        .aspectRatio(1, contentMode: .fit)
        // Animate a hit (#143): when a colour's bar grows, fly the hit checker(s)
        // from the point they were taken on to the bar, for the AI's hops and the
        // human's own moves alike. Undo (bar shrinking) snaps without animation.
        .onChange(of: layoutStacks) { old, new in
            let duration = session.animationTimings.aiMoveAnimationDuration
            guard duration > 0 else { return }
            let flights = BoardLayout.hits(from: old, to: new).map {
                HitFlight(from: $0.from, to: $0.to, color: $0.color, duration: duration)
            }
            guard !flights.isEmpty else { return }
            hitFlights += flights
            let ids = Set(flights.map(\.id))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                hitFlights.removeAll { ids.contains($0.id) }
            }
        }
        .onChange(of: liveDrag != nil) { _, lifted in onLiftChange?(lifted) }
        // Online (#134): lock the board on the opponent's turn — blocks tap-to-roll
        // and tap/drag while letting the incoming move animate.
        .disabled(!interactive)
        // #185: the physical board never mirrors under a right-to-left language — point
        // numbering, drag gestures and hit-testing all assume LTR geometry.
        .boardLayoutDirection()
    }

    /// Compact per-point checker counts, exposed for UI tests to assert board
    /// mutations without pixel inspection (the board is Canvas-drawn).
    private var boardSignature: String {
        (0...25).map { String(session.game.board.points[$0].count) }.joined(separator: ",")
    }

    // ── Gesture ─────────────────────────────────────────────────────────────

    /// One `DragGesture(minimumDistance: 0)` serves both interactions.
    ///
    /// **During drag** (`.updating`): the `@GestureState liveDrag` is updated with the
    /// source point and current finger location. This only reads from session (no mutation,
    /// no publish), so the gesture is never cancelled mid-flight. The floating checker and
    /// target highlights update reactively from `liveDrag`.
    ///
    /// **On release** (`onEnded`): a drag that started on a selectable source selects it
    /// and commits if the drop landed on a valid target. A failed drop shows a spring
    /// snap-back animation. Everything else routes through `handleTap`.
    ///
    /// Mutating session state from `onChanged` republishes and rebuilds the enclosing
    /// `GeometryReader`, cancelling the gesture on real devices — so all session intent
    /// dispatch stays in `onEnded`.
    private func boardGesture(geo: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($liveDrag) { value, state, _ in
                let moved = hypot(value.translation.width, value.translation.height) > dragThreshold
                // No drag while a route choice (#169) is pending: the next touch picks
                // an intermediate point or cancels.
                guard moved, session.routeChoice == nil,
                      let src = geo.hitTest(value.startLocation, candidates: sourceSlots)
                else { return }
                state = LiveDrag(sourcePoint: src, location: value.location)
            }
            .onEnded { value in
                if session.routeChoice != nil {
                    handleTap(value.location, geo: geo)
                    return
                }
                let moved = hypot(value.translation.width, value.translation.height) > dragThreshold
                if moved,
                   let src = geo.hitTest(value.startLocation, candidates: sourceSlots) {
                    // `src` is a display slot (a bar slot for a bar entry); the
                    // session speaks engine positions.
                    let from = sourcePosition(src)
                    session.selectPoint(from)
                    if let dest = geo.hitTest(value.location,
                                              candidates: Array(session.validTargets)) {
                        session.commitHalfMove(from: from, to: dest)
                    } else {
                        // Failed drop: spring the checker back to its stack position.
                        let pieces = layoutStacks[src]
                        let topSlot = max(0, min(pieces.count, 5) - 1)
                        let origin = geo.checkerCenter(point: src, slot: topSlot)
                        snapBack = SnapBack(position: value.location,
                                           origin: origin,
                                           color: pieces.last ?? .white)
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                            snapBack?.position = origin
                        }
                        snapBackTask?.cancel()
                        snapBackTask = Task { @MainActor in
                            do {
                                try await Task.sleep(nanoseconds: 450_000_000)
                                snapBack = nil
                            } catch {}
                        }
                        // Clear the selection that selectPoint(src) just set.
                        session.selectPoint(-1)
                    }
                } else {
                    handleTap(value.location, geo: geo)
                }
            }
    }

    /// Tap: commit when a target is tapped with a source already selected;
    /// otherwise (re)select the tapped point. Tapping empty space or a
    /// non-selectable point clears the selection (`selectPoint` ignores it).
    private func handleTap(_ location: CGPoint, geo: BoardGeometry) {
        // Display slots 0…27 (incl. the bar, #143). Targets are points or trays,
        // identical in both spaces; a source tap maps a bar slot to its engine end.
        let tapped = geo.hitTest(location, candidates: Array(0..<BoardLayout.slotCount)) ?? -1
        // Pending route choice (#169): a candidate intermediate point plays that route;
        // any other tap cancels with nothing played.
        if session.routeChoice != nil {
            session.chooseRoute(via: tapped)
            return
        }
        if let sel = session.selectedPoint, session.validTargets.contains(tapped) {
            session.commitHalfMove(from: sel, to: tapped)
        } else {
            session.selectPoint(sourcePosition(tapped))
        }
    }
}

/// Gold marking on every legal target (T7). A pure function of the target set +
/// style; overlays `BoardView` below the checkers. Playable points (1…24) are
/// marked on their triangle; bear-off slots (0/25) are marked as a gold tray box
/// on the corresponding half of the right frame strip (top = White/25,
/// bottom = Black/0) — the Caramel design has no bear-off art, so this is the
/// only bear-off visual. Both honor the same `HighlightStyle`.
struct TargetHighlightView: View {
    let targets: Set<Int>
    let style: HighlightStyle
    var flipped: Bool = false
    /// Overrides the amber marking (#169: `CaramelPalette.hlRoute` for the
    /// intermediate points of a pending route choice). `nil` = the standard colours.
    var tint: SwiftUI.Color? = nil

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            let s = geo.scale
            for n in targets {
                if n >= 1 && n <= 24 {
                    markTriangle(&context, geo: geo, point: n, s: s)
                } else if n == 0 || n == 25 {
                    markBearOff(&context, geo: geo, slot: n, s: s)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }

    private func markTriangle(_ context: inout GraphicsContext,
                              geo: BoardGeometry, point n: Int, s: CGFloat) {
        let pt = geo.point(n)
        var tri = Path()
        tri.move(to: pt.baselineLeft)
        tri.addLine(to: pt.baselineRight)
        tri.addLine(to: pt.tip)
        tri.closeSubpath()
        switch style {
        case .frame:
            context.stroke(tri, with: .color(tint ?? CaramelPalette.hl),
                           style: StrokeStyle(lineWidth: 5 * s, lineJoin: .round))
        case .fill:
            context.fill(tri, with: .color(tint ?? CaramelPalette.hlFill))
            context.stroke(tri, with: .color(CaramelPalette.triangleStroke),
                           style: StrokeStyle(lineWidth: 2.6 * s, lineJoin: .round))
        }
    }

    /// Gold tray box on the bear-off half-strip. The box is the slot's `hitRect`
    /// inset for breathing room, with rounded corners; `.frame` strokes it gold,
    /// `.fill` fills it gold with a dark edge (mirroring the triangle styles).
    private func markBearOff(_ context: inout GraphicsContext,
                             geo: BoardGeometry, slot n: Int, s: CGFloat) {
        let tray = geo.point(n).hitRect.insetBy(dx: 5 * s, dy: 10 * s)
        let box = Path(roundedRect: tray, cornerRadius: 8 * s)
        switch style {
        case .frame:
            context.stroke(box, with: .color(tint ?? CaramelPalette.hl), lineWidth: 5 * s)
        case .fill:
            context.fill(box, with: .color(tint ?? CaramelPalette.hlFill))
            context.stroke(box, with: .color(CaramelPalette.hlEdge), lineWidth: 2 * s)
        }
    }
}

/// Gold ring around every visible checker of the selected source point (T7).
/// Drawn above the checkers; the ring sits just outside the disc (radius
/// `checkerRadius + 3.2`), matching the design's `selected` ring.
struct SourceRingView: View {
    let selectedPoint: Int?
    /// Per-slot stacks (value type) so the ring tracks the selected stack reliably;
    /// see `CheckersView` for why `[Point]` references can't drive a Canvas redraw.
    let stacks: [[TavliEngine.Color]]
    var flipped: Bool = false

    var body: some View {
        Canvas { context, size in
            // Points 1…24 and the bar slots (#143); never a tray.
            guard let sel = selectedPoint, stacks.indices.contains(sel),
                  (1...24).contains(sel) || BoardLayout.isBarSlot(sel) else { return }
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            let r = geo.checkerRadius
            let s = geo.scale
            let visible = min(stacks[sel].count, 5)
            for slot in 0..<visible {
                let c = geo.checkerCenter(point: sel, slot: slot)
                let ringR = r + 3.2 * s
                let ring = Path(ellipseIn: CGRect(
                    x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR
                ))
                context.stroke(ring, with: .color(CaramelPalette.hl), lineWidth: 3.4 * s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }
}

/// How one move is drawn on the board in review/drill (#232). One meaning per colour,
/// on the blue–yellow axis that red-green colour blindness keeps (the old green "both"
/// colour vanished on the mahogany board — #232):
///
/// - `played` — your move (review) / your attempt (drill solution): amber, solid.
/// - `best` — the best move (also the in-game handicap hint): blue, solid.
/// - `ghost` — the drill's reminder of the move you played in the game, before an
///   attempt: grey, **dashed** and thinner. Dashed means "not actually on the board".
///
/// `MoveMarkSwatch` draws the same style as a short line for panel legends; a legend
/// shows a swatch only while that mark is drawn (`MoveHighlightView.drawnMarks`).
enum MoveMarkStyle {
    case played
    case best
    case ghost

    var color: SwiftUI.Color {
        switch self {
        case .played: return CaramelPalette.hl
        case .best: return CaramelPalette.hlBest
        case .ghost: return CaramelPalette.hlGhost
        }
    }

    /// Stroke for a landing frame (triangle / tray box), in board units scaled by `s`.
    func frameStroke(_ s: CGFloat) -> StrokeStyle {
        switch self {
        case .played: return StrokeStyle(lineWidth: 5 * s, lineJoin: .round)
        case .best: return StrokeStyle(lineWidth: 5 * s, lineJoin: .round)
        case .ghost: return StrokeStyle(lineWidth: 4.2 * s, lineJoin: .round, dash: [8 * s, 6 * s])
        }
    }

    /// Stroke for a source ring around a checker, in board units scaled by `s`.
    func ringStroke(_ s: CGFloat) -> StrokeStyle {
        switch self {
        case .played: return StrokeStyle(lineWidth: 3.4 * s)
        case .best: return StrokeStyle(lineWidth: 3.4 * s)
        case .ghost: return StrokeStyle(lineWidth: 3 * s, dash: [5 * s, 4 * s])
        }
    }

    /// The same stroke at legend size (points), for `MoveMarkSwatch`.
    var swatchStroke: StrokeStyle {
        switch self {
        case .played: return StrokeStyle(lineWidth: 3, lineCap: .round)
        case .best: return StrokeStyle(lineWidth: 3, lineCap: .round)
        case .ghost: return StrokeStyle(lineWidth: 2.4, dash: [3.5, 3])
        }
    }
}

/// A short line in a `MoveMarkStyle` — the legend swatch next to a move row (drill
/// panel, review legend; #232), matching how that move is drawn on the board.
/// Decorative: the row's text label carries the meaning.
struct MoveMarkSwatch: View {
    let style: MoveMarkStyle

    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 2, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            context.stroke(line, with: .color(style.color), style: style.swatchStroke)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    /// The swatch's footprint — also the gap a legend row leaves when its mark isn't drawn.
    static let size = CGSize(width: 24, height: 10)
}

/// Review/drill move highlighter (#133, restyled #232). Renders a *whole move* with
/// the Caramel highlight language — a ring on each source point's moved checkers, a
/// frame on each landing triangle — extended three ways the live `SourceRingView` /
/// `TargetHighlightView` pair did not:
///
///  1. **Every source is highlighted**, not just the first half-move's. A compound
///     move (two half-moves, or up to four under a Pasch double) rings all of them.
///  2. **Pass-through hops are cancelled by count.** Where a checker merely hops
///     over a point it gets no highlight (e.g. a single checker 13→9→5→1 marks only
///     source 13 and target 1). This is counted, not set-based: at a point where `k`
///     checkers arrive and `j` leave, `min(k, j)` are pass-throughs, any surplus
///     arrivals are genuine landings, and any surplus departures genuine sources — so
///     a point that is *both* a landing and a hop-over (one checker stays while
///     another passes through, e.g. a Pasch 1→4, 4→7, 1→4) still reads as a landing.
///  3. **Only the moved checkers are ringed** — the count of half-moves leaving a
///     point (usually one, up to four with doubles), taken from the top of the
///     stack — not every checker sitting there.
///
/// Styles (#232, `MoveMarkStyle`): `playedMove` draws in `playedStyle` (amber solid by
/// default; the drill's ghost passes `.ghost`), a non-nil `bestMove` in blue.
/// Where both moves land on one point, or lift a checker from one point, **both marks
/// are drawn**: the played frame/ring with a slightly larger blue one around it.
/// When the two moves are the same (same sources and landings) only the blue is drawn.
/// With `bestMove == nil` only the played move is shown.
struct MoveHighlightView: View {
    /// The move to show in `playedStyle` ("your move"). May be empty (e.g. a hint
    /// that only wants the blue best move).
    let playedMove: [[Int]]
    /// The best move to compare against, in blue; `nil` hides it.
    let bestMove: [[Int]]?
    /// Pre-move per-slot stacks, so rings track the real checker positions.
    let stacks: [[TavliEngine.Color]]
    var flipped: Bool = false
    /// The game's rules (#143): a source on a bar position (Portes entry) is ringed
    /// on the bar, and `stacks` are split into trays + bars the same way the board is.
    var variant: any GameVariant = GameVariants.plakoto
    /// How `playedMove` is drawn (#232): `.played` (amber solid) or `.ghost` (the
    /// drill's game move, grey dashed).
    var playedStyle: MoveMarkStyle = .played

    /// How far (board units) the outer blue mark of a shared point sits outside the
    /// inner one: half the inner stroke + a hair of gap + half the blue stroke.
    private static let frameOutset: CGFloat = 7
    private static let ringOutset: CGFloat = 5

    private var displayStacks: [[TavliEngine.Color]] {
        stacks.count == BoardLayout.slotCount ? stacks : BoardLayout.displayStacks(stacks, variant: variant)
    }

    /// The genuine source points and landing points of a move, after cancelling
    /// hop-overs *by count* (#133). `sources` lists each genuine source point
    /// once per checker lifted there (so a point can carry several rings); `targets`
    /// is the set of genuine landing points.
    private struct Marks: Equatable {
        var sources: [Int]
        var targets: Set<Int>

        static func == (a: Marks, b: Marks) -> Bool {
            a.sources.sorted() == b.sources.sorted() && a.targets == b.targets
        }
    }

    private static func marks(of move: [[Int]]) -> Marks {
        let pairs = move.filter { $0.count == 2 }
        // Per point: how many checkers arrive vs leave. The min cancels as a hop-over;
        // any surplus arrival is a real landing, any surplus departure a real source.
        var arrivals: [Int: Int] = [:], departures: [Int: Int] = [:]
        for p in pairs {
            departures[p[0], default: 0] += 1
            arrivals[p[1], default: 0] += 1
        }
        var sources: [Int] = []
        for (pt, dep) in departures {
            let net = dep - (arrivals[pt] ?? 0)
            if net > 0 { sources += Array(repeating: pt, count: net) }
        }
        let targets = Set(arrivals.compactMap { pt, arr in
            arr - (departures[pt] ?? 0) > 0 ? pt : nil
        })
        return Marks(sources: sources, targets: targets)
    }

    /// Which of the two moves actually leaves a mark on the board — for legends, which
    /// show a swatch only for a drawn mark (#232). The played move draws unless it is
    /// empty (no genuine source or landing) or the same as the best (then blue only);
    /// the best draws whenever it is given and non-empty.
    static func drawnMarks(playedMove: [[Int]], bestMove: [[Int]]?) -> (played: Bool, best: Bool) {
        let mine = marks(of: playedMove)
        let best = bestMove.map { marks(of: $0) }
        let mineEmpty = mine.sources.isEmpty && mine.targets.isEmpty
        let bestDrawn = best.map { !($0.sources.isEmpty && $0.targets.isEmpty) } ?? false
        return (played: !mineEmpty && mine != best, best: bestDrawn)
    }

    /// One ring on one lifted checker: its own style, plus the blue ring drawn
    /// around it when the best move lifts that checker too.
    private struct Ring { let style: MoveMarkStyle; var outer: MoveMarkStyle? = nil }

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            let s = geo.scale
            let best = bestMove.map { Self.marks(of: $0) }
            // Your move equal to the best → blue only (#232; the ✓ lives in the panel).
            let mine: Marks? = {
                let m = Self.marks(of: playedMove)
                if let best, best == m { return nil }
                return m
            }()
            let mineTargets = mine?.targets ?? []
            let bestTargets = best?.targets ?? []

            // Targets first (under the source rings). A point both moves land on gets
            // the played frame plus a slightly larger blue frame around it —
            // including when you reached it with the wrong die (#133).
            for t in mineTargets.union(bestTargets) {
                let isMine = mineTargets.contains(t), isBest = bestTargets.contains(t)
                if isMine {
                    drawTarget(&context, geo: geo, point: t, style: playedStyle, outset: 0, s: s)
                }
                if isBest {
                    drawTarget(&context, geo: geo, point: t, style: .best,
                               outset: isMine ? Self.frameOutset : 0, s: s)
                }
            }
            // Source rings, per point **by count** (#133): of the pieces lifted from a
            // point, the number both moves agree on carry both rings (regardless of
            // where each went — a right point / wrong move still counts), any extra the
            // best move lifts there are blue only, and any extra you lifted that the best
            // wouldn't are yours only. So played-1 / best-2 from one point reads as one
            // double ring + one blue ring.
            let toDisplay = { (p: Int) in BoardLayout.displaySlot(forSource: p, variant: variant) }
            let mineSources = (mine?.sources ?? []).map(toDisplay)
            let bestSources = (best?.sources ?? []).map(toDisplay)
            let shown = displayStacks
            for src in Set(mineSources).union(bestSources) {
                let m = mineSources.filter { $0 == src }.count
                let b = bestSources.filter { $0 == src }.count
                let shared = min(m, b)
                let rings = Array(repeating: Ring(style: playedStyle, outer: .best), count: shared)
                    + Array(repeating: Ring(style: .best), count: b - shared)      // best wants more off here
                    + Array(repeating: Ring(style: playedStyle), count: m - shared) // you lifted more than best
                drawSourceRings(&context, geo: geo, point: src, rings: rings, stacks: shown, s: s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }

    /// Frame the landing triangle (1…24) or the bear-off tray box (0/25), pushed
    /// `outset` board units outwards (the outer mark of a shared point).
    private func drawTarget(_ context: inout GraphicsContext, geo: BoardGeometry,
                            point n: Int, style: MoveMarkStyle, outset: CGFloat, s: CGFloat) {
        if n >= 1 && n <= 24 {
            let pt = geo.point(n)
            let corners = Self.outsetTriangle(pt.baselineLeft, pt.baselineRight, pt.tip,
                                              by: outset * s)
            var tri = Path()
            tri.move(to: corners[0])
            for c in corners.dropFirst() { tri.addLine(to: c) }
            tri.closeSubpath()
            context.stroke(tri, with: .color(style.color), style: style.frameStroke(s))
        } else if n == 0 || n == 25 {
            let tray = geo.point(n).hitRect.insetBy(dx: (5 - outset) * s, dy: (10 - outset) * s)
            context.stroke(Path(roundedRect: tray, cornerRadius: (8 + outset) * s),
                           with: .color(style.color), style: style.frameStroke(s))
        }
    }

    /// The triangle `a b c` (`c` = the sharp tip) with every edge pushed `d` outwards:
    /// scaled about its incentre, which moves each edge by the same distance. The
    /// tip is then cut square `d` past the original tip — a point's apex is so sharp
    /// that the pure outset spike would reach far into the middle of the board.
    private static func outsetTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint,
                                       by d: CGFloat) -> [CGPoint] {
        guard d > 0 else { return [a, b, c] }
        let la = hypot(b.x - c.x, b.y - c.y)   // side opposite a
        let lb = hypot(c.x - a.x, c.y - a.y)
        let lc = hypot(a.x - b.x, a.y - b.y)
        let perimeter = la + lb + lc
        guard perimeter > 0 else { return [a, b, c] }
        let incentre = CGPoint(x: (la * a.x + lb * b.x + lc * c.x) / perimeter,
                               y: (la * a.y + lb * b.y + lc * c.y) / perimeter)
        let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        let inradius = 2 * area / perimeter
        guard inradius > 0 else { return [a, b, c] }
        let k = (inradius + d) / inradius
        let scaled = [a, b, c].map {
            CGPoint(x: incentre.x + k * ($0.x - incentre.x), y: incentre.y + k * ($0.y - incentre.y))
        }
        let (a2, b2, c2) = (scaled[0], scaled[1], scaled[2])
        // Cut the tip: along the axis u (incentre → tip), keep only what lies within
        // `d` past the original tip.
        let axis = CGPoint(x: c.x - incentre.x, y: c.y - incentre.y)
        let axisLength = hypot(axis.x, axis.y)
        guard axisLength > 0 else { return scaled }
        let u = CGPoint(x: axis.x / axisLength, y: axis.y / axisLength)
        func along(_ p: CGPoint) -> CGFloat { (p.x - c.x) * u.x + (p.y - c.y) * u.y }
        let overshoot = along(c2)
        guard overshoot > d else { return scaled }
        func cut(towards q: CGPoint) -> CGPoint {
            let t = (d - overshoot) / (along(q) - overshoot)
            return CGPoint(x: c2.x + t * (q.x - c2.x), y: c2.y + t * (q.y - c2.y))
        }
        return [a2, b2, cut(towards: b2), cut(towards: a2)]
    }

    /// Ring the top checkers of the source point (the ones lifted off), one entry of
    /// `rings` per checker, applied top-down.
    private func drawSourceRings(_ context: inout GraphicsContext, geo: BoardGeometry,
                                 point n: Int, rings: [Ring],
                                 stacks: [[TavliEngine.Color]], s: CGFloat) {
        // Points 1…24 and the bar slots (a Portes entry, #143).
        guard (1...24).contains(n) || BoardLayout.isBarSlot(n), stacks.indices.contains(n),
              !rings.isEmpty else { return }
        let r = geo.checkerRadius
        let visible = min(stacks[n].count, 5)
        let count = min(rings.count, visible)
        for i in 0..<count {
            let slot = visible - 1 - i
            let c = geo.checkerCenter(point: n, slot: slot)
            let ring = rings[i]
            stroke(&context, ringAround: c, radius: r + 3.2 * s, style: ring.style, s: s)
            if let outer = ring.outer {
                stroke(&context, ringAround: c, radius: r + (3.2 + Self.ringOutset) * s,
                       style: outer, s: s)
            }
        }
    }

    private func stroke(_ context: inout GraphicsContext, ringAround c: CGPoint,
                        radius: CGFloat, style: MoveMarkStyle, s: CGFloat) {
        let circle = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius,
                                            width: 2 * radius, height: 2 * radius))
        context.stroke(circle, with: .color(style.color), style: style.ringStroke(s))
    }
}

// ── Previews ─────────────────────────────────────────────────────────────────

@MainActor
private func startScenarioSession() -> GameSession {
    // White on point 1, dice 3·5 → reachable targets 4, 6, 9 (matches the
    // design's reference highlight scenario), with point 1 selected.
    let session = GameSession(startingPlayer: .white)
    session.setDice(3, 5)
    session.selectPoint(1)
    return session
}

#Preview("Frame highlight (default)") {
    PlayableBoardView(session: startScenarioSession(), highlightStyle: .frame)
        .padding(24)
        .background(ChromeKit.pageColor)
}

#Preview("Fill highlight") {
    PlayableBoardView(session: startScenarioSession(), highlightStyle: .fill)
        .padding(24)
        .background(ChromeKit.pageColor)
}

// A near-end position with borne-off checkers in both trays — White (25, top)
// tall enough to show the count badge, Black (0, bottom) a short stack — so the
// persistent tray chrome + stacked borne-off checkers read against the board.
@MainActor
private func bearOffScenarioSession() -> GameSession {
    let session = GameSession(startingPlayer: .white)
    session.game.board.setPoint(25, pieces: Array(repeating: .white, count: 8))
    session.game.board.setPoint(0, pieces: Array(repeating: .black, count: 3))
    return session
}

#Preview("Borne-off checkers in trays") {
    PlayableBoardView(session: bearOffScenarioSession())
        .padding(24)
        .background(ChromeKit.pageColor)
}

// Bear-off target boxes on the right strip (top = White/25, bottom = Black/0).
// Driven directly (not via a session) to show the design without setting up a
// near-end-of-game board.
#Preview("Bear-off targets (frame)") {
    ZStack {
        BoardView()
        TargetHighlightView(targets: [0, 25], style: .frame)
    }
    .padding(24)
    .background(ChromeKit.pageColor)
}

#Preview("Bear-off targets (fill)") {
    ZStack {
        BoardView()
        TargetHighlightView(targets: [0, 25], style: .fill)
    }
    .padding(24)
    .background(ChromeKit.pageColor)
}
