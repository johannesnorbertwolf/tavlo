"""Weighted-dice calibration (#261): how strong is each mode's strength step?

Plays `games` 1-ply self-play games of a variant with fair dice and, on every White turn,
rates the 21 rolls (`Agent.roll_values`) and records, per weighted-dice mode and strength,
the expected luck of that turn E_q[v] − μ (win-chance-equivalent: × max_points). The
per-game sum is the first-order gain of a side holding that handicap all game (it ignores
that the tilted dice change the positions reached, so strong tilts are overstated a little:
the old fixed β 2.0 sums to +27 pp here and measured +22 pp in E1). Also reports the spread
σ of the roll values and the largest probability multiplier max_r q(r)/p(r).

    PYTHONPATH=. .venv/bin/python scripts/weighted_dice_calibration.py \
        config/config.yml models/gold_v11.pth 120

Seconds per dozen games; no training, no files written.
"""
import random
import statistics
import sys
import time

from ai.checkpoint_io import load_agent_from_checkpoint
from config.config_loader import ConfigLoader
from domain.constants import WHITE
from domain.handicap import (GAIN_STEPS_PP, LEAN_KAPPAS, ROLLS, plain_roll, roll_spread,
                             tilted_roll_probs, turn_beta)


def main(cfgpath: str, model: str, ngames: int) -> None:
    cfg = ConfigLoader(cfgpath)
    agent, _ = load_agent_from_checkpoint(model, cfg)
    rules = cfg.get_ruleset()
    mp = rules.max_points
    modes = ([("weighted_lean", k) for k in LEAN_KAPPAS]
             + [("weighted_gain", g) for g in GAIN_STEPS_PP]
             + [("weighted_hybrid", g) for g in GAIN_STEPS_PP])
    fair = [w for *_, w in ROLLS]
    sig = []
    gains = {m: [] for m in modes}
    maxmult = {m: [] for m in modes}
    t0 = time.time()
    rng = random.Random(1)
    for _ in range(ngames):
        board = rules.initial_board(cfg)
        player = WHITE
        per = {m: 0.0 for m in modes}
        plies = 0
        while not rules.is_over(board) and plies < 400:
            plies += 1
            if player == WHITE:
                vals = agent.roll_values(board, player, rules.legal_moves)
                mu, s = roll_spread(vals)
                sig.append(s * mp)
                for m in modes:
                    b = turn_beta(vals, m[0], m[1], mp)
                    q = tilted_roll_probs(vals, b) if b else fair
                    per[m] += (sum(qq * v for qq, v in zip(q, vals)) - mu) * mp
                    maxmult[m].append(max(qq / w for qq, w in zip(q, fair)))
            dice = plain_roll(rng.random(), rng.random())
            moves = rules.legal_moves(board, player, dice)
            if moves:
                mv, _ = agent.get_best_move(board, moves, player, lookahead_plies=1)
                board.apply(mv, player)
            player = -player
        for m in modes:
            gains[m].append(per[m])
    print(f"{cfgpath}: {ngames} games, {time.time() - t0:.0f}s, White turns {len(sig)}")
    q = sorted(sig)
    print("σ (pp): mean %.2f  p10 %.2f  p25 %.2f  median %.2f  p75 %.2f  p90 %.2f" % tuple(
        [100 * statistics.mean(sig)] + [100 * q[int(f * len(q))] for f in (.1, .25, .5, .75, .9)]))
    print("turns with σ < 1 pp: %.0f%%" % (100 * sum(1 for x in sig if x < 0.01) / len(sig)))
    for m in modes:
        turns = len(maxmult[m])
        mm = sorted(maxmult[m])
        print(f"{m[0]:16s} {m[1]:5}: first-order gain/game {100 * statistics.mean(gains[m]):5.1f} pp "
              f"(per roll {100 * sum(gains[m]) / turns:4.2f}); max multiplier median "
              f"{mm[turns // 2]:.2f}, p90 {mm[int(.9 * turns)]:.2f}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 120)
