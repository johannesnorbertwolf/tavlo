"""Regenerate the Python parity table in `WeightedDiceModesTests.swift` (#261, mirrored #271).

Keeps the table's four named float32-exact value vectors (steps, tense, quiet, flat) and
recomputes, per mode × level × max_points, from `domain/handicap.py`: the favoured side's own
β_t (`turn_beta`) and the opponent's mirrored β_t (`mirrored_turn_beta`), each with the faces
`weighted_faces` draws for the test's eight uniform pairs. Rewrites the block in place.

    PYTHONPATH=. .venv/bin/python ios/scripts/make_weighted_dice_parity.py
"""
import pathlib
import re

from domain.handicap import (KINDS, mirrored_turn_beta, roll_spread, turn_beta,
                             weighted_faces)

TEST = (pathlib.Path(__file__).resolve().parents[1]
        / "TavliEngine/Tests/TavliEngineTests/WeightedDiceModesTests.swift")
MODES = [(".lean", "weighted_lean"), (".fixedGain", "weighted_gain"), (".hybrid", "weighted_hybrid")]
BEGIN = "    typealias Row = "
END = "    ]\n}\n"


def main() -> None:
    src = TEST.read_text()
    m = re.search(r"private let uniforms: \[\(Double, Double\)\] = (\[.*?\])\n", src, re.S)
    uniforms = eval(m.group(1).replace("\n", " "))
    vectors = re.findall(r'^        \("(\w+)", \[([^\]]*)\]', src, re.M)
    out = [BEGIN + "(WeightedDiceMode, Int, Int, Double, [(Int, Int)], Double, [(Int, Int)])\n",
           "    /// (mode, level, maxPoints, own β_t, own faces, mirrored β_t, mirrored faces)\n",
           "    static let parity: [(String, [Float], Double, Double, [Row])] = [\n"]
    for name, raw in vectors:
        vals = [float(x) for x in raw.split(",")]
        mu, sigma = roll_spread(vals)
        out.append(f"        // {name}: μ {mu!r}, σ {sigma!r}\n")
        out.append(f'        ("{name}", [{", ".join(repr(v) for v in vals)}], {mu!r}, {sigma!r}, [\n')
        for swift, kind in MODES:
            for level, x in enumerate(KINDS[kind].intensities, 1):
                for mp in (1, 2):
                    b = turn_beta(vals, kind, x, mp)
                    bm = mirrored_turn_beta(vals, kind, x, mp)
                    f = [weighted_faces(u1, u2, vals, b) for u1, u2 in uniforms]
                    fm = [weighted_faces(u1, u2, vals, bm) for u1, u2 in uniforms]
                    fs = lambda faces: "[" + ", ".join(f"({a}, {c})" for a, c in faces) + "]"
                    out.append(f"            ({swift}, {level}, {mp}, {b!r}, {fs(f)}, {bm!r}, {fs(fm)}),\n")
        out.append("        ]),\n")
    start = src.index(BEGIN)
    end = src.rindex(END)
    assert end > start
    TEST.write_text(src[:start] + "".join(out) + END)
    print(f"wrote {len(vectors)} vectors to {TEST}")


if __name__ == "__main__":
    main()
