# ios/ — engine reference

Reimplementation-grade detail for the headless engine layer (turn controller,
persistence, stats) and the directory layout. The directory `CLAUDE.md` carries
the index, build/parity commands, and conventions; this file holds the deep
detail. The SwiftUI rendering layer is documented separately under
`TavliApp/TavliApp/Views/`.

## Turn controller (headless, UI-agnostic)

`GameSession` + `MoveBuilder` are the contract the SwiftUI views build against. Both are
**SwiftUI-free** (only `Combine` for `ObservableObject`) and fully exercised by `swift test`,
so the game flow is validated without a simulator.

- **`MoveBuilder`** incrementally composes a full `Move` from half-moves. It holds
  `activeMoves` (legal `Move`s still consistent with what's been picked) + `built: [HalfMove]`,
  and a **read-only reference to the live `GameBoard`** (it reads occupancy to decide
  playability; it never applies/undoes — the session mutates that same board in step, so the
  builder always sees the position after the built prefix). Constructed with the dice
  (`init(legalMoves:board:die1:die2:)`) so it can unmerge (below).
  **Order-independent:** the engine stores each multi-die move in one canonical order, but the
  player may play those halves in any order, so the builder treats a move's half-moves as a *bag*
  (`remaining(of:)` is a pure multiset difference of `m.halfMoves` minus `built`; `nil` if `built`
  isn't a sub-multiset). It decides which half-move may come next from the **live board**, not a
  board-blind heuristic: a remaining half-move is playable-next iff its `from` currently holds a
  movable checker (`movablePieces(for:) > 0`, or a checker just arrived there mid-chain) **and**
  its `to` is open. This distinguishes a genuine single-checker chain (`8→6→4`, where 6 is empty
  until the first hop fills it, so `6→4` waits) from two *independent* checkers whose ray
  positions coincide (a checker at 8 and a separate one at 6 — both immediately playable, either
  order). The old `to == from` test couldn't tell those apart and wrongly locked out the
  independent checker (issue #44). No ordering re-check is needed in `remaining` because every
  committed half-move was board-legal in real order at commit time.
  **Multi-hop (Pasch).** On doubles the engine stores each equal-distance hop as a separate
  half-move, so `validDestinations(for:)` returns the **full reachable ray** (`s±N, s±2N, …`) and
  `path(from:to:)` gives the ordered single-die hops the session commits for a tap on a far
  endpoint.
  **Unmerged (non-Pasch single checker).** When one checker plays *both* distinct dice the engine
  stores it *merged* as a single half-move of distance `d1+d2` (e.g. `1→9` for dice 3·5). Left
  merged the player could only tap the far endpoint, never stop on or continue from the
  intermediate. So at construction the builder **unmerges** every such move into its single-die hop
  sequence(s) through whichever intermediate(s) are open at turn start — one expanded `Move` per
  legal intermediate (`[1→4, 4→9]` and/or `[1→6, 6→9]`). Both the stops and the far endpoint then
  highlight, and tapping a stop lets the same checker continue; the final board position is
  identical to the merged half-move. With this, non-Pasch single-checker moves run through the same
  bag/chaining machinery as Pasch.
  **Legal play order (#169).** The bag would accept a legal move's halves in any order, incl.
  orders no player may play (the engine's canonical order is not always one either: house Plakoto
  lists `[22→25, 18→19]` for dice 3·1, standard Plakoto sorts its halves). So every play must also
  pass the variant's `isLegalStep(from:to:color:die:on:)` at the position it is played, for one of
  the still-unplayed dice (`diceStates`, a set of remaining-dice multisets per built half — a
  bear-off may be playable by more than one die). Portes/Fevga/standard Plakoto answer it with
  their own generator's step rule (`isStep`), house Plakoto with the protocol default. Enforced:
  Portes bar-first; bear-off only once every checker is home (bar included); larger-die bear-off
  only from the rearmost point; Fevga's first-checker lock. Before this, the builder let a player
  break each of these in all four variants. Commits are judged on the turn-start position replayed
  through `built`; far-endpoint chains are simulated on a scratch board. Without dice
  (`die1 == 0`, tests) only board playability is checked.
  **Routes (#169).** Portes never merges (a two-dice checker move is two halves in the legal list,
  since an intermediate hit matters), so the same chaining also offers its far endpoints — but
  `src→a→dst` and `src→b→dst` may end in different positions. `routeOptions(from:to:)` collects
  the **shortest** hop chains to `dst` that are prefixes of a surviving move (so the legal list,
  incl. bar-first and use-max-dice, decides what exists), applies each on a scratch board copy and
  keeps one chain per distinct resulting position (first in search order). One option → play it;
  several → the session asks (never auto-resolved). Plakoto/Fevga unmerged routes always end in the
  same position (a pin made in passing is released), so they keep playing directly; doubles have
  fixed intermediates, so they never ask. Engine move representation and Python parity untouched.
  **Gestures.** `commit(halfMoves:)` commits one player gesture's hops together (`commit(halfMove:)`
  is a one-hop gesture); `lastGesture` / `undoGesture()` take the whole last gesture back.
  `selectableSourcePoints` / `validDestinations(for:)` are the `from`/`to` of the board-aware
  playable-next half-moves across surviving moves; `commit(halfMove:)` keeps the moves whose
  remaining bag contains the half-move, appends it, and returns whether nothing remains (complete);
  `canFinishNow` is true when some surviving move has no remaining halves (a shorter move that is a
  prefix of a longer one is *finishable*, not *forced*); `undo()` (no `allLegal:` argument anymore)
  rebuilds `activeMoves` from the stored **expanded** legal-move set; `completedMove` is a surviving
  move with no remaining halves.

- **`GameSession`** (`@MainActor`, `ObservableObject`) owns the `Game` and drives the turn state
  machine. Phases: `awaitingRoll / picking / moving / aiThinking / animating / gameOver(winner:)`
  — the four human-move phases plus `aiThinking` (the off-main search) and `animating` (the
  presentational replay of the AI's turn, #93); both AI phases block human input through the
  same guards the intents already use. Intents: `roll` / `setDice(_:_:)`
  (deterministic dice for scripted play — tests, previews, the `-uiTestGame` hook, the drill
  seeder; always starts a human turn, #176) / `selectPoint` / `commitHalfMove(from:to:)` /
  `undo` / `undoLastDecision` / `confirm` / `surrender` / `newGame`. On roll it computes `legalMoves` via
  the variant's `legalMoves` (Plakoto: `PossibleMoves`); an empty set is a **forced pass** that advances the turn. `commitHalfMove`
  applies the half-move to the board and auto-finishes when the move is complete or the only
  continuation is itself legal. Win detection uses `game.getWinner()`; `finishTurn` records the
  ply, switches turn, and returns to `awaitingRoll`.
  **Pending roll (#171).** `pendingRoll: PendingRoll?` (published) is set by `markRolled()` the
  moment dice exist for the side on move — `rollDice()` (tap, auto-roll, the AI's roll, replayed
  dice), `setDice`, `undoLastDecision` — and cleared by `recordTurn` (the roll became a
  ply), `surrender`, `newGame` and `replay`. `rollRevision`
  (published `Int`) is bumped on every set and when the roll is dropped without a ply; `GameView` observes it to
  write the autosave as soon as a roll exists (alongside the existing per-ply
  `history.count` trigger). Half-moves already picked are **not** tracked: a resumed turn
  restarts with the full roll.
  Published read-state (`phase`, `legalMoves`, `selectedPoint`, `validTargets`, `selectableSources`,
  `winProbability`, plus `aiDiceRolling`/`aiHopInFlight` for the AI-turn animation, #93) is the
  view contract. No rendering lives here.

- **Manual dice entry removed (#174, #176).** The manual-dice mode (#110: human enters the AI's
  dice, `manualDiceEntry`, the Undo step-back to dice entry) is gone from the engine.
  `takeAITurn` is just `rollDice()` + `playAITurn(animateDiceRoll: true)`.

- **AI-turn animation (#93).** Driven entirely by the session so the view layer stays passive;
  knobs live in **`AnimationTimings`** (`aiDiceRollDuration` / `aiMoveAnimationDuration`, both
  0.6 s in `.standard` for a ~1.8 s two-move turn; settings UI lands with #77). The struct is a
  mutable `var animationTimings` on the session (init parameter, default `.standard`, also
  threaded through `resume(from:)`); `.off` (both zero) restores the fully synchronous
  pre-animation behavior — headless tests pass it — and `isAnimated` is the gate `takeAITurn`
  checks. Animated flow:
  1. `takeAITurn` rolls (values are set up front — the search needs them), then `playAITurn`
     computes legal moves and sets `aiDiceRolling = true` (when the effective roll window > 0).
     With a model it enters `aiThinking` and the search runs **concurrently with the dice tumble**;
     the random fallback and the forced pass skip straight to `animating`. (A resumed pending roll,
     #171, calls `playAITurn(animateDiceRoll: false)` so the roll window is 0 — no tumble.)
  2. Once the move is chosen, `animateAITurn` (phase → `animating`) sleeps out the *remainder* of
     the tumble window (`rollDuration`, 0 for a restored roll), then clears `aiDiceRolling` — the dice
     settle on the real values.
  3. For each half-move in stored order it publishes an **`AIAnimatedHop`** (`id` = ordinal —
     distinguishes consecutive hops with identical endpoints on a Pasch — plus `from`/`to`/
     `color`/`duration`), sleeps `aiMoveAnimationDuration`, then **lands** it: `applyHalfMove` on
     the live board, `moveBuilder.commit` (so the dice grey die-by-die), `aiHopInFlight = nil`.
     The board advances point by point; all four hops of a Pasch are individually visible.
  4. After the last hop: a fresh empty `MoveBuilder` (a stale `built` would re-enable the
     within-turn Undo for the human), the `winProbability` update, `recordTurn`, `finishTurn`.
     A forced pass (`move == nil`) still tumbles and settles the dice, holds them for a short
     beat (`passBeat` — 0.45 s at standard timings, scaled down with the knobs so near-zero test
     timings stay near-instant), then records the pass.
  **Cancellation.** The driver task is stored (`aiAnimationTask`) and re-validates
  `[weak self] + !Task.isCancelled + aiTurnEpoch` after every suspension; `newGame()` bumps the
  epoch, cancels the task, and resets the published animation state, so neither a half-played
  animation nor a stale search result (the search's `MainActor.run` completion checks the epoch
  too) can mutate the fresh game. Covered by `GameSessionAnimationTests` (sequential hops match
  the recorded ply, point-by-point landings, `.off` synchronous escape, `newGame` cancellation,
  full animated game terminates with checkers conserved).
- **Undo — two intents, two surfaces (#59).** Every committed ply (human or AI move, or a forced
  pass) is appended to a private `undoHistory` of `UndoRecord`s — `(mover, move?, dice)` — via
  `recordTurn`, in lockstep with the entry added to `record.plies`. The live `Move` objects let
  `board.undo(move)` reverse board mutations exactly; passes carry `move == nil`.
  - `undo()` — the **within-turn editing primitive**: peels the last committed **gesture** off
    `moveBuilder` (`lastGesture`, reversed on the board) while a move is being composed — a single
    step, or all hops of a Pasch multi-hop / Portes two-dice gesture at once (#169; before #169 a
    multi-hop gesture was peeled hop by hop); no-op otherwise. `canUndo` is
    true only while `moveBuilder.built` is non-empty.
  - `undoLastDecision()` — **decision-point rewind** (debug pane only): pops every ply from the
    human's last real move forward (reversing each on the board), restores that ply's player +
    dice, and re-enters the human's turn (`beginTurn` → `picking`) so the same position can be
    re-decided. Both `undoHistory` and `record.plies` are trimmed to the same target index so they
    stay in sync. Mirrors the CLI's `undo_to_my_decision`: typically two plies (your move + the
    AI's reply), skipping passes, clamped at game start. The decide-side is `aiColor?.opponent`;
    a human-vs-human session steps back the single last move. `canUndoLastDecision` gates the
    **"↩ Undo decision"** button in `DebugOverlay`. `replay` (loading a save, incl. the
    cold-launch autosave resume of a Full Tavli leg) rebuilds `undoHistory` too — each ply's
    `Move` from the very half-moves it applies, with the ply's dice — so undo reaches back past
    a resume exactly as in a game played in one sitting. (Before this fix `undoHistory` stayed
    empty after `replay`, greying the button out until the human's first new move; it showed
    up mostly in Full Tavli, the one multi-game mode that resumes on relaunch.) The button is
    still correctly disabled when the human has not yet made a real move in this game (e.g. the
    AI opened the leg), during the AI's turn/animation, and once the game is over.

- **AI integration (T6 + multi-ply search, #58).** `GameSession` optionally drives one side with
  the Core ML `Agent`. Construct it with `agent:` + `aiColor:` (+ optional `searchConfig:`);
  `GameSession.makeAgent()` loads the app-bundled `PlakotoValue.mlmodelc` (returns `nil` if absent →
  random fallback). Call `start()` once after construction so the AI moves first if it owns the
  starting player. When `finishTurn` (or `start`/`newGame`) lands on the AI's turn, `takeAITurn`
  rolls and `playAITurn` computes legal moves (empty = forced pass), then: with no model it picks a random legal
  move (applied synchronously under `.off` timings); with a model it enters `aiThinking` and runs
  the **multi-ply expectimax search** (`agent.getBestMove`) on a detached task **off the main
  actor**, hopping back via `MainActor.run` to apply the move — directly, or through the animated
  replay when `animationTimings.isAnimated` (see *AI-turn animation* above). `Agent` calls are
  wrapped in `try?` so a Core ML failure falls back to a random move. `winProbability` (WHITE's
  view: `mover == .white ? score : 1 - score`) updates only from a real model score and stays at
  its `0.5` default under the random fallback.
  Validated headless by `GameSessionAITests` (real-model game + missing-model fallback + these pin `searchConfig: SearchConfig(maxDepth: 1)` and
  `animationTimings: .off` so full-game tests stay fast and synchronous — the search itself is
  covered by `AgentSearchTests`).

  **Board-copy isolation.** The search must not race the live `game.board`: the main actor keeps
  reading/scoring it (UI render, debug overlay) while the search applies/undoes thousands of times,
  and sharing one board would interleave the unbalanced pop/push and corrupt the checker counts. So
  `takeAITurn` snapshots `game.board.captureStacks()` + the dice on the main actor, and the detached
  task rebuilds an **isolated `GameBoard` copy** (`restoreStacks`) to search. Move generation is
  deterministic, so the copy's move list matches `liveMoves` index-for-index; the search returns the
  chosen **index**, which the main actor maps back to the live `Move` before applying. An
  out-of-range/`nil` index (Core ML failure) falls back to a random live move.

- **Background analysis (#243; replaces the #146 in-play ranking).** Analysis is a job owned by
  the **game**, not by the review: `AnalysisService` (`AnalysisService.swift`, `@MainActor`) keeps
  one `GameAnalysisJob` per `gameId`. Setting `session.analysisService` attaches a session: every
  change of `record` (a ply, a step-back, the outcome — `record`'s `didSet` → `syncAnalysisJob`) is
  passed to its job (`update(record:)`), and a new `gameId` (`newGame`) takes a new job while the
  old one finishes on its own. `inPlayAnalysis` = `analysisJob.entries` (before attaching: what a
  resumed save carried). `nil` service = nothing is analysed (tests, drill sessions; attempt mode is
  never analysed). The app attaches every **offline** session (`RootView`'s `.task(id: session)`);
  online sessions are rebuilt with fresh ids on every reconnect, so they are not attached — their
  review makes a job on demand (memory only, as before).
  - **What a job does.** It replays the record model-free into `AnalysisPosition`s (pre-roll
    stacks, mover, dice, played half-moves — passes included) and works through units, **lowest
    tier first over all jobs** (then a `focused` job — an open review — then the oldest): tier 0 =
    1-ply ranking of every moved ply (instant graph), tier 1 = the ply's dice luck
    (`DiceLuck.rollValues`, as `analyzeLuck`), tier 2 = 2-ply ranking of every ply with a choice
    (in slices of 8 moves), tier 3 = 3-ply for the close calls (`GameReview.shouldRefine(_, pass:
    2)`, one move per unit) of `refineColors` — the human vs the computer, both sides in a
    two-player game; the computer's plies stop at 2-ply, as in the review. Each score is the same
    `evaluateMovesNply` over the same generated moves as `analyzeProgressive` (a slice scores
    exactly as inside the full ranking), the played move is keyed by `matchRecorded(_:_:on:mover:)`
    and the best by `argmax`, so a job's result equals a from-scratch review + `analyzeLuck`
    (`AnalysisServiceTests`). A unit that cannot be scored (no matching move, model error) is marked
    failed for its tier and skipped. `service.maxDepth` (default 3; tests use 2) caps the passes.
  - **Isolation and priority.** Units run one at a time on one serial `.utility` dispatch queue
    (`autoreleaseFrequency: .workItem`), each on a board rebuilt from the position's stacks —
    never the live `Game`. Every prediction goes through a **throttled agent**
    (`Agent.throttled(by:)`: same model, a checkpoint before each `value()`, still inside its own
    autorelease pool) that calls `AnalysisGate.checkpoint`: while the gate is held the prediction
    waits (condition wait, re-checked every 250 ms — no busy loop), and it throws once the unit's
    `AnalysisToken` is cancelled (the unit returns `.cancelled`, its result is dropped). The session
    holds the gate (`updateAnalysisGate`, from the `didSet`s of `phase`, `hintPending`,
    `preparingDice`) while `phase == .aiThinking`, a hint is computed or weighted dice / an AI reroll
    decision are prepared; the drill holds it while grading an attempt. Holders are weak, so a
    dropped session releases its hold. So the computer's search never shares the model or the CPU
    with analysis (the #155 slowdown). Measured (`AnalysisLatencyBenchmark`, Mac, CPU-only fixture
    net, the computer's full-strength 2-ply search on 60 fixed positions while a 120-ply backlog is
    refined at 3-ply): no analysis 157 ms mean / 123 median / 353 p90; with the service (gated)
    157 / 124 / 351 — unchanged; the same analysis **ungated** 168 / 133 / 376 (+7%, on a
    many-core Mac; worse on a 2+4-core phone). Hence no setting: the analysis always runs.
    No new work starts while `ProcessInfo.thermalState >= .serious` (resumes on the change
    notification); with nothing left the queue is idle.
  - **Cancellation / step-back.** A step-back truncates the job to the common prefix (results,
    partial slices and failures of the undone plies dropped; a unit on an undone ply is cancelled
    at once); `remove(gameId:)` cancels and forgets a job. Resign holds nothing (the phase leaves
    `.aiThinking`), so the gate is released and the analysis of the plies played goes on.
  - **Persistence (incremental).** Each landing marks the job dirty; after `persistDelay` (1 s,
    coalesced) `flush()` writes `entries` (`[AnalysisEntry](reviewResult:).withLuck`, luck-only pass
    entries included) — into the **game log** when the game is logged (`GameLogStore.mergeAnalysis`),
    else into the **autosave** when it holds this `gameId` (its `analysis` merged, everything else
    kept). Merging uses `AnalysisEntry.merge` (per ply the deeper entry wins for the same played
    move, luck kept from either; a different played move — a replayed line — replaces). The app also
    flushes on backgrounding. A new job is **seeded** from the session's restored analysis, the
    game log and the autosave (`seed`/`applySeeds`: entries matching the replayed ply — same played
    move — become evaluations at their stored depth with `hadChoice` recomputed, stored luck becomes
    `PlyLuck`), and only the missing tiers run: a resumed game, a reopened review or a relaunch
    continues from the saved depth (luck included) instead of restarting.
  - **Saved with the game.** `snapshot(name:)` / `snapshot(name:fullTavli:)` write `inPlayAnalysis`
    as the save's `analysis` (non-empty ⇒ schema v2), and `resume(from:)` keeps the entries that
    still match the replayed plies (same number, same recorded move; pass entries = empty move), which
    seed the job once a service is attached. A resumed game **keeps its `gameId`** (`save.gameId`;
    pre-#104 saves get a fresh one) — before #243 every resume minted a new id, so analysis landing
    after a relaunch could not find the autosave it belonged to.
  - Tests: `AnalysisServiceTests` (a game analysed as it is played equals a from-scratch review +
    luck; 3-ply refinement like the review; every variant + a handicap game; gate held while the
    computer thinks / released on resign; a held gate pauses work; removal cancels a unit waiting at
    the gate; focus priority; step-back; a new game's new job; incremental autosave / game-log
    writes and resume-without-recompute after a "relaunch"; `merge`), `ReviewCoverageTests` (every
    moved ply covered, resumed games included), `AnalysisLatencyBenchmark` (opt-in, `TAVLI_BENCH=1`).

- **`SearchConfig`** — the leaf scoring + inner pruning mirror the CLI's `config/config.yml` search
  section (so move *evaluation* matches `./run.sh play`), but the **root search strategy is
  iOS-specific** (see `getBestMove` below). `timeBudget`↔`play_time_budget_s` (20s — now a *hard* cap),
  `beamThreshold`↔`beam_threshold` (absolute fallback, used only when `relativeCutoff` is nil),
  `relativeCutoff`↔`search_relative_cutoff` (0.08), `maxBranch`↔`search_max_branch` — the cap on
  replies expanded per **inner** node, default `4`. **`maxDepth`**: `.standard` defaults to `2` for a
  fast 2-ply on-device search (typical turns are effectively instant); `maxDepth: 3`+ opts into the
  anytime deepening described below (its worst case can take the full `timeBudget`), and
  `SearchConfig(maxDepth: 1)` forces pure 1-ply (used by headless game tests to stay fast). Three
  knobs have **no CLI equivalent**: `maxRootBranches` (5) caps the root candidate set at every depth;
  `rootSoftBudget` (8s) and `minRootBranches` (2) only matter for the `maxDepth >= 3` deepening.
  `selectionNoise` (σ, default 0) is the **AI-strength dial** (see *AI level*).

- **AI level (#108, #189).** The player picks a **level 1–8** in the new-game sheet (it replaced
  #108's 0…1 strength slider). `AILevel.searchConfig(for:)` (engine, `AILevel.swift`) maps it onto
  two `SearchConfig` knobs, leaving every other field standard:

  | Level | Play search | `selectionNoise` σ |
  |---|---|---|
  | 8 (default) | 2-ply argmax (full strength) | 0 |
  | 7 | 1-ply argmax | 0 |
  | 6 / 5 / 4 / 3 / 2 | 1-ply | 0.010 / 0.020 / 0.035 / 0.050 / 0.070 |
  | 1 | 1-ply | 0.100 (= the old slider's weakest, `legacySigmaMax`) |

  The σ curve is **convex**: σ is Gaussian noise on win-probability move scores, so a small σ only
  swaps near-equal moves while a larger one passes up clearly better ones; wider steps toward
  level 1 keep each level a noticeable change. The noise is applied **only** in `getBestMove`'s
  1-ply selection (below), so leaf scoring and the in-play/review analysis stay full-strength and
  noise-free. `AppSettings.searchConfig` reads the stored level (`settings.aiLevel`, `AILevel.load`,
  default 8); `GameSession.searchConfig` is mutable and `GameView` re-applies it on entry and when
  the stored level changes (offline only — online matches have no AI side).
  **Migration:** `AILevel.migrate` (run once from `App.init` via `AppSettings.migrateLegacySettings`)
  maps a stored slider value to the nearest level — 1.0 → 8, else the 1-ply level whose σ is
  closest to the slider's `0.10·(1 − s)` (ties → stronger) — and deletes the old key; an existing
  level wins. `PlayAsPreference.migrate` rewrites Play as `ask` → `random` in the same pass.

- **`Agent` search (#58).** Three layers on top of the parity-validated
  1-ply primitive (`evaluateMoves`, which scores each candidate as `1 - opponentValue` and a `defer`
  restores the board on any exit). The leaf scoring and `evaluateMovesNply` are ported from
  `ai/agent.py`; `getBestMove`'s *root strategy* is iOS-specific (below):
  - `pruneBranches(scores:beamThreshold:relativeCutoff:maxBranch:)` — beam helper mirroring
    `_prune_branches`: keep `score >= best*(1-relativeCutoff)` when a relative cutoff is set, else
    `score >= best - beamThreshold`; sort best-first (ties by original index, matching Python's
    stable sort); cap to `maxBranch`; always keep ≥1.
  - `evaluateMovesNply(…depth:…deadline:)` — recursive expectimax (`_evaluate_moves_nply`). `depth ≤ 1`
    delegates to `evaluateMoves`. Deeper: for each candidate, iterate all 21 weighted dice outcomes
    (`diceOutcomes`); the chance nodes are **never** pruned (distribution stays exact); a pass-position
    (no opponent moves) is scored from our own perspective; otherwise opponent replies are 1-ply
    pre-screened, pruned via `pruneBranches`, recursed at `depth-1`, and folded in as
    `weight * (1 - oppDeep.max())`. Each apply is paired with a `defer`-undo so the board is restored
    even when a `SearchTimeout` unwinds from a deeper frame.
  - `getBestMove(…timeBudget:…maxDepth:rootSoftBudget:minRootBranches:maxRootBranches:selectionNoise:noiseSeed:)`
    — **2-ply baseline + anytime deepening** under a wall-clock `DispatchTime` deadline (this replaced
    the earlier iterative-deepening loop). Single move → fast path (depth 1, index 0). When
    `maxDepth <= 1` (AI levels 1–7, #108/#189): score every move 1-ply and select over
    **all** of them via `selectIndex` — plain argmax at `selectionNoise == 0`, else argmax of the
    scores perturbed by iid Gaussian(0, σ) (Box–Muller, seedable via `noiseSeed`/`SplitMix64` for
    tests), returning that pick at depth 1. Otherwise (full strength): (1) score every root move 1-ply
    and take the best-first candidate set within `relativeCutoff`, capped at `maxRootBranches`; (2) **2-ply baseline** — score the whole candidate set at depth 2 (the
    guaranteed floor: cheap, almost always completes, and orders the next step) — **at the default
    `maxDepth: 2` this baseline is the result and step 3 is skipped**; (3) when `maxDepth >= 3`,
    **deepen to `maxDepth`** one candidate at a time in 2-ply order, overwriting each baseline score
    with the deeper score — always at least `minRootBranches` (subject to the `timeBudget` hard cap),
    then keep widening up to `maxRootBranches` total **only while elapsed < `rootSoftBudget`**; inside
    each branch the 2nd/3rd levels prune to `maxBranch`; (4) return the argmax over the mixed
    2-ply/deepened scores. So cheap positions deepen the whole set in well under the soft budget, while
    a hugely-branching doubles roll still returns a complete 2-ply result plus a genuine `maxDepth`
    evaluation of its best moves within `timeBudget`. A `SearchTimeout` keeps the best result so far;
    if not even the 2-ply baseline finishes, the 1-ply best is returned (`depth = 1`). The cost floor
    on extreme positions is the per-node screen (every reply is scored before pruning), which
    `maxBranch` does not reduce. Returns `(move, score, index, depth)`. Validated by `AgentSearchTests`:
    `pruneBranches` unit cases, an independent in-test 2-ply reference vs unpruned `evaluateMovesNply`
    (float-exact), the budgeted path (legal move, budget respected, checkers conserved), an **anytime**
    case (tiny budget still yields a legal conserved move), and a **terminal-during-lookahead** case (a
    position where some lines pin Black's start point for an immediate win and others don't): every
    winning line must score exactly 1.0 via the `hasWon` short-circuit, non-winning lines strictly
    < 1.0, the search must pick a winning index, and the board must end byte-identical.

- **Game-over hook (#64).** `GameSession.onGameOver: (@MainActor (Color) -> Void)?` fires
  **exactly once**, inside `finishTurn` the moment the session enters `.gameOver`, with the
  winning color. It's the seam the app uses to record the human's win/loss; the engine itself
  stays unaware of stats persistence. It fires once per game because no intent re-enters
  `finishTurn` after `.gameOver` (all intents guard on the pre-game-over phases), and a fresh
  game (a new session, or `newGame`) re-arms it. `replay` (loading a save) deliberately does
  **not** fire it, so resuming a finished game never double-counts.

- **Surrender / resign (#74).** `surrender(as:)` concedes the game at **any** moment it is still
  running. Who resigns (`surrenderingColor`): vs the computer always the human (also while the
  computer is moving; an `as:` naming the computer is ignored); in a two-player game the side on
  move, or the `as:` colour the view captured when its confirmation opened (so the side named is
  the side that resigns even if an auto-roll forced pass moved the turn meanwhile). The other side
  wins **1 point** (`record.points = 1` in a 2-point variant), `record.outcome` is set and the
  session enters `.gameOver(winner:)` — the same terminal state a played-out game reaches, so
  `onGameOver` / `onGameFinished(winner, 1)` fire and stats, best-of-three and Full Tavli advance
  as for any loss (a resigned Full Tavli leg is a lost leg). `canSurrender` is true whenever the
  phase is not `.gameOver` and the session is not in attempt mode (the drill); a second resign is a
  no-op, so the hooks fire once. Online matches never call it (their chrome offers "Leave
  match"/forfeit instead, and `GameView.onSurrenderTapped` guards `online == nil`).
  **Mid-turn cancellation.** Everything the current turn has in flight is stopped first
  (`stopTurnInFlight`, shared with `newGame`): `aiTurnEpoch` is bumped (a search still running
  off the main actor discards its result when it lands; the handicap AI roll checks it too), the
  animation task is cancelled (`aiDiceRolling` / `aiHopInFlight` cleared), and a pending
  auto-roll tumble / auto-roll forced pass is cancelled; a weighted roll or reroll being prepared
  is dropped (`discardPendingHandicapRoll`) and the hint cleared (the background analysis gate is
  released with the phase).
  Then **every half-move of the unfinished turn is taken back** (`moveBuilder.built`, undone on
  the board): the human's half-built move, and equally the computer's hops that had already
  landed mid-animation. The board therefore shows the position at the start of the turn in which
  the game was resigned — exactly what `record.plies` (which never holds a partial ply) replays
  to; `pendingRoll` is cleared. It records nothing to `record.plies`, so the app's per-move
  auto-save hook does **not** fire on resign — the view clears the auto-save slot explicitly via
  `onAutosave` after confirming. Covered by `GameSessionSurrenderTests` and
  `GameSessionResignTests` (two players, 2-point variant, mid-animation, mid-search, handicap
  roll, auto-roll tumble, drill).
  `humanWinProbability` re-expresses WHITE's `winProbability` for the human side (or `nil` h-vs-h)
  and drives the UI's win-chance warning (vs the computer only); the engine owns the perspective flip, the view owns
  the 10% policy.

## Game variants (#136; ports #137 Portes, #138 Fevga, #139 standard Plakoto)

The rules seam — `GameVariant.swift` — mirrors the Python `RuleSet` ABC
(`domain/ruleset.py`). Each concrete variant ports its Python module and is pinned to it
by generated parity fixtures.

- **`protocol GameVariant: Sendable`** — rules: `id` (stable persisted string),
  `modelResourceName`, `setUpInitialPosition(on:)` (must `board.clear()` first — the board is
  reused by `newGame`), `legalMoves(on:color:dice:) -> [Move]` (deterministic; empty = forced
  pass), `applyHalfMove`/`undoHalfMove(_:on:)` (strict inverses), `apply`/`undo(_ move:on:)`
  (default: halves in order / reverse), `hasWon`, `isOpen(_:for:on:)`, `resultPoints`,
  `makeEncoder(config:) -> any BoardEncoding`.
- **Outcome seam** (protocol requirements with Plakoto defaults, mirroring `RuleSet`):
  `maxPoints` (1), `randomStartingPlayer` (false), `isOver(on:)` (either side `hasWon`),
  `outcome(on:) -> (winner: Color?, points: Int)` (`nil` winner = draw, 0 points; WHITE
  checked first), `terminalValue(on:perspective:) = 0.5 + signed/(2·maxPoints)` (1/0 for
  Plakoto, 0.5 draw, 0.75/0.25 for a 2-point variant's single win), and
  `endsOnlyByMoverWin` (true unless the variant overrides `isOver` — Python's
  `_mover_win_only`). Extension helpers: `winner(on:)` (nil while running **or drawn**),
  `startingPlayer(default:)` (coin flip when `randomStartingPlayer`).
- **Geometry hooks** (shared code must not assume `dst = src + color*die`):
  `pathIndex(of:for:boardSize:)` / `point(atPath:for:boardSize:)` (default: White = point,
  Black = `boardSize+1-point`; off = `boardSize+1`; Portes bar = path 0), `bearOffPoint`,
  `movableCount(at:for:on:)` (default `Point.movablePieces`; Portes counts bar checkers), and
  `intermediatePoints(of:die1:die2:on:)` — the midpoints through which a **merged** single-half
  two-dice move can legally be split. `MoveBuilder.unmerge` and its playability check use only
  these hooks. The default is Plakoto's (exact distance `d1+d2` along the path, landable
  midpoint); standard Plakoto / Fevga check each hop with their own rules (incl. larger-die
  bear-off and Fevga's first-checker rule, so an "open but illegal" midpoint is never offered);
  Portes returns `[]` (it never merges).
- **`BoardEncoding`** — `inputSize` + `encode(_:isWhitesTurn:)`. `BoardEncoder` (`unary_v3`,
  486), `PlakotoStdEncoder` (`plakoto_std_v1` = unary_v3 + 8 mother/borne-off features, 494),
  `FevgaEncoder` (`fevga_v1`, 406, mover's path order = rotation by 12 for Black),
  `PortesEncoder` (`portes_v1`, 414). Ratios are computed in `Double` then narrowed, like numpy.
- **Variants.**
  - `PlakotoVariant` — adapter over the unchanged port (`GameBoard`, `PossibleMoves`,
    `BoardEncoder`); `resultPoints` 1. Only change: `setUpInitialPosition` clears the board
    first (a reused board used to keep its trays).
  - `StandardPlakotoVariant` (`plakoto_standard`) — Plakoto stack mechanics; port of
    `domain/plakoto_standard_moves.py` (max-dice, larger-die rule, larger-die bear-off from the
    highest point; merged single half for one checker on both dice); mother rule (draw when both
    mothers pinned, 2 points for a mother win, 2 when the loser bore off none);
    `endsOnlyByMoverWin == false`.
  - `FevgaVariant` (`fevga`) — single-colour stacks, trays hold borne-off; Black's path wraps
    (13…24, 1…12, off at 0) via `FevgaGeometry`; port of `fevga_legal_moves` (DFS over sequences
    and prefixes, dedup by an additive position hash, R1/R2 end-of-move filter, dice obligation),
    one `Move` per resulting position in Python's insertion order; mars = 2.
  - `PortesVariant` (`portes`) — port of `domain/portes_move_generation.py` (bar entry first,
    hits, larger-die rules; never merged halves); gammon = 2, no triple.
  All three have `maxPoints == 2` and `randomStartingPlayer == true`.
- **Board state.** `GameBoard` (stack of colours per point, `0`/`boardSize+1` = the ends) is the
  shared container; a pin is just stack order. **Portes' bar** uses the same indices as Python
  (White bar = 0, Black bar = 25, so `[0, d]` is a White entry and `[s, 25]` a White bear-off).
  Each end stack holds one colour's borne-off checkers *below* the other colour's bar checkers —
  `points[0] = [Black off…, White bar…]`, `points[25] = [White off…, Black bar…]` — so the
  position lives entirely in the stacks: `captureStacks`, replay, review/drill boards
  (`boardStacks`), saves and online payloads (which store only move pairs) need no new fields
  and stay backward-compatible. A hit can't be recovered from the after-position, so Portes
  pushes one flag per applied half on `GameBoard.undoLog` (LIFO, popped by undo).
  `captureSnapshot()`/`restore(_:)` capture stacks **and** the log depth; use them (not
  `captureStacks`) around code that might abandon an apply (Agent 1-ply scoring, session
  replay validation). `PortesVariant.setPosition`/`signedSlots`/`barCount`/`borneOffCount`
  convert to/from the Python layout.
- **Game end through the variant.** `Game.isOver()`/`getWinner()`/`outcome()` call the variant.
  `GameSession` ends a turn when `isOver`: `.gameOver(winner: Color?)` (`nil` = draw),
  `record.outcome`/`isDraw`/`points` (points only when `maxPoints > 1`, so Plakoto records are
  unchanged), `onGameOver(winner)` for wins only (as before) and `onGameFinished(winner, points)`
  for every end. `GameSave` writes `outcome: "draw"` for a draw (not a `Color` raw value, so
  older readers see "no winner") and an optional `points` key (absent for Plakoto). Replay and
  `GameReview` stop on `isOver`.
- **Agent.** Leaves mirror `ai/agent.py`: after a candidate, `endsOnlyByMoverWin ?
  hasWon(mover) : isOver` decides terminal, scored `terminalValue(perspective: mover)` (exactly
  1.0 for Plakoto). `GameReview.matchRecorded(_:_:on:mover:)` disambiguates moves with the same
  net delta (Portes: `10→14→15` hitting on 14 vs `10→11→15`) by resulting position.
- **Persistence ids.** `GameRecord.variantID`, `GameSave.variant`, `OnlineMatchPayload.variant`
  are always written; absent ⇒ `"plakoto"`. `GameConfig(variantID:)` resolves unknown ids to
  Plakoto. `GameSession.makeAgent` loads `variant.modelResourceName` via `ModelCatalog.main`.
- **Models + gating (#143, `ModelCatalog.swift`).** `ModelCatalog` resolves a variant's model
  (`.mlmodelc`, else `.mlpackage` compiled at load) from a bundle / directory / custom lookup;
  `isAvailable(variant)` is the vs-AI gate — the app never builds a vs-AI session (new, resumed
  or auto-resumed) for a variant without its model; it shows "Computer not available yet" and offers
  two-player play instead. The new variants' models (`PlakotoStandardValue`, `FevgaValue`,
  `PortesValue`) are optional: `setup.sh` converts each from its config's `gold_model_path`
  once that checkpoint exists, and any `<Name>Value.mlpackage` dropped into
  `TavliApp/Resources/` (then `setup.sh` to regenerate the project) enables it. Only
  `PlakotoValue` is required by the `project.yml` build guard (the others only warn).
  `VariantPreference` persists the picked id under `settings.variant` and, since #258, the
  **House rules switch** under `settings.houseRules` (`Bool`, absent = **off**). The picker offers
  `choiceIDs` = Plakoto (`plakoto_standard`, the standard rules) · Portes · Fevga; house `plakoto`
  is no longer picked. `playedVariantID(choiceID:houseRules:)` gives the rules a new game is played
  under: a Plakoto choice → house `plakoto` with the switch on, else `plakoto_standard`; Portes /
  Fevga never change. `load()` = that played variant; `loadChoice()` = the picker choice;
  `save(_:)` stores the choice (house → `plakoto_standard`). `choiceID(forStored:)` reads house
  `plakoto`, unknown and missing ids as Plakoto. **Migration** (`migrate`, from
  `AppSettings.migrateLegacySettings` at launch): a stored house `plakoto` (any pre-#258 build)
  becomes `plakoto_standard` with the switch written **off** — house rules are opt-in for everyone,
  existing installs included; idempotent (later builds never store `plakoto` as the choice).
  Variant ids are unchanged everywhere else (saves, game log, stats, online payloads), so a game
  always keeps its own rule set whatever the switch says later. Pinned by `VariantSelectorTests`.
- **Display mapping (#143, `BoardLayout.swift`).** Views draw *display slots*: engine 0…25,
  with each colour's bar checkers split out of the end stacks into slots 26 (White) / 27
  (Black). Purely hook-driven: a checker of colour `c` at end `e` is borne off iff
  `e == bearOffPoint(c)`, on the bar iff `pathIndex(e, c) == 0`. `displayStacks`,
  `displaySlot(forSource:)` / `sourcePosition(forDisplaySlot:)` (trays are never sources),
  `borneOffCount`/`barCount`, and `hits(from:to:)` (bar growth → hit animation). For every
  variant but Portes the display is the engine stacks plus two empty bars.
- **Results + matches (#143).** `GameRecord.result` → `MatchGameResult` (winner + points, or
  `.draw`). `MatchState` stores `results` and scores **points** (`score(for:)`; a double game
  counts 2, a draw 0 and extends `maxGames`); `wins(for:)` still counts games. Codable writes
  `results` plus the legacy `gameWinners`; legacy JSON decodes as 1-point wins. Online
  `GameLog` gains optional `drawn`/`points` keys (omitted for Plakoto, so its payloads are
  unchanged); `OnlineMatchPayload.matchState` is built from `completedGameResults`.
  `reportsEquity`/`equity(fromValue:)` convert a `maxPoints > 1` value to expected points.
- **Full Tavli (#144, `FullTavliSession.swift`).** Pure `Codable` session: the fixed legs
  `portes`, `fevga`, `plakotoVariantID` (#258: `init(houseRules:aiColor:handicap:)` /
  `plakotoLegVariantID(houseRules:)` — house `plakoto` with the House rules switch on, else
  `plakoto_standard`; fixed at creation, so a resumed session keeps its rules; a stored id is
  normalized by `plakotoLegVariantID(preferredID:)`: anything but `plakoto_standard` is house,
  the pre-#144 default for a missing key), `aiColor`
  (`nil` = two-player) and `results: [MatchGameResult]`. `record`/`recordGame(winner:points:)`
  appends the current leg (points clamped to the leg's `maxPoints`, so house Plakoto = 1; a
  draw = 0 and still advances; no-op once complete). `score(for:)` sums points; after three legs
  `winner` is the higher total, equal totals `isDrawn` (no tiebreak). `currentLegIndex`/
  `currentVariant` (nil when complete), `legIndex(ofVariantID:)`. AI gate:
  `isAIAvailable(in: ModelCatalog)` needs **every** leg's model (`unavailableLegVariantIDs`).
  Persistence: `GameSave.fullTavli` (optional key, written only when present — schema version
  unchanged, older files decode as `nil`; `SaveMetadata.fullTavli` for the picker);
  `GameSession.snapshot(name:fullTavli:)`. `resume(savedGame:)` → `.inLeg(index)` /
  `.betweenLegs(nextIndex)` / `.complete`, judging "finished" by the saved record's
  outcome/draw (a surrendered game replays non-terminal) and recording a finished leg the
  session had not counted yet (never twice). Covered by `FullTavliSessionTests`.
  **Handicap (#246):** optional `handicap: HandicapSetup?` — one setup for all three legs,
  stored restricted to weighted dice, rerolls, hints and moves first (`sessionHandicap`: head
  start + tier-2 dropped, adjustment marks dropped, inactive → `nil`). `setupForCurrentLeg` (fresh
  tokens per leg), `startingPlayer(default:)` (the "moves first" side starts **every** leg, no
  opening roll), `carryHandicap(from: record)` (a finished leg's final — possibly adjusted, #236 —
  setup runs on to the next legs, like best-of-three; adjusted down to nothing → `nil`; a leg
  without a handicap leaves it alone). `resume(savedGame:)` carries it too when it records a missed
  leg. Codable key `handicap` written only when set (old files / malformed → `nil`), so it
  survives a relaunch between legs; mid-leg the leg's own `GameSave.handicap` holds the tokens.
- **Parity tests** (`VariantParityTests.swift`, fixtures from `generate_test_fixtures.py
  --variant <id>`, gitignored like Plakoto's): metadata, encodings (≤1e-6), exact ordered
  legal-move lists for all 21 rolls per sampled position plus apply → Python afterstate and undo
  → original for every move, outcomes (draws, 2-point wins, terminal values), and agent 1-ply /
  2-ply scores against Python with a seeded random-init net exported to Core ML by the same
  script (`convert_to_coreml.py --variant/--checkpoint/--out`). `VariantPlayTests.swift` covers
  MoveBuilder composition, full sessions + save replay, the draw path and timings.
- **Hot path.** Calls go through `any GameVariant` (one witness-table hop each). Release-build
  `legalMoves` per call over mid-game samples: Plakoto ≈36 µs, standard Plakoto ≈19 µs, Fevga
  ≈35 µs, Portes ≈37 µs (`VariantPlayTests.testLegalMoveTiming`).

## Move notation (#178)

`MoveNotation.swift` turns one turn — dice + recorded `[from, to]` pairs + the mover — into
readable backgammon-style notation, shared by the history sheet, review and drill. Pure; it
copies the given position and replays the pairs on the copy, because hits, pins and the mother
are not stored in `PlyRecord`.

**API.** `describe(_ pairs:die1:die2:mover:before:)` (a `GameBoard`, untouched) or
`describe(...stacks:config:)` (e.g. `PlyEvaluation.boardStacks`); `game(_ plies:startingPlayer:
config:)` replays a record from the variant's starting position, movers alternating (as
`GameSession.replay`). Result: `highDie`/`lowDie`, `segments: [Segment]` (each `from: Place`,
`stops: [Stop]` (place + optional `Mark`), `count`), `motherPinned`, `noMove`, and the plain
renderings `diceText` (`64`), `moveText` (`13/7^ 8/4` / `No move`), `text`
(`64: 13/7^ 8/4`, ` (mother pinned)` appended when set).

**Rules.**
- **Numbering** from the mover's side: `number = boardSize + 1 − variant.pathIndex(point,
  mover)`; `≥ 25` → `bar` (Portes path index 0), `≤ 0` → `off`. Via the path hooks, so Fevga's
  wrapped Black path and Portes' bar/off ends (index 0/25 swap meaning with the mover) need no
  special cases. White's start is its 24 point; Black's physical numbering in Plakoto/Portes
  already equals its notation.
- **Segments**: each half is chained onto the segment whose checker just arrived at its source
  (`lastIndex` of a segment ending there), so Plakoto/Fevga doubles (one half per die) and
  Portes (one half per die, never merged) read as one checker path; an intermediate stop is
  kept only when it was a **hit** (`13/7*/5`). A merged Plakoto/Fevga half is already one
  segment. Sorted by `from` descending (bar = 25, off = 0), ties by the farther landing first;
  identical paths group to `(n)` with their marks merged.
- **Hit** (`*`): the opponent had checkers on the landing point before the half and none after,
  on a board point (Portes only in practice; a Plakoto pin keeps the opponent underneath).
- **Pin** (`^`): Plakoto house + standard — a point the mover has captured in the **final**
  position but not before (`Point.isCaptured(by:)`), so a blot landed on and left mid-double
  is not marked and adding to an existing pin is not a new pin. Never for Portes/Fevga.
- A landing mark goes on the **first** segment (display order) landing on that point.
- **Mother** (standard Plakoto only): `StandardPlakotoVariant.motherPinned(opponent)` false
  before and true after — the engine's own mother rule, so it is exactly the pin that decides
  the game. House Plakoto never sets it.
- **No move**: empty pairs → `noMove`, no segments.

Tests: `MoveNotationTests` (all four rule sets, both colours, off/bar, doubles, hit chains,
pins, mother, pass, ordering, whole-game replay).

## Save & load (#61, replay-based)

Persist and resume in-progress games the same way the CLI does: **store only the move
history (dice + half-moves per ply), never the board state**, and rebuild by replaying from
the initial position. This is model-independent by construction — a game saved under model
vN reloads identically under vN+1 (acceptance criterion 3), because replay never consults the
model. Three engine files, all SwiftUI-free and covered by `GameSavePersistenceTests` (11
tests, no model/fixtures needed):

- **Canonical record — `GameRecord` (#71).** One value type `{ startingPlayer, aiColor,
  plies: [PlyRecord], outcome }` is the single source of truth for a game, in-progress and
  completed. `GameSession` holds one `@Published private(set) var record`; `history`,
  `startingPlayer` and `aiColor` are **computed passthroughs** over it (so every call site and
  the `onChange(of: session.history.count)` autosave keep working — mutating `record` still
  fires `objectWillChange`). `outcome` is the winner, set whenever a turn ends the game
  (`finishTurn`/`replay`), else `nil`; it lives in memory only — the on-disk format does not
  carry it yet (only in-progress games are persisted). This is the shared foundation the undo
  (#59), history-log (#60), review/drill (#62/#63) and stats (#64) features build on.
- **History recording — `GameSession`.** `history: [PlyRecord]` (the record's `plies`) gains one
  entry per **finished turn**, recorded at all five turn-end points (`recordTurn` captures the
  current dice + the played half-moves as `[[from, to]]`, and in parallel appends an `UndoRecord`
  to `undoHistory` for decision-point undo): the two human finish paths (`commitHalfMove`
  auto-finish and `confirm()`), the AI move (`applyAIMove`), and the two forced-pass paths (human
  `beginTurn`, AI `takeAITurn`) which record an **empty** half-move list. Saves are therefore only
  ever taken at clean turn boundaries for the *history* — partially built half-moves are never
  serialized (a deliberate simplification); only the turn's rolled dice are, as `pendingRoll`
  (#171, see `GameSave.swift` below). `newGame` resets the whole `record` (preserving `aiColor`).
  `isTerminal` is the public "game over?" predicate the app uses to decide whether a save is
  worth keeping.
- **Resume — `GameSession.resume(from:config:agent:)` + private `replay(_:)`.** Builds a fresh
  session at `save.startingPlayer`/`aiColor`, then `replay` applies each recorded pair directly
  to the board (`board.points[from].pop()` / `board.points[to].push(mover)`, mirroring
  `applyHalfMove`) **without re-deriving legal moves**, alternating the mover every ply and
  stopping early if `game.isOver()`. It lands the session at `.awaitingRoll` (or `.gameOver`)
  with an empty `MoveBuilder` and a refreshed evaluation; every replayed ply is also pushed onto
  `undoHistory` (decision-point undo works across the resume). Because turn order always alternates,
  the mover for ply *i* is `startingPlayer` when *i* is even, else its opponent — no per-ply
  color needs storing. Replay logic lives in `GameSession.swift` (not the model file) so it can
  reach file-private state; Swift `private` is file-scoped. Call `start()` after `resume` (as
  for a new game) so the AI moves if it owns the turn.
  **Pending roll (#171).** When the save carries a valid `pendingRoll` and the replayed game is
  not over, `resume` sets those dice, publishes them as the session's `pendingRoll` (so an
  immediate re-snapshot keeps them) and arms a private `restoreRollOnStart`; the session still
  sits at `.awaitingRoll`. `start()` (or a stray `roll()`) then consumes it via
  `resumePendingRoll()` **instead of** rolling: human mover → `beginTurn` (→ `.picking`, or the
  ordinary forced-pass path when the roll has no legal move — incl. the auto-roll 0.5 s pass
  beat); AI mover → `playAITurn(animateDiceRoll: false)` (searches and plays those dice, no
  tumble). This bypasses the auto-roll gate, so it holds with auto-roll on (an explicit
  `setDice` before `start()` supersedes it), in two-player
  games, in every variant and inside a Full Tavli leg. Online sessions never carry one (their
  state is the Game Center payload, unchanged; their `GameView` has no autosave hook).
- **`GameSave.swift`** — the `GameRecord` value type (now with a stable `gameId: UUID`, #104) plus
  the Codable wire format. `PlyRecord { die1, die2, halfMoves: [[Int]] }` and `GameSave {
  schemaVersion, gameId?, name, savedAt, startingPlayer, aiColor?, outcome?, history, analysis? }`.
  **Schema versions (#104):** `currentSchemaVersion = 2`. A custom `Codable` keeps full back-compat —
  decoding treats `gameId`/`outcome`/`analysis` as optional (a v1 file has none), and **encoding
  derives the version from content**: a save *without* analysis is written at `schemaVersion: 1`
  (byte-compatible with a v1 reader), gaining the `2` marker only once an `analysis` block is
  attached. **`pendingRoll` (#171)** — `PendingRoll { die1, die2 }`, the dice of the turn in
  progress (a double is two equal values), mover implied by the history parity. Written only when
  present (like `fullTavli`, it never changes `schemaVersion`), so a save between turns is
  byte-identical to the pre-#171 format and an older reader just ignores the key. Decoding is
  tolerant: a malformed value or dice outside 1…6 decode as `nil` (the save still loads, awaiting
  a roll). `snapshot(name:)` / `snapshot(name:fullTavli:)` copy the session's `pendingRoll`;
  `GameSave(record:…)` (the game log) never sets it. The snapshots also carry the session's
  background analysis so far as `analysis` (when non-empty, making the save v2), which `resume`
  restores — so a resumed game's analysis, and its review, still cover the plies before the save. `AnalysisEntry { plyNumber, playedMove, playedScore, bestMove, bestScore, depth, luck? }` is the
  durable per-ply analysis (no `boardStacks` — reconstructed by replay; scores as `Double`; field
  names match the Python schema; `luck` (#231) is optional and omitted when `nil`, so no schema bump
  and older files/readers are unaffected). An entry with an **empty `playedMove`** is a luck-only
  **pass** ply (scores = the pass's 1-ply value, depth 1); `cachedResult` never matches it to a move.
  **`aiLevel` (#231)** — optional on `GameRecord` and `GameSave` (written only when present, no
  version bump, clamped to 1…8 on decode, unreadable ⇒ `nil`): the computer's level for a
  vs-computer game. `GameSession(aiLevel:)` records it only when there is an `aiColor` (RootView's
  `makeSession` passes `AppSettings.aiLevel`); `resume` restores it; `restart` keeps it;
  `noteAILevel(_:)` (GameView, when the level changes mid-game) keeps the **lowest** level played.
  Two-player, online and pre-#231 games are `nil`. `GameRecord.opponentCanErr(of:)`: human
  opponent → true; computer opponent → `AILevel.canErr(level:)` (level < 8; 8 or unknown → false). `[AnalysisEntry](reviewResult:)` projects a `GameReviewResult`.
  Bridges: `GameSave(record:name:savedAt:analysis:)` flattens (carrying `gameId`/`outcome`), and
  `GameSave.record` reads back (a pre-#104 save gets a fresh `gameId`). Colors serialize as `rawValue`.
- **`SaveStore.swift`** — file-backed store, one pretty-printed JSON file per game under
  `directory` (the app uses `Documents/SavedGames`), `.iso8601` dates. One reserved **autosave**
  slot (`autosave.json`) plus any number of named manual saves (`save-<uuid8>.json`, so repeated
  names never clobber). The single autosave slot is overwritten on every move and every roll (#171), so only the
  **last** in-progress game is ever kept. All IO is **synchronous** so the autosave completes
  before the app suspends. `list()` returns `SaveMetadata` (filename, name, savedAt, plyCount, isAutosave)
  newest-first, **skipping** unreadable or wrong-`schemaVersion` files; `load(filename:)` instead
  **throws** `SaveStoreError.incompatibleSchema` on a version mismatch. `writeAutosave` /
  `loadAutosave` / `clearAutosave` manage the reserved slot; `writeManual` returns the generated
  filename. `SaveStore.default()` roots it at `Documents/SavedGames`. Reads any schema **≤**
  `currentSchemaVersion` (so v1 *and* v2 both load); only a *newer* version throws/skips (#104).
- **`GameLogStore.swift`** (#104) — append-only log of **every finished game**, one JSON file per
  `gameId` (`game-<uuid>.json`) under `Documents/GameLog`, written from `GameSession.onGameOver`
  regardless of outcome or whether the game was ever manually saved (distinct from the single
  resume autosave slot, which `SaveStore` keeps). Reuses `GameSave` as the wire format, so a logged
  game is itself replayable. `append` writes/overwrites by id; `list()` returns `GameLogMetadata`
  (adds outcome/aiColor/`hasAnalysis`); `analysis(forGameId:)` reads a game's saved analysis and
  `attachAnalysis(_:forGameId:)` patches it back (bumping that file to v2). #231: it **carries
  stored luck** — a new entry without `luck` inherits the stored one for the same ply + played
  move, and stored luck-only pass entries are kept — so re-attaching a fresh review never drops
  the luck pass; `attachLuck(_:forGameId:)` writes a `[PlyLuck]` in via `withLuck`.
  `mergeAnalysis(_:forGameId:)` (#243) is the background service's write: `AnalysisEntry.merge`
  (deeper wins, luck kept), no-op-safe like `attachAnalysis`. The game-over hook writes
  `session.inPlayAnalysis` (the background analysis so far) into the logged game
  (`GameSave(record:name:analysis:)`, empty ⇒ stays v1); the service merges every later result in.

The app wiring (autosave after every move, every roll (#171) and on background, auto-resume on launch, the
saved-games list, and the in-game manual save) lives in `RootView`/`GameView` — see
`Views/CLAUDE.md`.

## Online multiplayer (#134, Game Center)

Two people on separate devices play over the internet via **Game Center turn-based matches**
(`GKTurnBasedMatch`) — no server to run. The whole feature rests on the replay-based state
model above: **a match's entire state is its ply log**, so sync, persistence, and reconnection
are all "decode + replay", with no board state to reconcile.

- **The match data is an `OnlineMatchPayload` (`OnlineMatch.swift`, engine).** Schema **v2** (#145):
  `{ schemaVersion, targetWins, startingPlayer (raw "W"/"B", the game-1 starter), colorByPlayerID:
  [gamePlayerID → raw colour], games: [GameLog] }`, where `GameLog = { plies: [PlyRecord], winnerRaw }`.
  Each game's ply log uses the same `PlyRecord` wire type as a save; an explicit colour assignment lets
  each device compute its own side independent of turn order. The last `games` element is the
  current/just-finished game; every earlier game is complete (has a `winner`). A **single game is just
  `targetWins == 1` with one `GameLog`**, so the #134 and #145 paths share one shape. Helpers:
  `completedGameWinners`, `matchState` (a `MatchState` view of the score), `currentGameIndex`,
  `startingPlayer(forGameIndex:)` (alternates from the base), `gameSave(forGameIndex:)` (a `GameSave`
  view for the rebuild path), and `pendingPlies(fromGameIndex:plyCount:)` (the diff applied during
  live play, which may cross a game boundary). `encoded()`/`decoded(from:)` rejects a newer
  `schemaVersion`; **a v1 payload still decodes** — its flat `plies` map to one `GameLog`, `targetWins`
  1. Stored verbatim in `GKTurnBasedMatch.matchData`; a best-of-three is a few KB, far under Game
  Center's limit. Covered by `OnlineMatchTests`.

- **Match score — `MatchState` (`MatchState.swift`, engine).** A pure `Codable` value type shared by
  the offline (vs-AI) and online surfaces: `{ targetWins, baseStartingPlayer, gameWinners: [Color] }`
  with derived `wins(for:)`, `completedGames`, `currentGameNumber`, `maxGames`, `matchWinner` /
  `isComplete` (a 2–0 short-circuits the third game), and `currentStartingPlayer` (alternates from the
  base so games 2+ need no opening-roll ceremony and both online devices agree). `recordGame(winner:)`
  is a no-op once decided. Covered by `MatchStateTests`.

- **Applying a remote ply — `GameSession.applyRemoteMove(_:) -> Bool` (#134).** An online game is an
  ordinary **human-vs-human** session (`aiColor == nil`); a networked move is structurally the AI
  move the session already animates, so it funnels through the same path (`animateAITurn`, or a
  synchronous apply when `animationTimings.off`). The ply carries its own dice (the active player
  rolled locally and broadcast them); the receiver sets those dice, regenerates the legal moves, and
  **validates by outcome** — the ply is legal iff applying it reaches the same board as some legal
  move. Outcome comparison (not half-move identity) is required because the *same* physical move is
  recorded differently by side: a single-checker two-die move is stored **merged** (`1→9`) by the
  move generator but **unmerged** (`1→4,4→9`) when a human plays it via `MoveBuilder`, and both
  replay to the identical position. Returns `false` without mutating on an illegal/malformed ply or
  one arriving outside `.awaitingRoll` (a desync) — the coordinator then rebuilds from the
  authoritative log. An empty `halfMoves` is a forced pass, legal only when there are no legal moves.
  Covered by `GameSessionRemoteTests` (accept/reject/pass/Pasch + exact equivalence with `replay`).

- **Match logic — `OnlineMatchController` (engine) behind `OnlineMatchService`.** All online
  match behaviour is in the engine, testable without GameKit. The service seam is plain values:
  `OnlineMatchSnapshot` (`matchID`, `data`, participants with `playerID?`/status/outcome,
  `currentPlayerID`, `isEnded`) and the operations `endTurn` / `saveTurn` / `endMatch(localWon:)`
  / `quit(inTurn:)` / `acceptInvite` / `load`. Entry points: `open(_:newMatchTargetWins:newMatchVariantID:)`
  (accepts a pending invite first; a stateless match on the local turn is this device's creation and
  is initialised), `receive(_:)` (any event — applied only to the open match; another match's event
  never replaces it, it just sets `status = .yourTurnElsewhere`), `refresh()` (reload the open match:
  foreground, retry), `close()` (back to the lobby, match kept) and `forfeit()` (quit in/out of turn).
  Rules, each pinned by `OnlineMatchControllerTests` (two `FakeDevice`s on a `FakeGameCenter` that
  fills auto-match seats only when the turn reaches them):
  - **Colours:** creator = White; a player missing from `colorByPlayerID` (its seat was unfilled at
    creation — auto-match or an unresolved invite) takes the free colour, and the merged map is
    written back with the next turn.
  - **End of match:** a `matchEnded` event goes through `receive` like a turn, so the loser applies the
    final move; a decided match locks the board (`isMatchOver`). An opponent whose outcome is `.quit`
    makes the controller end the match as a local win (`status = .opponentLeft`).
  - **Local turns** are pushed when the session's ply log grows by a local-colour ply, handled on the
    next main-queue turn (a game-ending move appends its ply before the result is recorded). A finished
    game appends its `GameLog`, records `MatchState`, then ends the match or starts the next game and
    hands the turn to its starter (`saveTurn` when that is us).
  - **Unsent turns:** a failed write keeps the op (`hasUnsentTurn`, `status = .sendFailed`), never rolls
    the board back; a snapshot that is *behind* the local log triggers a resend instead of a rebuild,
    one that has caught up clears it. Retries reload after 10 s, doubling to 5 min.

- **The bridge — `GameKitCoordinator` (`TavliApp/Online/`, app target, `@MainActor`).** Adapts GameKit
  to `OnlineMatchService` (keeps live `GKTurnBasedMatch`es by id; outcomes for `endMatch` skip
  participants who already quit) and routes events: the open match → `receive`; a match this device
  just created via the matchmaker (lobby length + variant remembered) → dismiss the matchmaker and
  `open`; a notification tap (`didBecomeActive`) → `open` + `showOnlineRequested` (RootView switches to
  the online screen); anything else only refreshes the lobby list. Signs in **at launch without UI**
  (`authenticate(presentUI: false)`, so the listener exists before a notification is tapped; a needed
  sign-in sheet is held until Play Online opens). `wantsToQuitMatch` = the *local* player quit from
  Game Center's own UI → forfeit in turn. Foreground (`didBecomeActive`) reloads the list and the open
  match. Lobby: your-turn first, then their turn, then finished (context menu "Remove"). **Dice** stay
  local-roll-and-broadcast; there is no shared RNG.

- **Best-of-three flow (#145).** When a local move wins the current game, the coordinator appends the
  winner to `matchState` and the finished `GameLog` to its history. If the **match** is now decided it
  `endMatchInTurn`s with each participant's outcome set by the **match** winner; otherwise it starts
  the next game locally (empty log, alternating starter), raises `pendingGameResult`, and hands the
  turn to that starter — `endTurn` when the opponent starts, or `saveCurrentTurn` (keep the turn) when
  the local player does. On the receiving side, a finished current game with the match still going
  advances the local session to the next game behind the between-games overlay, so subsequent incoming
  first-moves apply cleanly. `pendingGameResult` (the just-finished game's winner) drives that overlay;
  the chrome clears it on "Next game". Single-game online (`targetWins == 1`) keeps the original #134
  behaviour (game-over → back-to-lobby win overlay). Not covered by `swift test` (GameKit needs a
  signed build + two devices + sandbox accounts) — verified manually; the codec, `MatchState`, the
  `pendingPlies` diff, and `applyRemoteMove` it calls are tested headlessly. UI wiring (lobby +
  match-length toggle, online turn lock, "Leave match", scoreboard, match transition overlay) is in
  `Views/CLAUDE.md`.

**Variants online (#143).** The lobby's variant picker (shared `settings.variant`) goes to
`presentInvite(targetWins:variantID:)`; the creator writes it into the opening payload, and
game 1's starter is `variant.startingPlayer(default: .white)` (White for house Plakoto, a coin
flip for the bkgm-rules variants — when Black starts, the creator ends its turn right away).
Every variant works online (two humans, no model). A finished game — win of 1/2 points or a
draw — is logged as `GameLog(plies:result:)`, recorded into `MatchState` by points, and
`pendingGameResult` is a `MatchGameResult`; a draw never ends the match (even a single game
rolls into a replay). Older builds don't know the new variant ids and would fall back to
Plakoto, so both players need this build.

## Human game stats (#64)

`HumanGameStats.swift` is the iPad analogue of the CLI's post-game summary box / `human-stats`
command (`main.py`). Pooled results only — no per-opponent / per-model breakdown (out of scope).
SwiftUI-free (Foundation + Combine), so it's covered by `swift test`
(`HumanGameStatsTests`, `HumanStatsStoreTests`).

- **`HumanGameRecord`** — `Codable` `{ date, humanWon }`. One completed game.
- **`HumanGameStats(records:)`** — a **pure** summary mirroring `_print_human_record`:
  `total` / `wins` / `losses`, `winRate` (∈ [0, 1], 0 when empty), `recent` (up to the last 20
  outcomes, **oldest→newest**, for the sparkline), and the current streak (`streakCount` +
  `streakIsWin`, counting back from the most recent game; `0`/`false` when empty). `.empty` is
  the no-games value.
- **`HumanGameLog` + `HumanGameLogStore`** — persistence, following the **same conventions as
  `SaveStore`** (not `UserDefaults`): `HumanGameLog` is a schema-versioned Codable wrapper
  (`currentSchemaVersion`, `games: [HumanGameRecord]`), and `HumanGameLogStore` is a file-backed
  store writing a single JSON file (the app uses `Documents/HumanGameLog.json`) with `.iso8601`
  dates, pretty-printed + sorted-keys encoding, atomic writes, and an unrecognized
  `schemaVersion` **skipped** (read as empty) — exactly like `SaveStore.list()`. This is the
  iPad analogue of the CLI's `human_game_history.log` (the app is offline + sandboxed, so it can't
  share that file). It is deliberately a **separate outcome log**, not part of the
  `GameSave`/`SaveStore` game-storage standard (which stores resumable games), but it matches that
  standard's on-disk style. Tests run it against a real temp file (like the `SaveStore` tests).
- **`HumanStatsStore`** (`@MainActor`, `ObservableObject`) — loads on init from a
  `HumanGameLogStore` (default `.default()`), `record(humanWon:)` appends + persists immediately
  and republishes so SwiftUI panels re-derive `stats`. `RootView` owns one (`@StateObject`) and
  wires `session.onGameOver` to `store.record(humanWon: winner == humanColor)`.
- **Handicap games (#148)** — `HumanGameRecord.handicap` (optional, omitted when `nil`, so a log
  without handicap games is unchanged). `stats` counts only normal games; `handicapStats` only
  handicap games; `record(humanWon:handicap:)`. `adjustedHandicapGames` (#236) counts the ones whose
  setup carries `adjusted` (handicap changed mid-game); pre-#236 records decode as not adjusted.

## Handicaps, tier 1 (#148)

Spec: `docs/handicap-concept.md` (§3 tier 1, §4 builder, §5 estimator, §7 app). Engine files:
`Handicap.swift` (types, start position) and `HandicapDice.swift` (dice maths, estimator, table).
Tests: `HandicapTests` / `HandicapStatsTests` / `HandicapVariantTests` (#246). **Every variant
(#246):** weighted dice, rerolls, hints and moves first need only the variant's own value net and
rules, so they work in house Plakoto, standard Plakoto, Fevga and Portes (`HandicapSetup.supports`
= any registered variant) and across Full Tavli. The **head start and the tier-2 rules are house
Plakoto only** (`supportsHeadStartAndRules`, `positionAndRulesVariantID`) and off in every Full
Tavli leg: `availability(_ item: HandicapItemKind, variantID:fullTavli:)` →
`.available` / `.houseRulesOnly` / `.notInFullTavli` (the builder's disabled reasons; since #258
house Plakoto = Plakoto with the House rules switch on, so the app words `.houseRulesOnly` as
"Needs House rules: turn them on in Settings."), and
`restricted(toVariantID:fullTavli:)` drops them (the `GameSession` init applies it, so a setup of
only those items is a normal game elsewhere; `setUpInitialPosition` also leaves every other
variant's start alone). **Off path:** with no (or an inactive) setup nothing changes
— `GameSession.handicap == nil`, no new save key, same position, same dice path (pinned by
`testNoHandicapLeavesSessionSaveAndPositionUnchanged`).

**Types.**
- `HandicapItems` — one side: `headStart` (0…8 checkers 6 pips ahead), `movesFirst`, `diceTilt`
  (β, 0 = fair), `rerolls` (0…4 per game), `hints` (0…5 per game). Tolerant decode (missing = off),
  `clamped`.
- `HandicapSetup` — `version` (1) + `white`/`black` items, `subscript(color)`, `isActive`,
  `normalized` (clamped; "moves first" on both sides cancels), `forcedStarter`, `altersDice`
  (weighted dice or rerolls: the review notes fair-dice win chances), `needsEvaluator`,
  `diceTiltSteps = [0, 2, 4, 8, 16]` (**the one β grid**, Off/Slight/Moderate/Strong/Very strong;
  harness grid 1…16, β≈1 barely registers), `setUpInitialPosition(on:)`.
- `HandicapGameState` — setup + `rerollsLeft`/`hintsLeft` (`SideCounts`). Persisted as the
  optional **`GameSave.handicap`** (written only when present, never bumps `schemaVersion`; an old
  reader ignores it and loads the game unhandicapped; malformed → `nil`). `GameRecord.handicap`
  carries the setup (`GameSave.record` / `init(record:)` map it; a game-log entry gets full tokens).
- `HumanGameRecord.handicap` (optional): handicap games are kept out of `HumanStatsStore.stats`
  (the vs-Computer record) and summarised in `handicapStats`.

**Start position.** `HandicapSetup.setUpInitialPosition` = the variant's start, then `m` checkers
moved from the start point 6 pips forward (White 1 → 7, Black 24 → 18) — exactly
`HandicappedPlakotoRules.initial_board` (`pip_headstart`), pinned against Python-generated boards
for m = 0…8 both sides. Every replay from the start goes through
`GameRecord.setUpInitialPosition(on:)`: `GameSession` init/`newGame`/`resume`, `GameReview`
(`analyze`, `replayContexts`), `MoveNotation.game(..., handicap:)`.

**Session hooks** (`GameSession`, all inert without `handicap`):
- `init(..., handicap:, handicapAgent:)` — normalises, restricts it to the variant (#246), applies
  `forcedStarter` (overrides `startingPlayer`), lays out the head start. `handicapAgent` (default
  the session's `agent`) is the net for dice/rerolls/hints — a two-player game passes one.
  `resume(from:..., handicapAgent:)` restores setup + tokens; `newGame` keeps the setup with
  fresh tokens.
- **Weighted dice** — when the side on move has β > 0 (and no undo-replay is queued), `roll()`,
  auto-roll and the AI turn rate the 21 rolls off the main actor (`HandicapDice.rollValues` on a
  board copy; `preparingDice` blocks input meanwhile, epoch-guarded) and draw with
  `HandicapDice.weightedFaces(u1, u2, values, β)` from `handicapUniform` (injectable for tests).
- **Rerolls** — human: `canReroll` / `reroll()` (picking/moving; built half-moves are taken back;
  the new roll is weighted if that side has β, else fair from `handicapUniform`; with animation on
  the new dice tumble like an auto-roll — `humanDiceRolling` for `aiDiceRollDuration` — before the
  turn resumes, epoch-guarded). Computer: `takeHandicappedAITurn` draws, then
  `applyComputerRerolls` rerolls **while tokens remain and**
  `HandicapDice.shouldReroll(values, d1, d2, beta:)` (`lastComputerReroll` drives the UI note). A
  restored pending roll (#171) for a computer with tokens goes through `resumeHandicappedAIRoll`:
  the same reroll decision, tumbling only if the dice changed. A roll with **no legal move** is
  never rerollable: the turn passes at once (known limitation, kept on purpose).
- **Undo across a reroll** — `undoLastDecision` restores each rewound ply's *final* (post-reroll)
  dice, and later turns replay their recorded dice from `diceReplays` (no weighting, no computer
  reroll decision while a replay is queued), so the same dice come back. Tokens spent in the rewound
  turns are not refunded. A reroll still tumbling is discarded (`handicapEpoch`).
- **Best-of-three (#148 follow-up)** — every game of an offline best-of-three gets the match's
  setup with fresh tokens (a new session per game); `HandicapSetup.startingPlayer(for:default:)`
  lets "moves first" override the match's alternating starter. A resumed autosave is still a
  standalone game, with its handicap restored.
- **Hints** — `canHint` / `requestHint()`: full-strength `getBestMove` (`SearchConfig.standard`,
  2-ply) on a board copy off the main actor; publishes `hint` (`[from, to]` pairs) without playing;
  charged only when it arrives; cleared on the next checker move / new turn (`hintEpoch`).
- Tokens publish through `handicap` (Equatable) so the app autosaves on a spend.

**Mid-game changes (#236).** `GameSession.adjustHandicap(for:diceTilt:rerollsLeft:hintsLeft:)`
changes, for either side (the computer's too), the weighted-dice β (snapped to `diceTiltSteps`),
the rerolls left (0…4) and the hints left (0…5, a human side only — `isHumanSide(_:)`). Head start,
moves first and the tier-2 rules never change mid-game: replays, notation and the review rebuild
the game from the start position and rules, which therefore stay valid.
- **From the next roll.** Nothing is cached: `roll()`, auto-roll and `takeAITurn` read
  `weightedTiltForCurrentPlayer` / `computerMayReroll` from the live `handicap` at each roll,
  `drawHandicapRoll` reads β when it draws, and `applyComputerRerolls` reads tokens and β per
  reroll. A roll already being rated draws with the β in force when it lands.
- **Allowance = new count.** A new rerolls / hints count is both the tokens left and the setup's
  per-game allowance (so the decode clamp `left ≤ allowance` holds and later games start with it).
  A hint arriving after its count was set to 0 is shown, never charged below 0.
- **Marks.** The change sets `HandicapSetup.adjusted` and, when the dice were not fair before it
  (`altersDice`), `alteredDiceEarlier`; `altersDice` includes it, so the review's "win chances assume
  fair dice" note (read from `record.handicap.altersDice`) stays right after weighted dice / rerolls
  are switched off. Both keys are written only when true (an unadjusted setup encodes exactly as
  before; old JSON decodes with both false). `record.handicap` mirrors the live setup, so the
  autosave (`GameSave.handicap`), the game log, My Record (`HumanGameRecord.handicap`) and the
  review all see the **final** setup. `isKept` (= `isActive || adjusted`): an adjusted game whose
  items were all switched off keeps its handicap on save/resume (`GameSave` decode and
  `GameSession.init` accept it) — it still started as a handicap game.
- **Next game.** `forNextGame` drops the marks; `newGame` and the app's best-of-three
  (`RootView.startNextMatchGame`) start the next game from the final setup with fresh tokens (an
  inactive one = a normal game). Two-player handicap games always get a `handicapAgent` (not only
  when the setup needs the net), so weighted dice / hints can be switched on mid-game.
- **Favoured side** (the in-game button): `HandicapSetup.beneficiaries` — a side's own head start,
  moves first, weighted dice, rerolls, hints, overshoot, safe point or extra checkers help it;
  fewer checkers or a smaller home help its opponent. `HandicapEstimator.favouredSide(setup:
  estimate:table:)`: one beneficiary → that side; both → the estimate's favourite (the net position
  estimate + table when known, else the table alone from 0.5), `nil` within `balancedMargin` (1 pp).
- Tests: `HandicapAdjustTests` (next human / computer roll uses the new β, computer rerolls with
  tokens added mid-game, tokens + marks, save/resume and game-log round trips, old JSON, My Record
  count, next game, favoured side).

**Dice maths (`HandicapDice`) — keep in sync with the Python** (`domain/handicap.py`
`tilted_roll_probs`/`weighted_faces`, `ai/agent.py` `roll_values`, `ai/handicap_sweep.py`
`wants_reroll`): rolls in `diceOutcomes` order (= `ROLLS`), p = 1/36 doubles, 2/36 others;
`rollValues` = best 1-ply move value per roll, a no-move roll = `1 − value(opponent to move)`;
`tilt` = `p'(r) ∝ p(r)·exp(β·v(r))` (β = 0 returns the fair p exactly); `weightedFaces` = inverse
CDF of `u = (int(6u1)+u2)/6` over the 36 ordered outcomes (β = 0 is `(face(u1), face(u2))`);
`shouldReroll` = `v(roll) < E_p[v] − 0.02` with p the side's own (tilted) distribution. Pinned by
Python-generated cases. Differences: no bear-off DB in Swift (race values are the net's).

**Estimate (`HandicapEstimator`, concept §5).** `positionWhiteWinChance(setup, agent, rule)`:
from the handicap start, the starter's fair mean of `rollValues` (= harness `start_estimate`);
"moves first" fixes the starter, else `HandicapStartRule` — `.rollOff` (the app's opening roll: a
fair coin, the starter then rolls fresh) averages both starters (exactly 0.5 with no handicap),
`.fixed(c)`. `combine(positionWhite:setup:table:)` adds log-odds: per side, the measured shift of
its dice-lever cell (`weighted_dice:β`, `rerolls:N`, or an exact `+` combo) from `HandicapTable`
(`HandicapTable.json` in the app bundle, keyed like `docs/handicap-e1-tier1.json`, generated by
`ios/scripts/make_handicap_table.py`; shift = `logit(favoured win rate)`). Unmeasured levers are
listed in `unmeasured` and left out of the number; hints only set `approximate`.
**Per variant (#246):** the table was measured in house Plakoto only (`HandicapTable.measuredVariantIDs`,
`forVariant(_:)` → `.unmeasured` elsewhere) and `HandicapEstimator.isMeasured(variantID:)` is
house Plakoto only — the 2-point variants' net values are normalized equity, not a win chance —
so the app shows "not measured yet" for the other variants and Full Tavli instead of a number.
The per-roll values (`rollValues`) are variant-generic: the variant's `legalMoves` (Portes bar
entry first, hits; Fevga no hitting + the lock rule) and its `terminalValue`, a moveless roll (e.g.
a blocked Portes entry) a pass, identical to `DiceLuck.rollValues` (pinned per variant). β keeps
the one grid; in a 2-point variant the same β tilts a little less (values span half the range).

## Handicaps, tier 2 (#148 P3b)

Spec: `docs/handicap-concept.md` §3, §11 (E3 results), §12. Rule levers per side, each describing
that side's **own** rules (Python `HandicapBoard` per colour). Engine files: `HandicapRules.swift`
(rules, board/variant hooks, move generator), `Handicap.swift` (items, setup, start position),
`HandicapDice.swift` (table mapping). Tests: `Tier2Tests` + the committed Python fixture
`Tests/TavliEngineTests/Tier2Fixtures/tier2_moves.json` (`ios/scripts/make_tier2_fixtures.py`).

**Items.** `HandicapItems` gains `overshoot` (Bool), `safePoint` (0 or one of
`HandicapSetup.safePointCandidates` = 2/4/6/8/10/12, own numbering), `checkers` (13…17, default 15;
**more is the advantage**), `homeSize` (6/5/4/3). Tolerant decode (missing = normal), `clamped`.
`HandicapSetup.currentVersion` = **2**; a version-1 build ignores the new keys (and would replay
such a game under the normal rules). `setup.rules` → `HandicapRules?` (`nil` without tier-2 items),
`hasTier2`, `tier1Only`.

**Where the rules live.** `GameConfig.handicapRules: HandicapRules?` (part of equality/hash;
`nil` = normal game). `GameConfig.applying(setup)` adds them for house Plakoto only;
`GameRecord.replayConfig` = the record's variant + rules. Because every board copy is
`GameBoard(config: board.config)`, the session, the search (hints, 2-ply, AI turn), in-play analysis,
`MoveBuilder` scratch boards, `GameReview` (its entry points apply `record.handicap`), drill and
notation all play the same rules with no extra plumbing. `piecesPerPlayer` stays the model's 15.
- `GameBoard` caches per-side home size / checker count from the config (`homeSize(of:)`,
  `checkerCount(_:)`): `isHomePoint`/`countCheckersOutsideHome` use the side's home size,
  `allPlayersInGoal` the side's count (`>=`), `initializeBoard` the per-side stacks. With no rules
  these equal the config values: the normal path is unchanged.
- `PlakotoVariant` consults `board.config.handicapRules` only when set: `legalMoves` →
  `HandicapMoveGenerator`; `isOpen` → `handicapIsOpen` (a lone checker on its owner's safe point is
  closed to the opponent); `isLegalStep` → exact die, or (overshoot side) a bear-off with a larger
  die when no own checker, movable or pinned, is farther from the slot; `intermediatePoints` →
  midpoints through which a one-checker two-dice half is two legal steps (exact landings and
  overshoot bear-offs, so `MoveBuilder` can split them).
- **`HandicapMoveGenerator`** ports `domain/handicap_moves.py` `legal_moves_tier2` on a private
  copy of the position (Python's `n`/`color`/`pinned` arrays, own apply/undo): pairs (legality
  checked in each order on the board after the first half), merged exact single-checker jumps,
  merged jumps whose second leg overshoots, rule-2 singles, and the pasch loop with its persistent
  shorter-sequence flags and sources extended past the slot. A non-overshoot side runs the same code
  with overshoot halves off, which equals the house generator over the rules' open points / homes.
  Results deduplicated by their sorted halves. **Pinned to Python** by position sets on 1 041 cases
  (random-play positions from random tier-2 starts incl. 13…17 checkers and head starts, plus
  synthetic bear-off races with pins; doubles, overshoot bear-offs, safe points, homes 3…5), and
  `MoveBuilder` playability is checked by exploring every gesture sequence on a quarter of them.

**Start and win.** `HandicapSetup.setUpInitialPosition` puts each side's checker count (minus its
head start) on its start point (`tier2_board`). A side wins with **all its own** checkers off; the
mother-pin win is unchanged.

**Encoder.** `BoardEncoder` caps a point's unary units at 15 (`ai/board_encoder.py`
`count if count <= ppp else ppp`); 16/17 stacks only occur with extra checkers. The globals are
unchanged (borne-off ratios may exceed 1, as in Python). **No second model**: E3's handicap-aware
net never beat its warm start (gold_v11 with zero weights on the new inputs), so the regular
`PlakotoValue` plays tier-2 games; the rules reach it through the legal moves.

**Estimate.** The net's position estimate runs on `setup.tier1Only` (normal 15/15 start, head
start only): the net cannot see tier-2 levers. They come from `HandicapTable.json` (E3 cells
`overshoot:1`, `safe_point:p`, `checkers:n`, `smaller_house:k`, `+` combos), whose rate is the
sweep's *handicapped* colour's (spec `side`), so `logOddsShift` favours that colour's opponent.
`HandicapTable.tier2Groups(setup)` maps the app's per-side items to spec sides: overshoot / safe
point → spec side = the holder's opponent; smaller home → the holder; fewer than 15 checkers → the
holder's opponent (`HandicapSpec.target` = −side), more than 15 → the holder. Per spec side: an
exact measured combo cell for the whole group in **any order** (`shift(for:)` now tries every
permutation, also for tier-1 combos), else the sum of the singles; the group's shift is added for
the spec side's opponent. Combined with tier 1 additively in logit. Signs pinned against the table
(White overshoot ≈ 75.5 %, White 13 checkers ≈ 28.5 %, White 17 ≈ 66.9 %, Black home 4 ≈ 63.2 % White).
A group of three levers without its exact cell sums singles even when a measured pair is in it
(combos are super-additive, so such an estimate is conservative).

## Post-game blunder review (#62)

`GameReview.swift` is the on-device analogue of the CLI's `review` command
(`play/loop.py:_handle_review` → `_collect_blunders`): after a game ends it replays the canonical
`GameRecord` and re-evaluates each human ply to surface the moves where the player deviated most
from the AI's best choice. SwiftUI-free (Foundation + Core ML via `Agent`), so it's covered by
`swift test` (`GameReviewTests`).

- **`GameReview.analyze(record:agent:humanColor:depth:config:searchConfig:onEvaluation:progress:)`** —
  replays the record from the initial position, advancing the board by applying each ply's recorded
  half-moves in place (identical to `GameSession.replay`, so reconstruction is model-independent).
  At each ply where it's the **human's** move and the move was **not a forced pass** (empty
  half-moves), it ranks *every* legal move with `Agent.evaluateMovesNply` at `depth`
  (default **2** — fast, and the depth on-device play uses; the same parity-validated scoring the
  live AI uses), with **no wall-clock deadline** since analysis is offline. `evaluateMovesNply`
  capture/restores stacks, so the working board is never corrupted. The played move is located among
  the legal moves by **multiset-comparing `(from, to)` pairs** (order-independent — the recorded
  order may differ from the generator's; the Swift analogue of the CLI's structural `_pairs`/`_find`
  match). `onEvaluation` fires per evaluated ply **as it is scored** (lets the UI stream blunders —
  show the first one immediately while the rest are still being found); `progress` fires once per
  evaluated human ply with `(done, total)`. **Forced single-legal-move plies are evaluated too**
  (#131): they score their one move (best == played, zero gap) and are flagged `hadChoice: false`,
  so the review timeline runs unbroken to the final move instead of stopping short at the first
  forced bear-off ply. Earlier the `len(moves) <= 1` skip dropped them and the review visibly
  ended before the real game end.
- **`GameReview.analyzeProgressive(record:agent:humanColor:depths:…onEvaluation:onPassComplete:progress:)`**
  (#103) — deepening analysis that streams. Replays the record **once** into a list of `PlyContext`
  (each captures a human ply's pre-move `boardStacks`, dice, mover, played pairs), then scores them
  in passes: **1-ply** over all plies first (so the graph + drill are usable immediately), then
  **2-ply** over **every real-choice ply** — clear blunders included, because the *displayed best
  move* must be accurate and ranking the candidates is what finds it — then **3-ply** for only the
  ones still too close to call (`absoluteGap ≥ 0.5%` and `relativeGap` in **5–15%**, the band around
  the 10% threshold where the extra depth can flip the verdict). Each pass rebuilds an isolated
  board from the stored stacks (no live `Move`/`Point` kept across passes). Every (re)scored ply is
  emitted via `onEvaluation` carrying its current `depth`; the consumer **keys by `plyNumber`** and
  replaces shallower results. `onPassComplete(pass, depth)` fires per finished pass (pass 0 = the
  1-ply base). Forced plies (`hadChoice == false`) never deepen. With **`includeOpponent: true`**
  (#132) the AI's plies are evaluated too, so the review can step through and annotate them — they
  deepen to **2-ply** like the human's (a 1-ply best is too noisy to match what the strong AI
  actually played) but **not to 3-ply** (only the human's plies are flagged/drilled, so the
  borderline refinement is theirs alone). Each evaluation carries its `mover`, so the consumer keeps
  blunder flagging and the drill to the human's own plies.
  **`seed:` (#146)** — pre-computed analysis (the in-play 2-ply written during the game, or a full
  prior review) to start from. Each seeded ply is placed into the working set at its stored `depth`,
  and a pass **skips** any ply already at/beyond that pass's depth (`alreadyDeep`). So a complete
  2-ply seed makes the 1-/2-ply passes no-ops and leaves only the human's borderline plies to refine
  at 3-ply — the review opens with no visible 2-ply pass. An empty seed reproduces the original
  full 1→2→3-ply behaviour exactly (pre-#146 logs / analysis-off games review unchanged).
  **Cancellation:** the pass loop checks `Task.isCancelled` before each ply and, once cancelled,
  returns at once with what it has (seed included, no further `onPassComplete`). The app no longer
  calls it: the review reads the background analysis job (#243), which runs the same scoring.
- **`PlyEvaluation`** — one analyzed human ply: 1-based `plyNumber`, dice, the **pre-move**
  `boardStacks` snapshot (for rendering the position faced), `mover`, the `playedMove`/`bestMove`
  `[from,to]` pairs and their win-probability scores (for `mover`), `hadChoice` (false ⇒ a forced
  ply the UI labels "Only move available" rather than praising), `depth` (the search depth this
  result was scored at — 1/2/3 under progressive analysis), `pointScale` (the variant's
  `maxPoints`, stamped by every `GameReview` constructor; default 1), plus derived `relativeGap`
  `(best − played)/best` (now only the 3-ply band), `absoluteGap`, `decisionLoss`, `severity`,
  `isBlunder` and `accuracy` (see *Mistake levels, luck, accuracy* below).
- **`GameReviewResult`** — every analyzed ply (`evaluations`); `blunders` (severity `.blunder`,
  both sides — filter by `mover`), `plies(atLeast:)`, `summary(for:luck:)`.

### Mistake levels, luck, accuracy (#231)

- **Severity (`MoveSeverity`).** By **absolute** decision loss, inclusive lower bounds:
  `none` < 2 pp ≤ `inaccuracy` (?!) < 5 pp ≤ `mistake` (?) < 10 pp ≤ `blunder` (??). Forced plies
  are always `none`. `classify(lossPoints:)` adds a 1e-4 pp tolerance so Float scores hit their
  boundary. Replaces the relative `isBlunder(threshold:)` (gap/best ≥ 10% and ≥ 1 pp), which is
  removed; the review badge, chart rings, "My blunders" toggle and the drill now use `isBlunder`
  (= `.blunder`).
- **2-point variants.** Scores are the net value `v = 0.5 + E/(2·maxPoints)`, so a raw gap `d`
  is `2·maxPoints·d` expected points (what `EvalScale.gap` shows as equity). `decisionLoss =
  d · 100 · maxPoints` is the **single-game win-chance equivalent** of that equity loss (1 point =
  50 pp). The thresholds therefore mean the same expected-points cost everywhere: a blunder gives
  up ≥ 0.2 points — 10 pp in Plakoto, an equity loss ≥ 0.20 in Portes/Fevga (= a raw value gap of
  only 0.05 there). Luck uses the same scaling (`PlyLuck.luckPoints`).
- **Dice luck (`DiceLuck`, `PlyLuck`).** At each ply's pre-roll position, every distinct roll
  (21; doubles 1/36, others 2/36; generic over `config.dieSides`) gets `v(r)` = the mover's best
  1-ply move value (`Agent.evaluateMoves`, so every prediction is inside `Agent.value`'s
  autoreleasepool), or `1 − value(opponent to move)` when it has no move (a pass). Luck =
  `v(rolled) − E[v]` (mover's perspective; weighted sum over all 36 rolls is exactly 0). Same
  per-roll rule as `HandicapDice.rollValues` (tested equal). The distribution is always the **fair**
  one, even in a weighted-dice handicap game (the tilt shows up as luck); rules/head start come from
  the config `applying(record.handicap)`, as in the review.
- **`GameReview.analyzeLuck(record:agent:config:onLuck:progress:)`** — a **separate pass** run
  after the review (no extra predictions in the review passes), synchronous (call it off the main
  actor), streams each `PlyLuck` in play order, covers **every ply incl. passes, both sides**, stops
  early on task cancellation. Cost: Σ over plies of 21 × legal moves — measured on the fixture net
  (Mac, CPU-only): a 113-ply game = 41,293 predictions in ~3.7 s (~90 µs each).
  `GameReview.cachedLuck(record:analysis:config:)` rebuilds it model-free from saved entries, or
  returns `nil` unless **every** ply has stored luck (⇒ run the pass). `[AnalysisEntry].withLuck(_:record:)`
  attaches it (moved plies gain `luck`; passes become luck-only entries).
- **`GameReviewSummary`** (`result.summary(for: color, luck:)`): `accuracy` = mean over `color`'s
  plies **with a choice** of Lichess's per-move `103.1668·exp(−0.04354·loss_pp) − 3.1669`, clamped
  0…100 (`nil` with no choice plies); `inaccuracies`/`mistakes`/`blunders` + `count(_:)`;
  `decisionLoss` (pp total over choice plies); `luck` / `opponentLuck` (pp totals, `nil` until the
  luck pass has run).
- **App wiring.** The luck is computed per ply by the background analysis job (#243, tier 1, right
  after each ply's 1-ply ranking) and saved with it; `GameReviewModel.luck` = `job.luck` (complete or
  `nil`).
- **Not changed:** the 3-ply refinement band (`shouldRefine`, relative 5–15% + ≥ 0.5 pp) still
  targets the old relative threshold.

The app side (`GameReviewView` + its `@MainActor GameReviewModel`) runs **no analysis of its own**
(#243): it takes the game's job from `AnalysisService.app` (the one that ran during play, or a new
one seeded from the game log) and mirrors it — `result`, `luck`, `firstPassComplete`, `isComplete` —
on every `revision`, while open marking it `focused` (its work goes first). Closing the review changes
nothing else: the job keeps going and saves as it goes, so reopening it (or a relaunch) shows the
progress so far and continues. The pager opens as soon as
the first ply is scored; the
win-probability graph and the drill become available once the 1-ply base pass completes
(`firstPassComplete`: every moved ply has an evaluation), while the 2-/3-ply passes refine live (a
small spinner by the move counter shows until all passes finish). The screen is a **full-screen,
board-centric** mode (a `fullScreenCover` from the win overlay): the position the player faced fills
the screen, with a panel (played→best + win-prob gap, the Your-move/Compare overlay) and
Prev/Next/swipe to page through moves. Both sides' moves are shown (#132): each card is tagged You
or **Computer**, opponent cards annotate the computer's played/best, and an "All moves /
My blunders" toggle jumps navigation only between your own blunders. Blunder flagging, the chart
rings, and the drill stay scoped to the human's plies (filtered by `mover == humanColor`). The drill
is launched the same way, with the current `GameReviewResult` handed over as a precomputed result.

## Post-game drill (#63)

The interactive sibling of the review — the on-device analogue of the CLI's `drill` command
(`play/loop.py:_handle_drill` / `_drill_inner`): step through the same blunders, and for each, ask
the player to find a better move **on the real board**. It reuses #62's blunder detection
(`GameReview`/`PlyEvaluation`) and two small additions to `GameSession`:

- **Attempt mode** (`onMoveAttempt: (@MainActor (Move) -> Void)?`). When set, the session runs in
  attempt mode: completing a move (via the normal `commitHalfMove`/`confirm` tap flow) reports it
  to the hook instead of recording it and advancing the turn. `record.plies`/`undoHistory` and the
  turn are left untouched, so a finished game's record is never mutated. By default the move is then
  **rolled back** immediately (`board.undoHalfMove` per built half-move, then `beginTurn()` re-arms
  `.picking` at the same dice) so the player can re-attempt. With **`holdAttempts == true`** (#114)
  the move instead **stays on the board** (input locked: selection/legal-moves cleared) and
  `heldAttempt` holds it; `retryAttempt()` is the explicit rollback (undo + `beginTurn()`). Both
  completion sites funnel through one private `completeMove()`; with the hook nil (normal play)
  behaviour is unchanged.
- **Drill seeder** (`GameSession.drill(boardStacks:die1:die2:mover:agent:config:)`). Stands up a
  **human-vs-human** session (`aiColor: nil`, so no AI auto-moves) at an arbitrary position: seed
  each point via `setPoint`, then `setDice` → `.picking` with `mover` to play.

Grading reuses `Agent.scoreCandidate(boardStacks:move:mover:depth:)` (in `GameReview.swift`): it
rebuilds an **isolated** board from the stacks, reconstructs the attempted move against it, and
scores that single candidate via `evaluateMovesNply` **at the card's own `PlyEvaluation.depth`** —
identical to that move's entry in a full ranking at that depth, so it's directly comparable to the
`bestScore`, and safe to run off the main actor (the attempt's own `Move` references the live drill
board the main actor keeps reading). The review deepens close calls to 3-ply, so a fixed 2-ply
attempt score once graded the best move itself as "51% vs 53% — close". On top of that, an attempt
whose resulting board equals the best move's (or the game move's) — `Agent.sameOutcome`, compared by
board, not pair order — takes that move's known score without re-scoring. `gap = bestScore − attemptScore`; the feedback tiers mirror `_drill_inner` (correct =
`gap ≤ max(0.01, best·0.03)`, close = `gap ≤ max(0.04, best·0.10)`, else wrong).

The app side (`DrillView` + `@MainActor DrillModel`) analyzes (or takes a precomputed
`GameReviewResult` from the review screen), seeds a card per mistake or blunder (? / ??), wires `onMoveAttempt` to grade
off the main actor, reveals the best move with `SourceRingView`/`TargetHighlightView`, and tracks
solved/skipped for the "Drill complete" summary. Launched **from the review screen** (#130) — the
win overlay offers Review only; the in-review "Drill mistakes" button hands over the already-computed
`GameReviewResult`, so the drill never re-analyzes.

## Layout

```
ios/
├── TavliEngine/                 SwiftPM package — pure game engine + encoder + Core ML agent
│   ├── Sources/TavliEngine/     Color, GameConfig, GameVariant, Point, HalfMove, Move, Dice,
│   │                            GameBoard, PossibleMoves, BoardEncoder, Agent,
│   │                            SearchConfig, MoveBuilder, GameSession,
│   │                            GameSave, SaveStore, MatchState, FullTavliSession, …
│   └── Tests/TavliEngineTests/  ParityTests, AgentParityTests, AgentSearchTests,
│                                FixtureSupport, MoveBuilderTests, GameSessionTests,
│                                GameSessionAITests, GameSessionAnimationTests,
│                                GameSessionAnalysisTests, GameSavePersistenceTests,
│                                PendingRollPersistenceTests (#171)
│       └── Fixtures/            fixtures.json + PlakotoValue.mlpackage (generated; see below)
├── TavliApp/                    SwiftUI iPad + iPhone app (xcodegen project; .xcodeproj is generated)
│   ├── project.yml              xcodegen spec — iPhone + iPad (device family 1,2, #109), iOS 17, Swift-5 mode,
│   │                            local TavliEngine dep, bundles Resources/
│   ├── setup.sh                 generate model (if missing) → ensure xcodegen → generate project → resolve packages
│   ├── TavliAppUITests/         XCUITest target — drives the real gesture stack:
│   │                            BoardInteractionUITests (tap/drag move, visual
│   │                            repaint, full-turn → AI response). Launched with
│   │                            `-uiTestGame` (RootView starts a deterministic
│   │                            Black-to-move game, dice 3·5); asserts via the
│   │                            board's `accessibilityValue` checker-count signature.
│   └── TavliApp/
│       ├── App.swift            @main — hosts RootView (T10)
│       ├── Views/               SwiftUI views — BoardView (T3), CheckersView (T4),
│       │                        DiceView (T8), PlayableBoardView (T7), GameView (T9+T10),
│       │                        DebugOverlay (T11), RootView (T10 — picker + navigation)
│       ├── Info.plist           iPad all orientations, iPhone portrait + landscape; UIAppFonts
│       └── Resources/           bundled into the app:
│           ├── PlakotoValue.mlpackage   (generated; Xcode compiles → .mlmodelc)
│           ├── {PlakotoStandard,Fevga,Portes}Value.mlpackage  (optional, #143)
│           ├── CormorantGaramond.ttf    (variable font, committed)
│           └── Inter.ttf                (variable font, committed)
└── scripts/
    ├── generate_test_fixtures.py   Python → fixtures.json (encodings, legal moves, scores)
    └── convert_to_coreml.py        gold_v9.pth → PlakotoValue.mlpackage, written to BOTH the
                                     test Fixtures dir and TavliApp/Resources (+ self parity check)
```

## Releasing

`ios/scripts/release_archive.sh` is the one way to build a store build:

1. **Models:** refuses to run unless all four `*Value.mlpackage` (Plakoto, PlakotoStandard, Fevga,
   Portes) are in `TavliApp/TavliApp/Resources`, and checks the archive holds four `.mlmodelc`. A
   missing model would ship that variant without a computer player.
2. **Version and build number:** `Info.plist` reads `CFBundleShortVersionString` from
   `MARKETING_VERSION` and `CFBundleVersion` from `CURRENT_PROJECT_VERSION` (both in `project.yml`).
   The script overrides the build number with `git rev-list --count HEAD`, so every build from a
   later commit on main is higher (App Store Connect rejects repeated or lower numbers). It refuses
   uncommitted changes under `ios/` unless `--allow-dirty` (test archives only). Bump
   `MARKETING_VERSION` for each App Store version (1.0 → 1.0.1 …).
3. **Export compliance:** `ITSAppUsesNonExemptEncryption = NO` in `Info.plist` (only Apple's
   standard HTTPS/Game Center encryption), so App Store Connect doesn't ask at every upload.
4. **Signing:** automatic, `-allowProvisioningUpdates`, team from `TAVLO_TEAM`. Needs the Apple
   Developer Program team signed in to Xcode; a free Personal Team can archive but fails the export
   ("does not have permission to create iOS App Store provisioning profiles").
5. **Export vs upload:** without flags it writes a signed `.ipa` (`ios/build/release/`, gitignored);
   `--upload` sends it to App Store Connect, where it appears in TestFlight after processing.
   Needs the app record (bundle ID `com.plakoto.TavliApp`, Game Center enabled).

