#if DEBUG
import SwiftUI
import TavliEngine

/// DEBUG-only shortcut into an online game with the shared weighted dice (#272), for
/// checking the tag and the card without Game Center or a second device. Launch with
/// `-debugOnlineDice`: a full-screen online `GameView` over an in-memory one-device match
/// (you = White, on turn, opponent "Eleni"). `-debugOnlineDiceLevel N` sets the dice
/// first (−4…4 from your side: positive favours you), `-debugOnlineDiceCard` opens the
/// card over the game. Nothing is saved or sent. Compiled out of release builds.
enum DebugOnlineDice {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-debugOnlineDice") }
    static var opensCard: Bool { ProcessInfo.processInfo.arguments.contains("-debugOnlineDiceCard") }

    /// `-debugOnlineDiceVariant portes` (any registry id); house Plakoto otherwise (its
    /// model is the one always bundled).
    static var variantID: String {
        UserDefaults.standard.string(forKey: "debugOnlineDiceVariant") ?? GameVariants.defaultID
    }

    /// The value after `-debugOnlineDiceLevel` (read from the raw arguments, so "-2" works).
    static var level: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-debugOnlineDiceLevel"), i + 1 < args.count else { return 0 }
        return Int(args[i + 1]) ?? 0
    }
}

/// An in-memory turn-based service: one match, every write succeeds.
@MainActor
private final class DebugOnlineService: OnlineMatchService {
    let localPlayerID = "debug-you"
    private var data: Data?
    private var current: String? = "debug-you"

    var snapshot: OnlineMatchSnapshot {
        OnlineMatchSnapshot(matchID: "debug-match", data: data,
                            participants: [OnlineParticipant(playerID: localPlayerID, displayName: "You"),
                                           OnlineParticipant(playerID: "debug-eleni", displayName: "Eleni")],
                            currentPlayerID: current, isEnded: false)
    }

    func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        self.data = data
        current = "debug-eleni"
        completion(nil)
    }
    func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        self.data = data
        completion(nil)
    }
    func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion) {
        self.data = data
        completion(nil)
    }
    func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion) {
        completion(nil)
    }
    func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        completion(snapshot, nil)
    }
    func load(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        completion(snapshot, nil)
    }
}

@MainActor
private final class DebugOnlineMatch: ObservableObject {
    let service = DebugOnlineService()
    let controller: OnlineMatchController

    init() {
        controller = OnlineMatchController(service: service, liveTurns: nil,
                                           handicapAgent: { GameSession.makeAgent(config: $0) })
        controller.open(service.snapshot, newMatchTargetWins: 2,
                        newMatchVariantID: DebugOnlineDice.variantID)
        controller.setDiceHandicap(levelTowardsMe: DebugOnlineDice.level)
    }
}

private struct DebugOnlineDiceScreen: View {
    @StateObject private var match = DebugOnlineMatch()
    @State private var showCard = DebugOnlineDice.opensCard
    let onClose: () -> Void

    var body: some View {
        if let session = match.controller.session {
            DebugOnlineGame(controller: match.controller, session: session, onClose: onClose)
                .sheet(isPresented: $showCard) {
                    OnlineDiceSheet(controller: match.controller, opponentName: "Eleni")
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        } else {
            Button(action: onClose) {
                Text(verbatim: "No online session (\(String(describing: match.controller.status)))")
            }
        }
    }
}

private struct DebugOnlineGame: View {
    @ObservedObject var controller: OnlineMatchController
    @ObservedObject var session: GameSession
    let onClose: () -> Void

    var body: some View {
        GameView(session: session, humanColor: controller.localColor, onBack: onClose,
                 online: GameView.Online(localColor: controller.localColor,
                                         isLocalTurn: controller.isLocalTurn,
                                         isMatchOver: controller.isMatchOver,
                                         opponentName: "Eleni", banner: nil,
                                         onBack: onClose, onLeave: onClose,
                                         controller: controller),
                 match: controller.matchState.isMatch
                    ? GameView.Match(state: controller.matchState, localColor: controller.localColor,
                                     opponentName: "Eleni", lastGameResult: nil,
                                     showResultOverlay: false, onNextGame: {}, onRematch: nil,
                                     onExit: onClose)
                    : nil)
    }
}

private struct DebugOnlineDiceModifier: ViewModifier {
    @State private var show = DebugOnlineDice.isRequested

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $show) {
            DebugOnlineDiceScreen { show = false }
        }
    }
}

extension View {
    /// DEBUG: open the online shared-dice check scene with `-debugOnlineDice` (#272).
    func debugOnlineDice() -> some View { modifier(DebugOnlineDiceModifier()) }
}
#endif
