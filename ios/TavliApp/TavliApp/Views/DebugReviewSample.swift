#if DEBUG
import SwiftUI
import TavliEngine

/// DEBUG-only shortcut into the post-game review (#232), for checking review/drill
/// visuals without playing a game first. Launch with `-debugReviewSample`: the app
/// opens a full-screen `GameReviewView` over a seeded sample game (house Plakoto, you =
/// White vs the computer, 24 plies of seeded random legal moves, then the computer
/// "wins" by resignation). Random play leaves plenty of blunders, so "Drill blunders"
/// is always offered. Nothing is saved or counted in the stats. Compiled out of release
/// builds.
enum DebugReviewSample {
    static let launchArgument = "-debugReviewSample"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// The side you review as (#233): `-debugReviewAs red` reviews as Red (the
    /// computer plays White); White otherwise.
    static var humanColor: TavliEngine.Color {
        UserDefaults.standard.string(forKey: "debugReviewAs") == "red" ? .black : .white
    }

    /// The computer's level (#233): `-debugReviewLevel 5` marks a computer that can
    /// err, so its mistakes show on the chart; unset = unknown (treated as full strength).
    static var aiLevel: Int? {
        let level = UserDefaults.standard.integer(forKey: "debugReviewLevel")
        return level == 0 ? nil : level
    }

    /// The same game on every launch (fixed seed), so screenshots are reproducible.
    static func record(plies count: Int = 24, seed: UInt64 = 232) -> GameRecord {
        var rng = SplitMix(state: seed)
        let config = GameConfig.standard
        let variant = config.variant
        let board = GameBoard(config: config)
        variant.setUpInitialPosition(on: board)
        let dice = Dice(numberOfSides: config.dieSides)
        var record = GameRecord(startingPlayer: .white, aiColor: humanColor.opponent,
                                variantID: variant.id, aiLevel: aiLevel)
        var mover = TavliEngine.Color.white
        for _ in 0..<count {
            let d1 = Int(rng.next() % 6) + 1, d2 = Int(rng.next() % 6) + 1
            dice.set(d1, d2)
            let legal = variant.legalMoves(on: board, color: mover, dice: dice)
            var pairs: [[Int]] = []
            if !legal.isEmpty {
                let move = legal[Int(rng.next() % UInt64(legal.count))]
                pairs = move.halfMoves.map { [$0.from.position, $0.to.position] }
                variant.apply(move, on: board)
            }
            record.plies.append(PlyRecord(die1: d1, die2: d2, halfMoves: pairs))
            if variant.isOver(on: board) { break }
            mover = mover.opponent
        }
        record.outcome = humanColor.opponent
        return record
    }

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// Presents the sample review over the root view when `-debugReviewSample` is set.
private struct DebugReviewSampleModifier: ViewModifier {
    @State private var showing = DebugReviewSample.isRequested
    @State private var record = DebugReviewSample.record()

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $showing) {
            GameReviewView(record: record, agent: GameSession.makeAgent(),
                           humanColor: DebugReviewSample.humanColor)
        }
    }
}

extension View {
    /// DEBUG: open the seeded sample review when launched with `-debugReviewSample`.
    func debugReviewSample() -> some View { modifier(DebugReviewSampleModifier()) }
}
#endif
