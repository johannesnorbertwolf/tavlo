import Foundation

/// One player's post-game summary (#231), built from a review's evaluations and
/// (optionally) the dice-luck pass. All losses and luck are in **win-chance-equivalent
/// percentage points** (`PlyEvaluation.decisionLoss` / `PlyLuck.luckPoints`), so they
/// read the same in Plakoto and the 2-point variants.
public struct GameReviewSummary: Equatable, Sendable {
    /// The player summarized.
    public let color: Color
    /// Mean per-move accuracy (0…100, `moveAccuracy`) over `color`'s plies **with a
    /// choice**; `nil` when it had none (or none were evaluated).
    public let accuracy: Double?
    /// `color`'s evaluated plies with a choice (the accuracy's denominator).
    public let choicePlies: Int
    public let inaccuracies: Int
    public let mistakes: Int
    public let blunders: Int
    /// Total decision loss over `color`'s plies with a choice, in percentage points.
    public let decisionLoss: Double
    /// `color`'s total dice luck in percentage points (positive = lucky), or `nil`
    /// until the luck pass has run.
    public let luck: Double?
    /// The opponent's total dice luck, or `nil` until the luck pass has run.
    public let opponentLuck: Double?
    /// How many of `color`'s / the opponent's rolls the luck covers (#259: the luck
    /// may be partial while the analysis runs); 0 without luck.
    public let luckRolls: Int
    public let opponentLuckRolls: Int

    public init(color: Color, accuracy: Double?, choicePlies: Int, inaccuracies: Int,
                mistakes: Int, blunders: Int, decisionLoss: Double,
                luck: Double?, opponentLuck: Double?,
                luckRolls: Int = 0, opponentLuckRolls: Int = 0) {
        self.color = color
        self.accuracy = accuracy
        self.choicePlies = choicePlies
        self.inaccuracies = inaccuracies
        self.mistakes = mistakes
        self.blunders = blunders
        self.decisionLoss = decisionLoss
        self.luck = luck
        self.opponentLuck = opponentLuck
        self.luckRolls = luckRolls
        self.opponentLuckRolls = opponentLuckRolls
    }

    /// Summarize `color` from `evaluations` (any mix of both sides; only `color`'s
    /// count) and optional `luck` (both sides; `nil` leaves the luck totals `nil`).
    /// Both may be partial (#259) — what the analysis has found so far: the averages
    /// below are over what is in.
    public init(color: Color, evaluations: [PlyEvaluation], luck: [PlyLuck]? = nil) {
        let mine = evaluations.filter { $0.mover == color }
        let choices = mine.filter(\.hadChoice)
        let accuracy = choices.isEmpty ? nil
            : choices.reduce(0.0) { $0 + $1.accuracy } / Double(choices.count)
        self.init(
            color: color,
            accuracy: accuracy,
            choicePlies: choices.count,
            inaccuracies: mine.filter { $0.severity == .inaccuracy }.count,
            mistakes: mine.filter { $0.severity == .mistake }.count,
            blunders: mine.filter { $0.severity == .blunder }.count,
            decisionLoss: choices.reduce(0.0) { $0 + $1.decisionLoss },
            luck: luck.map { Self.totalLuck($0, of: color) },
            opponentLuck: luck.map { Self.totalLuck($0, of: color.opponent) },
            luckRolls: luck?.filter { $0.mover == color }.count ?? 0,
            opponentLuckRolls: luck?.filter { $0.mover == color.opponent }.count ?? 0)
    }

    /// `color`'s mean decision loss per ply with a choice, in percentage points
    /// (#233/#259); `nil` while there is none.
    public var decisionLossPerMove: Double? {
        choicePlies > 0 ? decisionLoss / Double(choicePlies) : nil
    }

    /// `color`'s mean luck per roll minus the opponent's, in percentage points
    /// (positive = the dice favoured `color`; a side with no rolls counts 0). `nil`
    /// without luck, or before any roll's luck is in.
    public var netLuckPerRoll: Double? {
        guard let luck, let opponentLuck, luckRolls + opponentLuckRolls > 0 else { return nil }
        func mean(_ total: Double, _ n: Int) -> Double { n > 0 ? total / Double(n) : 0 }
        return mean(luck, luckRolls) - mean(opponentLuck, opponentLuckRolls)
    }

    /// Whether the luck covers at least one roll of each side — enough for a fair
    /// per-roll comparison while the luck is still partial (#259).
    public var luckCoversBothSides: Bool { luckRolls > 0 && opponentLuckRolls > 0 }

    /// The count of `color`'s plies at `severity` (`.none` counts the choice plies
    /// that were none of the three).
    public func count(_ severity: MoveSeverity) -> Int {
        switch severity {
        case .none: return choicePlies - inaccuracies - mistakes - blunders
        case .inaccuracy: return inaccuracies
        case .mistake: return mistakes
        case .blunder: return blunders
        }
    }

    /// Lichess's per-move accuracy for a loss of `lossPoints` percentage points:
    /// `103.1668·exp(−0.04354·loss) − 3.1669`, clamped to 0…100 (≈ 100 at no loss,
    /// ≈ 62 at 10 pp, 0 from ≈ 80 pp).
    public static func moveAccuracy(lossPoints: Double) -> Double {
        let raw = 103.1668 * exp(-0.04354 * max(0, lossPoints)) - 3.1669
        return min(100, max(0, raw))
    }

    /// Sum of `color`'s ply luck, in percentage points.
    public static func totalLuck(_ luck: [PlyLuck], of color: Color) -> Double {
        luck.filter { $0.mover == color }.reduce(0.0) { $0 + $1.luckPoints }
    }
}
