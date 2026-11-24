import XCTest
@testable import TavliEngine

/// Weighted-dice modes (#261): lean (constant bend), fixed gain (constant luck per roll,
/// capped), hybrid (min of both). Pure maths over 21 roll values — the parity table is
/// computed by `domain/handicap.py` (`turn_beta`, `weighted_faces`) on float32-exact values.
final class WeightedDiceModesTests: XCTestCase {

    private let fair = HandicapDice.outcomes.map(\.p)

    /// 21 values with mean `mu` and spread exactly `sigma` (fair weights): one fixed
    /// standardised shape scaled, so positions differ only in σ. Built in Double, then Float.
    private func spreadValues(_ sigma: Double, mu: Double = 0.5) -> [Float] {
        let raw = (0..<21).map { sin(1.7 * Double($0) + 0.3) }
        let m = zip(fair, raw).reduce(0.0) { $0 + $1.0 * $1.1 }
        let sd = zip(fair, raw).reduce(0.0) { $0 + $1.0 * ($1.1 - m) * ($1.1 - m) }.squareRoot()
        return raw.map { Float(mu + sigma * ($0 - m) / sd) }
    }

    private func gain(_ p: [Double], _ values: [Float]) -> Double {
        let mu = HandicapDice.spread(values).mu
        return zip(p, values).reduce(0.0) { $0 + $1.0 * Double($1.1) } - mu
    }

    private func maxMultiplier(_ p: [Double]) -> Double {
        zip(p, fair).map { $0 / $1 }.max()!
    }

    private let uniforms: [(Double, Double)] = [(0.0, 0.0), (0.13, 0.77), (0.5, 0.5), (0.71, 0.02),
                                                (0.999, 0.999), (0.4, 0.95), (0.25, 0.33), (0.86, 0.61)]

    // MARK: - Parity with the Python

    func testBetaAndDrawMatchPython() {
        for (name, values, mu, sigma, rows) in Self.parity {
            let s = HandicapDice.spread(values)
            XCTAssertEqual(s.mu, mu, accuracy: 1e-12, name)
            XCTAssertEqual(s.sigma, sigma, accuracy: 1e-12, name)
            for (mode, level, maxPoints, beta, faces) in rows {
                let dice = WeightedDice(mode: mode, level: level)
                let b = HandicapDice.beta(values: values, dice: dice, maxPoints: maxPoints)
                XCTAssertEqual(b, beta, accuracy: max(1e-9, beta * 1e-9),
                               "\(name) \(mode) L\(level) ×\(maxPoints)")
                for ((u1, u2), want) in zip(uniforms, faces) {
                    let got = HandicapDice.weightedFaces(u1: u1, u2: u2, values: values, beta: b)
                    XCTAssertTrue(got == want, "\(name) \(mode) L\(level) ×\(maxPoints) u=(\(u1),\(u2)): got \(got), want \(want)")
                }
            }
        }
    }

    func testStrengthGridsMatchPython() {
        // domain/handicap.py LEAN_KAPPAS / GAIN_STEPS_PP / SIGMA_FLOOR / GAIN_CAP / HYBRID_KAPPA_MAX.
        XCTAssertEqual(WeightedDiceMode.lean.strengths, [0.04, 0.08, 0.15, 0.25])
        XCTAssertEqual(WeightedDiceMode.fixedGain.strengths, [0.2, 0.4, 0.8, 1.5])
        XCTAssertEqual(WeightedDiceMode.hybrid.strengths, [0.2, 0.4, 0.8, 1.5])
        XCTAssertEqual(HandicapDice.sigmaFloor, 0.01)
        XCTAssertEqual(HandicapDice.gainCap, 3)
        XCTAssertEqual(HandicapDice.hybridKappaMax, 0.3)
        XCTAssertEqual(WeightedDiceMode.allCases.map(\.harnessKind),
                       ["weighted_lean", "weighted_gain", "weighted_hybrid"])
        for mode in WeightedDiceMode.allCases {
            XCTAssertEqual(mode.strengths.count, WeightedDice.levels)
            XCTAssertEqual(WeightedDice(mode: mode, level: 0).strength, 0)
        }
    }

    // MARK: - Properties

    /// Lean bends every position alike: relative to fair, a roll z standard deviations
    /// above another is e^{κz}× as likely, whatever σ (2σ above average: e^{2κ}×).
    func testLeanGivesConstantBendAcrossPositions() {
        for level in 1...WeightedDice.levels {
            let dice = WeightedDice(mode: .lean, level: level)
            let kappa = dice.strength
            for sigma in [0.015, 0.04, 0.12] {
                let values = spreadValues(sigma)
                let sd = HandicapDice.spread(values).sigma
                let p = HandicapDice.probabilities(values: values, dice: dice)
                XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-12)
                let ratio = zip(p, fair).map { $0 / $1 }
                for i in 0..<21 {
                    for j in 0..<21 {
                        let z = Double(values[i] - values[j]) / sd
                        XCTAssertEqual(ratio[i] / ratio[j], exp(kappa * z), accuracy: 1e-9)
                    }
                }
                let beta = HandicapDice.beta(values: values, dice: dice)
                XCTAssertEqual(exp(beta * 2 * sd), exp(2 * kappa), accuracy: 1e-9)
                XCTAssertEqual(gain(p, values) / (kappa * sd), 1, accuracy: 0.15, "gain ≈ κσ")
            }
        }
    }

    func testFixedGainHitsTargetWhereReachableAndRespectsCap() {
        var hit = 0, capped = 0
        for sigma in [0.012, 0.02, 0.05, 0.12] {
            let values = spreadValues(sigma)
            for g in WeightedDiceMode.fixedGain.strengths + [5] {
                let b = HandicapDice.gainBeta(values: values, gainPP: g)
                let p = HandicapDice.tilt(values: values, beta: b)
                XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-12)
                let m = maxMultiplier(p)
                let e = gain(p, values)
                XCTAssertLessThanOrEqual(m, HandicapDice.gainCap + 1e-9)
                XCTAssertLessThanOrEqual(e, g / 100 + 1e-9)
                if m < HandicapDice.gainCap - 1e-6 {
                    XCTAssertEqual(e, g / 100, accuracy: 1e-8, "σ \(sigma) g \(g)")
                    hit += 1
                } else {
                    XCTAssertEqual(m, HandicapDice.gainCap, accuracy: 1e-6)
                    capped += 1
                }
            }
        }
        XCTAssertGreaterThan(hit, 0)
        XCTAssertGreaterThan(capped, 0)
    }

    func testHybridIsMinOfGainAndLeanCeiling() {
        var gainBinds = false, leanBinds = false
        for sigma in [0.011, 0.02, 0.05, 0.12] {
            let values = spreadValues(sigma)
            for level in 1...WeightedDice.levels {
                let g = WeightedDiceMode.hybrid.strengths[level - 1]
                let bg = HandicapDice.gainBeta(values: values, gainPP: g)
                let bl = HandicapDice.leanBeta(values: values, kappa: HandicapDice.hybridKappaMax)
                XCTAssertEqual(HandicapDice.beta(values: values, dice: WeightedDice(mode: .hybrid, level: level)),
                               min(bg, bl))
                gainBinds = gainBinds || bg < bl
                leanBinds = leanBinds || bl < bg
            }
        }
        XCTAssertTrue(gainBinds && leanBinds, "both branches exercised")
    }

    func testSigmaNearZeroIsFair() {
        for values in [[Float](repeating: 0.5, count: 21), spreadValues(1e-4), spreadValues(0.0099)] {
            for mode in [WeightedDiceMode.fixedGain, .hybrid] {
                let dice = WeightedDice(mode: mode, level: WeightedDice.levels)
                XCTAssertEqual(HandicapDice.beta(values: values, dice: dice), 0)
                XCTAssertEqual(HandicapDice.probabilities(values: values, dice: dice), fair)
            }
        }
        // Lean below the floor bends no harder than at σ = floor; flat values stay fair.
        let tiny = spreadValues(0.002)
        XCTAssertEqual(HandicapDice.leanBeta(values: tiny, kappa: 0.15), 0.15 / HandicapDice.sigmaFloor,
                       accuracy: 1e-12)
        XCTAssertLessThan(maxMultiplier(HandicapDice.probabilities(
            values: tiny, dice: WeightedDice(mode: .lean, level: WeightedDice.levels))), 1.2)
        let flat = HandicapDice.probabilities(values: [Float](repeating: 0.5, count: 21),
                                              dice: WeightedDice(mode: .lean, level: WeightedDice.levels))
        for (q, w) in zip(flat, fair) { XCTAssertEqual(q, w, accuracy: 1e-15) }
        // Off is fair whatever the values.
        XCTAssertEqual(HandicapDice.probabilities(values: spreadValues(0.1), dice: .off), fair)
    }

    func testProbabilitiesSumToOneInEveryMode() {
        for sigma in [0.0, 0.005, 0.03, 0.2] {
            let values = spreadValues(sigma, mu: 0.4)
            for mode in WeightedDiceMode.allCases {
                for level in 0...WeightedDice.levels {
                    for maxPoints in [1, 2] {
                        let p = HandicapDice.probabilities(values: values, dice: WeightedDice(mode: mode, level: level),
                                                           maxPoints: maxPoints)
                        XCTAssertEqual(p.count, 21)
                        XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-12)
                        XCTAssertTrue(p.allSatisfy { $0 >= 0 && $0.isFinite })
                    }
                }
            }
        }
    }

    /// 2-point variants: g and the σ floor are win-chance-equivalent pp (÷ maxPoints in
    /// normalised-equity units); κ is scale-free.
    func testTwoPointScaling() {
        let values = spreadValues(0.03)
        let b = HandicapDice.gainBeta(values: values, gainPP: 0.4, maxPoints: 2)
        XCTAssertEqual(gain(HandicapDice.tilt(values: values, beta: b), values), 0.002, accuracy: 1e-8)
        XCTAssertEqual(HandicapDice.leanBeta(values: values, kappa: 0.15, maxPoints: 2),
                       HandicapDice.leanBeta(values: values, kappa: 0.15))
        let tiny = spreadValues(0.007)   // under 1 pp, over 0.5 pp
        XCTAssertEqual(HandicapDice.gainBeta(values: tiny, gainPP: 0.4), 0)
        XCTAssertGreaterThan(HandicapDice.gainBeta(values: tiny, gainPP: 0.4, maxPoints: 2), 0)
    }

    func testDrawIsDeterministic() {
        let values = spreadValues(0.06)
        for mode in WeightedDiceMode.allCases {
            let dice = WeightedDice(mode: mode, level: 3)
            let b1 = HandicapDice.beta(values: values, dice: dice)
            let b2 = HandicapDice.beta(values: values, dice: dice)
            XCTAssertEqual(b1, b2)
            var u = 0.0137
            for _ in 0..<300 {
                u = (u * 7919 + 0.123).truncatingRemainder(dividingBy: 1)
                let v = (u * 104729).truncatingRemainder(dividingBy: 1)
                XCTAssertTrue(HandicapDice.weightedFaces(u1: u, u2: v, values: values, beta: b1)
                              == HandicapDice.weightedFaces(u1: u, u2: v, values: values, beta: b2))
            }
        }
    }

    /// The draw follows the mode's distribution (inverse CDF over a uniform grid).
    func testDrawFollowsModeDistribution() {
        let values = spreadValues(0.08)
        for mode in WeightedDiceMode.allCases {
            let dice = WeightedDice(mode: mode, level: WeightedDice.levels)
            let b = HandicapDice.beta(values: values, dice: dice)
            var hist = [Int](repeating: 0, count: 21)
            let n = 240
            for i in 0..<n {
                for j in 0..<n {
                    let f = HandicapDice.weightedFaces(u1: (Double(i) + 0.5) / Double(n),
                                                       u2: (Double(j) + 0.5) / Double(n),
                                                       values: values, beta: b)
                    hist[HandicapDice.outcomeIndex(f.0, f.1)!] += 1
                }
            }
            let p = HandicapDice.tilt(values: values, beta: b)
            for k in 0..<21 { XCTAssertEqual(Double(hist[k]) / Double(n * n), p[k], accuracy: 0.004, "\(mode) \(k)") }
        }
    }

    // MARK: - Model + migration

    func testOffValuesAreEqualWhateverTheMode() {
        XCTAssertEqual(WeightedDice(mode: .lean, level: 0), .off)
        XCTAssertEqual(HandicapItems(weightedDice: WeightedDice(mode: .fixedGain, level: 0)), .none)
        XCTAssertTrue(HandicapItems(weightedDice: WeightedDice(mode: .lean, level: 0)).isEmpty)
        XCTAssertNotEqual(WeightedDice(mode: .lean, level: 2), WeightedDice(mode: .hybrid, level: 2))
        XCTAssertEqual(Set([WeightedDice(mode: .lean, level: 0), .off]).count, 1)
        XCTAssertEqual(WeightedDice(mode: .lean, level: 9).clamped, WeightedDice(mode: .lean, level: 4))
        XCTAssertFalse(WeightedDice(mode: .lean, level: -2).clamped.isOn)
    }

    func testSetupRoundTripsModeAndLevel() throws {
        let s = HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .lean, level: 3), rerolls: 1),
                              black: HandicapItems(weightedDice: WeightedDice(mode: .fixedGain, level: 1)))
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""mode":"lean""#), json)
        XCTAssertFalse(json.contains("diceTilt"), "the old key is never written")
        XCTAssertEqual(try JSONDecoder().decode(HandicapSetup.self, from: data), s)
        XCTAssertEqual(s.version, 3)
        // Off is not written at all.
        let off = String(decoding: try JSONEncoder().encode(HandicapItems(rerolls: 2)), as: UTF8.self)
        XCTAssertFalse(off.contains("weightedDice"), off)
    }

    /// Pre-#261 setups carry a fixed β (`diceTilt`): they load as hybrid dice of a
    /// comparable strength (old app steps β 0.3 / 0.6 / 1.2 / 2.0 → levels 1 / 1 / 2 / 3).
    func testOldBetaMigratesToHybrid() throws {
        let cases: [(Double, Int)] = [(0, 0), (0.3, 1), (0.6, 1), (1.2, 2), (2.0, 3), (8, 4), (-1, 0)]
        for (beta, level) in cases {
            let json = #"{"version":2,"white":{"diceTilt":\#(beta),"rerolls":1},"black":{}}"#
            let s = try JSONDecoder().decode(HandicapSetup.self, from: Data(json.utf8))
            let dice = s.white.weightedDice
            XCTAssertEqual(dice.level, level, "β \(beta)")
            if level > 0 { XCTAssertEqual(dice.mode, .hybrid) }
            XCTAssertEqual(s.white.rerolls, 1)
            XCTAssertEqual(s.hasWeightedDice, level > 0)
        }
        // A whole old save (GameSave.handicap) loads with its dice migrated and tokens kept.
        let save = #"{"setup":{"version":2,"white":{},"black":{"diceTilt":1.2,"rerolls":2}},"rerollsLeft":{"white":0,"black":1},"hintsLeft":{"white":0,"black":0}}"#
        let state = try JSONDecoder().decode(HandicapGameState.self, from: Data(save.utf8))
        XCTAssertEqual(state.setup.black.weightedDice, WeightedDice(mode: .hybrid, level: 2))
        XCTAssertEqual(state.rerollsLeft.black, 1)
        // Re-encoded, it is a version-3 file without the old key.
        let again = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(again.contains("diceTilt"))
        XCTAssertTrue(again.contains(#""mode":"hybrid""#))
    }

    func testWeightedDiceAreNotInTheEstimate() {
        // No weighted-dice cell is measured (#261): listed as unmeasured, the other side's
        // rerolls and the same side's rerolls still count.
        let table = HandicapTable(cells: ["rerolls:2": .init(logOddsShift: 0.2)])
        let setup = HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .lean, level: 2), rerolls: 2))
        let e = HandicapEstimator.combine(positionWhite: 0.5, setup: setup, table: table)
        XCTAssertEqual(e.unmeasured, ["weighted_lean"])
        XCTAssertEqual(e.whiteWinChance, 1 / (1 + exp(-0.2)), accuracy: 1e-9)
    }

    /// The handicap button's favourite counts unmeasured weighted dice at their rough
    /// calibrated strength: moderate weighted dice outweigh one measured reroll.
    func testFavouredSideCountsWeightedDiceRoughly() {
        let table = HandicapTable(cells: ["rerolls:1": .init(logOddsShift: 0.1966)])
        let setup = HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .fixedGain, level: 2)),
                                  black: HandicapItems(rerolls: 1))
        let e = HandicapEstimator.combine(positionWhite: 0.5, setup: setup, table: table)
        XCTAssertLessThan(e.whiteWinChance, 0.5, "the shown estimate leaves the dice out")
        XCTAssertEqual(HandicapEstimator.favouredSide(setup: setup, estimate: e, table: table), .white)
        XCTAssertEqual(HandicapEstimator.favouredSide(setup: setup, estimate: nil, table: table), .white)
        // Equal dice on both sides cancel out.
        let even = HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .lean, level: 2)),
                                 black: HandicapItems(weightedDice: WeightedDice(mode: .lean, level: 2)))
        XCTAssertNil(HandicapEstimator.favouredSide(setup: even, estimate: nil, table: .unmeasured))
        // Monotone in the level, in every mode.
        for mode in WeightedDiceMode.allCases {
            let shifts = (0...WeightedDice.levels).map { WeightedDice(mode: mode, level: $0).approximateLogOddsShift }
            XCTAssertEqual(shifts[0], 0)
            XCTAssertEqual(shifts, shifts.sorted(), "\(mode)")
        }
    }

    // MARK: - Python parity table (generated by domain/handicap.py, float32-exact values)

    typealias Row = (WeightedDiceMode, Int, Int, Double, [(Int, Int)])
    static let parity: [(String, [Float], Double, Double, [Row])] = [
        // steps: μ 0.49944444352553946, σ 0.1809994517546057
        ("steps", [0.30000001192092896, 0.3199999928474426, 0.3400000035762787, 0.8999999761581421, 0.3799999952316284, 0.4000000059604645, 0.41999998688697815, 0.4399999976158142, 0.46000000834465027, 0.47999998927116394, 0.05000000074505806, 0.5199999809265137, 0.5400000214576721, 0.5600000023841858, 0.5799999833106995, 0.6000000238418579, 0.6200000047683716, 0.6399999856948853, 0.6600000262260437, 0.6800000071525574, 0.699999988079071], 0.49944444352553946, 0.1809994517546057, [
            (.lean, 1, 1, 0.2209951445280119, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.lean, 1, 2, 0.2209951445280119, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.lean, 2, 1, 0.4419902890560238, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 2, 2, 0.4419902890560238, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 3, 1, 0.8287317919800445, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 3, 2, 0.8287317919800445, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 4, 1, 1.3812196533000742, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 5)]),
            (.lean, 4, 2, 1.3812196533000742, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 5)]),
            (.fixedGain, 1, 1, 0.06112905194146094, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 1, 2, 0.03054449397935045, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 2, 1, 0.12241618672343448, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 2, 2, 0.06112905194146094, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 3, 1, 0.24544687233413565, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 3, 2, 0.12241618672343448, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 4, 1, 0.4621173871262868, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.fixedGain, 4, 2, 0.23003567331411878, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 1, 1, 0.06112905194146094, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 1, 2, 0.03054449397935045, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 2, 1, 0.12241618672343448, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 2, 2, 0.06112905194146094, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 3, 1, 0.24544687233413565, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 3, 2, 0.12241618672343448, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 4, 1, 0.4621173871262868, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.hybrid, 4, 2, 0.23003567331411878, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
        ]),
        // tense: μ 0.46212866571214467, σ 0.11242445060143288
        ("tense", [0.42953309416770935, 0.3603396713733673, 0.5603737831115723, 0.32897451519966125, 0.5143527984619141, 0.4462755620479584, 0.3231995701789856, 0.502974271774292, 0.3149982690811157, 0.47345826029777527, 0.3279421627521515, 0.33628520369529724, 0.4698076844215393, 0.6307408213615417, 0.3495207726955414, 0.3892955780029297, 0.5509732961654663, 0.6790835857391357, 0.5308411717414856, 0.4586721956729889, 0.6905020475387573], 0.46212866571214467, 0.11242445060143288, [
            (.lean, 1, 1, 0.35579448941945896, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.lean, 1, 2, 0.35579448941945896, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.lean, 2, 1, 0.7115889788389179, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 2, 2, 0.7115889788389179, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 3, 1, 1.334229335322971, [(1, 1), (1, 5), (4, 5), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 3, 2, 1.334229335322971, [(1, 1), (1, 5), (4, 5), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.lean, 4, 1, 2.2237155588716186, [(1, 1), (1, 5), (4, 5), (5, 2), (6, 6), (4, 2), (2, 3), (6, 5)]),
            (.lean, 4, 2, 2.2237155588716186, [(1, 1), (1, 5), (4, 5), (5, 2), (6, 6), (4, 2), (2, 3), (6, 5)]),
            (.fixedGain, 1, 1, 0.15769805965073203, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 1, 2, 0.0789824834132774, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 2, 1, 0.3143596261803818, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 2, 2, 0.15769805965073203, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 3, 1, 0.6248156386947434, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.fixedGain, 3, 2, 0.3143596261803818, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.fixedGain, 4, 1, 1.1601110528849157, [(1, 1), (1, 5), (4, 5), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.fixedGain, 4, 2, 0.5862058920001014, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.hybrid, 1, 1, 0.15769805965073203, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 1, 2, 0.0789824834132774, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 2, 1, 0.3143596261803818, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 2, 2, 0.15769805965073203, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 3, 1, 0.6248156386947434, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.hybrid, 3, 2, 0.3143596261803818, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 3), (6, 4)]),
            (.hybrid, 4, 1, 1.1601110528849157, [(1, 1), (1, 5), (4, 5), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
            (.hybrid, 4, 2, 0.5862058920001014, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (4, 1), (2, 3), (6, 4)]),
        ]),
        // quiet: μ 0.6176026993327671, σ 0.009089458123002528
        ("quiet", [0.6118011474609375, 0.6338688731193542, 0.6087899208068848, 0.626144528388977, 0.6075555682182312, 0.6124232411384583, 0.6349738836288452, 0.6112819314002991, 0.6242560744285583, 0.6187739968299866, 0.6185939908027649, 0.6198495030403137, 0.6107669472694397, 0.6299156546592712, 0.6076869964599609, 0.6120254993438721, 0.6055997610092163, 0.6130030155181885, 0.6172299385070801, 0.6320619583129883, 0.616372287273407], 0.6176026993327671, 0.009089458123002528, [
            (.lean, 1, 1, 4.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 1, 2, 4.40070238057126, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 2, 1, 8.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 2, 2, 8.80140476114252, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 3, 1, 15.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 3, 2, 16.502633927142224, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 4, 1, 25.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 5)]),
            (.lean, 4, 2, 27.50438987857037, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 5), (2, 2), (6, 5)]),
            (.fixedGain, 1, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 1, 2, 11.786015608983773, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 2, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 2, 2, 23.093397959493416, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 3, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 3, 2, 45.06998450783472, [(1, 1), (1, 5), (4, 2), (5, 1), (6, 6), (3, 5), (2, 2), (6, 5)]),
            (.fixedGain, 4, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 4, 2, 79.20748032220651, [(1, 1), (1, 4), (4, 1), (4, 6), (6, 6), (3, 5), (2, 1), (6, 5)]),
            (.hybrid, 1, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 1, 2, 11.786015608983773, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 2, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 2, 2, 23.093397959493416, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 3, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 3, 2, 33.00526785428445, [(1, 1), (1, 5), (4, 2), (5, 1), (6, 6), (3, 5), (2, 2), (6, 5)]),
            (.hybrid, 4, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 4, 2, 33.00526785428445, [(1, 1), (1, 5), (4, 2), (5, 1), (6, 6), (3, 5), (2, 2), (6, 5)]),
        ]),
        // flat: μ 0.8093503961960477, σ 0.002882868030677331
        ("flat", [0.8096300959587097, 0.8087331056594849, 0.8063853979110718, 0.8136656284332275, 0.8050643801689148, 0.8100278377532959, 0.8139829635620117, 0.8058081269264221, 0.8105427026748657, 0.811166524887085, 0.8054089546203613, 0.8087902069091797, 0.8120347857475281, 0.8095201849937439, 0.8122506737709045, 0.8065715432167053, 0.8073801398277283, 0.8061094880104065, 0.8100627064704895, 0.8142383098602295, 0.8109042644500732], 0.8093503961960477, 0.002882868030677331, [
            (.lean, 1, 1, 4.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 1, 2, 8.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 2, 1, 8.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 2, 2, 16.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 3, 1, 15.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 3, 2, 30.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 4, 1, 25.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.lean, 4, 2, 50.0, [(1, 1), (1, 5), (4, 3), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 1, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 1, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 2, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 2, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 3, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 3, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 4, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.fixedGain, 4, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 1, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 1, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 2, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 2, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 3, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 3, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 4, 1, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
            (.hybrid, 4, 2, 0.0, [(1, 1), (1, 5), (4, 4), (5, 1), (6, 6), (3, 6), (2, 2), (6, 4)]),
        ]),
    ]
}

