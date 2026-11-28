import Foundation
import Combine

// The server lobby's logic (#287), app-independent so `swift test` covers it: the account's
// matches in sections (your turn → their turn → finished, the Game Center lobby's order),
// what each row says and offers (share the invite again, cancel, decline, remove), invites by
// link or typed code, a random opponent, and opening a match. The app's
// `ServerOnlineCoordinator` owns one per signed-in account and the views render it; all
// networking goes through `ServerMatchService` (`server/REFERENCE.md` "Invites, auto-match,
// lobby, push").

/// Invite codes as the server makes them: 6 characters without look-alikes.
public enum InviteCode {
    public static let alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    public static let length = 6

    /// A typed code, or a pasted invite link, as the server stores codes: upper case,
    /// spaces and dashes dropped; nil when it can't be a code. (Look-alikes are not in the
    /// alphabet, so a typed O / 0 / I / 1 simply finds nothing.)
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/"), let url = URL(string: trimmed), let code = fromLink(url) { return code }
        let code = trimmed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard (6...12).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return code
    }

    /// The code of an invite link `https://<server>/join/<code>` (a universal link).
    public static func fromLink(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "join" else { return nil }
        let code = parts[1].uppercased()
        guard (6...12).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return code
    }
}

/// The lobby's three groups, in display order.
public enum LobbySectionKind: String, CaseIterable, Sendable {
    case yourTurn, theirTurn, finished
}

public struct LobbySection: Equatable, Sendable {
    public var kind: LobbySectionKind
    public var rows: [ServerAPI.MatchSummary]
}

/// What a row tells the player.
public enum LobbyRowStatus: Equatable, Sendable {
    /// The local player moves (also: the creator of an open-seat match may start).
    case yourTurn
    /// Someone challenged the local player directly: open = accept.
    case invitedToYou
    case theirTurn
    /// The opponent has not accepted the direct challenge yet.
    case waitingForAccept
    /// The seat is open for whoever accepts the invite code.
    case waitingForFriend(code: String)
    /// Auto-match: the seat is open for a random opponent.
    case lookingForOpponent
    case finished(ServerAPI.MatchOutcome)
}

/// What a row offers (context menu / swipe).
public enum LobbyRowAction: String, CaseIterable, Sendable {
    case shareInvite, cancel, decline, remove
}

public extension ServerAPI.MatchSummary {
    /// The other seat is still empty (auto-match or an invite code), match running.
    var hasOpenSeat: Bool { opponent.playerID == nil && state != .ended }

    var lobbySection: LobbySectionKind {
        switch state {
        case .yourTurn, .invited: return .yourTurn
        case .theirTurn, .waitingForOpponent: return .theirTurn
        case .ended, .unknown: return .finished
        }
    }

    /// The row's main status line.
    var lobbyStatus: LobbyRowStatus {
        switch state {
        case .ended, .unknown: return .finished(outcome)
        case .invited: return .invitedToYou
        default: break
        }
        if hasOpenSeat {
            if let invite { return .waitingForFriend(code: invite.code) }
            if state == .yourTurn { return .yourTurn }
            return .lookingForOpponent
        }
        switch state {
        case .yourTurn: return .yourTurn
        case .waitingForOpponent: return .waitingForAccept
        default: return .theirTurn
        }
    }

    /// An open auto-match seat (no invite) while the creator may already play.
    var isLookingForOpponent: Bool { hasOpenSeat && invite == nil }

    var lobbyActions: [LobbyRowAction] {
        switch state {
        case .ended, .unknown: return [.remove]
        case .invited: return [.decline]
        default: break
        }
        if hasOpenSeat { return invite != nil ? [.shareInvite, .cancel] : [.cancel] }
        return []
    }
}

/// The account's lobby: list, sections, row actions, invites, auto-match, opening matches.
@MainActor
public final class ServerLobby: ObservableObject {
    /// The account's matches, newest first (as the server lists them).
    @Published public private(set) var matches: [ServerAPI.MatchSummary] = []
    /// The last lobby action failed (player copy from `describeError`).
    @Published public var error: String?
    @Published public private(set) var isWorking = false
    /// The list was loaded at least once (the view shows a spinner until then).
    @Published public private(set) var hasLoaded = false

    public let service: ServerMatchService
    public let controller: OnlineMatchController
    /// Player-facing text for a failure (the app localizes).
    public var describeError: (Error) -> String = { "\($0)" }
    /// A match was created or joined here (the app asks for push permission once).
    public var onMatchStarted: (() -> Void)?

    public init(service: ServerMatchService, controller: OnlineMatchController) {
        self.service = service
        self.controller = controller
    }

    /// Rows grouped your turn → their turn → finished; empty groups left out.
    public var sections: [LobbySection] { Self.sections(matches) }

    public static func sections(_ rows: [ServerAPI.MatchSummary]) -> [LobbySection] {
        LobbySectionKind.allCases.compactMap { kind in
            let inKind = rows.filter { $0.lobbySection == kind }
                .sorted { ($0.updatedAt, $0.matchID) > ($1.updatedAt, $1.matchID) }
            return inKind.isEmpty ? nil : LobbySection(kind: kind, rows: inKind)
        }
    }

    // MARK: List

    public func refresh() async {
        do {
            matches = try await service.listMatches().matches
            hasLoaded = true
        } catch {
            self.error = describeError(error)
        }
    }

    // MARK: Opening

    /// Open `snap` on this device (the controller accepts a pending challenge first) and
    /// keep its socket.
    public func open(_ snap: ServerAPI.MatchSnapshot) {
        controller.open(snap.onlineSnapshot, newMatchTargetWins: snap.targetWins, newMatchVariantID: snap.variant)
        service.watch(snap.matchID)
    }

    /// Load and open a match by id (lobby row, push notification). False when it failed.
    @discardableResult
    public func open(matchID: String) async -> Bool {
        error = nil
        do {
            open(try await service.loadSnapshot(matchID: matchID))
            return true
        } catch {
            self.error = describeError(error)
            return false
        }
    }

    // MARK: New matches

    /// A match with an open seat + its code/link to share. The match is not opened: the
    /// share sheet comes first, then `open(invite.match)` ("Start playing").
    public func createInvite(variant: String, targetWins: Int) async -> ServerAPI.Invite? {
        await working {
            let invite = try await service.createInvite(variant: variant, targetWins: targetWins)
            onMatchStarted?()
            await refresh()
            return invite
        }
    }

    /// A random opponent: joins someone's waiting match (opened at once) or waits in a new
    /// one, which is opened too (the creator may play first, as with Game Center).
    @discardableResult
    public func autoMatch(variant: String, targetWins: Int) async -> ServerAPI.MatchSnapshot? {
        await working {
            let snap = try await service.autoMatch(variant: variant, targetWins: targetWins)
            open(snap)
            onMatchStarted?()
            await refresh()
            return snap
        }
    }

    /// What a typed or linked code invites to (nil + `error` when it can't be used).
    public func preview(code raw: String) async -> ServerAPI.InvitePreview? {
        guard let code = InviteCode.normalize(raw) else {
            error = describeError(ServerLobbyError.malformedCode)
            return nil
        }
        return await working { try await service.previewInvite(code: code) }
    }

    /// Join by code (typed or from a link) and open the match.
    @discardableResult
    public func join(code raw: String) async -> ServerAPI.MatchSnapshot? {
        guard let code = InviteCode.normalize(raw) else {
            error = describeError(ServerLobbyError.malformedCode)
            return nil
        }
        return await working {
            let snap = try await service.acceptInvite(code: code)
            open(snap)
            onMatchStarted?()
            await refresh()
            return snap
        }
    }

    public func declineInvite(code raw: String) async {
        guard let code = InviteCode.normalize(raw) else { return }
        _ = await working { try await service.declineInvite(code: code) }
    }

    // MARK: Row actions

    /// Hide a finished match (optimistic: the row goes at once, back on failure).
    public func remove(_ row: ServerAPI.MatchSummary) async {
        guard row.lobbyActions.contains(.remove) else { return }
        let before = matches
        matches.removeAll { $0.matchID == row.matchID }
        do {
            try await service.removeMatch(matchID: row.matchID)
        } catch {
            matches = before
            self.error = describeError(error)
        }
    }

    /// Stop waiting: revoke the invite, or leave the auto-match queue (quit while the seat
    /// is open). The match ends and moves to Finished.
    public func cancel(_ row: ServerAPI.MatchSummary) async {
        guard row.lobbyActions.contains(.cancel) else { return }
        _ = await working {
            if let invite = row.invite {
                try await service.revokeInvite(code: invite.code)
            } else {
                try await service.cancelWaiting(matchID: row.matchID)
            }
        }
        await refresh()
    }

    /// Turn down a direct challenge.
    public func decline(_ row: ServerAPI.MatchSummary) async {
        guard row.lobbyActions.contains(.decline) else { return }
        _ = await working { try await service.decline(matchID: row.matchID) }
        await refresh()
    }

    // MARK: Helpers

    private func working<T>(_ body: () async throws -> T) async -> T? {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            return try await body()
        } catch {
            self.error = describeError(error)
            return nil
        }
    }
}

public enum ServerLobbyError: Error, Equatable {
    /// The typed text can't be an invite code.
    case malformedCode
}

/// Push notifications, app-independent parts (#287).
public enum PushSupport {
    /// An APNs device token as the server wants it: lower-case hex.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    /// The match a tapped notification opens (our server's payload only).
    public static func matchID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        ServerAPI.PushPayload(userInfo: userInfo)?.matchID
    }

    /// Ask for permission once, right after the player's first own match (created or
    /// joined) — when "your turn" pushes start to matter — and never before.
    public static func shouldAskPermission(isUndetermined: Bool, askedBefore: Bool) -> Bool {
        isUndetermined && !askedBefore
    }

    /// Show a push while the app is in front only when it is about another match than the
    /// one on screen (that one updates live).
    public static func shouldPresentInForeground(pushMatchID: String?, openMatchID: String?) -> Bool {
        guard let pushMatchID else { return true }
        return pushMatchID != openMatchID
    }

    /// #301: an incoming challenge's match (nil for every other push).
    public static func challengeMatchID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let p = ServerAPI.PushPayload(userInfo: userInfo), p.kind == .challengeReceived else { return nil }
        return p.matchID
    }

    /// #301: in front, an incoming challenge shows as the in-app card instead of a banner
    /// (when the app shows challenges); everything else as before.
    public static func shouldPresentInForeground(kind: ServerAPI.PushKind?, pushMatchID: String?, openMatchID: String?,
                                                 showsChallengesInApp: Bool) -> Bool {
        if kind == .challengeReceived { return !showsChallengesInApp }
        return shouldPresentInForeground(pushMatchID: pushMatchID, openMatchID: openMatchID)
    }

    /// #301: notification action identifiers of the CHALLENGE category.
    public static let acceptAction = "CHALLENGE_ACCEPT"
    public static let declineAction = "CHALLENGE_DECLINE"
}
