"""Handicaps for house-rule Plakoto (#148, phase 1): a layer on top of the RuleSet.

A `HandicapSpec(kind, intensity, side)` disadvantages `side` (the "stronger player").
Penalty kinds modify `side` itself; bonus kinds (`KINDS[kind].bonus`) modify the
opponent instead — either way the spec's `side` is the one expected to win less.

`make_handicapped_rules(specs)` returns the plain `PlakotoRules` singleton when
`specs` is empty (bit-identical, zero overhead), else a `HandicappedPlakotoRules`
that adds the per-side behaviour the game loop needs:

    rules.initial_board(config)                  # pre-borne / headstart / per-side house
    rules.roll(color, u1, u2, q1, q2) -> Dice    # dice from uniforms (see `face`)
    rules.legal_moves(board, color, dice)        # demoted doubles play as two dice
    rules.first_mover(default) -> color
    rules.skips_turn(color, own_turn_no) -> bool # predetermined pass schedule
    rules.needs_roll_values(color) -> bool       # weighted dice: roll() needs per-roll values
    rules.reroll_tokens(color) -> int            # rerolls per game (the game loop spends them)

Dice are drawn as uniforms u in [0, 1) and mapped through the side's die: a fair die
is 1 + int(6u); a ceiling-k die is 1 + int(k u) (uniform on 1..k); a floor-x die is
x + int((7 - x) u) (uniform on x..6). Mapping the SAME uniform keeps the paired
(duplicate-dice) harness aligned under modified dice. q1/q2 are per-turn uniforms for
the probabilistic kinds (forced low roll, no doubles).

Weighted dice (tier 1, #148; three modes since #261; mirrored since #271): before EITHER side
rolls in a game where one side has weighted dice, a `roll_valuer(board, color)` (injected by the
caller; the harness passes the agent's 1-ply `Agent.roll_values`) rates the 21 distinct rolls
(`ROLLS` order) by the value v(r) of the ROLLER's best move. The roll distribution is tilted to
q(r) ∝ p(r)·exp(β_t·v(r)) with a PER-TURN β_t chosen by the mode (`turn_beta`; μ = Σ p v,
σ² = Σ p (v − μ)², σ floor `SIGMA_FLOOR`). The favoured side's own roll leans towards rolls good
for it (β_t ≥ 0, below); its opponent's roll is the mirror image (`mirrored_turn_beta`, β_t ≤ 0):
the same rule applied to the negated values, so the opponent's roll leans towards rolls bad for
the opponent by the same per-roll magnitude (fixed gain: E_q[v] − μ = −g; lean: a roll 2σ BELOW
average e^{2κ}× as likely; the cap bounds the most-boosted bad roll). If both sides hold weighted
dice, the roller's β_t is the sum of its own bend and the opponent's mirrored one
(`HandicappedPlakotoRules.roll_beta`; equal setups about cancel, equal lean ones exactly). The modes:
- `weighted_lean:κ`   β_t = κ / max(σ, σ_floor): the same bend every turn (a roll 2σ above the
                      average is e^{2κ}× as likely as an average one); expected gain ≈ κ·σ.
- `weighted_gain:g`   β_t ≥ 0 solved by bisection so the expected luck E_q[v] − μ = g pp per roll
                      (E_q[v] is monotone in β), capped so no roll is more than `GAIN_CAP`× its fair
                      probability; σ < σ_floor → fair dice.
- `weighted_hybrid:g` β_t = min(β_gain(g), `HYBRID_KAPPA_MAX` / max(σ, σ_floor)).
(First order the gain is β·σ², which is why a fixed β barely helped early and swamped endgames.)
For a 2-point variant v is normalised equity: g and σ_floor are win-chance-equivalent pp and are
divided by `max_points` (κ, the cap and κ_max are scale-free).
The roll is drawn by inverse CDF from ONE uniform per turn,
u = (int(6 u1) + u2) / 6, over the 36 *ordered* outcomes in lexicographic order (each ordered
pair carries its unordered roll's tilt, so the distribution over the 21 rolls is exactly the
tilted one). For a fair die that inverse CDF is (1 + int(6 u1), 1 + int(6 u2)) — the same dice,
in the same order, as the fair path — so β_t = 0 reproduces fair dice exactly and the paired
harness stays aligned (a tilt only moves the CDF boundaries; the uniform is the same).
Rerolls are a per-game token count (`reroll_tokens`); deciding *when* to reroll is a player
policy and lives in the game loop (ai/handicap_sweep.py).

Tier 2 (#148, concept doc §3; needs the handicap-aware net `plakoto_hc`): rule-changing
levers that live on the board itself (`HandicapBoard`), so every consumer — the plain move
generator, the `plakoto_hc` RuleSet, the encoder, the bear-off gate — reads them from the board:
- `overshoot:1` (bonus): the favoured side bears off with a higher die when no own checker
  (movable or pinned) sits farther from the bear-off slot (standard-Plakoto rule); the other side
  keeps exact-die. Needs its own generator (domain/handicap_moves.py).
- `safe_point:p` (bonus): a lone favoured checker on point p (favoured side's own numbering,
  p = 1 its start) cannot be pinned (`HandicapBoard.is_open_for`). p in 2..23; p = 1 would be
  "mother protection", which the user rejected.
- `checkers:n`: n < 15 -> the favoured side plays with n (target = opponent of `side`), n > 15
  -> the handicapped side plays with n; 13..17. Win = all of a side's own n checkers off.
- `smaller_house:k` (already phase 1): the handicapped side bears off from its last k points.
`TIER2_KINDS` lists them; `sample_tier2_specs` draws the self-play / eval mix.

Kinds deliberately not implemented (see docs/handicap-phase1.md):
- stacked start: house Plakoto already starts all 15 checkers on one point.
- shifted-back start for the stronger side: the start point is already the last point;
  the inverse lever is `pip_headstart` for the weaker side.
"""

import math
import random
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, NamedTuple, Optional, Sequence, Tuple

from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.move_generation import legal_moves as _plakoto_legal_moves
from domain.plakoto_rules import PlakotoRules
from domain.ruleset import get_ruleset


#: Weighted-dice modes (#261), each a handicap kind whose intensity is the mode's strength:
#: `weighted_lean` κ (scale-free bend), `weighted_gain` / `weighted_hybrid` g (win-chance pp per roll).
WEIGHTED_KINDS: Tuple[str, ...] = ("weighted_lean", "weighted_gain", "weighted_hybrid")
#: The app's strength steps (Slight → Very strong), the same for either side. Recalibrated for
#: the mirrored bend (#271): each step's TOTAL first-order gain per game (Σ over the favoured side's
#: rolls of E_q[v] − μ plus Σ over the opponent's rolls of μ − E_q[v], gold_v11 1-ply self-play,
#: 480 games, `scripts/weighted_dice_calibration.py`) is about the one-sided #261 step's on the same
#: games, or a little more: lean +8 / +15 / +28 / +50 pp (#261: +7 / +14 / +26 / +46), fixed gain
#: +7 / +15 / +30 / +51 (+8 / +15 / +29 / +48), hybrid +7 / +15 / +26 / +35 (+8 / +15 / +25 / +35).
#: The mirrored half is about as large as the own half, so the g / κ steps are roughly halved; hybrid
#: needs its own (smaller) top steps because its κ_max ceiling binds more often. (For scale: the old
#: fixed β 0.3 … 2.0 summed one-sided to +3.7 … +27.1 and measured +3.7 … +22.0 in E1 — the
#: first-order sum overstates strong tilts a little.)
LEAN_KAPPAS: Tuple[float, ...] = (0.025, 0.045, 0.085, 0.15)
GAIN_STEPS_PP: Tuple[float, ...] = (0.1, 0.2, 0.4, 0.7)
HYBRID_STEPS_PP: Tuple[float, ...] = (0.1, 0.2, 0.35, 0.5)
#: σ floor (win-chance pp, ÷ max_points for normalised equity): below it the 21 values differ by
#: model noise only — lean bends no harder than at σ = floor, fixed gain / hybrid roll fair dice.
SIGMA_FLOOR = 0.01
#: Fixed gain's cap: no roll more than this many times as likely as with fair dice.
GAIN_CAP = 3.0
#: Hybrid's lean ceiling κ_max (β_t ≤ κ_max / σ): a roll 2σ above average at most e^{0.6} ≈ 1.8×
#: as likely as an average one (fixed gain's cap allows 3×).
HYBRID_KAPPA_MAX = 0.3
#: Bisection for fixed gain: β searched in [0, BETA_SPAN / σ] in BISECTION_STEPS halvings.
BETA_SPAN = 50.0
BISECTION_STEPS = 60


class KindInfo(NamedTuple):
    category: str            # "dice" | "tempo" | "position" | "geometry"
    bonus: bool              # True: applied to the opponent of the handicapped side
    intensities: Tuple       # default sweep grid
    on_distribution: bool    # False: positions/encoding the gold net never saw
    describe: str            # player-facing wording; {x} = intensity, {side} = favoured side


KINDS: Dict[str, KindInfo] = {
    "dice_ceiling": KindInfo("dice", False, (5, 4, 3), True,
                             "your dice only go up to {x}"),
    "no_doubles": KindInfo("dice", False, (0.5, 1.0), True,
                           "your doubles count as a normal roll ({x:.0%} of the time)"),
    "forced_low": KindInfo("dice", False, (0.25, 0.5, 1.0), True,
                           "one of your dice is a 1 ({x:.0%} of rolls)"),
    "dice_floor": KindInfo("dice", True, (2, 3), True,
                           "opponent's dice never show less than {x}"),
    "weighted_lean": KindInfo("dice", True, LEAN_KAPPAS, True,
                              "dice lean towards {side} (bend {x})"),
    "weighted_gain": KindInfo("dice", True, GAIN_STEPS_PP, True,
                              "dice give {side} about +{x} pp per roll"),
    "weighted_hybrid": KindInfo("dice", True, HYBRID_STEPS_PP, True,
                                "dice give {side} up to +{x} pp per roll, gently in quiet positions"),
    "rerolls": KindInfo("dice", True, (1, 2, 3, 4), True,
                        "{x} rerolls per game"),
    "first_mover": KindInfo("tempo", False, (1,), True,
                            "you always move second"),
    "pass_turns": KindInfo("tempo", False, (1, 2, 4, 8), True,
                           "you skip {x} turns per game"),
    "pre_borne": KindInfo("position", True, (1, 2, 3, 5), False,
                          "opponent starts with {x} checkers already borne off"),
    "pip_headstart": KindInfo("position", True, (1, 2, 4), False,
                              "{x} opponent checkers start 6 pips advanced"),
    "smaller_house": KindInfo("geometry", False, (5, 4, 3), False,
                              "you bear off from a {x}-point home board"),
    "larger_house": KindInfo("geometry", True, (7, 9), False,
                             "opponent bears off from a {x}-point home board"),
    # --- tier 2 (handicap-aware net only) ---
    "overshoot": KindInfo("rules", True, (1,), False,
                          "{side} may bear off with a higher die"),
    "safe_point": KindInfo("rules", True, (2, 4, 6, 8, 10, 12), False,
                           "{side}'s lone checker on point {x} cannot be pinned"),
    "checkers": KindInfo("position", False, (13, 14, 16, 17), False,
                         "{x} checkers (fewer: favoured side; more: handicapped side)"),
}

#: Rule-changing levers the handicap-aware net (`plakoto_hc`, encoder `unary_v3_hc1`) covers.
TIER2_KINDS: Tuple[str, ...] = ("overshoot", "safe_point", "checkers", "smaller_house")

#: Candidate safe points (favoured side's own numbering, 1 = its start point). Even points from
#: the opponent's home (2/4/6: where the favoured side's runners get pinned and the pinner can sit
#: until it bears in) through the near outer board (8/10/12: the landing zone of the first runs).
#: Point 1 is excluded (mother protection, rejected); 13+ matter far less (pins there are rare
#: and short-lived). Fewer candidates = more training games per one-hot input.
SAFE_POINT_CANDIDATES: Tuple[int, ...] = (2, 4, 6, 8, 10, 12)

#: Encoder capacity: largest checker count a side may have (unary_v3_hc1 encodes up to 17).
MAX_CHECKERS = 17
MIN_CHECKERS = 13

#: The 21 distinct rolls (d1 <= d2, fair probability) in the order every per-roll value list
#: uses — identical to ai.agent._DICE_OUTCOMES.
ROLLS: Tuple[Tuple[int, int, float], ...] = tuple(
    (i, j, (1.0 if i == j else 2.0) / 36.0) for i in range(1, 7) for j in range(i, 7))
_ROLL_INDEX = {(i, j): k for k, (i, j, _) in enumerate(ROLLS)}

#: (board, color) -> 21 values in ROLLS order (win prob of `color`'s best move per roll).
RollValuer = Callable[[Board, int], Sequence[float]]

#: Kinds that change a side's die faces; weighted dice replace the face mapping of both sides'
#: rolls (mirrored, #271), so they cannot be combined with any of them.
_FACE_KINDS = ("dice_ceiling", "dice_floor", "forced_low", "no_doubles")

#: Own turns over which `pass_turns` spreads its skips (~ a typical game's own-turn count).
PASS_SCHEDULE_TURNS = 40


@dataclass(frozen=True)
class HandicapSpec:
    kind: str
    intensity: float
    side: int = WHITE   # the disadvantaged colour

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"unknown handicap kind '{self.kind}'; known: {', '.join(KINDS)}")
        if self.side not in (WHITE, BLACK):
            raise ValueError("side must be WHITE or BLACK")
        _validate(self.kind, self.intensity)

    @property
    def target(self) -> int:
        """Colour whose rules are modified (the opponent of `side` for bonus kinds).
        `checkers`: fewer than 15 goes to the favoured side, more to the handicapped side."""
        if self.kind == "checkers":
            return -self.side if self.intensity < 15 else self.side
        return -self.side if KINDS[self.kind].bonus else self.side

    def with_side(self, side: int) -> "HandicapSpec":
        return HandicapSpec(self.kind, self.intensity, side)

    def label(self) -> str:
        x = self.intensity
        return f"{self.kind}:{int(x) if float(x).is_integer() else x}"


def _validate(kind: str, x) -> None:
    ok = {
        "dice_ceiling": lambda: 1 <= x <= 6 and float(x).is_integer(),
        "dice_floor": lambda: 1 <= x <= 6 and float(x).is_integer(),
        "no_doubles": lambda: 0.0 <= x <= 1.0,
        "forced_low": lambda: 0.0 <= x <= 1.0,
        "weighted_lean": lambda: 0 <= x <= 5,
        "weighted_gain": lambda: 0 <= x <= 50,
        "weighted_hybrid": lambda: 0 <= x <= 50,
        "rerolls": lambda: 0 <= x <= 20 and float(x).is_integer(),
        "first_mover": lambda: x in (0, 1),
        "pass_turns": lambda: 0 <= x <= PASS_SCHEDULE_TURNS and float(x).is_integer(),
        "pre_borne": lambda: 0 <= x <= 14 and float(x).is_integer(),
        "pip_headstart": lambda: 0 <= x <= 15 and float(x).is_integer(),
        "smaller_house": lambda: 1 <= x <= 6 and float(x).is_integer(),
        "larger_house": lambda: 6 <= x <= 12 and float(x).is_integer(),
        "overshoot": lambda: x in (0, 1),
        "safe_point": lambda: 2 <= x <= 23 and float(x).is_integer(),
        "checkers": lambda: MIN_CHECKERS <= x <= MAX_CHECKERS and float(x).is_integer(),
    }[kind]()
    if not ok:
        raise ValueError(f"invalid intensity {x!r} for handicap '{kind}'")


def parse_spec(text: str, side: int = WHITE) -> HandicapSpec:
    """'dice_ceiling:5' -> HandicapSpec('dice_ceiling', 5, side)."""
    kind, _, val = text.strip().partition(":")
    if not val:
        val = str(KINDS[kind].intensities[0]) if kind in KINDS else "1"
    x = float(val)
    if x.is_integer():
        x = int(x)
    return HandicapSpec(kind, x, side)


def pass_schedule(n: int, turns: int = PASS_SCHEDULE_TURNS) -> frozenset:
    """Own-turn numbers (1-based) skipped by `pass_turns:n`, evenly spaced over `turns`."""
    return frozenset(round(k * turns / (n + 1)) for k in range(1, int(n) + 1))


def face(u: float, lo: int = 1, hi: int = 6) -> int:
    """Uniform u in [0,1) -> die face uniform on lo..hi (monotone in u)."""
    return lo + int(u * (hi - lo + 1))


def roll_index(d1: int, d2: int) -> int:
    """Index into ROLLS of the unordered roll {d1, d2}."""
    return _ROLL_INDEX[(d1, d2) if d1 <= d2 else (d2, d1)]


def tilted_roll_probs(values: Sequence[float], beta: float) -> List[float]:
    """p'(r) ∝ p(r)·exp(β·v(r)) over the 21 ROLLS, normalised (β = 0: the fair probabilities)."""
    if not beta:
        return [w for _, _, w in ROLLS]
    vmax = max(values)  # shift for numerical safety; cancels in the normalisation
    raw = [w * math.exp(beta * (v - vmax)) for (_, _, w), v in zip(ROLLS, values)]
    z = sum(raw)
    return [r / z for r in raw]


def roll_spread(values: Sequence[float]) -> Tuple[float, float]:
    """(μ, σ) of the 21 per-roll values under the fair roll probabilities."""
    mu = sum(w * v for (_, _, w), v in zip(ROLLS, values))
    var = sum(w * (v - mu) ** 2 for (_, _, w), v in zip(ROLLS, values))
    return mu, math.sqrt(max(var, 0.0))


def _tilt_moments(values: Sequence[float], beta: float, vmax: float) -> Tuple[float, float]:
    """(E_q[v], max_r q(r)/p(r)) of the tilt q ∝ p·exp(β·v)."""
    z = 0.0
    ev = 0.0
    for (_, _, w), v in zip(ROLLS, values):
        e = w * math.exp(beta * (v - vmax))
        z += e
        ev += e * v
    return ev / z, 1.0 / z


def lean_beta(values: Sequence[float], kappa: float, max_points: int = 1) -> float:
    """Lean: β_t = κ / max(σ, σ_floor) — a roll 2σ above average is e^{2κ}× as likely."""
    if kappa <= 0:
        return 0.0
    _, sigma = roll_spread(values)
    return kappa / max(sigma, SIGMA_FLOOR / max_points)


def gain_beta(values: Sequence[float], gain_pp: float, max_points: int = 1,
              cap: float = GAIN_CAP) -> float:
    """Fixed gain: the largest β ≥ 0 with E_q[v] − μ ≤ g (g in win-chance pp; ÷ max_points for
    normalised equity) and max_r q(r)/p(r) ≤ cap — both monotone in β, so one bisection over
    [0, BETA_SPAN/σ]. Reachable g is hit (to bisection precision); otherwise the cap (or the
    span) binds. σ < σ_floor (or g ≤ 0) → 0, fair dice."""
    if gain_pp <= 0:
        return 0.0
    mu, sigma = roll_spread(values)
    if sigma < SIGMA_FLOOR / max_points:
        return 0.0
    target = gain_pp / 100.0 / max_points
    vmax = max(values)
    lo, hi = 0.0, BETA_SPAN / sigma
    for _ in range(BISECTION_STEPS):
        mid = 0.5 * (lo + hi)
        ev, ratio = _tilt_moments(values, mid, vmax)
        if ev - mu <= target and ratio <= cap:
            lo = mid
        else:
            hi = mid
    return lo


def hybrid_beta(values: Sequence[float], gain_pp: float, max_points: int = 1,
                kappa_max: float = HYBRID_KAPPA_MAX) -> float:
    """Hybrid: min(fixed gain's β, κ_max / max(σ, σ_floor))."""
    return min(gain_beta(values, gain_pp, max_points), lean_beta(values, kappa_max, max_points))


def turn_beta(values: Sequence[float], kind: str, strength: float, max_points: int = 1) -> float:
    """This turn's β_t for a weighted-dice kind (`WEIGHTED_KINDS`) at `strength`."""
    if kind == "weighted_lean":
        return lean_beta(values, strength, max_points)
    if kind == "weighted_gain":
        return gain_beta(values, strength, max_points)
    if kind == "weighted_hybrid":
        return hybrid_beta(values, strength, max_points)
    raise ValueError(f"not a weighted-dice kind: {kind!r}")


def mirrored_turn_beta(values: Sequence[float], kind: str, strength: float,
                       max_points: int = 1) -> float:
    """The mirrored bend (#271) on the roll of the favoured side's OPPONENT, from that
    opponent's own 21 values: −turn_beta(−v) ≤ 0 — the mode's rule applied to the negated
    values, so the roll leans towards rolls bad for the roller by the same per-roll magnitude
    (fixed gain E_q[v] − μ = −g, lean κ/σ, hybrid the smaller of both, cap on the boosted
    bad rolls). 0 = fair."""
    b = turn_beta([-v for v in values], kind, strength, max_points)
    return -b if b else 0.0


def roll_uniform(u1: float, u2: float) -> float:
    """The single per-turn uniform of the weighted-dice scheme: (int(6 u1) + u2) / 6."""
    return (int(u1 * 6) + u2) / 6.0


def weighted_faces(u1: float, u2: float, values: Sequence[float], beta: float) -> Tuple[int, int]:
    """Ordered faces (d1, d2) by inverse CDF of u = roll_uniform(u1, u2) over the 36 ordered
    outcomes (lexicographic), each weighted by its unordered roll's tilt exp(β·v).
    β = 0 takes the exact fair path (face(u1), face(u2)), which is that inverse CDF."""
    if not beta:
        return face(u1), face(u2)
    vmax = max(values)
    tilt = [math.exp(beta * (v - vmax)) for v in values]
    cum = []
    total = 0.0
    for a in range(1, 7):
        for b in range(1, 7):
            total += tilt[roll_index(a, b)]
            cum.append(total)
    target = roll_uniform(u1, u2) * total
    for k, c in enumerate(cum):
        if target < c:
            break
    return 1 + k // 6, 1 + k % 6


class _DemotedDoubleDice(Dice):
    """A double that plays as an ordinary two-dice roll (two halves, not four)."""
    __slots__ = ()

    def is_pasch(self) -> bool:
        return False


class HandicapBoard(Board):
    """Plakoto `Board` carrying per-colour handicap state (tier 1 geometry + tier 2 rules).

    Per colour c (dicts keyed WHITE / BLACK):
      home_white / home_black  bear-off home size (`is_home`)
      checkers[c]              c's checker count; c wins when all of them are off
      overshoot[c]             c may bear off with a higher die (domain/handicap_moves.py)
      safe_point[c]            point p (c's own numbering, 1 = its start; 0 = none) where a lone
                               c checker cannot be pinned (`is_open_for`)
    State, apply/undo and the pin win are inherited unchanged. The house move generator
    reaches the geometry only through `is_home` / `is_open_for`, so it needs no change except
    for overshoot, which `domain.handicap_moves.legal_moves_tier2` dispatches on."""

    __slots__ = ("home_white", "home_black", "checkers", "overshoot", "safe_point", "_safe_slot")

    def __init__(self, board_size: int = 24, home_size: int = 6, pieces_per_player: int = 15,
                 home_white: Optional[int] = None, home_black: Optional[int] = None,
                 checkers: Optional[Dict[int, int]] = None,
                 overshoot: Optional[Dict[int, bool]] = None,
                 safe_point: Optional[Dict[int, int]] = None) -> None:
        super().__init__(board_size, home_size, pieces_per_player)
        self.home_white = home_size if home_white is None else home_white
        self.home_black = home_size if home_black is None else home_black
        self.checkers = {WHITE: pieces_per_player, BLACK: pieces_per_player}
        if checkers:
            self.checkers.update(checkers)
        self.overshoot = {WHITE: False, BLACK: False}
        if overshoot:
            self.overshoot.update({c: bool(v) for c, v in overshoot.items()})
        self.safe_point = {WHITE: 0, BLACK: 0}
        if safe_point:
            self.safe_point.update({c: int(v) for c, v in safe_point.items()})
        self._sync_safe_slots()

    def _sync_safe_slots(self) -> None:
        """Board slot of each colour's safe point (-1 = none)."""
        bs = self.board_size
        self._safe_slot = {
            c: (-1 if not p else (p if c == WHITE else bs + 1 - p))
            for c, p in self.safe_point.items()}

    def set_safe_point(self, color: int, point: int) -> None:
        self.safe_point[color] = int(point)
        self._sync_safe_slots()

    def home_size_of(self, c: int) -> int:
        return self.home_white if c == WHITE else self.home_black

    def is_home(self, c: int, i: int) -> bool:
        if c == WHITE:
            return self.board_size - self.home_white + 1 <= i <= self.board_size
        return 1 <= i <= self.home_black

    def is_open_for(self, i: int, c: int) -> bool:
        n = self.n[i]
        if n == 0 or self.color[i] == c:
            return True
        if n != 1 or self.pinned[i]:
            return False
        # A lone opponent checker: pinnable unless it sits on the opponent's safe point.
        return i != self._safe_slot[-c]

    def all_borne_off(self, c: int) -> bool:
        return self.borne_off[c] >= self.checkers[c]

    @property
    def bearoff_exact(self) -> bool:
        """True iff the exact bear-off DB (ai/bearoff.py: exact-die, <= 15 checkers, 6-point
        quadrant) is exact for BOTH sides here. A smaller home is fine (a race only starts once
        every checker is inside it, and from there the DB's moves are the same), fewer checkers
        are fine, a safe point cannot matter in a contact-free race. Overshoot, > 15 checkers
        or a home larger than the quadrant are not."""
        hs = self.home_size
        return (not self.overshoot[WHITE] and not self.overshoot[BLACK]
                and self.checkers[WHITE] <= 15 and self.checkers[BLACK] <= 15
                and self.home_white <= hs and self.home_black <= hs)

    def is_handicapped(self) -> bool:
        """Any tier-2 / geometry lever active (False = a plain game on this class)."""
        hs, ppp = self.home_size, self.pieces_per_player
        return (self.home_white != hs or self.home_black != hs
                or any(self.overshoot.values()) or any(self.safe_point.values())
                or self.checkers[WHITE] != ppp or self.checkers[BLACK] != ppp)

    def clone(self) -> "HandicapBoard":
        b = HandicapBoard.__new__(HandicapBoard)
        b.board_size = self.board_size
        b.home_size = self.home_size
        b.pieces_per_player = self.pieces_per_player
        b.home_white = self.home_white
        b.home_black = self.home_black
        b.checkers = dict(self.checkers)
        b.overshoot = dict(self.overshoot)
        b.safe_point = dict(self.safe_point)
        b._safe_slot = dict(self._safe_slot)
        b.n = self.n[:]
        b.color = self.color[:]
        b.pinned = self.pinned[:]
        b.borne_off = dict(self.borne_off)
        return b


def _dedupe(moves: List) -> List:
    seen = set()
    out = []
    for m in moves:
        key = tuple(sorted(m.halves))
        if key not in seen:
            seen.add(key)
            out.append(m)
    return out


def _legal_moves_with_demotion(board, color, dice):
    moves = _plakoto_legal_moves(board, color, dice)
    if dice.die1.value == dice.die2.value and not dice.is_pasch():
        # A demoted double runs through the non-pasch generator with d1 == d2,
        # which emits each unordered pair (and rule-2 single) twice.
        moves = _dedupe(moves)
    return moves


class HandicappedPlakotoRules(PlakotoRules):
    """House-rule Plakoto plus one or more `HandicapSpec`s. Not registered: it is a
    parametrised instance (name stays "plakoto"; checkpoints/encoder are unchanged)."""

    def __init__(self, specs: Sequence[HandicapSpec],
                 roll_valuer: Optional[RollValuer] = None) -> None:
        self.specs: Tuple[HandicapSpec, ...] = tuple(specs)
        #: Per-roll value oracle for weighted dice (see module doc); set by the caller.
        self.roll_valuer = roll_valuer
        kinds = [s.kind for s in self.specs]
        if len(set((s.kind, s.target) for s in self.specs)) != len(self.specs):
            raise ValueError(f"duplicate handicap kind on one side: {kinds}")
        self._by_target: Dict[int, Dict[str, float]] = {WHITE: {}, BLACK: {}}
        for s in self.specs:
            self._by_target[s.target][s.kind] = s.intensity
        self._dice_lo = {c: int(self._by_target[c].get("dice_floor", 1)) for c in (WHITE, BLACK)}
        self._dice_hi = {c: int(self._by_target[c].get("dice_ceiling", 6)) for c in (WHITE, BLACK)}
        for c in (WHITE, BLACK):
            if self._dice_lo[c] > self._dice_hi[c]:
                raise ValueError("dice floor above dice ceiling")
        #: Per colour: (weighted-dice kind, strength) or None (fair dice).
        self._weighting: Dict[int, Optional[Tuple[str, float]]] = {}
        for c in (WHITE, BLACK):
            on = [(k, float(self._by_target[c][k])) for k in WEIGHTED_KINDS
                  if self._by_target[c].get(k)]
            if len(on) > 1:
                raise ValueError("one weighted-dice mode per side: " + ", ".join(k for k, _ in on))
            self._weighting[c] = on[0] if on else None
        self._rerolls = {c: int(self._by_target[c].get("rerolls", 0)) for c in (WHITE, BLACK)}
        # Mirrored (#271): weighted dice bend both sides' rolls, so they replace the face mapping
        # of both sides — no face kind on either side.
        if any(self._weighting.values()) and any(
                k in self._by_target[c] for c in (WHITE, BLACK) for k in _FACE_KINDS):
            raise ValueError("weighted dice cannot be combined with "
                             + "/".join(_FACE_KINDS) + " (they bend both sides' rolls)")
        self._skip = {c: pass_schedule(self._by_target[c]["pass_turns"])
                      if "pass_turns" in self._by_target[c] else frozenset()
                      for c in (WHITE, BLACK)}
        self._second = [s.side for s in self.specs if s.kind == "first_mover" and s.intensity]
        if len(set(self._second)) > 1:
            raise ValueError("first_mover on both sides")
        # Instance attribute (plain function, no binding): the plain generator unless
        # a no-doubles handicap can hand it a demoted double.
        any_demote = any("no_doubles" in self._by_target[c] for c in (WHITE, BLACK))
        self._tier2 = any(s.kind in TIER2_KINDS and s.kind != "smaller_house" for s in self.specs)
        if any(self._by_target[c].get("overshoot") for c in (WHITE, BLACK)):
            from domain.handicap_moves import legal_moves_tier2  # handles demoted doubles too
            self.legal_moves = legal_moves_tier2
        else:
            self.legal_moves = _legal_moves_with_demotion if any_demote else _plakoto_legal_moves

    # --- position ---

    def initial_board(self, config) -> Board:
        hw = int(self._house(WHITE))
        hb = int(self._house(BLACK))
        bs = config.get_board_size()
        ppp = config.get_pieces_per_player()
        count = {c: int(self._by_target[c].get("checkers", ppp)) for c in (WHITE, BLACK)}
        if hw == hb == config.get_home_size() and not self._tier2:
            b = Board.from_config(config)
        else:
            b = HandicapBoard(
                bs, config.get_home_size(), ppp, home_white=hw, home_black=hb, checkers=count,
                overshoot={c: bool(self._by_target[c].get("overshoot", 0)) for c in (WHITE, BLACK)},
                safe_point={c: int(self._by_target[c].get("safe_point", 0)) for c in (WHITE, BLACK)})
        for c in (WHITE, BLACK):
            mods = self._by_target[c]
            start = 1 if c == WHITE else bs
            off = bs + 1 if c == WHITE else 0
            borne = int(mods.get("pre_borne", 0))
            ahead = int(mods.get("pip_headstart", 0))
            on_start = count[c] - borne - ahead
            if on_start < 1:
                raise ValueError("handicap leaves no checker on the start point")
            b.set_point(start, c, on_start)
            if ahead:
                b.set_point(start + 6 * c, c, ahead)
            if borne:
                b.set_point(off, c, borne)
                b.borne_off[c] = borne
        return b

    def _house(self, c: int) -> int:
        mods = self._by_target[c]
        return mods.get("smaller_house", mods.get("larger_house", 6))

    # --- dice ---

    def needs_roll_values(self, color: int) -> bool:
        """True when `roll` for `color` needs the 21 per-roll values: either side has weighted
        dice (#271: the favoured side's own rolls and, mirrored, its opponent's)."""
        return self._weighting[color] is not None or self._weighting[-color] is not None

    def roll_beta(self, color: int, values: Optional[Sequence[float]]) -> float:
        """This turn's tilt β_t for `color` given its 21 roll values (0 = fair dice): its own
        weighted dice' bend (≥ 0) plus the opponent's weighted dice' mirrored bend (≤ 0)."""
        if values is None:
            return 0.0
        beta = 0.0
        own, opp = self._weighting[color], self._weighting[-color]
        if own is not None:
            beta += turn_beta(values, own[0], own[1], self.max_points)
        if opp is not None:
            beta += mirrored_turn_beta(values, opp[0], opp[1], self.max_points)
        return beta

    def reroll_tokens(self, color: int) -> int:
        """Rerolls `color` may spend per game."""
        return self._rerolls[color]

    def roll(self, color: int, u1: float, u2: float, q1: float, q2: float,
             board: Optional[Board] = None, values: Optional[Sequence[float]] = None) -> Dice:
        """Dice for `color` from the turn's uniforms. Weighted dice need `values` (21, ROLLS
        order) or a `board` for `self.roll_valuer`; other kinds ignore both."""
        mods = self._by_target[color]
        if self.needs_roll_values(color):
            if values is None:
                if self.roll_valuer is None or board is None:
                    raise ValueError("weighted dice need roll values (roll_valuer + board)")
                values = self.roll_valuer(board, color)
            dice = Dice()
            dice.set(*weighted_faces(u1, u2, values, self.roll_beta(color, values)))
            return dice
        lo, hi = self._dice_lo[color], self._dice_hi[color]
        d1, d2 = face(u1, lo, hi), face(u2, lo, hi)
        p_low = mods.get("forced_low")
        if p_low is not None and q1 < p_low:
            d2 = 1
        p_nd = mods.get("no_doubles")
        dice = _DemotedDoubleDice() if (p_nd is not None and d1 == d2 and q2 < p_nd) else Dice()
        dice.set(d1, d2)
        return dice

    # --- tempo ---

    def first_mover(self, default: int) -> int:
        return -self._second[0] if self._second else default

    def skips_turn(self, color: int, own_turn_no: int) -> bool:
        return own_turn_no in self._skip[color]


def make_handicapped_rules(specs: Iterable[HandicapSpec] = (),
                           roll_valuer: Optional[RollValuer] = None):
    """Plain `plakoto` RuleSet when there is no handicap, else a HandicappedPlakotoRules."""
    specs = tuple(specs)
    if not specs:
        return get_ruleset("plakoto")
    return HandicappedPlakotoRules(specs, roll_valuer)


# --- tier-2 sampling (self-play mix and the handicapped paired eval) ---

#: Default per-lever probabilities of the tier-2 sampler (each lever independent; a draw with
#: no lever on is redrawn, so every handicapped game has at least one). Overridable from config
#: (`handicap_lever_probs`).
DEFAULT_LEVER_PROBS: Dict[str, float] = {
    "overshoot": 0.5, "safe_point": 0.5, "checkers": 0.4, "smaller_house": 0.4}

#: Intensity grid per lever, drawn uniformly. `checkers`: 13/14 go to the favoured side, 16/17
#: to the handicapped side (HandicapSpec.target).
TIER2_GRID: Dict[str, Tuple] = {
    "overshoot": (1,),
    "safe_point": SAFE_POINT_CANDIDATES,
    "checkers": (13, 14, 16, 17),
    "smaller_house": (5, 4, 3),
}


def sample_tier2_specs(rng, lever_probs: Optional[Dict[str, float]] = None
                       ) -> Tuple[HandicapSpec, ...]:
    """One random tier-2 setup: a uniformly random handicapped colour (the favoured side is its
    opponent), each lever independently on with its probability and a uniform intensity from
    `TIER2_GRID`, at least one lever on. Consumes only `rng` (a random.Random or the `random`
    module) — never numpy."""
    probs = dict(DEFAULT_LEVER_PROBS)
    if lever_probs:
        probs.update({k: float(v) for k, v in lever_probs.items()})
    for k in probs:
        if k not in TIER2_GRID:
            raise ValueError(f"unknown tier-2 lever '{k}'; known: {', '.join(TIER2_GRID)}")
    if not any(p > 0 for p in probs.values()):
        raise ValueError("all tier-2 lever probabilities are 0")
    side = WHITE if rng.random() < 0.5 else BLACK
    while True:
        specs = []
        for kind in TIER2_GRID:  # fixed order: reproducible draws
            if rng.random() < probs.get(kind, 0.0):
                grid = TIER2_GRID[kind]
                specs.append(HandicapSpec(kind, grid[int(rng.random() * len(grid))], side))
        if specs:
            return tuple(specs)


def tier2_board(specs: Sequence[HandicapSpec], config) -> Board:
    """Start position (a HandicapBoard carrying the rules) of a tier-2 setup."""
    return HandicappedPlakotoRules(specs).initial_board(config)


def specs_label(specs: Sequence[HandicapSpec]) -> str:
    return "+".join(s.label() for s in specs) or "baseline"


# --- plain-rules counterparts so a game loop can treat both uniformly ---

def plain_roll(u1: float, u2: float) -> Dice:
    d = Dice()
    d.set(face(u1), face(u2))
    return d
