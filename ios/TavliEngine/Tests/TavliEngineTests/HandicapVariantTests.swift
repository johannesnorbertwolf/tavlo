import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Handicaps in every variant and across Full Tavli (#246): weighted dice, rerolls (the
/// human's and the computer's rule), hints and moves first in house Plakoto, standard
/// Plakoto, Fevga and Portes, with each variant's own value net; the head start and the
/// tier-2 rules stay house-Plakoto-only; one Full Tavli setup runs through all three legs
/// and survives save / resume mid-leg and between legs.
@MainActor
final class HandicapVariantTests: XCTestCase {

    private static let variants: [any GameVariant] = [
        GameVariants.plakoto, GameVariants.plakotoStandard, GameVariants.fevga, GameVariants.portes,
    ]

    private static var agents: [String: Agent] = [:]
    private func agent(_ variant: any GameVariant) throws -> Agent {
        if let a = Self.agents[variant.id] { return a }
        let a = try VariantAgentParity.agent(for: variant)
        Self.agents[variant.id] = a
        return a
    }

    /// A deterministic uniform stream.
    private func uniforms(_ values: [Double]) -> () -> Double {
        var i = 0
        return { defer { i += 1 }; return values[i % values.count] }
    }

    /// Fair uniforms that produce die `d` (`HandicapDice.face`).
    private func u(_ d: Int) -> Double { (Double(d) - 0.5) / 6 }

    private func config(_ v: any GameVariant) -> GameConfig { GameConfig(variant: v) }

    /// The variant's own start position, as stacks.
    private func startStacks(_ v: any GameVariant) -> [[Color]] {
        let b = GameBoard(config: config(v))
        v.setUpInitialPosition(on: b)
        return b.captureStacks()
    }

    // MARK: - Availability

    func testAvailabilityPerVariantAndFullTavli() {
        for v in Self.variants {
            XCTAssertTrue(HandicapSetup.supports(variantID: v.id), v.id)
            for item in HandicapItemKind.allCases {
                let single = HandicapSetup.availability(item, variantID: v.id)
                let ft = HandicapSetup.availability(item, variantID: v.id, fullTavli: true)
                if item.needsHouseRules {
                    XCTAssertEqual(single, v.id == "plakoto" ? .available : .houseRulesOnly, "\(v.id) \(item)")
                    XCTAssertEqual(ft, .notInFullTavli, "\(v.id) \(item)")
                } else {
                    XCTAssertEqual(single, .available, "\(v.id) \(item)")
                    XCTAssertEqual(ft, .available, "\(v.id) \(item)")
                }
            }
        }
        XCTAssertFalse(HandicapSetup.supports(variantID: "nope"))
        XCTAssertEqual(Set(HandicapItemKind.allCases.filter(\.needsHouseRules)), [.headStart, .ruleChanges])
    }

    func testRestrictedKeepsTheModelFreeItemsOnly() {
        let full = HandicapSetup(white: HandicapItems(headStart: 3, weightedDice: WeightedDice(mode: .hybrid, level: 2), rerolls: 2, hints: 1,
                                                      overshoot: true, safePoint: 4, checkers: 16),
                                 black: HandicapItems(movesFirst: true, homeSize: 4))
        XCTAssertEqual(full.restricted(toVariantID: "plakoto"), full, "house Plakoto keeps everything")
        let expected = HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .hybrid, level: 2), rerolls: 2, hints: 1),
                                     black: HandicapItems(movesFirst: true))
        for id in ["plakoto_standard", "fevga", "portes"] {
            XCTAssertEqual(full.restricted(toVariantID: id), expected, id)
        }
        XCTAssertEqual(full.restricted(toVariantID: "plakoto", fullTavli: true), expected)
        // Only house-Plakoto items: nothing left elsewhere.
        let rulesOnly = HandicapSetup(white: HandicapItems(headStart: 2, overshoot: true))
        XCTAssertFalse(rulesOnly.restricted(toVariantID: "fevga").isActive)
    }

    // MARK: - Session: every variant

    func testMovesFirstAndNoHeadStartOutsideHousePlakoto() {
        let setup = HandicapSetup(white: HandicapItems(headStart: 2, checkers: 14),
                                  black: HandicapItems(movesFirst: true, rerolls: 1))
        for v in Self.variants {
            let s = GameSession(startingPlayer: .white, config: config(v), animationTimings: .off,
                                handicap: setup)
            XCTAssertEqual(s.startingPlayer, .black, "\(v.id): moves first")
            XCTAssertEqual(s.currentPlayer, .black, v.id)
            let h = try! XCTUnwrap(s.handicap, v.id)
            XCTAssertEqual(s.record.handicap, h.setup, v.id)
            XCTAssertEqual(h.rerollsLeft[.black], 1, v.id)
            if v.id == "plakoto" {
                XCTAssertEqual(h.setup.white.headStart, 2)
                XCTAssertEqual(s.game.board.points[7].pieces.count, 2, "house Plakoto: head start")
            } else {
                XCTAssertEqual(h.setup.white, .none, "\(v.id): head start / checkers dropped")
                XCTAssertEqual(s.game.board.captureStacks(), startStacks(v), "\(v.id): own start position")
                XCTAssertNil(s.game.board.config.handicapRules, v.id)
                // A replay from the start reconstructs the same position.
                let b = GameBoard(config: s.record.replayConfig)
                s.record.setUpInitialPosition(on: b)
                XCTAssertEqual(b.captureStacks(), startStacks(v), v.id)
            }
        }
        // Only house-Plakoto items in another variant: a normal game.
        let s = GameSession(startingPlayer: .white, config: config(GameVariants.portes),
                            animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(headStart: 2, safePoint: 4)))
        XCTAssertNil(s.handicap)
        XCTAssertNil(s.record.handicap)
    }

    /// The per-roll values are the variant's own 1-ply values — the same as the review's
    /// dice luck — at the start and at a bar-entry position (Portes) / a race (Fevga).
    func testRollValuesMatchDiceLuckInEveryVariant() throws {
        for v in Self.variants {
            let agent = try agent(v)
            var boards: [GameBoard] = []
            let start = GameBoard(config: config(v))
            v.setUpInitialPosition(on: start)
            boards.append(start)
            if v.id == "portes" { boards.append(portesBarPosition()) }
            for b in boards {
                for color in Color.allCases {
                    let before = b.captureStacks()
                    let values = try HandicapDice.rollValues(agent: agent, board: b, color: color)
                    XCTAssertEqual(b.captureStacks(), before, "\(v.id): board unchanged")
                    let luck = try DiceLuck.rollValues(agent: agent, board: b, mover: color)
                    XCTAssertEqual(values.count, 21)
                    for (x, r) in zip(values, luck) {
                        XCTAssertEqual(Double(x), r.value, accuracy: 1e-6, "\(v.id) \(r.d1)-\(r.d2)")
                        XCTAssertTrue((0...1).contains(x), "\(v.id): value in [0, 1]")
                    }
                }
            }
        }
    }

    /// Portes: White has one checker on the bar; Black holds five of White's six entry
    /// points, so only a roll with a 6 enters — every other roll is a pass.
    private func portesBarPosition() -> GameBoard {
        let b = GameBoard(config: config(GameVariants.portes))
        // White enters on points 1…6 (`[0, d]`); Black holds 1…5.
        PortesVariant.setPosition(on: b, white: [12: 14], black: [1: 2, 2: 2, 3: 2, 4: 2, 5: 2, 13: 5],
                                  whiteBar: 1)
        return b
    }

    func testPortesBarEntryPassesAreValuedAsPasses() throws {
        let v = GameVariants.portes
        let agent = try agent(v)
        let b = portesBarPosition()
        let values = try HandicapDice.rollValues(agent: agent, board: b, color: .white)
        let pass = 1 - (try agent.winProbability(b, color: .black))
        let dice = Dice()
        var passes = 0
        for (i, o) in HandicapDice.outcomes.enumerated() {
            dice.set(o.d1, o.d2)
            if v.legalMoves(on: b, color: .white, dice: dice).isEmpty {
                passes += 1
                XCTAssertEqual(values[i], pass, accuracy: 1e-6, "\(o.d1)-\(o.d2) is a pass")
            }
        }
        XCTAssertGreaterThan(passes, 10, "most rolls can't enter")
        XCTAssertLessThan(passes, 21, "a 6 enters")
        // The tilt pushes towards the entering rolls when they are better.
        let tilted = HandicapDice.tilt(values: values, beta: 8)
        XCTAssertEqual(tilted.reduce(0, +), 1, accuracy: 1e-9)
        let fairEV = Double(HandicapDice.expectedValue(values))
        let tiltedEV = zip(tilted, values).reduce(0.0) { $0 + $1.0 * Double($1.1) }
        XCTAssertGreaterThanOrEqual(tiltedEV, fairEV - 1e-9)
    }

    /// Weighted dice draw from the tilted distribution with the variant's own net, and
    /// the background analysis is paused while the roll is being prepared (#243).
    func testWeightedRollInEveryVariantAndAnalysisWaits() async throws {
        for v in Self.variants {
            let agent = try agent(v)
            let service = AnalysisService(gameLog: nil, saveStore: nil) { _ in agent }
            service.persistDelay = 0
            // Each variant with another mode (the draw path is the same for all three).
            let mode = WeightedDiceMode.allCases[Self.variants.firstIndex { $0.id == v.id }! % 3]
            let dice = WeightedDice(mode: mode, level: WeightedDice.levels)
            let s = GameSession(startingPlayer: .white, config: config(v), animationTimings: .off,
                                handicap: HandicapSetup(white: HandicapItems(weightedDice: dice)),
                                handicapAgent: agent)
            s.analysisService = service
            let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .white)
            let beta = HandicapDice.beta(values: values, dice: dice, maxPoints: v.maxPoints)
            let expected = HandicapDice.weightedFaces(u1: 0.5, u2: 0.1, values: values, beta: beta)
            s.handicapUniform = uniforms([0.5, 0.1])
            s.roll()
            XCTAssertTrue(s.preparingDice, v.id)
            XCTAssertTrue(service.gate.isHeld, "\(v.id): analysis paused while the dice are prepared")
            await s.awaitDiceForTesting()
            XCTAssertFalse(service.gate.isHeld, "\(v.id): analysis resumes")
            XCTAssertEqual(s.phase, .picking, v.id)
            XCTAssertEqual(s.game.dice.die1.value, expected.0, v.id)
            XCTAssertEqual(s.game.dice.die2.value, expected.1, v.id)
            let probs = HandicapDice.probabilities(values: values, dice: dice, maxPoints: v.maxPoints)
            let tiltedEV = zip(probs, values).reduce(0.0) { $0 + $1.0 * Double($1.1) }
            if beta > 0 {
                XCTAssertGreaterThan(tiltedEV, Double(HandicapDice.expectedValue(values)), "\(v.id) \(mode)")
            }
            // The dice are not fair: the review's note applies.
            XCTAssertTrue(try XCTUnwrap(s.record.handicap).altersDice, v.id)
        }
    }

    /// The tilted distribution itself: off is fair, a higher level of every mode moves
    /// at least as much mass to the better rolls (β_t grows with the level), in every variant.
    func testTiltedDistributionInEveryVariant() throws {
        for v in Self.variants {
            let agent = try agent(v)
            let b = GameBoard(config: config(v))
            v.setUpInitialPosition(on: b)
            let values = try HandicapDice.rollValues(agent: agent, board: b, color: .black)
            XCTAssertEqual(HandicapDice.tilt(values: values, beta: 0), HandicapDice.outcomes.map(\.p))
            XCTAssertEqual(HandicapDice.probabilities(values: values, dice: .off, maxPoints: v.maxPoints),
                           HandicapDice.outcomes.map(\.p))
            for mode in WeightedDiceMode.allCases {
                var last = HandicapDice.spread(values).mu
                for level in 1...WeightedDice.levels {
                    let p = HandicapDice.probabilities(values: values, dice: WeightedDice(mode: mode, level: level),
                                                       maxPoints: v.maxPoints)
                    XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-9)
                    let ev = zip(p, values).reduce(0.0) { $0 + $1.0 * Double($1.1) }
                    XCTAssertGreaterThanOrEqual(ev, last - 1e-9, "\(v.id) \(mode) L\(level)")
                    last = ev
                }
            }
            // The 36-slot draw matches the distribution: count slots over a fine grid.
            var counts = [Double](repeating: 0, count: 21)
            let n = 120
            for i in 0..<n {
                for j in 0..<n {
                    let f = HandicapDice.weightedFaces(u1: (Double(i) + 0.5) / Double(n),
                                                       u2: (Double(j) + 0.5) / Double(n),
                                                       values: values, beta: 2)
                    counts[HandicapDice.outcomeIndex(f.0, f.1)!] += 1
                }
            }
            let p = HandicapDice.tilt(values: values, beta: 2)
            for k in 0..<21 {
                XCTAssertEqual(counts[k] / Double(n * n), p[k], accuracy: 0.02, "\(v.id) roll \(k)")
            }
        }
    }

    func testHumanRerollInEveryVariant() {
        for v in Self.variants {
            let s = GameSession(startingPlayer: .white, config: config(v), animationTimings: .off,
                                handicap: HandicapSetup(white: HandicapItems(rerolls: 2)))
            s.setDice(3, 5)
            XCTAssertTrue(s.canReroll, v.id)
            let before = s.game.board.captureStacks()
            if let h = s.moveBuilder.activeMoves.first?.halfMoves.first {
                s.selectPoint(h.from.position)
                s.commitHalfMove(from: h.from.position, to: h.to.position)
            }
            s.handicapUniform = uniforms([u(6), u(6)])
            s.reroll()
            XCTAssertEqual(s.game.dice.die1.value, 6, v.id)
            XCTAssertEqual(s.game.dice.die2.value, 6, v.id)
            XCTAssertEqual(s.game.board.captureStacks(), before, "\(v.id): built half taken back")
            XCTAssertEqual(s.rerollsLeft(.white), 1, v.id)
            XCTAssertEqual(s.pendingRoll, PendingRoll(die1: 6, die2: 6), v.id)
            XCTAssertTrue(try! XCTUnwrap(s.record.handicap).altersDice, v.id)
        }
    }

    /// The computer's reroll rule with the variant's own values: forced onto its worst
    /// roll, it rerolls (when that roll is bad enough) and plays the next one.
    func testComputerRerollRuleInEveryVariant() async throws {
        var rerolledIn: [String] = []
        for v in Self.variants {
            let agent = try agent(v)
            let s = GameSession(startingPlayer: .black, config: config(v), agent: agent, aiColor: .black,
                                searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                                handicap: HandicapSetup(black: HandicapItems(rerolls: 3)))
            setUpBearOffRace(s.game.board)
            let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .black)
            let worst = values.indices.min { values[$0] < values[$1] }!
            let best = values.indices.max { values[$0] < values[$1] }!
            let w = HandicapDice.outcomes[worst], b = HandicapDice.outcomes[best]
            let rerolls = HandicapDice.shouldReroll(values: values, d1: w.d1, d2: w.d2)
            XCTAssertFalse(HandicapDice.shouldReroll(values: values, d1: b.d1, d2: b.d2), v.id)
            s.handicapUniform = uniforms([u(w.d1), u(w.d2), u(b.d1), u(b.d2)])
            s.start()
            let deadline = Date().addingTimeInterval(60)
            while (s.phase == .aiThinking || s.preparingDice), Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let ply = try XCTUnwrap(s.history.first, v.id)
            XCTAssertTrue(rerolls, "\(v.id): the worst roll of an exact bear-off is worth a reroll")
            if rerolls {
                rerolledIn.append(v.id)
                XCTAssertEqual(s.rerollsLeft(.black), 2, v.id)
                XCTAssertEqual(s.lastComputerReroll, .black, v.id)
                XCTAssertEqual(HandicapDice.outcomeIndex(ply.die1, ply.die2), best, v.id)
            } else {
                XCTAssertEqual(s.rerollsLeft(.black), 3, v.id)
                XCTAssertEqual(HandicapDice.outcomeIndex(ply.die1, ply.die2), worst, v.id)
            }
        }
        XCTAssertEqual(rerolledIn.count, Self.variants.count)
    }

    /// A bear-off where the roll decides a lot, laid out through the variant's own
    /// geometry: Black (to move) has 13 off and checkers 6 and 5 pips from home; White
    /// has 14 off and one checker 7 pips from home. A 6-5 wins on the spot.
    private func setUpBearOffRace(_ b: GameBoard) {
        let v = b.variant, n = b.boardSize
        for i in b.points.indices { b.setPoint(i, pieces: []) }
        b.setPoint(v.bearOffPoint(for: .black, boardSize: n), pieces: Array(repeating: .black, count: 13))
        b.setPoint(v.point(atPath: n - 5, for: .black, boardSize: n), pieces: [.black])
        b.setPoint(v.point(atPath: n - 4, for: .black, boardSize: n), pieces: [.black])
        b.setPoint(v.bearOffPoint(for: .white, boardSize: n), pieces: Array(repeating: .white, count: 14))
        b.setPoint(v.point(atPath: n - 6, for: .white, boardSize: n), pieces: [.white])
    }

    func testHintInEveryVariant() async throws {
        for v in Self.variants {
            let agent = try agent(v)
            let s = GameSession(startingPlayer: .white, config: config(v), animationTimings: .off,
                                handicap: HandicapSetup(white: HandicapItems(hints: 2)),
                                handicapAgent: agent)
            s.setDice(6, 4)
            let before = s.game.board.captureStacks()
            XCTAssertTrue(s.canHint, v.id)
            s.requestHint()
            await s.awaitHintForTesting()
            let hint = try XCTUnwrap(s.hint, v.id)
            XCTAssertEqual(s.game.board.captureStacks(), before, "\(v.id): the hint is not played")
            XCTAssertEqual(s.hintsLeft(.white), 1, v.id)
            let legal = s.legalMoves.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } }
            XCTAssertTrue(legal.contains(hint), "\(v.id): the hint is a legal move")
        }
    }

    func testAdjustCardWorksInEveryVariant() {
        for v in Self.variants {
            let s = GameSession(startingPlayer: .white, config: config(v), animationTimings: .off,
                                handicap: HandicapSetup(white: HandicapItems(hints: 1)))
            s.adjustHandicap(for: .black, weightedDice: WeightedDice(mode: .hybrid, level: 2), rerollsLeft: 2)
            let setup = try! XCTUnwrap(s.record.handicap, v.id)
            XCTAssertEqual(setup.black.weightedDice, WeightedDice(mode: .hybrid, level: 2), v.id)
            XCTAssertEqual(s.rerollsLeft(.black), 2, v.id)
            XCTAssertTrue(setup.adjusted, v.id)
        }
    }

    func testEstimateTableOnlyForHousePlakoto() {
        let table = HandicapTable(cells: ["rerolls:2": .init(logOddsShift: 0.25)])
        XCTAssertEqual(table.forVariant("plakoto"), table)
        for id in ["plakoto_standard", "fevga", "portes"] {
            XCTAssertEqual(table.forVariant(id), .unmeasured, id)
            XCTAssertFalse(HandicapEstimator.isMeasured(variantID: id), id)
            let e = HandicapEstimator.combine(positionWhite: 0.5,
                                              setup: HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .hybrid, level: 2))),
                                              table: table.forVariant(id))
            XCTAssertEqual(e.unmeasured, ["weighted_hybrid"], id)
        }
        XCTAssertTrue(HandicapEstimator.isMeasured(variantID: "plakoto"))
    }

    // MARK: - Full Tavli

    private let ftSetup = HandicapSetup(
        white: HandicapItems(headStart: 2, weightedDice: WeightedDice(mode: .hybrid, level: 1), rerolls: 2, hints: 3, overshoot: true),
        black: HandicapItems(movesFirst: true, homeSize: 5))

    func testFullTavliKeepsOneSetupThroughEveryLegAndTheFavouredSideStartsEach() throws {
        var ft = FullTavliSession(aiColor: .black, handicap: ftSetup)
        let expected = HandicapSetup(white: HandicapItems(weightedDice: WeightedDice(mode: .hybrid, level: 1), rerolls: 2, hints: 3),
                                     black: HandicapItems(movesFirst: true))
        XCTAssertEqual(ft.handicap, expected, "head start and rule changes are off in Full Tavli")
        var legs: [String] = []
        while let variant = ft.currentVariant {
            legs.append(variant.id)
            let setup = try XCTUnwrap(ft.setupForCurrentLeg, variant.id)
            XCTAssertEqual(setup, expected, variant.id)
            let starter = ft.startingPlayer(default: .white)
            XCTAssertEqual(starter, .black, "\(variant.id): moves first in every leg")
            let s = GameSession(startingPlayer: starter, config: config(variant), aiColor: .black,
                                animationTimings: .off, handicap: setup)
            XCTAssertEqual(s.startingPlayer, .black, variant.id)
            XCTAssertEqual(s.rerollsLeft(.white), 2, "\(variant.id): fresh tokens")
            XCTAssertEqual(s.hintsLeft(.white), 3, variant.id)
            XCTAssertEqual(s.game.board.captureStacks(), startStacks(variant), variant.id)
            XCTAssertNil(s.game.board.config.handicapRules, "\(variant.id): no tier-2 rules")
            s.surrender()
            ft.carryHandicap(from: s.record)
            ft.recordGame(winner: s.record.outcome, points: s.record.points ?? 1)
        }
        XCTAssertEqual(legs, ["portes", "fevga", "plakoto"])
        XCTAssertTrue(ft.isComplete)
        XCTAssertNil(ft.setupForCurrentLeg)
    }

    func testFullTavliCarriesAMidLegAdjustmentToTheNextLegs() throws {
        var ft = FullTavliSession(aiColor: nil, handicap: ftSetup)
        let s = GameSession(startingPlayer: .black, config: config(GameVariants.portes),
                            animationTimings: .off, handicap: ft.setupForCurrentLeg)
        s.adjustHandicap(for: .white, weightedDice: WeightedDice(mode: .fixedGain, level: 3), rerollsLeft: 1)
        s.surrender(as: .black)
        ft.carryHandicap(from: s.record)
        ft.recordGame(winner: s.record.outcome, points: s.record.points ?? 1)
        let next = try XCTUnwrap(ft.setupForCurrentLeg)
        XCTAssertEqual(next.white.weightedDice, WeightedDice(mode: .fixedGain, level: 3))
        XCTAssertEqual(next.white.rerolls, 1)
        XCTAssertFalse(next.adjusted, "a new leg is not itself adjusted")
        XCTAssertTrue(next.black.movesFirst)
        // Adjusted down to nothing (moves first can't change, so drop it here): normal legs.
        var plain = FullTavliSession(handicap: HandicapSetup(white: HandicapItems(rerolls: 1)))
        let g = GameSession(startingPlayer: .white, config: config(GameVariants.portes),
                            animationTimings: .off, handicap: plain.setupForCurrentLeg)
        g.adjustHandicap(for: .white, rerollsLeft: 0)
        g.surrender(as: .white)
        plain.carryHandicap(from: g.record)
        XCTAssertNil(plain.handicap)
        // A leg without a handicap leaves the session's setup alone.
        var kept = FullTavliSession(handicap: ftSetup)
        kept.carryHandicap(from: GameRecord(startingPlayer: .white, variantID: "portes"))
        XCTAssertNotNil(kept.handicap)
    }

    func testFullTavliSaveResumeMidLegAndBetweenLegsCarriesTheHandicap() throws {
        let ft = FullTavliSession(aiColor: nil, handicap: ftSetup)
        // Mid-leg (Portes): a reroll used, then saved and relaunched.
        let s = GameSession(startingPlayer: ft.startingPlayer(default: .white),
                            config: config(GameVariants.portes), animationTimings: .off,
                            handicap: ft.setupForCurrentLeg)
        XCTAssertEqual(s.currentPlayer, .black)
        s.setDice(3, 1)
        let move = try XCTUnwrap(s.legalMoves.first)
        for h in move.halfMoves {
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
        s.confirm()
        XCTAssertEqual(s.currentPlayer, .white)
        s.setDice(2, 1)
        s.handicapUniform = uniforms([u(4), u(4)])
        s.reroll()
        XCTAssertEqual(s.rerollsLeft(.white), 1)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let save = try dec.decode(GameSave.self, from: enc.encode(s.snapshot(name: "ft", fullTavli: ft)))
        var loadedFT = try XCTUnwrap(save.fullTavli)
        XCTAssertEqual(loadedFT.handicap, ft.handicap)
        XCTAssertEqual(loadedFT.resume(savedGame: save.record), .inLeg(index: 0))
        let resumed = GameSession.resume(from: save, animationTimings: .off)
        XCTAssertEqual(resumed.handicap?.setup, s.handicap?.setup)
        XCTAssertEqual(resumed.rerollsLeft(.white), 1, "tokens left survive the relaunch")
        XCTAssertEqual(resumed.hintsLeft(.white), 3)
        XCTAssertEqual(resumed.game.board.captureStacks(), s.game.board.captureStacks())

        // The leg ends; the app wrote the finished leg + the session, then was killed
        // before recording it. Relaunch: between legs, the next leg keeps the handicap.
        resumed.surrender(as: .black)
        let finished = try dec.decode(GameSave.self,
                                      from: enc.encode(resumed.snapshot(name: "ft", fullTavli: loadedFT)))
        var between = try XCTUnwrap(finished.fullTavli)
        XCTAssertEqual(between.resume(savedGame: finished.record), .betweenLegs(nextIndex: 1))
        XCTAssertEqual(between.currentVariant?.id, "fevga")
        let next = try XCTUnwrap(between.setupForCurrentLeg)
        XCTAssertEqual(next, ft.handicap, "fresh tokens, same items")
        XCTAssertEqual(between.startingPlayer(default: .white), .black)
        let fevga = GameSession(startingPlayer: between.startingPlayer(default: .white),
                                config: config(GameVariants.fevga), animationTimings: .off, handicap: next)
        XCTAssertEqual(fevga.rerollsLeft(.white), 2)
    }

    func testFullTavliWithoutHandicapEncodesAsBefore() throws {
        let plain = FullTavliSession(aiColor: .black)
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("handicap"))
        // An older session file (no key) and a malformed one decode without a handicap.
        let legacy = #"{"plakotoVariantID":"plakoto","aiColor":"B","results":[]}"#
        XCTAssertNil(try JSONDecoder().decode(FullTavliSession.self, from: Data(legacy.utf8)).handicap)
        let bad = #"{"plakotoVariantID":"plakoto","results":[],"handicap":"garbage"}"#
        XCTAssertNil(try JSONDecoder().decode(FullTavliSession.self, from: Data(bad.utf8)).handicap)
        // Round trip with one.
        let with = FullTavliSession(aiColor: .black, handicap: ftSetup)
        XCTAssertEqual(try JSONDecoder().decode(FullTavliSession.self, from: JSONEncoder().encode(with)), with)
        // A setup of only house-Plakoto items is no handicap in Full Tavli.
        XCTAssertNil(FullTavliSession(handicap: HandicapSetup(white: HandicapItems(headStart: 3))).handicap)
    }
}
