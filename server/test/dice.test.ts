// Server dice (#286): the TypeScript port of the app's hybrid bend must match the Python
// reference row for row (test/data/weighted-dice-parity.json, written by
// ios/scripts/make_weighted_dice_parity.py — the same table the Swift
// WeightedDiceModesTests check), and the draws must have the right distributions.
import { describe, expect, it } from "vitest";
import parity from "./data/weighted-dice-parity.json";
import {
  cryptoRandom,
  type DiceRandom,
  drawRoll,
  face,
  mirroredBeta,
  outcomeIndex,
  ROLL_OUTCOMES,
  rollBeta,
  spread,
  turnBeta,
  weightedFaces,
} from "../src/dice";

interface Row {
  level: number;
  maxPoints: number;
  beta: number;
  faces: [number, number][];
  mirroredBeta: number;
  mirroredFaces: [number, number][];
}
const table = parity as { uniforms: [number, number][]; vectors: { name: string; values: number[]; rows: Row[] }[] };

/** Exact where the arithmetic is identical; bisection results agree to rounding. */
const close = (a: number, b: number) => expect(Math.abs(a - b)).toBeLessThanOrEqual(1e-12 * Math.max(1, Math.abs(b)));

/** A seeded PRNG (mulberry32) standing in for crypto in distribution tests. */
function seeded(seed: number): DiceRandom {
  let s = seed >>> 0;
  const next = () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return { uniform: next, die: () => face(next()) };
}

describe("weighted dice parity with the app (Python table)", () => {
  it("covers the four vectors × four levels × two maxPoints", () => {
    expect(table.vectors.map((v) => v.name)).toEqual(["steps", "tense", "quiet", "flat"]);
    for (const v of table.vectors) expect(v.rows).toHaveLength(8);
  });

  for (const vector of table.vectors) {
    it(`${vector.name}: β_t, mirrored β_t and the faces drawn`, () => {
      for (const row of vector.rows) {
        const own = turnBeta(vector.values, row.level, row.maxPoints);
        const mirrored = mirroredBeta(vector.values, row.level, row.maxPoints);
        close(own, row.beta);
        close(mirrored, row.mirroredBeta);
        expect(rollBeta(vector.values, "W", row.level, row.maxPoints)).toBe(own);
        expect(rollBeta(vector.values, "B", row.level, row.maxPoints)).toBe(mirrored);
        expect(rollBeta(vector.values, "B", -row.level, row.maxPoints)).toBe(own);
        expect(rollBeta(vector.values, "W", -row.level, row.maxPoints)).toBe(mirrored);
        table.uniforms.forEach(([u1, u2], i) => {
          expect(weightedFaces(u1, u2, vector.values, own)).toEqual(row.faces[i]);
          expect(weightedFaces(u1, u2, vector.values, mirrored)).toEqual(row.mirroredFaces[i]);
        });
      }
    });
  }

  it("is fair at level 0 and for flat values", () => {
    const flat = table.vectors.find((v) => v.name === "flat")!.values;
    expect(rollBeta(flat, "W", 0)).toBe(0);
    expect(spread(flat).sigma).toBeLessThan(0.01);
    expect(turnBeta(flat, 4)).toBe(0); // σ below the floor: model noise only
    expect(weightedFaces(0.5, 0.5, flat, 0)).toEqual([face(0.5), face(0.5)]);
  });

  it("orders the 21 rolls like HandicapDice.outcomes", () => {
    expect(ROLL_OUTCOMES).toHaveLength(21);
    expect(ROLL_OUTCOMES.slice(0, 7)).toEqual([[1, 1], [1, 2], [1, 3], [1, 4], [1, 5], [1, 6], [2, 2]]);
    expect(outcomeIndex(6, 5)).toBe(19);
  });
});

describe("dice distributions", () => {
  const N = 72_000;

  it("crypto fair dice are uniform and independent (χ² over 36 outcomes)", () => {
    const counts = new Array(36).fill(0);
    for (let i = 0; i < N; i++) {
      const { die1, die2, weighted, beta } = drawRoll(0, "W", undefined, 1, cryptoRandom);
      expect(weighted).toBeUndefined();
      expect(beta).toBeUndefined();
      counts[(die1 - 1) * 6 + (die2 - 1)]++;
    }
    const expected = N / 36;
    const chi2 = counts.reduce((s, c) => s + (c - expected) ** 2 / expected, 0);
    expect(chi2).toBeLessThan(75); // df 35: p ≈ 1e-4
  }, 60_000); // statistical: seconds on a slow CI runner

  it("the bend tilts the draw to q ∝ p·exp(β v) and its mirror to the other side", () => {
    const values = table.vectors.find((v) => v.name === "steps")!.values;
    const rng = seeded(7);
    for (const roller of ["W", "B"] as const) {
      const beta = rollBeta(values, roller, 4, 1);
      expect(roller === "W" ? beta > 0 : beta < 0).toBe(true);
      const counts = new Array(21).fill(0);
      for (let i = 0; i < N; i++) {
        const r = drawRoll(4, roller, values, 1, rng);
        expect(r.weighted).toBe(4);
        expect(r.beta).toBe(beta);
        counts[outcomeIndex(r.die1, r.die2)]++;
      }
      const fair = ROLL_OUTCOMES.map(([a, b]) => (a === b ? 1 : 2) / 36);
      const raw = fair.map((p, i) => p * Math.exp(beta * values[i]!));
      const z = raw.reduce((s, x) => s + x, 0);
      const chi2 = raw.reduce((s, x, i) => s + (counts[i] - (N * x) / z) ** 2 / ((N * x) / z), 0);
      expect(chi2).toBeLessThan(50); // df 20
      // The favoured side gains, the other side loses, against fair dice.
      const mean = counts.reduce((s, c, i) => s + c * values[i]!, 0) / N;
      const fairMean = fair.reduce((s, p, i) => s + p * values[i]!, 0);
      if (roller === "W") expect(mean).toBeGreaterThan(fairMean + 0.002);
      else expect(mean).toBeLessThan(fairMean - 0.002);
    }
  }, 60_000); // statistical: ~7 s on a CI runner (the default 5 s timed out)

  it("2-point variants bend less per level (g and σ floor ÷ maxPoints)", () => {
    const values = table.vectors.find((v) => v.name === "tense")!.values;
    expect(turnBeta(values, 2, 2)).not.toBe(turnBeta(values, 2, 1));
  });
});
