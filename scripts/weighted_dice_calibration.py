"""Weighted-dice calibration (#261, mirrored since #271): how strong is each mode's step?

Plays `games` 1-ply self-play games of a variant with fair dice. White is the favoured side.
On every turn it rates the mover's 21 rolls (`Agent.roll_values`) and records, per weighted-dice
mode and strength, the expected luck of that turn for White (win-chance-equivalent: × max_points):
- White's turn, its own bend: E_q[v_W] − μ_W with β_t = `turn_beta` (≥ 0);
- Black's turn, the mirrored bend (#271): −(E_q[v_B] − μ_B) with β_t = `mirrored_turn_beta` (≤ 0).
The per-game sum is the first-order gain of a side holding that handicap all game (it ignores
that the tilted dice change the positions reached, so strong tilts are overstated a little:
the old fixed β 2.0 summed to +27 pp one-sided and measured +22 pp in E1). Reported per cell:
"own" = White's turns only (the #261 one-sided dice), "mirror" = Black's turns, "total" = both
(today's dice), each as mean ± 95 % CI over games, plus the largest probability multiplier
max_r q(r)/p(r) over both sides' turns. Also reports the spread σ of the roll values.

    PYTHONPATH=. .venv/bin/python scripts/weighted_dice_calibration.py \
        config/config.yml models/gold_v11.pth 120 [workers] [--grid lean=0.02,0.04 gain=0.1,0.2 ...]

Without --grid it measures the app's grids (`LEAN_KAPPAS`, `GAIN_STEPS_PP`, `HYBRID_STEPS_PP`). Game k is seeded
with k (deterministic for any worker count). No training, no files written.
"""
import multiprocessing as mp
import random
import statistics
import sys
import time

from config.config_loader import ConfigLoader
from domain.constants import WHITE
from domain.handicap import (GAIN_STEPS_PP, HYBRID_STEPS_PP, LEAN_KAPPAS, ROLLS,
                             mirrored_turn_beta, plain_roll, roll_spread, tilted_roll_probs,
                             turn_beta)

_KIND = {"lean": "weighted_lean", "gain": "weighted_gain", "hybrid": "weighted_hybrid"}
_W = {}


def _init(cfgpath, model, modes):
    import torch
    torch.set_num_threads(1)
    from ai.checkpoint_io import load_agent_from_checkpoint
    cfg = ConfigLoader(cfgpath)
    _W["cfg"] = cfg
    _W["agent"], _ = load_agent_from_checkpoint(model, cfg)
    _W["modes"] = modes


def _luck(vals, beta, mu, fair):
    q = tilted_roll_probs(vals, beta) if beta else fair
    return sum(qq * v for qq, v in zip(q, vals)) - mu, max(qq / w for qq, w in zip(q, fair))


def _game(seed):
    cfg, agent, modes = _W["cfg"], _W["agent"], _W["modes"]
    rules = cfg.get_ruleset()
    mpts = rules.max_points
    fair = [w for *_, w in ROLLS]
    own = {m: 0.0 for m in modes}
    mirror = {m: 0.0 for m in modes}
    mult = {m: [] for m in modes}
    sig = []
    rng = random.Random(seed)
    board = rules.initial_board(cfg)
    player = WHITE
    plies = 0
    while not rules.is_over(board) and plies < 400:
        plies += 1
        vals = agent.roll_values(board, player, rules.legal_moves)
        mu, s = roll_spread(vals)
        sig.append(s * mpts)
        for m in modes:
            if player == WHITE:
                g, x = _luck(vals, turn_beta(vals, m[0], m[1], mpts), mu, fair)
                own[m] += g * mpts
            else:
                g, x = _luck(vals, mirrored_turn_beta(vals, m[0], m[1], mpts), mu, fair)
                mirror[m] -= g * mpts
            mult[m].append(x)
        dice = plain_roll(rng.random(), rng.random())
        moves = rules.legal_moves(board, player, dice)
        if moves:
            mv, _ = agent.get_best_move(board, moves, player, lookahead_plies=1)
            board.apply(mv, player)
        player = -player
    return own, mirror, mult, sig


def _ci(xs):
    m = statistics.mean(xs)
    h = 1.96 * statistics.stdev(xs) / len(xs) ** 0.5 if len(xs) > 1 else 0.0
    return 100 * m, 100 * h


def parse_grid(args):
    modes = []
    for a in args:
        name, _, xs = a.partition("=")
        modes += [(_KIND[name], float(x)) for x in xs.split(",") if x]
    return modes


def main(cfgpath: str, model: str, ngames: int, workers: int, modes) -> None:
    t0 = time.time()
    if workers > 1:
        with mp.get_context("spawn").Pool(workers, _init, (cfgpath, model, modes)) as pool:
            results = pool.map(_game, range(ngames), chunksize=1)
    else:
        _init(cfgpath, model, modes)
        results = [_game(k) for k in range(ngames)]
    sig = [s for *_, ss in results for s in ss]
    print(f"{cfgpath}: {ngames} games, {workers} workers, {time.time() - t0:.0f}s, turns {len(sig)}")
    q = sorted(sig)
    print("σ (pp): mean %.2f  p10 %.2f  p25 %.2f  median %.2f  p75 %.2f  p90 %.2f" % tuple(
        [100 * statistics.mean(sig)] + [100 * q[int(f * len(q))] for f in (.1, .25, .5, .75, .9)]))
    print("turns with σ < 1 pp: %.0f%%" % (100 * sum(1 for x in sig if x < 0.01) / len(sig)))
    print(f"{'mode':16s} {'x':>5s}  {'own (#261)':>13s}  {'mirror':>13s}  {'total (#271)':>13s}"
          f"  max q/p med/p90")
    for m in modes:
        own = [r[0][m] for r in results]
        mir = [r[1][m] for r in results]
        tot = [a + b for a, b in zip(own, mir)]
        mm = sorted(x for r in results for x in r[2][m])
        cells = "  ".join("%+6.1f ± %4.1f" % _ci(xs) for xs in (own, mir, tot))
        print(f"{m[0]:16s} {m[1]:5}  {cells}  {mm[len(mm) // 2]:.2f}/{mm[int(.9 * len(mm))]:.2f}",
              flush=True)


if __name__ == "__main__":
    argv = sys.argv[1:]
    grid = []
    if "--grid" in argv:
        i = argv.index("--grid")
        grid, argv = argv[i + 1:], argv[:i]
    modes = parse_grid(grid) if grid else (
        [("weighted_lean", k) for k in LEAN_KAPPAS]
        + [("weighted_gain", g) for g in GAIN_STEPS_PP]
        + [("weighted_hybrid", g) for g in HYBRID_STEPS_PP])
    main(argv[0], argv[1], int(argv[2]) if len(argv) > 2 else 120,
         int(argv[3]) if len(argv) > 3 else 1, modes)
