import Foundation
import Combine

// People, presence, one-tap challenges, handles (#301), app-independent so `swift test`
// covers it. The app's `ServerOnlineCoordinator` owns one `ServerPeople` + one
// `ServerPresenceConnection` per signed-in account; the views render them. Server behaviour:
// `server/REFERENCE.md` "People, presence, challenges" + "Handles and search".

// MARK: - Handles

/// The server's handle rule (3–20 of A–Z a–z 0–9 _, unique ignoring case, reserved words),
/// a suggestion from a display name, and search-query clean-up.
public enum HandleRule {
    public static let minLength = 3
    public static let maxLength = 20
    /// = the server's `RESERVED_HANDLES` (plus anything starting with "tavtav").
    public static let reserved: Set<String> = [
        "admin", "administrator", "anonymous", "api", "apple", "computer", "everyone", "google", "help",
        "me", "mod", "moderator", "nobody", "null", "official", "owner", "player", "root", "server",
        "staff", "support", "system", "tavli", "tavlo", "team", "undefined", "you",
    ]

    public enum Problem: Equatable, Sendable { case invalid, reserved }

    private static func isHandleCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_")
    }

    /// Why `handle` can't be anyone's (nil = fine as far as the rule goes; it may be taken).
    public static func problem(_ handle: String) -> Problem? {
        guard (minLength...maxLength).contains(handle.count), handle.allSatisfy(isHandleCharacter) else { return .invalid }
        let key = handle.lowercased()
        if reserved.contains(key) || key.hasPrefix("tavtav") { return .reserved }
        return nil
    }

    /// A handle from a display name: transliterated to Latin (Greek / Persian names give
    /// something readable), accents dropped, spaces / dashes / dots → `_`, the rest dropped,
    /// at most 20; nil when too little is left or it would be reserved.
    public static func suggest(from displayName: String) -> String? {
        let latin = displayName.applyingTransform(.toLatin, reverse: false) ?? displayName
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        var out = ""
        var lastUnderscore = false
        for c in plain {
            if c.isWhitespace || c == "-" || c == "." || c == "_" {
                if !out.isEmpty && !lastUnderscore { out.append("_"); lastUnderscore = true }
            } else if isHandleCharacter(c) {
                out.append(c)
                lastUnderscore = false
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        out = String(out.prefix(maxLength))
        while out.hasSuffix("_") { out.removeLast() }
        return problem(out) == nil ? out : nil
    }

    /// A search box's text as the server wants it (leading `@` dropped, lower case); nil
    /// while it can't be searched (fewer than 3 characters, or not handle characters).
    public static func searchQuery(_ raw: String) -> String? {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.hasPrefix("@") { q.removeFirst() }
        guard (ServerAPI.searchMinChars...maxLength).contains(q.count), q.allSatisfy(isHandleCharacter) else { return nil }
        return q.lowercased()
    }
}

// MARK: - Presence + row status

/// What a person's row says about them.
public enum PersonStatus: Equatable, Sendable {
    /// They challenged you: the row offers Accept.
    case wantsToPlay(matchID: String)
    /// You challenged them: waiting for the answer.
    case waitingForAnswer(matchID: String)
    case online
    case lastSeen(Date)
    /// Hidden, never seen, or not allowed to see.
    case none
}

public extension ServerAPI.Person {
    /// Online right now (green dot).
    var isOnline: Bool { presence?.online == true }

    func status(now: Date = Date()) -> PersonStatus {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        if let c = challenge, c.expiresAt > nowMillis {
            return c.direction == .incoming ? .wantsToPlay(matchID: c.matchID) : .waitingForAnswer(matchID: c.matchID)
        }
        guard let p = presence else { return .none }
        if p.online { return .online }
        if let seen = p.lastSeenAt { return .lastSeen(ServerAPI.date(seen)) }
        return .none
    }

    /// Pinned first, then the newest game (never played last), then by name.
    static func listOrder(_ a: Self, _ b: Self) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        if (a.lastPlayedAt ?? -1) != (b.lastPlayedAt ?? -1) { return (a.lastPlayedAt ?? -1) > (b.lastPlayedAt ?? -1) }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }
}

// MARK: - Challenges as the app shows them

/// A challenge to the local player that waits for an answer (the incoming-challenge card).
public struct IncomingChallenge: Identifiable, Equatable, Sendable {
    public var matchID: String
    public var fromID: String?
    public var fromName: String
    public var variant: String
    public var targetWins: Int
    public var expiresAt: Int64
    public var id: String { matchID }

    public init(matchID: String, fromID: String?, fromName: String, variant: String, targetWins: Int, expiresAt: Int64) {
        self.matchID = matchID
        self.fromID = fromID
        self.fromName = fromName
        self.variant = variant
        self.targetWins = targetWins
        self.expiresAt = expiresAt
    }
}

/// The local player's challenge the challenge sheet waits on ("Waiting for Alex…").
public struct OutgoingChallenge: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case sending, waiting, accepted, declined, expired, cancelled
        /// The server refused it (player copy).
        case failed(String)
    }
    public var matchID: String?
    public var playerID: String
    public var name: String
    public var variant: String
    public var targetWins: Int
    public var state: State
}

/// The variant + length a challenge used last time (the sheet starts from it).
public struct ChallengeChoice: Equatable, Sendable {
    public var variant: String
    public var targetWins: Int
    public static let variantKey = "people.lastChallengeVariant"
    public static let lengthKey = "people.lastChallengeLength"

    public init(variant: String, targetWins: Int) {
        self.variant = variant
        self.targetWins = targetWins
    }

    public static func load(from defaults: UserDefaults, fallback: ChallengeChoice) -> ChallengeChoice {
        let variant = defaults.string(forKey: variantKey) ?? fallback.variant
        let length = defaults.integer(forKey: lengthKey)
        return ChallengeChoice(variant: GameVariantRegistry.isKnown(variant) ? variant : fallback.variant,
                               targetWins: (1...2).contains(length) ? length : fallback.targetWins)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(variant, forKey: Self.variantKey)
        defaults.set(targetWins, forKey: Self.lengthKey)
    }
}

enum GameVariantRegistry {
    static func isKnown(_ id: String) -> Bool { ["plakoto", "plakoto_standard", "fevga", "portes"].contains(id) }
}

// MARK: - Presence socket

/// The foreground app's one socket to the presence hub (`GET /v1/presence/socket`): it is
/// what makes the player "online" for their people, and it brings presence changes and
/// challenge events live. **Only while the app is in front** (`start` on becoming active,
/// `stop` on going to the background) — no background keep-alive; ping every 30 s (the
/// socket factory), answered by the server runtime without waking anything.
@MainActor
public final class ServerPresenceConnection {
    public var onMessage: (@MainActor (ServerAPI.PresenceMessage) -> Void)?
    public var reconnectBase: TimeInterval = 1
    public var reconnectMax: TimeInterval = 60
    public private(set) var isConnected = false
    public private(set) var isRunning = false

    private let service: ServerMatchService
    private let sockets: ServerSocketFactory?
    private var socket: ServerSocket?
    private var generation = 0
    private var attempts = 0
    private var reconnectTask: Task<Void, Never>?

    public init(service: ServerMatchService, sockets: ServerSocketFactory?) {
        self.service = service
        self.sockets = sockets
    }

    /// The app is in front: connect (no-op while already running).
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        attempts = 0
        connect()
    }

    /// The app went to the background (or signed out): close at once.
    public func stop() {
        isRunning = false
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.close()
        socket = nil
        isConnected = false
    }

    private func connect() {
        guard isRunning, let sockets else { return }
        generation += 1
        let gen = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let request = try? await self.service.presenceSocketRequest()
            guard gen == self.generation, self.isRunning else { return }
            guard let request else { self.scheduleReconnect(gen); return }
            self.socket = sockets.open(request, onText: { [weak self] text in
                self?.handle(text, gen)
            }, onClose: { [weak self] code in
                self?.closed(code, gen)
            })
        }
    }

    private func handle(_ text: String, _ gen: Int) {
        guard gen == generation,
              let message = try? ServerAPI.decoder().decode(ServerAPI.PresenceMessage.self, from: Data(text.utf8)) else { return }
        if case .hello = message {
            isConnected = true
            attempts = 0
        }
        onMessage?(message)
    }

    private func closed(_ code: Int?, _ gen: Int) {
        guard gen == generation else { return }
        socket = nil
        isConnected = false
        if code == 4403 { return }   // account deleted / refused
        scheduleReconnect(gen, immediately: code == 4401)
    }

    private func scheduleReconnect(_ gen: Int, immediately: Bool = false) {
        guard isRunning, gen == generation else { return }
        let delay = immediately ? 0 : min(reconnectMax, reconnectBase * pow(2, Double(attempts)))
        attempts += 1
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
}

// MARK: - People

/// The account's people (played with or added by handle): presence, pin / remove / block,
/// search by handle, one-tap challenges (sending + waiting, incoming cards, accept /
/// decline), live updates from the presence socket.
@MainActor
public final class ServerPeople: ObservableObject {
    /// Pinned first, then the newest game.
    @Published public private(set) var people: [ServerAPI.Person] = []
    /// Whom the local player blocked (the account page lists them to unblock).
    @Published public private(set) var blocked: [ServerAPI.PlayerCard] = []
    @Published public private(set) var hasLoaded = false
    @Published public var error: String?
    /// Challenges to the local player that wait for an answer, newest first.
    @Published public private(set) var incoming: [IncomingChallenge] = []
    /// The challenge the sheet waits on.
    @Published public private(set) var waiting: OutgoingChallenge?
    @Published public private(set) var searchResults: [ServerAPI.PlayerResult] = []
    @Published public private(set) var isSearching = false

    public let service: ServerMatchService
    public let lobby: ServerLobby
    public var describeError: (Error) -> String = { "\($0)" }
    /// The local player's challenge was accepted (the app opens the match, or offers to).
    public var onAccepted: (@MainActor (OutgoingChallenge) -> Void)?
    /// A new challenge arrived live (the app shows the card).
    public var onIncoming: (@MainActor (IncomingChallenge) -> Void)?
    public var now: () -> Date = Date.init

    /// Incoming challenges by match, from every source (socket, people list, lobby rows).
    private var known: [String: IncomingChallenge] = [:]
    /// Answered / closed / put aside here: never shown again.
    private var closed: Set<String> = []
    private var dismissed: Set<String> = []
    private var searchGeneration = 0

    public init(service: ServerMatchService, lobby: ServerLobby) {
        self.service = service
        self.lobby = lobby
    }

    private var nowMillis: Int64 { Int64(now().timeIntervalSince1970 * 1000) }

    // MARK: List

    /// Reloads the people list (and picks up pending challenges to the local player from it
    /// and from the lobby's rows — a stranger's challenge is only there).
    public func refresh() async {
        do {
            let answer = try await service.listPeople()
            people = answer.people.sorted(by: ServerAPI.Person.listOrder)
            blocked = answer.blocked ?? []
            hasLoaded = true
            for p in answer.people {
                guard let c = p.challenge, c.direction == .incoming else { continue }
                learn(IncomingChallenge(matchID: c.matchID, fromID: p.playerID, fromName: p.displayName,
                                        variant: c.variant, targetWins: c.targetWins, expiresAt: c.expiresAt))
            }
            syncWithLobby()
        } catch {
            self.error = describeError(error)
        }
    }

    /// Pending challenges from the lobby's rows; rows answered elsewhere close their card.
    public func syncWithLobby() {
        for row in lobby.matches {
            if row.state == .invited, let c = row.challenge, c.status == .pending {
                learn(IncomingChallenge(matchID: row.matchID, fromID: row.opponent.playerID,
                                        fromName: row.opponent.displayName ?? "?", variant: row.variant,
                                        targetWins: row.targetWins, expiresAt: c.expiresAt))
            } else if known[row.matchID] != nil {
                close(row.matchID)
            }
        }
        publishIncoming()
    }

    public func person(_ playerID: String) -> ServerAPI.Person? { people.first { $0.playerID == playerID } }

    // MARK: Pin, remove, block

    /// ⭐ (optimistic). Pinning someone found by handle adds them to the list (reloaded).
    public func setPinned(_ pinned: Bool, playerID: String) async {
        let before = people
        if let i = people.firstIndex(where: { $0.playerID == playerID }) {
            people[i].pinned = pinned
            people.sort(by: ServerAPI.Person.listOrder)
        }
        do {
            try await service.setPinned(pinned, playerID: playerID)
            if let i = searchResults.firstIndex(where: { $0.playerID == playerID }), pinned { searchResults[i].isPerson = true }
            if before.first(where: { $0.playerID == playerID }) == nil { await refresh() }
        } catch {
            people = before
            self.error = describeError(error)
        }
    }

    /// Off the list until the next game (optimistic).
    public func remove(playerID: String) async {
        let before = people
        people.removeAll { $0.playerID == playerID }
        do {
            try await service.removePerson(playerID: playerID)
        } catch {
            people = before
            self.error = describeError(error)
        }
    }

    /// They can't challenge you, find you or see your status; their pending challenges to
    /// you are declined (no notification for them).
    public func block(playerID: String) async {
        let before = people
        people.removeAll { $0.playerID == playerID }
        for c in known.values where c.fromID == playerID { close(c.matchID) }
        publishIncoming()
        searchResults.removeAll { $0.playerID == playerID }
        do {
            try await service.setBlocked(true, playerID: playerID)
            await refresh()
        } catch {
            people = before
            self.error = describeError(error)
        }
    }

    public func unblock(playerID: String) async {
        do {
            try await service.setBlocked(false, playerID: playerID)
            blocked.removeAll { $0.playerID == playerID }
            await refresh()
        } catch {
            self.error = describeError(error)
        }
    }

    // MARK: Search

    /// Prefix search on handles (nothing is sent for < 3 characters; a later query wins).
    public func search(_ raw: String) async {
        searchGeneration += 1
        let gen = searchGeneration
        guard let q = HandleRule.searchQuery(raw) else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        defer { if gen == searchGeneration { isSearching = false } }
        do {
            let found = try await service.searchPlayers(q)
            if gen == searchGeneration { searchResults = found }
        } catch {
            if gen == searchGeneration { self.error = describeError(error) }
        }
    }

    public func clearSearch() {
        searchGeneration += 1
        searchResults = []
        isSearching = false
    }

    // MARK: Challenging

    /// One tap: challenge `playerID` to `variant` / `targetWins`; `waiting` follows it. When
    /// they had just challenged the local player to the same game, the server accepts that
    /// one instead and the match opens at once.
    @discardableResult
    public func challenge(playerID: String, name: String, variant: String, targetWins: Int) async -> Bool {
        error = nil
        waiting = OutgoingChallenge(matchID: nil, playerID: playerID, name: name, variant: variant,
                                    targetWins: targetWins, state: .sending)
        do {
            let snap = try await service.createMatch(variant: variant, targetWins: targetWins, opponentID: playerID)
            lobby.onMatchStarted?()
            waiting?.matchID = snap.matchID
            if !snap.isEnded, snap.participants.allSatisfy({ $0.status == .active }) {
                // Crossed taps: their challenge to the same game was accepted.
                close(snap.matchID)
                publishIncoming()
                waiting?.state = .accepted
                if let w = waiting { onAccepted?(w) }
            } else {
                waiting?.state = .waiting
            }
            setChallenge(on: playerID, matchID: snap.matchID, variant: variant, targetWins: targetWins)
            await lobby.refresh()
            return true
        } catch {
            waiting?.state = .failed(describeError(error))
            return false
        }
    }

    /// Take the waiting challenge back.
    public func cancelWaiting() async {
        guard let w = waiting, let id = w.matchID else { waiting = nil; return }
        do {
            try await service.cancelChallenge(matchID: id)
            waiting?.state = .cancelled
            clearChallenge(on: w.playerID)
            waiting = nil
        } catch {
            // Answered meanwhile (accepted): the reload shows the match.
            self.error = describeError(error)
        }
        await lobby.refresh()
    }

    /// The sheet closed: stop following (the challenge itself stays pending).
    public func clearWaiting() { waiting = nil }

    /// Opens the accepted challenge's match (the challenger's side) and clears `waiting`.
    @discardableResult
    public func openAccepted() async -> Bool {
        guard let w = waiting, w.state == .accepted, let id = w.matchID else { return false }
        waiting = nil
        return await lobby.open(matchID: id)
    }

    // MARK: Answering

    /// Accept: the match opens (the controller accepts the seat first).
    @discardableResult
    public func accept(_ challenge: IncomingChallenge) async -> Bool {
        close(challenge.matchID)
        publishIncoming()
        let opened = await lobby.open(matchID: challenge.matchID)
        if !opened { error = lobby.error }
        await refresh()
        return opened
    }

    public func decline(_ challenge: IncomingChallenge) async {
        close(challenge.matchID)
        publishIncoming()
        do {
            try await service.decline(matchID: challenge.matchID)
        } catch {
            self.error = describeError(error)
        }
        await lobby.refresh()
        await refresh()
    }

    /// Put the card aside (the challenge stays pending in the people list / lobby).
    public func dismiss(_ challenge: IncomingChallenge) {
        dismissed.insert(challenge.matchID)
        publishIncoming()
    }

    // MARK: Live events

    public func handle(_ message: ServerAPI.PresenceMessage) {
        switch message {
        case .presence(let playerID, let presence):
            if let i = people.firstIndex(where: { $0.playerID == playerID }) { people[i].presence = presence }
        case .challenge(let event, let c):
            handleChallenge(ServerAPI.ChallengeEvent(rawValue: event), c)
        case .hello:
            // (Re)connected: whatever happened meanwhile.
            Task { await self.refresh() }
        case .error, .unknown:
            break
        }
    }

    private func handleChallenge(_ event: ServerAPI.ChallengeEvent?, _ c: ServerAPI.Challenge) {
        let mine = c.from.playerID == service.localPlayerID
        switch event {
        case .received where !mine:
            let card = IncomingChallenge(matchID: c.matchID, fromID: c.from.playerID, fromName: c.from.displayName,
                                         variant: c.variant, targetWins: c.targetWins, expiresAt: c.expiresAt)
            let isNew = known[c.matchID] == nil && !closed.contains(c.matchID)
            learn(card)
            publishIncoming()
            setChallenge(on: c.from.playerID, matchID: c.matchID, variant: c.variant, targetWins: c.targetWins, incoming: true)
            if isNew { onIncoming?(card) }
        case .accepted where mine:
            clearChallenge(on: c.to.playerID)
            if waiting?.matchID == c.matchID {
                waiting?.state = .accepted
                if let w = waiting { onAccepted?(w) }
            } else {
                onAccepted?(OutgoingChallenge(matchID: c.matchID, playerID: c.to.playerID, name: c.to.displayName,
                                              variant: c.variant, targetWins: c.targetWins, state: .accepted))
            }
        case .declined where mine, .expired where mine, .cancelled where mine:
            clearChallenge(on: c.to.playerID)
            if waiting?.matchID == c.matchID {
                waiting?.state = event == .declined ? .declined : event == .expired ? .expired : .cancelled
            }
        case .expired, .cancelled, .declined, .accepted:
            // To me: the card goes.
            close(c.matchID)
            publishIncoming()
            clearChallenge(on: c.from.playerID)
        default:
            break
        }
        Task { await self.lobby.refresh() }
    }

    // MARK: Helpers

    private func learn(_ card: IncomingChallenge) {
        guard !closed.contains(card.matchID) else { return }
        known[card.matchID] = card
    }

    private func close(_ matchID: String) {
        closed.insert(matchID)
        known[matchID] = nil
    }

    private func publishIncoming() {
        let nowMillis = self.nowMillis
        incoming = known.values
            .filter { !dismissed.contains($0.matchID) && $0.expiresAt > nowMillis }
            .sorted { ($0.expiresAt, $0.matchID) > ($1.expiresAt, $1.matchID) }
    }

    private func setChallenge(on playerID: String, matchID: String, variant: String, targetWins: Int, incoming: Bool = false) {
        guard let i = people.firstIndex(where: { $0.playerID == playerID }) else { return }
        people[i].challenge = ServerAPI.PersonChallenge(
            matchID: matchID, direction: incoming ? .incoming : .outgoing, variant: variant, targetWins: targetWins,
            expiresAt: nowMillis + 24 * 3_600_000)
    }

    private func clearChallenge(on playerID: String) {
        guard let i = people.firstIndex(where: { $0.playerID == playerID }) else { return }
        people[i].challenge = nil
    }
}
