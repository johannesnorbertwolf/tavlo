import Foundation

// Online play through our own server (#286, epic #278): `ServerMatchService` implements the
// controller's `OnlineMatchService` seam (and `OnlineServerDiceService`: the server draws
// every roll and holds the shared slider) over HTTPS — the Server v1 contract in
// `server/REFERENCE.md`, bodies in `ServerAPI` — plus one WebSocket for the open match that
// pushes the opponent's turns, rolls and slider changes. Writes name the revision they
// build on (`baseRevision`, tracked here per match); a stale one is reloaded and resent once
// when that is safe. The socket reconnects with backoff; while it is down the controller's
// fallback poll (`LiveTurnTiming`) takes over. Seams: `ServerMatchClient` (the app's
// `AuthClient`) and `ServerSocketFactory` (`URLSessionSocketFactory`), faked in tests.

// MARK: - Seams

/// The authorized HTTP the match service needs: the app's `AuthClient` (bearer token,
/// refresh, sign-out on a refused session), a fake in tests.
@MainActor
public protocol ServerMatchClient: AnyObject {
    var baseURL: URL { get }
    var clientHeader: String { get }
    /// The signed-in account id (= the player id in matches), nil when signed out.
    var signedInAccountID: String? { get }
    func authorized<B: Encodable, R: Decodable>(method: String, path: String, body: B?,
                                                allowRefresh: Bool) async throws -> R
    /// A current access token (for the socket's upgrade request).
    func accessToken() async throws -> String
}

extension AuthClient: ServerMatchClient {
    public var signedInAccountID: String? { account?.id }
}

/// An open WebSocket.
@MainActor
public protocol ServerSocket: AnyObject {
    func close()
}

/// Opens the match socket; `URLSessionSocketFactory` in the app, a fake in tests.
@MainActor
public protocol ServerSocketFactory: AnyObject {
    /// `onText` gets every text message; `onClose` once, with the close code (nil = the
    /// connection failed or dropped without one).
    func open(_ request: URLRequest, onText: @escaping @MainActor (String) -> Void,
              onClose: @escaping @MainActor (Int?) -> Void) -> ServerSocket
}

/// `URLSessionWebSocketTask`, with the contract's keepalive (`{"type":"ping"}`, answered by
/// the server runtime without waking the match room).
@MainActor
public final class URLSessionSocketFactory: ServerSocketFactory {
    private let session: URLSession
    private let pingInterval: TimeInterval

    public init(session: URLSession = .shared, pingInterval: TimeInterval = 30) {
        self.session = session
        self.pingInterval = pingInterval
    }

    public func open(_ request: URLRequest, onText: @escaping @MainActor (String) -> Void,
                     onClose: @escaping @MainActor (Int?) -> Void) -> ServerSocket {
        let socket = URLSessionServerSocket(task: session.webSocketTask(with: request), onText: onText,
                                            onClose: onClose, pingInterval: pingInterval)
        socket.start()
        return socket
    }
}

@MainActor
private final class URLSessionServerSocket: ServerSocket {
    private let task: URLSessionWebSocketTask
    private let onText: @MainActor (String) -> Void
    private let onClose: @MainActor (Int?) -> Void
    private let pingInterval: TimeInterval
    private var pingTask: Task<Void, Never>?
    private var closed = false

    init(task: URLSessionWebSocketTask, onText: @escaping @MainActor (String) -> Void,
         onClose: @escaping @MainActor (Int?) -> Void, pingInterval: TimeInterval) {
        self.task = task
        self.onText = onText
        self.onClose = onClose
        self.pingInterval = pingInterval
    }

    func start() {
        task.resume()
        receive()
        let interval = pingInterval
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.task.send(.string(ServerAPI.wsPing)) { _ in }
            }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .success(.string(let text)):
                    self.onText(text)
                    self.receive()
                case .success(.data(let data)):
                    self.onText(String(decoding: data, as: UTF8.self))
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    let code = self.task.closeCode.rawValue
                    self.finish(code == 0 ? nil : code)
                }
            }
        }
    }

    private func finish(_ code: Int?) {
        guard !closed else { return }
        closed = true
        pingTask?.cancel()
        onClose(code)
    }

    func close() {
        guard !closed else { return }
        closed = true
        pingTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Errors

/// A failed server call, as the controller shows it (`OnlineMatchStatus.error`).
public struct ServerMatchError: Error, LocalizedError, Equatable {
    /// The contract's error code (`ServerAPI.ErrorCode` raw value), nil for no answer.
    public let code: String?
    public let status: Int?
    public let message: String
    public var errorDescription: String? { message }
}

// MARK: - Service

@MainActor
public final class ServerMatchService: OnlineServerDiceService {
    /// Gets the open match's events (snapshots via `receive`, requests via `receiveRequest`).
    public weak var controller: OnlineMatchController?
    /// Every newer snapshot this service learns of from the server (lobby refresh).
    public var onMatchChanged: (@MainActor (ServerAPI.MatchSnapshot) -> Void)?
    /// Player-facing text for an error (the app localizes; tests keep the default).
    public var describeError: (Error) -> String = { "\($0)" }
    /// Socket reconnect backoff: `reconnectBase` seconds doubling up to `reconnectMax`.
    public var reconnectBase: TimeInterval = 1
    public var reconnectMax: TimeInterval = 60

    /// The open match's socket is connected (said hello).
    public private(set) var isSocketConnected = false
    public var deliversEventsLive: Bool { isSocketConnected }
    public var localPlayerID: String { client.signedInAccountID ?? "" }

    private let client: ServerMatchClient
    private let sockets: ServerSocketFactory?
    /// The newest snapshot seen per match (its revision is the next write's base).
    private var cache: [String: ServerAPI.MatchSnapshot] = [:]
    private var watchedMatchID: String?
    private var socket: ServerSocket?
    private var socketGeneration = 0
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    /// Writes on their way per match; socket events wait for them (see `deliver`).
    private var writesInFlight: [String: Int] = [:]
    private var heldEvents: [String: ServerAPI.MatchSnapshot] = [:]

    public init(client: ServerMatchClient, sockets: ServerSocketFactory? = nil) {
        self.client = client
        self.sockets = sockets
    }

    /// The newest known snapshot of a match.
    public func snapshot(for matchID: String) -> ServerAPI.MatchSnapshot? { cache[matchID] }

    // MARK: Lobby

    /// `GET /v1/matches` (newest first; `state` "active" / "ended" / nil = all).
    public func listMatches(state: String? = nil, cursor: String? = nil) async throws -> ServerAPI.MatchList {
        var query: [String] = []
        if let state { query.append("state=\(state)") }
        if let cursor, let c = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query.append("cursor=\(c)")
        }
        let path = "/v1/matches" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        return try await call("GET", path, body: Optional<Int>.none)
    }

    /// `POST /v1/matches`: a direct challenge of `opponentID` (or an open seat).
    public func createMatch(variant: String, targetWins: Int, opponentID: String?) async throws -> ServerAPI.MatchSnapshot {
        let snap: ServerAPI.MatchSnapshot = try await call(
            "POST", "/v1/matches",
            body: ServerAPI.CreateMatchRequest(variant: variant, targetWins: targetWins, opponentID: opponentID))
        store(snap)
        return snap
    }

    /// `GET /v1/matches/{id}`, cached.
    public func loadSnapshot(matchID: String) async throws -> ServerAPI.MatchSnapshot {
        let snap = try await fetch(matchID)
        store(snap)
        return snap
    }

    /// `POST /v1/matches/{id}/decline`.
    public func decline(matchID: String) async throws {
        let _: Empty? = try await call("POST", path(matchID, "decline"), body: Optional<Int>.none)
    }

    // MARK: Lobby, invites, auto-match, push (#287)

    /// `DELETE /v1/matches/{id}`: hide an ended match from the lobby.
    public func removeMatch(matchID: String) async throws {
        let _: Empty? = try await call("DELETE", path(matchID), body: Optional<Int>.none)
    }

    /// Stop waiting in a match whose seat is still open (auto-match): quit out of turn.
    public func cancelWaiting(matchID: String) async throws {
        let snap: ServerAPI.MatchSnapshot = try await call("POST", path(matchID, "quit"),
                                                           body: ServerAPI.QuitRequest(inTurn: false))
        store(snap)
    }

    /// `POST /v1/invites`: a new match with an open seat + its code and link.
    public func createInvite(variant: String, targetWins: Int) async throws -> ServerAPI.Invite {
        let invite: ServerAPI.Invite = try await call(
            "POST", "/v1/invites", body: ServerAPI.CreateInviteRequest(variant: variant, targetWins: targetWins))
        store(invite.match)
        return invite
    }

    /// `GET /v1/invites/{code}`.
    public func previewInvite(code: String) async throws -> ServerAPI.InvitePreview {
        try await call("GET", invitePath(code), body: Optional<Int>.none)
    }

    /// `POST /v1/invites/{code}/accept`: join the invite's match.
    public func acceptInvite(code: String) async throws -> ServerAPI.MatchSnapshot {
        let snap: ServerAPI.MatchSnapshot = try await call("POST", invitePath(code, "accept"), body: Optional<Int>.none)
        store(snap)
        return snap
    }

    /// `POST /v1/invites/{code}/decline`.
    public func declineInvite(code: String) async throws {
        let _: Empty? = try await call("POST", invitePath(code, "decline"), body: Optional<Int>.none)
    }

    /// `DELETE /v1/invites/{code}`: the creator takes its invite back (the match ends).
    public func revokeInvite(code: String) async throws {
        let _: Empty? = try await call("DELETE", invitePath(code), body: Optional<Int>.none)
    }

    /// `POST /v1/automatch`: join someone's waiting match or wait in a new one.
    public func autoMatch(variant: String, targetWins: Int) async throws -> ServerAPI.MatchSnapshot {
        let snap: ServerAPI.MatchSnapshot = try await call(
            "POST", "/v1/automatch", body: ServerAPI.AutoMatchRequest(variant: variant, targetWins: targetWins))
        store(snap)
        return snap
    }

    /// `PUT /v1/push-tokens`.
    public func registerPushToken(_ token: String, environment: String, locale: String?) async throws {
        let _: Empty? = try await call("PUT", "/v1/push-tokens",
                                       body: ServerAPI.PushTokenRequest(token: token, environment: environment, locale: locale))
    }

    /// `DELETE /v1/push-tokens/{token}`.
    public func unregisterPushToken(_ token: String) async throws {
        let _: Empty? = try await call("DELETE", "/v1/push-tokens/\(token)", body: Optional<Int>.none)
    }

    // MARK: People, presence, challenges, handles (#301)

    /// `GET /v1/people`.
    public func listPeople() async throws -> ServerAPI.PeopleResponse {
        try await call("GET", "/v1/people", body: Optional<Int>.none)
    }

    /// `PATCH /v1/people/{id}` (⭐; pinning someone found by handle adds them).
    public func setPinned(_ pinned: Bool, playerID: String) async throws {
        let _: Empty? = try await call("PATCH", peoplePath(playerID), body: ServerAPI.UpdatePersonRequest(pinned: pinned))
    }

    /// `DELETE /v1/people/{id}`: off the list until the next game.
    public func removePerson(playerID: String) async throws {
        let _: Empty? = try await call("DELETE", peoplePath(playerID), body: Optional<Int>.none)
    }

    /// `POST /v1/people/{id}/block` / `DELETE …/block`.
    public func setBlocked(_ blocked: Bool, playerID: String) async throws {
        let _: Empty? = try await call(blocked ? "POST" : "DELETE", peoplePath(playerID) + "/block",
                                       body: Optional<Int>.none)
    }

    /// `GET /v1/players?q=` (≥ 3 characters of a handle).
    public func searchPlayers(_ query: String) async throws -> [ServerAPI.PlayerResult] {
        let q = query.addingPercentEncoding(withAllowedCharacters: Self.idCharacters) ?? query
        let answer: ServerAPI.PlayerSearchResponse = try await call("GET", "/v1/players?q=\(q)", body: Optional<Int>.none)
        return answer.players
    }

    /// `GET /v1/handles/{handle}`.
    public func checkHandle(_ handle: String) async throws -> ServerAPI.HandleAvailability {
        let h = handle.addingPercentEncoding(withAllowedCharacters: Self.idCharacters) ?? handle
        return try await call("GET", "/v1/handles/\(h)", body: Optional<Int>.none)
    }

    /// `POST /v1/matches/{id}/cancel`: the challenger takes a pending challenge back.
    public func cancelChallenge(matchID: String) async throws {
        let _: Empty? = try await call("POST", path(matchID, "cancel"), body: Optional<Int>.none)
    }

    /// The presence socket's upgrade request (`GET /v1/presence/socket`).
    public func presenceSocketRequest() async throws -> URLRequest {
        let token = try await client.accessToken()
        var c = URLComponents(url: client.baseURL.appendingPathComponent("v1/presence/socket"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: c.url!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(client.clientHeader, forHTTPHeaderField: ServerAPI.clientHeader)
        return request
    }

    private func peoplePath(_ playerID: String) -> String {
        "/v1/people/" + (playerID.addingPercentEncoding(withAllowedCharacters: Self.idCharacters) ?? playerID)
    }

    /// Ids, handles and queries go into paths as is; anything else is percent-encoded.
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

    private func invitePath(_ code: String, _ action: String? = nil) -> String {
        let c = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code
        return "/v1/invites/\(c)" + (action.map { "/\($0)" } ?? "")
    }

    // MARK: Socket

    /// Keep a socket open for `matchID` (the match on screen), or none (`nil`).
    public func watch(_ matchID: String?) {
        if matchID == watchedMatchID {
            if matchID != nil, socket == nil, reconnectTask == nil { connectSocket() }
            return
        }
        disconnect()
        watchedMatchID = matchID
        reconnectAttempts = 0
        if matchID != nil { connectSocket() }
    }

    /// Reconnect now if the socket is down (the app came back to the foreground).
    public func reconnectNow() {
        guard watchedMatchID != nil, socket == nil || !isSocketConnected else { return }
        disconnect(keepWatching: true)
        reconnectAttempts = 0
        connectSocket()
    }

    /// Stop watching and close the socket.
    public func close() {
        watch(nil)
    }

    private func disconnect(keepWatching: Bool = false) {
        socketGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        socket?.close()
        socket = nil
        isSocketConnected = false
        if !keepWatching { watchedMatchID = nil }
    }

    private func connectSocket() {
        guard let id = watchedMatchID, let sockets else { return }
        socketGeneration += 1
        let generation = socketGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let token = try? await self.client.accessToken()
            guard generation == self.socketGeneration, self.watchedMatchID == id else { return }
            guard let token else { self.scheduleReconnect(generation); return }
            var request = URLRequest(url: self.socketURL(id))
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(self.client.clientHeader, forHTTPHeaderField: ServerAPI.clientHeader)
            self.socket = sockets.open(request, onText: { [weak self] text in
                self?.handle(text, generation: generation)
            }, onClose: { [weak self] code in
                self?.socketClosed(code, generation: generation)
            })
        }
    }

    private func socketURL(_ matchID: String) -> URL {
        var c = URLComponents(url: client.baseURL.appendingPathComponent(String(path(matchID, "socket").dropFirst())),
                              resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        return c.url!
    }

    private func handle(_ text: String, generation: Int) {
        guard generation == socketGeneration,
              let message = try? ServerAPI.decoder().decode(ServerAPI.ServerMessage.self, from: Data(text.utf8))
        else { return }
        switch message {
        case .hello(let matchID, _, _):
            isSocketConnected = true
            reconnectAttempts = 0
            // Whatever happened while the socket was down: one reload.
            Task { @MainActor [weak self] in
                guard let self, let snap = try? await self.fetch(matchID),
                      generation == self.socketGeneration else { return }
                self.deliver(snap)
            }
        case .match(_, let snap):
            deliver(snap)
        case .request(let matchID, let request):
            controller?.receiveRequest(matchID: matchID, data: request.data)
        case .roll, .error, .unknown:
            break   // the roll shows with the mover's live write; the close follows an error
        }
    }

    private func socketClosed(_ code: Int?, generation: Int) {
        guard generation == socketGeneration else { return }
        socket = nil
        isSocketConnected = false
        // 4403 not a participant / 4410 gone: no point reconnecting.
        if code == 4403 || code == 4410 { return }
        scheduleReconnect(generation, immediately: code == 4401)
    }

    private func scheduleReconnect(_ generation: Int, immediately: Bool = false) {
        guard watchedMatchID != nil, generation == socketGeneration else { return }
        let delay = immediately ? 0 : min(reconnectMax, reconnectBase * pow(2, Double(reconnectAttempts)))
        reconnectAttempts += 1
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, generation == self.socketGeneration else { return }
            self.reconnectTask = nil
            self.connectSocket()
        }
    }

    /// A snapshot from the server that the controller did not ask for (socket event, or
    /// the reload after hello): passed on when it is newer than what this device has.
    /// While a write of ours is out the event waits for its answer, so the controller
    /// never sees its own write echoed ahead of the write's completion.
    private func deliver(_ snap: ServerAPI.MatchSnapshot) {
        let id = snap.matchID
        if (writesInFlight[id] ?? 0) > 0 {
            if let held = heldEvents[id], held.revision > snap.revision { return }
            heldEvents[id] = snap
            return
        }
        if let cached = cache[id], snap.revision < cached.revision || snap == cached { return }
        cache[id] = snap
        onMatchChanged?(snap)
        controller?.receive(snap.onlineSnapshot)
    }

    // MARK: OnlineMatchService

    public func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        performWrite(matchID, op: "end-turn", data: data, completion: completion)
    }

    public func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        performWrite(matchID, op: "save-turn", data: data, completion: completion)
    }

    public func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion) {
        performWrite(matchID, op: "end-match", data: data, outcome: localWon ? .won : .lost, completion: completion)
    }

    public func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion) {
        if inTurn {
            performWrite(matchID, op: "quit", data: data, completion: completion)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snap: ServerAPI.MatchSnapshot = try await self.call(
                    "POST", self.path(matchID, "quit"), body: ServerAPI.QuitRequest(inTurn: false))
                self.store(snap)
                completion(nil)
            } catch {
                completion(self.wrap(error))
            }
        }
    }

    public func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snap: ServerAPI.MatchSnapshot = try await self.call("POST", self.path(matchID, "accept"),
                                                                        body: Optional<Int>.none)
                self.store(snap)
                completion(snap.onlineSnapshot, nil)
            } catch {
                completion(nil, self.wrap(error))
            }
        }
    }

    public func load(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snap = try await self.loadSnapshot(matchID: matchID)
                completion(snap.onlineSnapshot, nil)
            } catch {
                completion(nil, self.wrap(error))
            }
        }
    }

    public func sendRequest(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let _: RequestID = try await self.call("POST", self.path(matchID, "requests"),
                                                       body: ServerAPI.SendRequestRequest(data: data))
                completion(nil)
            } catch {
                completion(self.wrap(error))
            }
        }
    }

    // MARK: OnlineServerDiceService

    public func roll(matchID: String, gameIndex: Int, plyIndex: Int,
                     rollValues: [Float]?) async throws -> GameSession.RemoteRoll {
        do {
            let record: ServerAPI.RollRecord = try await call(
                "POST", path(matchID, "roll"),
                body: ServerAPI.RollRequest(gameIndex: gameIndex, plyIndex: plyIndex, rollValues: rollValues))
            return GameSession.RemoteRoll(die1: record.die1, die2: record.die2, weighted: record.weighted)
        } catch let error as AuthError where error.serverCode == .badRequest && rollValues == nil {
            throw OnlineServerDiceError.rollValuesRequired
        } catch {
            throw wrap(error)
        }
    }

    public func changeDice(matchID: String, whiteLevel: Int, baseRev: Int) async throws -> OnlineDiceHandicap {
        do {
            let dice: ServerAPI.DiceHandicap = try await call(
                "POST", path(matchID, "dice"), body: ServerAPI.DiceChangeRequest(whiteLevel: whiteLevel, baseRev: baseRev))
            if var cached = cache[matchID], dice.rev > cached.diceHandicap.rev {
                cached.diceHandicap = dice
                cache[matchID] = cached
            }
            return dice.online
        } catch {
            throw wrap(error)
        }
    }

    // MARK: Writes

    private func performWrite(_ matchID: String, op: String, data: Data,
                              outcome: ServerAPI.EndMatchRequest.Outcome? = nil,
                              completion: @escaping OnlineCompletion) {
        writesInFlight[matchID, default: 0] += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: Error?
            do {
                _ = try await self.write(matchID, op: op, data: data, outcome: outcome, retryStale: true)
            } catch {
                failure = self.wrap(error)
            }
            self.writesInFlight[matchID, default: 1] -= 1
            completion(failure)
            if self.writesInFlight[matchID] == 0, let held = self.heldEvents.removeValue(forKey: matchID) {
                self.deliver(held)
            }
        }
    }

    /// One write on the newest known revision. `409 stale_revision` (our last answer got
    /// lost, or the cache is behind) → reload, and resend once if we still hold the turn
    /// and the server's log is not ahead of ours; anything else goes to the controller.
    private func write(_ matchID: String, op: String, data: Data, outcome: ServerAPI.EndMatchRequest.Outcome?,
                       retryStale: Bool) async throws -> ServerAPI.MatchSnapshot {
        let base: Int
        if let cached = cache[matchID] { base = cached.revision } else { base = try await loadSnapshot(matchID: matchID).revision }
        do {
            let snap: ServerAPI.MatchSnapshot
            switch op {
            case "end-match":
                snap = try await call("POST", path(matchID, op),
                                      body: ServerAPI.EndMatchRequest(baseRevision: base, data: data, outcome: outcome ?? .won))
            case "quit":
                snap = try await call("POST", path(matchID, op),
                                      body: ServerAPI.QuitRequest(inTurn: true, baseRevision: base, data: data))
            default:
                snap = try await call("POST", path(matchID, op), body: ServerAPI.WriteTurnRequest(baseRevision: base, data: data))
            }
            store(snap)
            return snap
        } catch let error as AuthError where error.serverCode == .staleRevision && retryStale {
            let fresh = try await loadSnapshot(matchID: matchID)
            guard fresh.currentPlayerID == localPlayerID, !fresh.isEnded,
                  !Self.isAhead(fresh.data, of: data) else { throw error }
            return try await write(matchID, op: op, data: data, outcome: outcome, retryStale: false)
        }
    }

    /// The server's payload has more of the match than ours (games, then plies).
    static func isAhead(_ server: Data?, of ours: Data) -> Bool {
        guard let server, let theirs = try? OnlineMatchPayload.decoded(from: server),
              let mine = try? OnlineMatchPayload.decoded(from: ours) else { return false }
        let a = (theirs.games.count, theirs.games.last?.plies.count ?? 0)
        let b = (mine.games.count, mine.games.last?.plies.count ?? 0)
        return a > b
    }

    // MARK: Helpers

    private struct Empty: Decodable {}
    private struct RequestID: Decodable { let id: String }

    private func path(_ matchID: String, _ action: String? = nil) -> String {
        let id = matchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? matchID
        return "/v1/matches/\(id)" + (action.map { "/\($0)" } ?? "")
    }

    private func call<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?) async throws -> R {
        try await client.authorized(method: method, path: path, body: body, allowRefresh: true)
    }

    private func fetch(_ matchID: String) async throws -> ServerAPI.MatchSnapshot {
        try await call("GET", path(matchID), body: Optional<Int>.none)
    }

    /// Keep the newest snapshot (a late answer never replaces a newer revision).
    private func store(_ snap: ServerAPI.MatchSnapshot) {
        if let cached = cache[snap.matchID], cached.revision > snap.revision { return }
        cache[snap.matchID] = snap
        onMatchChanged?(snap)
    }

    private func wrap(_ error: Error) -> Error {
        if error is ServerMatchError || error is OnlineServerDiceError { return error }
        let auth = error as? AuthError
        var code: String?
        var status: Int?
        if case .server(let c, let s)? = auth { code = c; status = s }
        return ServerMatchError(code: code, status: status, message: describeError(error))
    }
}
