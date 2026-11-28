import Foundation
import XCTest
import CoreML
@testable import TavliEngine

// ── An in-memory Tavtav server (the #286 contract, simplified) ─────────────────

/// The match endpoints of `server/REFERENCE.md` in memory: seats, turn holder, payload +
/// revision (stale → 409, an identical resend → 200), server rolls (scripted or random,
/// idempotent per ply) checked against every written ply, the dice slider (the
/// `OnlineDiceRequest` rule), quit/end outcomes, and the socket fan-out (`FakeSockets`).
@MainActor
final class FakeTavtavServer {
    struct Stored {
        var snap: ServerAPI.MatchSnapshot
        var lastWrite: (player: String, op: String)?
        var rolls: [String: ServerAPI.RollRecord] = [:]
        var rollValues: [String: [Double]] = [:]
    }

    var matches: [String: Stored] = [:]
    var names: [String: String] = [:]
    /// Dice the next rolls draw, in order (random once empty).
    var scriptedDice: [(Int, Int)] = []
    /// Every request: "POST /v1/matches/m1/roll".
    var log: [String] = []
    /// Requests fail with no answer (offline).
    var offline = false
    /// The next write of this kind ("end-turn") is applied but its answer is lost.
    var loseNextReplyFor: String?
    let sockets = FakeSockets()
    private var nextID = 1
    private var clock: Int64 = 1_800_000_000_000

    struct Failure: Error { let status: Int; let code: String }

    private func now() -> Int64 { clock += 1; return clock }

    func handle(account: String, method: String, path: String, body: Data?) throws -> Data {
        log.append("\(method) \(path)")
        if offline { throw AuthError.network }
        let parts = path.split(separator: "?")[0].split(separator: "/").map(String.init)   // v1 matches id action
        let enc = JSONEncoder()
        func decode<T: Decodable>(_ t: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: body ?? Data()) }
        if parts == ["v1", "matches"], method == "POST" {
            let req = try decode(ServerAPI.CreateMatchRequest.self)
            if let opponent = req.opponentID { return try enc.encode(challenge(account, opponent, req)) }
            return try enc.encode(create(account, req))
        }
        if let answer = try peopleEndpoints(account: account, method: method, parts: parts, path: path, body: body) {
            return answer
        }
        if let answer = try lobbyEndpoints(account: account, method: method, parts: parts, body: body) {
            return answer
        }
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "matches", var m = matches[parts[2]] else {
            throw AuthError.server(code: "not_found", status: 404)
        }
        guard let seat = m.snap.participants.firstIndex(where: { $0.playerID == account }) else {
            throw AuthError.server(code: "forbidden", status: 403)
        }
        let action = parts.count > 3 ? parts[3] : ""
        let color = m.snap.participants[seat].color
        func save() { matches[m.snap.matchID] = m }
        func view() -> ServerAPI.MatchSnapshot { m.snap }
        switch (method, action) {
        case ("GET", ""):
            return try enc.encode(view())
        case ("POST", "accept"):
            if let c = challenges[m.snap.matchID], c.to == account {
                if c.status == "accepted" { return try enc.encode(view()) }
                guard c.status == "pending" else { throw AuthError.server(code: "invite_unavailable", status: 410) }
                challenges[m.snap.matchID]?.status = "accepted"
                presence(to: c.from, event: "accepted", m.snap.matchID)
            }
            m.snap.participants[seat].status = .active
            m.snap.updatedAt = now()
            save()
            broadcast(m.snap, "accepted")
            return try enc.encode(view())
        case ("POST", "cancel"):
            guard let c = challenges[m.snap.matchID], c.from == account else { throw AuthError.server(code: "forbidden", status: 403) }
            if c.status == "cancelled" { return Data() }
            guard c.status == "pending" else { throw AuthError.server(code: "invite_unavailable", status: 410) }
            challenges[m.snap.matchID]?.status = "cancelled"
            m.snap.participants[1].status = .declined
            m.snap.participants[0].status = .done
            m.snap.isEnded = true
            m.snap.currentPlayerID = nil
            m.snap.updatedAt = now()
            save()
            presence(to: c.to, event: "cancelled", m.snap.matchID)
            return Data()
        case ("POST", "decline"):
            if let c = challenges[m.snap.matchID], c.to == account, c.status == "pending" {
                challenges[m.snap.matchID]?.status = "declined"
                presence(to: c.from, event: "declined", m.snap.matchID)
            }
            m.snap.participants[seat].status = .declined
            m.snap.participants[1 - seat].status = .done
            m.snap.isEnded = true
            m.snap.currentPlayerID = nil
            m.snap.updatedAt = now()
            save()
            broadcast(m.snap, "declined")
            return Data()
        case ("POST", "end-turn"), ("POST", "save-turn"), ("POST", "end-match"), ("POST", "quit"):
            var base: Int?
            var data: Data?
            var outcome = "won"
            var inTurn = true
            switch action {
            case "end-match":
                let r = try decode(ServerAPI.EndMatchRequest.self)
                (base, data, outcome) = (r.baseRevision, r.data, r.outcome.rawValue)
            case "quit":
                let r = try decode(ServerAPI.QuitRequest.self)
                (base, data, inTurn) = (r.baseRevision, r.data, r.inTurn)
            default:
                let r = try decode(ServerAPI.WriteTurnRequest.self)
                (base, data) = (r.baseRevision, r.data)
            }
            if inTurn, let base, let data {
                if base == m.snap.revision - 1, m.lastWrite?.player == account, m.lastWrite?.op == action,
                   m.snap.data == data {
                    return try enc.encode(view())   // identical resend
                }
                guard !m.snap.isEnded else { throw AuthError.server(code: "match_ended", status: 409) }
                guard m.snap.currentPlayerID == account else { throw AuthError.server(code: "not_your_turn", status: 409) }
                guard base == m.snap.revision else { throw AuthError.server(code: "stale_revision", status: 409) }
                try verifyDice(m, data)
                m.snap.data = data
                m.snap.revision += 1
                m.lastWrite = (account, action)
            } else if m.snap.isEnded {
                throw AuthError.server(code: "match_ended", status: 409)
            }
            let other = 1 - seat
            var event = "turnSaved"
            switch action {
            case "end-turn":
                m.snap.currentPlayerID = m.snap.participants[other].playerID
                event = "turnEnded"
            case "end-match":
                m.snap.participants[seat].outcome = ServerAPI.MatchOutcome(rawValue: outcome) ?? .won
                if m.snap.participants[other].outcome != .quit {
                    m.snap.participants[other].outcome = outcome == "won" ? .lost : (outcome == "lost" ? .won : .tied)
                }
                m.snap.isEnded = true
                m.snap.currentPlayerID = nil
                event = "matchEnded"
            case "quit":
                m.snap.participants[seat].outcome = .quit
                m.snap.participants[seat].status = .done
                m.snap.participants[other].outcome = .won
                m.snap.isEnded = true
                m.snap.currentPlayerID = nil
                event = "quit"
            default:
                break
            }
            m.snap.updatedAt = now()
            save()
            if loseNextReplyFor == action {
                loseNextReplyFor = nil
                broadcast(m.snap, event)
                throw AuthError.network
            }
            broadcast(m.snap, event)
            return try enc.encode(view())
        case ("POST", "roll"):
            let r = try decode(ServerAPI.RollRequest.self)
            let key = "\(r.gameIndex)/\(r.plyIndex)"
            if let existing = m.rolls[key] { return try enc.encode(existing) }
            guard !m.snap.isEnded else { throw AuthError.server(code: "match_ended", status: 409) }
            guard m.snap.currentPlayerID == account else { throw AuthError.server(code: "not_your_turn", status: 409) }
            let level = m.snap.diceHandicap.whiteLevel
            if level != 0 {
                guard let values = r.rollValues, values.count == 21 else {
                    throw AuthError.server(code: "bad_request", status: 400)
                }
                m.rollValues[key] = values
            }
            let (d1, d2) = scriptedDice.isEmpty ? (Int.random(in: 1...6), Int.random(in: 1...6)) : scriptedDice.removeFirst()
            let record = ServerAPI.RollRecord(gameIndex: r.gameIndex, plyIndex: r.plyIndex, player: color,
                                              die1: d1, die2: d2, weighted: level == 0 ? nil : level,
                                              beta: level == 0 ? nil : Double(level) / 10, rolledAt: now())
            m.rolls[key] = record
            m.snap.lastRoll = record
            save()
            sockets.send(matchID: m.snap.matchID, to: nil, text: Self.json(["type": "roll", "matchID": m.snap.matchID,
                                                                           "roll": Self.object(record)]))
            return try enc.encode(record)
        case ("POST", "dice"):
            let r = try decode(ServerAPI.DiceChangeRequest.self)
            let current = m.snap.diceHandicap
            guard r.baseRev >= current.rev || current.by == color else {
                throw AuthError.server(code: "stale_revision", status: 409)
            }
            if current.whiteLevel != r.whiteLevel {
                m.snap.diceHandicap = ServerAPI.DiceHandicap(whiteLevel: r.whiteLevel, rev: current.rev + 1, by: color)
                m.snap.updatedAt = now()
                save()
                broadcast(m.snap, "diceChanged")
            }
            return try enc.encode(m.snap.diceHandicap)
        default:
            throw AuthError.server(code: "not_found", status: 404)
        }
    }

    // ── #287: lobby list + removal, invites, auto-match, push tokens ─────────────

    /// code → (match, creator, status)
    var invites: [String: (matchID: String, creator: String, status: String)] = [:]
    /// account → registered push tokens
    var pushTokens: [String: Set<String>] = [:]
    /// "account/match" rows hidden from the lobby
    var hidden: Set<String> = []
    /// auto-match: waiting match ids, oldest first
    var waiting: [String] = []
    private var nextCode = 0

    private func lobbyEndpoints(account: String, method: String, parts: [String], body: Data?) throws -> Data? {
        let enc = JSONEncoder()
        func decode<T: Decodable>(_ t: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: body ?? Data()) }
        switch (method, parts) {
        case ("GET", ["v1", "matches"]):
            return try enc.encode(ServerAPI.MatchList(matches: summaries(for: account), nextCursor: nil))
        case ("DELETE", let p) where p.count == 3 && p[1] == "matches":
            guard let m = matches[p[2]], m.snap.participants.contains(where: { $0.playerID == account }) else {
                throw AuthError.server(code: "not_found", status: 404)
            }
            guard m.snap.isEnded else { throw AuthError.server(code: "forbidden", status: 403) }
            hidden.insert("\(account)/\(p[2])")
            return Data()
        case ("POST", ["v1", "invites"]):
            let req = try decode(ServerAPI.CreateInviteRequest.self)
            var snap = create(account, ServerAPI.CreateMatchRequest(variant: req.variant, targetWins: req.targetWins))
            snap.participants[1].status = .invited
            matches[snap.matchID]?.snap = snap
            nextCode += 1
            let code = "K7Q4M\(InviteCode.alphabet[InviteCode.alphabet.index(InviteCode.alphabet.startIndex, offsetBy: nextCode % 31)])"
            invites[code] = (snap.matchID, account, "open")
            let invite = ServerAPI.Invite(code: code, url: URL(string: "https://tavtav.test/join/\(code)")!,
                                          expiresAt: snap.createdAt + 7 * 86_400_000, match: snap)
            return try enc.encode(invite)
        case (_, let p) where p.count >= 3 && p[0] == "v1" && p[1] == "invites":
            guard var inv = invites[p[2]], let m = matches[inv.matchID] else {
                throw AuthError.server(code: "not_found", status: 404)
            }
            let action = p.count > 3 ? p[3] : ""
            switch (method, action) {
            case ("GET", ""):
                let preview: [String: Any] = [
                    "code": p[2], "from": ["playerID": inv.creator, "displayName": names[inv.creator] ?? inv.creator],
                    "variant": m.snap.variant, "targetWins": m.snap.targetWins, "status": inv.status,
                    "expiresAt": m.snap.createdAt + 7 * 86_400_000,
                ]
                return try JSONSerialization.data(withJSONObject: preview)
            case ("POST", "accept"):
                guard inv.creator != account else { throw AuthError.server(code: "forbidden", status: 403) }
                guard inv.status == "open" else { throw AuthError.server(code: "invite_unavailable", status: 410) }
                inv.status = "accepted"
                invites[p[2]] = inv
                return try enc.encode(join(account, inv.matchID))
            case ("POST", "decline"), ("DELETE", ""):
                guard inv.status == "open" else { throw AuthError.server(code: "invite_unavailable", status: 410) }
                inv.status = method == "DELETE" ? "cancelled" : "declined"
                invites[p[2]] = inv
                closeOpenSeat(inv.matchID)
                return Data()
            default:
                throw AuthError.server(code: "not_found", status: 404)
            }
        case ("POST", ["v1", "automatch"]):
            let req = try decode(ServerAPI.AutoMatchRequest.self)
            while let id = waiting.first(where: { id in
                guard let s = matches[id]?.snap else { return false }
                return s.variant == req.variant && s.targetWins == req.targetWins && s.participants[0].playerID != account
            }) {
                waiting.removeAll { $0 == id }
                if let s = matches[id]?.snap, !s.isEnded, s.participants[1].playerID == nil {
                    return try enc.encode(join(account, id))
                }
            }
            let snap = create(account, ServerAPI.CreateMatchRequest(variant: req.variant, targetWins: req.targetWins))
            waiting.append(snap.matchID)
            return try enc.encode(snap)
        case ("PUT", ["v1", "push-tokens"]):
            let req = try decode(ServerAPI.PushTokenRequest.self)
            pushTokens[account, default: []].insert(req.token)
            return Data()
        case ("DELETE", let p) where p.count == 3 && p[1] == "push-tokens":
            pushTokens[account]?.remove(p[2])
            return Data()
        default:
            return nil
        }
    }

    // ── #301: people, challenges, search, blocks ─────────────────────────────────

    /// match id → the direct challenge's lifecycle
    var challenges: [String: (from: String, to: String, status: String)] = [:]
    /// account → its people (tests seed them; `challenge` is filled in from `challenges`)
    var people: [String: [ServerAPI.Person]] = [:]
    /// "blocker/blocked"
    var blocks: Set<String> = []
    /// every account's handle, for search
    var handles: [String: String] = [:]
    /// "Who can challenge me: only my people" accounts
    var peopleOnly: Set<String> = []

    private func challenge(_ account: String, _ opponent: String, _ req: ServerAPI.CreateMatchRequest) throws -> ServerAPI.MatchSnapshot {
        if blocks.contains("\(opponent)/\(account)") || blocks.contains("\(account)/\(opponent)") {
            throw AuthError.server(code: "forbidden", status: 403)
        }
        if peopleOnly.contains(opponent), !(people[opponent] ?? []).contains(where: { $0.playerID == account }) {
            throw AuthError.server(code: "forbidden", status: 403)
        }
        // Crossed taps: accept theirs.
        if let (id, _) = challenges.first(where: { $0.value.from == opponent && $0.value.to == account && $0.value.status == "pending" }),
           let m = matches[id], m.snap.variant == req.variant, m.snap.targetWins == req.targetWins {
            return try JSONDecoder().decode(ServerAPI.MatchSnapshot.self,
                                            from: handle(account: account, method: "POST", path: "/v1/matches/\(id)/accept", body: nil))
        }
        if let (id, _) = challenges.first(where: { $0.value.from == account && $0.value.to == opponent && $0.value.status == "pending" }),
           let m = matches[id], m.snap.variant == req.variant, m.snap.targetWins == req.targetWins {
            return m.snap
        }
        let snap = create(account, req)
        challenges[snap.matchID] = (account, opponent, "pending")
        presence(to: opponent, event: "received", snap.matchID)
        return snap
    }

    /// A challenge event on `to`'s presence socket.
    func presence(to: String, event: String, _ matchID: String) {
        guard let c = challenges[matchID], let m = matches[matchID] else { return }
        let challenge = ServerAPI.Challenge(
            matchID: matchID, from: .init(playerID: c.from, displayName: names[c.from] ?? c.from),
            to: .init(playerID: c.to, displayName: names[c.to] ?? c.to), variant: m.snap.variant,
            targetWins: m.snap.targetWins, status: ServerAPI.ChallengeStatus(rawValue: c.status) ?? .unknown,
            createdAt: m.snap.createdAt, expiresAt: m.snap.createdAt + 86_400_000)
        sockets.send(matchID: "socket", to: to, text: Self.json(["type": "challenge", "event": event, "challenge": Self.object(challenge)]))
    }

    /// `to`'s presence socket hears that `playerID` came online / went.
    func presenceChange(to: String, playerID: String, online: Bool) {
        sockets.send(matchID: "socket", to: to, text: Self.json(["type": "presence", "playerID": playerID,
                                                                 "online": online, "lastSeenAt": 1_800_000_000_000]))
    }

    private func peopleEndpoints(account: String, method: String, parts: [String], path: String, body: Data?) throws -> Data? {
        let enc = JSONEncoder()
        switch (method, parts) {
        case ("GET", ["v1", "people"]):
            let list = (people[account] ?? []).filter { !blocks.contains("\(account)/\($0.playerID)") && !blocks.contains("\($0.playerID)/\(account)") }
                .map { p -> ServerAPI.Person in
                    var p = p
                    if let (id, c) = challenges.first(where: { $0.value.status == "pending" && Set([$0.value.from, $0.value.to]) == Set([account, p.playerID]) }),
                       let m = matches[id] {
                        p.challenge = .init(matchID: id, direction: c.from == account ? .outgoing : .incoming,
                                            variant: m.snap.variant, targetWins: m.snap.targetWins,
                                            expiresAt: m.snap.createdAt + 86_400_000)
                    }
                    return p
                }
            let blocked = blocks.compactMap { key -> ServerAPI.PlayerCard? in
                let ab = key.split(separator: "/").map(String.init)
                guard ab[0] == account else { return nil }
                return .init(playerID: ab[1], handle: handles[ab[1]] ?? ab[1], displayName: names[ab[1]] ?? ab[1])
            }
            return try enc.encode(ServerAPI.PeopleResponse(people: list, blocked: blocked))
        case ("PATCH", let p) where p.count == 3 && p[1] == "people":
            let pinned = try JSONDecoder().decode(ServerAPI.UpdatePersonRequest.self, from: body ?? Data()).pinned
            if let i = people[account]?.firstIndex(where: { $0.playerID == p[2] }) {
                people[account]![i].pinned = pinned
            } else if pinned, let name = names[p[2]] {
                people[account, default: []].append(.init(playerID: p[2], handle: handles[p[2]] ?? p[2], displayName: name,
                                                          pinned: true, lastPlayedAt: nil))
            } else {
                throw AuthError.server(code: "not_found", status: 404)
            }
            return Data()
        case ("DELETE", let p) where p.count == 3 && p[1] == "people":
            people[account]?.removeAll { $0.playerID == p[2] }
            return Data()
        case (_, let p) where p.count == 4 && p[1] == "people" && p[3] == "block":
            if method == "POST" {
                blocks.insert("\(account)/\(p[2])")
                for (id, c) in challenges where c.from == p[2] && c.to == account && c.status == "pending" {
                    challenges[id]?.status = "declined"
                }
            } else {
                blocks.remove("\(account)/\(p[2])")
            }
            return Data()
        case ("GET", ["v1", "players"]):
            let q = (URLComponents(string: path)?.queryItems?.first { $0.name == "q" }?.value ?? "").lowercased()
            guard q.count >= 3 else { throw AuthError.server(code: "bad_request", status: 400) }
            let found = handles.filter { $0.key != account && $0.value.lowercased().hasPrefix(q) && !blocks.contains("\($0.key)/\(account)") }
                .sorted { a, b in
                    let ax = a.value.lowercased() == q, bx = b.value.lowercased() == q
                    return ax != bx ? ax : a.value < b.value
                }
                .map { entry in
                    ServerAPI.PlayerResult(playerID: entry.key, handle: entry.value, displayName: names[entry.key] ?? entry.key,
                                           isPerson: (people[account] ?? []).contains { $0.playerID == entry.key },
                                           canChallenge: !peopleOnly.contains(entry.key))
                }
            return try enc.encode(ServerAPI.PlayerSearchResponse(players: Array(found.prefix(20))))
        default:
            return nil
        }
    }

    private func join(_ account: String, _ matchID: String) -> ServerAPI.MatchSnapshot {
        var m = matches[matchID]!
        m.snap.participants[1].playerID = account
        m.snap.participants[1].displayName = names[account] ?? account
        m.snap.participants[1].status = .active
        if m.snap.currentPlayerID == nil, !m.snap.isEnded { m.snap.currentPlayerID = account }
        m.snap.updatedAt = now()
        matches[matchID] = m
        broadcast(m.snap, "joined")
        return m.snap
    }

    private func closeOpenSeat(_ matchID: String) {
        guard var m = matches[matchID], !m.snap.isEnded, m.snap.participants[1].playerID == nil else { return }
        m.snap.participants[1].status = .declined
        m.snap.participants[0].status = .done
        m.snap.isEnded = true
        m.snap.currentPlayerID = nil
        m.snap.updatedAt = now()
        matches[matchID] = m
        broadcast(m.snap, "declined")
    }

    /// The lobby rows of `account` (the server's `match_index` view), newest first.
    func summaries(for account: String) -> [ServerAPI.MatchSummary] {
        matches.values.compactMap { stored -> ServerAPI.MatchSummary? in
            let s = stored.snap
            guard let seat = s.participants.firstIndex(where: { $0.playerID == account }),
                  !hidden.contains("\(account)/\(s.matchID)") else { return nil }
            let me = s.participants[seat]
            let other = s.participants[1 - seat]
            let state: ServerAPI.LobbyState
            if s.isEnded || me.status == .declined || me.status == .done { state = .ended }
            else if me.status == .invited { state = .invited }
            else if s.currentPlayerID == account { state = .yourTurn }
            else if other.playerID == nil || other.status == .invited || other.status == .matching { state = .waitingForOpponent }
            else { state = .theirTurn }
            let code = invites.first { $0.value.matchID == s.matchID && $0.value.status == "open" && $0.value.creator == account }?.key
            let challenge = challenges[s.matchID].map {
                ServerAPI.ChallengeState(status: ServerAPI.ChallengeStatus(rawValue: $0.status) ?? .unknown,
                                         expiresAt: s.createdAt + 86_400_000)
            }
            return ServerAPI.MatchSummary(
                matchID: s.matchID, variant: s.variant, targetWins: s.targetWins, state: state,
                opponent: .init(playerID: other.playerID, displayName: other.displayName),
                outcome: me.outcome, updatedAt: s.updatedAt,
                invite: code.map { ServerAPI.InviteRef(code: $0, url: URL(string: "https://tavtav.test/join/\($0)")!,
                                                       expiresAt: s.createdAt + 7 * 86_400_000) },
                challenge: challenge)
        }
        .sorted { ($0.updatedAt, $0.matchID) > ($1.updatedAt, $1.matchID) }
    }

    private func create(_ account: String, _ req: ServerAPI.CreateMatchRequest) -> ServerAPI.MatchSnapshot {
        let id = "m_\(nextID)"
        nextID += 1
        let t = now()
        let json: [String: Any] = [
            "matchID": id, "revision": 0, "variant": req.variant, "targetWins": req.targetWins,
            "startingPlayer": "W", "data": NSNull(),
            "participants": [
                ["playerID": account, "displayName": names[account] ?? account, "color": "W", "status": "active", "outcome": "none"],
                ["playerID": req.opponentID.map { $0 as Any } ?? NSNull(),
                 "displayName": req.opponentID.map { (names[$0] ?? $0) as Any } ?? NSNull(),
                 "color": "B", "status": req.opponentID == nil ? "matching" : "invited", "outcome": "none"],
            ],
            "currentPlayerID": account, "isEnded": false, "diceHandicap": ["whiteLevel": 0, "rev": 0],
            "lastRoll": NSNull(), "requests": [], "createdAt": t, "updatedAt": t,
        ]
        let snap = try! JSONDecoder().decode(ServerAPI.MatchSnapshot.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        matches[id] = Stored(snap: snap)
        return snap
    }

    /// Every ply must carry the server's roll (the client can't choose its dice).
    private func verifyDice(_ m: Stored, _ data: Data) throws {
        guard let payload = try? OnlineMatchPayload.decoded(from: data) else {
            throw AuthError.server(code: "bad_request", status: 400)
        }
        for (g, game) in payload.games.enumerated() {
            for (p, ply) in game.plies.enumerated() {
                guard let roll = m.rolls["\(g)/\(p)"],
                      Set([roll.die1, roll.die2]) == Set([ply.die1, ply.die2]) else {
                    throw AuthError.server(code: "bad_request", status: 400)
                }
            }
        }
    }

    private func broadcast(_ snap: ServerAPI.MatchSnapshot, _ event: String) {
        sockets.send(matchID: snap.matchID, to: nil,
                     text: Self.json(["type": "match", "event": event, "match": Self.object(snap)]))
    }

    static func object<T: Encodable>(_ value: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func payload(_ id: String) -> OnlineMatchPayload? {
        matches[id]?.snap.data.flatMap { try? OnlineMatchPayload.decoded(from: $0) }
    }
}

/// The sockets: one per (account, match); messages are delivered on the next main-queue turn.
@MainActor
final class FakeSockets: ServerSocketFactory {
    final class Socket: ServerSocket {
        let account: String
        let matchID: String
        let onText: @MainActor (String) -> Void
        let onClose: @MainActor (Int?) -> Void
        var isOpen = true
        weak var owner: FakeSockets?
        init(account: String, matchID: String, onText: @escaping @MainActor (String) -> Void,
             onClose: @escaping @MainActor (Int?) -> Void) {
            self.account = account
            self.matchID = matchID
            self.onText = onText
            self.onClose = onClose
        }
        func close() { isOpen = false }
    }

    var open: [Socket] = []
    var opened = 0
    /// New connections fail at once (server unreachable).
    var refuse = false

    func open(_ request: URLRequest, onText: @escaping @MainActor (String) -> Void,
              onClose: @escaping @MainActor (Int?) -> Void) -> ServerSocket {
        let parts = request.url!.path.split(separator: "/").map(String.init)
        let account = String(request.value(forHTTPHeaderField: "Authorization")!.dropFirst("Bearer ".count))
        let socket = Socket(account: account, matchID: parts[2], onText: onText, onClose: onClose)
        socket.owner = self
        opened += 1
        if refuse {
            socket.isOpen = false
            Task { @MainActor in onClose(nil) }
            return socket
        }
        open.append(socket)
        let hello = FakeTavtavServer.json(["type": "hello", "matchID": parts[2], "revision": 0, "serverTime": 1])
        Task { @MainActor in if socket.isOpen { onText(hello) } }
        return socket
    }

    func send(matchID: String, to account: String?, text: String) {
        for s in open where s.isOpen && s.matchID == matchID && (account == nil || s.account == account) {
            Task { @MainActor in if s.isOpen { s.onText(text) } }
        }
    }

    /// The server drops every connection (close code `code`).
    func dropAll(code: Int? = nil) {
        let all = open
        open = []
        for s in all where s.isOpen {
            s.isOpen = false
            s.onClose(code)
        }
    }

    func live(_ account: String) -> Int { open.filter { $0.isOpen && $0.account == account }.count }
}

/// A signed-in device's HTTP: straight into the fake server (the token is the account id).
@MainActor
final class FakeServerClient: ServerMatchClient {
    let baseURL = URL(string: "https://tavtav.test")!
    let clientHeader = "ios/test"
    let account: String
    unowned let server: FakeTavtavServer
    var signedInAccountID: String? { account }

    init(_ account: String, server: FakeTavtavServer) {
        self.account = account
        self.server = server
    }

    func authorized<B: Encodable, R: Decodable>(method: String, path: String, body: B?,
                                                allowRefresh: Bool) async throws -> R {
        await Task.yield()
        let data = try body.map { try JSONEncoder().encode($0) }
        let answer = try server.handle(account: account, method: method, path: path, body: data)
        return try JSONDecoder().decode(R.self, from: answer.isEmpty ? Data("null".utf8) : answer)
    }

    func accessToken() async throws -> String {
        if server.offline { throw AuthError.network }
        return account
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────────

/// `ServerMatchService` (#286) under the real `OnlineMatchController` and `GameSession`, two
/// devices against `FakeTavtavServer`: server-drawn dice, live events over the socket,
/// stale revisions, a lost reply, the socket dropping (poll fallback + reconnect), the
/// shared slider through the server, and a roll that fails offline.
@MainActor
final class ServerMatchServiceTests: XCTestCase {
    private var server: FakeTavtavServer!
    private var alice: ServerMatchService!
    private var bob: ServerMatchService!
    private var aliceController: OnlineMatchController!
    private var bobController: OnlineMatchController!
    private var matchID = ""

    override func setUp() async throws {
        server = FakeTavtavServer()
        server.names = ["acc_alice": "Alice", "acc_bob": "Bob"]
    }

    override func tearDown() async throws {
        aliceController?.close()
        bobController?.close()
        alice?.close()
        bob?.close()
    }

    private func makeDevice(_ account: String, agent: Agent? = nil) -> (ServerMatchService, OnlineMatchController) {
        let service = ServerMatchService(client: FakeServerClient(account, server: server), sockets: server.sockets)
        service.reconnectBase = 0.01
        service.reconnectMax = 0.05
        let controller = OnlineMatchController(service: service, animationTimings: .off, retryDelay: nil,
                                               liveTurns: FakeDevice.instantLive,
                                               handicapAgent: agent.map { a in { _ in a } })
        service.controller = controller
        return (service, controller)
    }

    private func drain(_ turns: Int = 12) async {
        for _ in 0..<turns { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private func until(_ what: String, timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Alice challenges Bob; both open the match and watch it.
    private func startMatch(targetWins: Int = 1, agent: Agent? = nil) async throws {
        (alice, aliceController) = makeDevice("acc_alice", agent: agent)
        (bob, bobController) = makeDevice("acc_bob", agent: agent)
        let created = try await alice.createMatch(variant: "plakoto", targetWins: targetWins, opponentID: "acc_bob")
        matchID = created.matchID
        aliceController.open(created.onlineSnapshot, newMatchTargetWins: targetWins, newMatchVariantID: "plakoto")
        alice.watch(matchID)
        await until("Alice's opening write") { server.matches[matchID]?.snap.data != nil }
        let forBob = try await bob.loadSnapshot(matchID: matchID)
        bobController.open(forBob.onlineSnapshot)
        bob.watch(matchID)
        await until("both sockets") { alice.isSocketConnected && bob.isSocketConnected }
        await until("Bob accepted") { server.matches[matchID]?.snap.participants[1].status == .active }
        XCTAssertTrue(aliceController.isLocalTurn)
        XCTAssertEqual(bobController.localColor, .black)
    }

    /// Roll through the server and play the whole turn with the first legal hops.
    @discardableResult
    private func rollAndPlay(_ controller: OnlineMatchController) async -> (Int, Int) {
        let s = controller.session!
        XCTAssertTrue(controller.isLocalTurn)
        let plies = s.record.plies.count
        s.roll()
        await s.awaitRemoteRollForTesting()
        await until("the dice") { s.phase != .awaitingRoll || s.record.plies.count > plies || s.remoteRollFailed }
        let dice = (s.game.dice.die1.value, s.game.dice.die2.value)
        while s.record.plies.count == plies, let hop = anyHop(s) {
            s.commitHalfMove(from: hop.0, to: hop.1)
        }
        await drain()
        return dice
    }

    private func anyHop(_ s: GameSession) -> (Int, Int)? {
        for from in s.selectableSources.sorted() {
            for to in s.moveBuilder.validDestinations(for: from).sorted()
            where s.moveBuilder.routeOptions(from: from, to: to).first?.count == 1 {
                return (from, to)
            }
        }
        return nil
    }

    // MARK: - Turns with server dice

    func testTwoDevicesPlayWithTheServersDice() async throws {
        try await startMatch()
        server.scriptedDice = [(3, 1), (6, 5), (4, 2), (5, 5), (2, 1), (6, 3)]
        for turn in 0..<6 {
            let mover = turn % 2 == 0 ? aliceController! : bobController!
            let waiter = turn % 2 == 0 ? bobController! : aliceController!
            let dice = await rollAndPlay(mover)
            XCTAssertEqual(Set([dice.0, dice.1]), Set(turnDice(turn)), "turn \(turn): the server's roll is used")
            await until("turn \(turn) reaches the other device") {
                waiter.session?.record.plies.count == turn + 1 && waiter.isLocalTurn
            }
        }
        // The server's log and both devices agree, ply for ply, with the scripted rolls.
        let plies = server.payload(matchID)!.games[0].plies
        XCTAssertEqual(plies.count, 6)
        for (i, ply) in plies.enumerated() { XCTAssertEqual(Set([ply.die1, ply.die2]), Set(turnDice(i))) }
        XCTAssertEqual(aliceController.session!.record.plies, bobController.session!.record.plies)
        // Only the turn holder rolled, once per ply.
        XCTAssertEqual(server.log.filter { $0.hasSuffix("/roll") }.count, 6)
    }

    private func turnDice(_ turn: Int) -> [Int] {
        [[3, 1], [6, 5], [4, 2], [5, 5], [2, 1], [6, 3]][turn]
    }

    func testTheWaitingDeviceSeesTheRollLive() async throws {
        try await startMatch()
        server.scriptedDice = [(6, 4)]
        let s = aliceController.session!
        s.roll()
        await s.awaitRemoteRollForTesting()
        await until("Bob sees Alice's dice before her move") {
            bobController.session?.isShowingRemoteTurn == true
                && bobController.session?.game.dice.die1.value == 6
                && bobController.session?.game.dice.die2.value == 4
        }
    }

    func testARollFailsOfflineAndWorksAgain() async throws {
        try await startMatch()
        server.scriptedDice = [(2, 2)]
        let s = aliceController.session!
        server.offline = true
        s.roll()
        await s.awaitRemoteRollForTesting()
        await until("the failure") { s.remoteRollFailed }
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertFalse(s.humanDiceRolling)
        server.offline = false
        s.roll()
        await s.awaitRemoteRollForTesting()
        await until("the dice") { s.phase != .awaitingRoll }
        XCTAssertFalse(s.remoteRollFailed)
        XCTAssertEqual([s.game.dice.die1.value, s.game.dice.die2.value], [2, 2])
    }

    func testAPlyWithOtherDiceIsRefused() async throws {
        try await startMatch()
        // A tampered client writes a ply with dice it chose: the server refuses it.
        var payload = server.payload(matchID)!
        payload.games[0].plies = [PlyRecord(die1: 6, die2: 6, halfMoves: [])]
        let expectation = expectation(description: "refused")
        alice.endTurn(matchID: matchID, data: try payload.encoded()) { error in
            XCTAssertEqual((error as? ServerMatchError)?.code, "bad_request")
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - Revisions

    func testALostReplyIsRecognisedWithoutAResend() async throws {
        try await startMatch()
        server.scriptedDice = [(3, 1)]
        server.loseNextReplyFor = "end-turn"   // Alice's end of turn lands, its answer is lost
        await rollAndPlay(aliceController)
        // The write failed for Alice, but the server's event (held until the write was
        // answered) shows it landed: nothing unsent, no second end-turn.
        aliceController.refresh()
        await until("Alice's turn confirmed") { !aliceController.hasUnsentTurn }
        await until("Bob got the turn") { bobController.isLocalTurn }
        XCTAssertEqual(server.payload(matchID)!.games[0].plies.count, 1)
        XCTAssertEqual(server.log.filter { $0.hasSuffix("/end-turn") }.count, 1)
        XCTAssertNotEqual(aliceController.status, .sendFailed)
    }

    func testAnIdenticalResendIsAnswered() async throws {
        try await startMatch()
        let data = server.matches[matchID]!.snap.data!
        let rev = server.matches[matchID]!.snap.revision
        // Alice's service believes the opening write never landed (cache one behind).
        server.matches[matchID]!.lastWrite = ("acc_alice", "save-turn")
        let fresh = try await alice.loadSnapshot(matchID: matchID)
        XCTAssertEqual(fresh.revision, rev)
        let answered = expectation(description: "answered")
        let client = FakeServerClient("acc_alice", server: server)
        let snap: ServerAPI.MatchSnapshot = try await client.authorized(
            method: "POST", path: "/v1/matches/\(matchID)/save-turn",
            body: ServerAPI.WriteTurnRequest(baseRevision: rev - 1, data: data), allowRefresh: true)
        XCTAssertEqual(snap.revision, rev, "no new revision")
        answered.fulfill()
        await fulfillment(of: [answered], timeout: 1)
    }

    func testAStaleRevisionIsReloadedAndResent() async throws {
        try await startMatch()
        server.scriptedDice = [(5, 2)]
        // The service's cached revision falls behind (a write it never heard back from).
        let s = aliceController.session!
        s.roll()
        await s.awaitRemoteRollForTesting()
        await until("Alice's live write") { server.matches[matchID]!.snap.revision >= 2 }
        server.matches[matchID]!.snap.revision += 1   // as if a reply was lost
        while s.record.plies.isEmpty, let hop = anyHop(s) { s.commitHalfMove(from: hop.0, to: hop.1) }
        await until("Bob got the turn") { bobController.isLocalTurn }
        XCTAssertFalse(aliceController.hasUnsentTurn)
        XCTAssertNil(aliceController.status)
        XCTAssertTrue(server.log.filter { $0.hasSuffix("/end-turn") }.count >= 2, "stale, then resent")
    }

    // MARK: - Socket

    func testSocketDropFallsBackToPollingAndReconnects() async throws {
        try await startMatch()
        XCTAssertTrue(bob.deliversEventsLive)
        server.sockets.refuse = true
        server.sockets.dropAll()
        XCTAssertFalse(bob.deliversEventsLive)
        // Alice plays while Bob's socket is down; Bob's poll (the controller) catches up.
        server.scriptedDice = [(4, 1)]
        await rollAndPlay(aliceController)
        bobController.refresh()
        await until("Bob catches up without the socket") { bobController.isLocalTurn }
        // The server is back: the socket reconnects and says hello.
        server.sockets.refuse = false
        await until("reconnected", timeout: 3) { bob.isSocketConnected && alice.isSocketConnected }
        XCTAssertGreaterThan(server.sockets.opened, 4)
    }

    func testAnExpiredTokenReconnectsAtOnceAndAForbiddenSocketStaysClosed() async throws {
        try await startMatch()
        let before = server.sockets.opened
        server.sockets.dropAll(code: 4401)
        await until("both reconnect") { alice.isSocketConnected && bob.isSocketConnected }
        XCTAssertEqual(server.sockets.opened, before + 2)
        server.sockets.dropAll(code: 4403)
        await drain(30)
        XCTAssertFalse(alice.isSocketConnected)
        XCTAssertEqual(server.sockets.opened, before + 2, "no reconnect after 4403")
    }

    // MARK: - Shared dice through the server

    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else { throw XCTSkip("PlakotoValue.mlpackage not found") }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        return Agent(model: try MLModel(contentsOf: compiled, configuration: cfg),
                     encoder: BoardEncoder(config: .standard))
    }

    func testTheWaitingPlayerChangesTheDiceAndTheBendIsRecorded() async throws {
        try await startMatch(agent: try loadAgent())
        XCTAssertTrue(bobController.canChangeDice)
        // Bob is waiting; with our server he writes the slider directly.
        bobController.setDiceHandicap(levelTowardsMe: 2)
        XCTAssertTrue(bobController.isDiceChangePending)
        await until("the server took Bob's change") { server.matches[matchID]!.snap.diceHandicap.whiteLevel == -2 }
        await until("Bob's change confirmed") { !bobController.isDiceChangePending }
        await until("Alice sees it") { aliceController.diceHandicap.whiteLevel == -2 }
        XCTAssertEqual(aliceController.diceHandicap.changedBy, .black)
        XCTAssertTrue(server.log.contains("POST /v1/matches/\(matchID)/dice"))
        XCTAssertFalse(server.log.contains { $0.hasSuffix("/requests") }, "no out-of-turn request needed")

        // Alice's roll sends her 21 values; the ply is stamped with the server's bend.
        server.scriptedDice = [(6, 2)]
        await rollAndPlay(aliceController)
        XCTAssertEqual(server.matches[matchID]!.rollValues["0/0"]?.count, 21)
        await until("the ply reached the server") { server.payload(matchID)?.games[0].plies.count == 1 }
        XCTAssertEqual(server.payload(matchID)!.games[0].plies[0].weighted, -2)
        await until("Bob has the stamped ply") { bobController.session?.record.plies.first?.weighted == -2 }
    }

    func testARollAsksForTheValuesWhenTheServerHasNewerDice() async throws {
        try await startMatch(agent: try loadAgent())
        // The slider changed on the server but this device has not heard yet.
        server.matches[matchID]!.snap.diceHandicap = ServerAPI.DiceHandicap(whiteLevel: 1, rev: 1, by: "B")
        XCTAssertTrue(aliceController.diceHandicap.isFair)
        server.scriptedDice = [(1, 3)]
        await rollAndPlay(aliceController)
        XCTAssertEqual(server.matches[matchID]!.rollValues["0/0"]?.count, 21)
        let rolls = server.log.filter { $0.hasSuffix("/roll") }
        XCTAssertEqual(rolls.count, 2, "first without values (400), then with them")
    }

    func testTheOtherPlayersUnseenChangeWins() async throws {
        try await startMatch(agent: try loadAgent())
        // Bob changed it on the server; Alice's change on the old base is refused.
        server.matches[matchID]!.snap.diceHandicap = ServerAPI.DiceHandicap(whiteLevel: -1, rev: 1, by: "B")
        aliceController.setDiceHandicap(levelTowardsMe: 3)
        await until("Alice reloads Bob's value") { aliceController.diceHandicap.whiteLevel == -1 }
        XCTAssertFalse(aliceController.isDiceChangePending)
        XCTAssertEqual(server.matches[matchID]!.snap.diceHandicap.whiteLevel, -1)
    }

    // MARK: - End of match

    func testQuitOutOfTurnEndsTheMatchForBoth() async throws {
        try await startMatch()
        bobController.forfeit()
        await until("Alice sees the forfeit") { aliceController.isMatchOver }
        XCTAssertEqual(aliceController.status, .opponentLeft)
        XCTAssertTrue(server.matches[matchID]!.snap.isEnded)
        XCTAssertEqual(server.matches[matchID]!.snap.participants.map(\.outcome), [.won, .quit])
    }
}
