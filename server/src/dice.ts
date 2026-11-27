// Server dice (#286, REFERENCE.md "Server dice"): fair rolls from the Workers crypto RNG,
// and the shared slider's weighted bend — a port of the app's `HandicapDice` hybrid mode
// with the #271 mirror (Swift `HandicapDice.hybridBeta` / `mirroredBeta` / `weightedFaces`,
// Python `domain/handicap.py` `hybrid_beta` / `mirrored_turn_beta` / `weighted_faces`).
// **Keep in sync**: `test/dice.test.ts` checks every hybrid row of the Python parity table
// (`test/data/weighted-dice-parity.json`, written by ios/scripts/make_weighted_dice_parity.py).

import { type Color, ROLL_COUNT } from "./api";

/** The 21 distinct rolls (d1 <= d2) in canonical order (Swift `HandicapDice.outcomes`). */
export const ROLL_OUTCOMES: readonly (readonly [number, number])[] = (() => {
  const out: [number, number][] = [];
  for (let a = 1; a <= 6; a++) for (let b = a; b <= 6; b++) out.push([a, b]);
  return out;
})();

/** Fair probability of each of the 21 rolls (doubles 1/36, the rest 2/36). */
const FAIR = ROLL_OUTCOMES.map(([a, b]) => (a === b ? 1 : 2) / 36);

/** Hybrid gain g per level 1…4 in win-chance pp (`WeightedDiceMode.hybrid.strengths`). */
export const HYBRID_STRENGTHS = [0.1, 0.2, 0.35, 0.5] as const;
export const SIGMA_FLOOR = 0.01;
export const GAIN_CAP = 3;
export const HYBRID_KAPPA_MAX = 0.3;
const BETA_SPAN = 50;
const BISECTION_STEPS = 60;

/** (μ, σ) of the 21 values under the fair roll probabilities. */
export function spread(values: readonly number[]): { mu: number; sigma: number } {
  let mu = 0;
  for (let i = 0; i < FAIR.length; i++) mu += FAIR[i]! * values[i]!;
  let variance = 0;
  for (let i = 0; i < FAIR.length; i++) variance += FAIR[i]! * (values[i]! - mu) * (values[i]! - mu);
  return { mu, sigma: Math.sqrt(Math.max(variance, 0)) };
}

export function leanBeta(values: readonly number[], kappa: number, maxPoints = 1): number {
  if (!(kappa > 0) || values.length !== ROLL_COUNT) return 0;
  return kappa / Math.max(spread(values).sigma, SIGMA_FLOOR / maxPoints);
}

/** Fixed gain: the largest β ≥ 0 with E_q[v] − μ ≤ g and max q/p ≤ cap (bisection). */
export function gainBeta(values: readonly number[], gainPP: number, maxPoints = 1, cap = GAIN_CAP): number {
  if (!(gainPP > 0) || values.length !== ROLL_COUNT) return 0;
  const { mu, sigma } = spread(values);
  if (sigma < SIGMA_FLOOR / maxPoints) return 0;
  const target = gainPP / 100 / maxPoints;
  const vmax = Math.max(...values);
  let lo = 0;
  let hi = BETA_SPAN / sigma;
  for (let step = 0; step < BISECTION_STEPS; step++) {
    const mid = 0.5 * (lo + hi);
    let z = 0;
    let ev = 0;
    for (let i = 0; i < FAIR.length; i++) {
      const e = FAIR[i]! * Math.exp(mid * (values[i]! - vmax));
      z += e;
      ev += e * values[i]!;
    }
    if (ev / z - mu <= target && 1 / z <= cap) lo = mid;
    else hi = mid;
  }
  return lo;
}

/** Hybrid: min(fixed gain's β, κ_max / max(σ, σ_floor)). */
export function hybridBeta(values: readonly number[], gainPP: number, maxPoints = 1): number {
  return Math.min(gainBeta(values, gainPP, maxPoints), leanBeta(values, HYBRID_KAPPA_MAX, maxPoints));
}

/** The favoured side's own β_t at `level` (1…4; 0 = fair). */
export function turnBeta(values: readonly number[], level: number, maxPoints = 1): number {
  const g = HYBRID_STRENGTHS[level - 1];
  return g === undefined ? 0 : hybridBeta(values, g, maxPoints);
}

/** The mirrored bend on the opponent's roll (#271): −β_t(−v) ≤ 0. */
export function mirroredBeta(values: readonly number[], level: number, maxPoints = 1): number {
  const b = turnBeta(
    values.map((v) => -v),
    level,
    maxPoints,
  );
  return b === 0 ? 0 : -b;
}

/** β_t for `roller` when the slider is `whiteLevel` (+n favours White, −n Black). */
export function rollBeta(values: readonly number[], roller: Color, whiteLevel: number, maxPoints = 1): number {
  if (whiteLevel === 0) return 0;
  const favoured: Color = whiteLevel > 0 ? "W" : "B";
  const level = Math.abs(whiteLevel);
  return roller === favoured ? turnBeta(values, level, maxPoints) : mirroredBeta(values, level, maxPoints);
}

/** A fair face from a uniform in [0, 1). */
export const face = (u: number): number => 1 + Math.min(Math.floor(u * 6), 5);

/** The index of roll (d1, d2) in `ROLL_OUTCOMES` (either order). */
export function outcomeIndex(d1: number, d2: number): number {
  const lo = Math.min(d1, d2);
  const hi = Math.max(d1, d2);
  return ROLL_OUTCOMES.findIndex(([a, b]) => a === lo && b === hi);
}

/**
 * Ordered faces for uniforms u1, u2 in [0, 1): inverse CDF of `(int(6 u1) + u2) / 6` over
 * the 36 ordered outcomes, each weighted by its roll's tilt exp(β·(v − vmax)). β = 0 (or
 * no values) is the fair `(face(u1), face(u2))`.
 */
export function weightedFaces(u1: number, u2: number, values: readonly number[] | undefined, beta: number): [number, number] {
  if (beta === 0 || !values || values.length !== ROLL_COUNT) return [face(u1), face(u2)];
  const vmax = Math.max(...values);
  const tilt = values.map((v) => Math.exp(beta * (v - vmax)));
  const cum: number[] = [];
  let total = 0;
  for (let a = 1; a <= 6; a++) {
    for (let b = 1; b <= 6; b++) {
      total += tilt[outcomeIndex(a, b)]!;
      cum.push(total);
    }
  }
  const target = ((Math.floor(u1 * 6) + u2) / 6) * total;
  let k = 35;
  for (let i = 0; i < cum.length; i++) {
    if (target < cum[i]!) {
      k = i;
      break;
    }
  }
  return [1 + Math.floor(k / 6), 1 + (k % 6)];
}

/** Source of randomness; tests replace it to make draws deterministic. */
export interface DiceRandom {
  /** Uniform in [0, 1) with 53 random bits. */
  uniform(): number;
  /** A fair die face 1…6 (rejection sampling, no modulo bias). */
  die(): number;
}

export const cryptoRandom: DiceRandom = {
  uniform() {
    const w = crypto.getRandomValues(new Uint32Array(2));
    return ((w[0]! >>> 11) * 2 ** 32 + w[1]!) / 2 ** 53;
  },
  die() {
    const byte = new Uint8Array(1);
    for (;;) {
      crypto.getRandomValues(byte);
      if (byte[0]! < 252) return 1 + (byte[0]! % 6); // 252 = 42 × 6: unbiased
    }
  },
};

export interface DrawnRoll {
  die1: number;
  die2: number;
  /** The slider level the roll was bent with (absent = fair: slider at 0). */
  weighted?: number;
  /** β_t applied (absent = fair draw). */
  beta?: number;
}

/**
 * Draws a roll. Fair slider → two independent fair faces (`values` ignored). Weighted
 * slider → `values` are required (the caller validated them) and the roll follows the
 * hybrid bend for `roller`, `weighted` = the slider level, `beta` = β_t.
 */
export function drawRoll(
  whiteLevel: number,
  roller: Color,
  values: readonly number[] | undefined,
  maxPoints: number,
  random: DiceRandom = cryptoRandom,
): DrawnRoll {
  if (whiteLevel === 0 || !values) return { die1: random.die(), die2: random.die() };
  const beta = rollBeta(values, roller, whiteLevel, maxPoints);
  const [die1, die2] = weightedFaces(random.uniform(), random.uniform(), values, beta);
  return { die1, die2, weighted: whiteLevel, beta };
}
