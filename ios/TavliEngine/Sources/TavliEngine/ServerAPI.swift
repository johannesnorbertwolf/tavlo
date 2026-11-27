import Foundation

/// The Server v1 wire contract (#284, epic #278): the Codable mirror of
/// `server/src/api.ts`, documented in `server/REFERENCE.md` ("API contract"). Both sides
/// decode the same `server/fixtures/*.json` (`ServerAPITests` here, `fixtures.test.ts`
/// there), so change all three together.
///
/// Conventions: camelCase keys; times are Unix **milliseconds** (`Int64`, `...At`); opaque
/// bytes (the `OnlineMatchPayload`, out-of-turn requests) are standard base64, which is
/// `JSONDecoder`'s default `Data` strategy; colours are the raw `Color` values "W"/"B" as
/// in the payload. Readers ignore unknown keys, and unknown enum values decode to a
/// fallback (`unknown` / `other`) instead of failing, so the server can add values
/// without breaking shipped builds. The types are plain values; `ServerMatchService`
/// (#286) will speak HTTP/WebSocket with them behind `OnlineMatchService`.
public enum ServerAPI {
    /// Major API version: the `/v1` path prefix and the `X-Tavtav-Api` response header.
    public static let version = 1
    /// Max decoded size of a match payload or out-of-turn request.
    public static let maxPayloadBytes = 64 * 1024
    /// Length of `RollRequest.rollValues` (the 21 distinct rolls, `HandicapDice.outcomes` order).
    public static let rollCount = 21
    /// Request header naming the client build, e.g. `ios/1.0.1 (330)`.
    public static let clientHeader = "X-Tavtav-Client"
    /// WebSocket keepalive (answered without waking the match room).
    public static let wsPing = #"{"type":"ping"}"#
    public static let wsPong = #"{"type":"pong"}"#

    // ── Health (#284) ───────────────────────────────────────────────────────────

    public struct Health: Codable, Equatable, Sendable {
        public struct Checks: Codable, Equatable, Sendable {
            public var d1: String
            public var durableObjects: String
        }
        /// "ok", or "degraded" (HTTP 503) from a failing deep check.
        public var status: String
        public var service: String
        public var version: String
        public var commit: String
        public var environment: String
        public var apiVersion: Int
        public var time: Int64
        public var checks: Checks?
    }

    // ── Errors ──────────────────────────────────────────────────────────────────

    /// Every error response: `{ "error": { code, message, … } }`.
    public struct ErrorResponse: Codable, Equatable, Sendable, Error {
        public var error: Body

        public struct Body: Codable, Equatable, Sendable {
            /// An `ErrorCode` raw value; kept as a string so a new code never fails decoding.
            public var code: String
            public var message: String
            public var requestId: String?
            /// Seconds to wait (429 / 503), same as `Retry-After`.
            public var retryAfter: Int?
            /// `bad_request`: the offending field.
            public var path: String?
            /// `not_implemented`: the issue that builds the endpoint.
            public var ticket: String?
        }

        public var code: ErrorCode? { ErrorCode(rawValue: error.code) }
    }

    public enum ErrorCode: String, Codable, Sendable, CaseIterable {
        case badRequest = "bad_request"
        case unauthorized
        case tokenExpired = "token_expired"
        case forbidden
        case notFound = "not_found"
        case methodNotAllowed = "method_not_allowed"
        case staleRevision = "stale_revision"
        case notYourTurn = "not_your_turn"
        case matchEnded = "match_ended"
        case inviteUnavailable = "invite_unavailable"
        case payloadTooLarge = "payload_too_large"
        case upgradeRequired = "upgrade_required"
        case rateLimited = "rate_limited"
        case `internal`
        case notImplemented = "not_implemented"
        case unavailable
    }

    // ── Accounts (#285) ─────────────────────────────────────────────────────────

    public struct Account: Codable, Equatable, Sendable {
        /// The player id used in matches and in the payload's `colorByPlayerID`.
        public var id: String
        public var displayName: String
        /// "apple" / "google".
        public var providers: [String]
        public var createdAt: Int64
        public init(id: String, displayName: String, providers: [String], createdAt: Int64) {
            self.id = id
            self.displayName = displayName
            self.providers = providers
            self.createdAt = createdAt
        }
    }

    public struct AppleSignInRequest: Codable, Equatable, Sendable {
        public var identityToken: String
        /// The raw nonce whose SHA-256 went into the Apple request.
        public var nonce: String
        /// Apple's name, sent only on the first sign-in.
        public var displayName: String?
        /// Apple's one-time authorization code; the server exchanges it (when configured)
        /// so it can revoke the Apple grant when the account is deleted (#285).
        public var authorizationCode: String?
        public init(identityToken: String, nonce: String, displayName: String? = nil,
                    authorizationCode: String? = nil) {
            self.identityToken = identityToken
            self.nonce = nonce
            self.displayName = displayName
            self.authorizationCode = authorizationCode
        }
    }

    public struct GoogleSignInRequest: Codable, Equatable, Sendable {
        public var idToken: String
        public var nonce: String
        public init(idToken: String, nonce: String) {
            self.idToken = idToken
            self.nonce = nonce
        }
    }

    public struct RefreshRequest: Codable, Equatable, Sendable {
        public var refreshToken: String
        public init(refreshToken: String) { self.refreshToken = refreshToken }
    }

    public struct AuthSession: Codable, Equatable, Sendable {
        public var accessToken: String
        public var accessExpiresAt: Int64
        public var refreshToken: String
        public var refreshExpiresAt: Int64
        public var account: Account
        public var isNewAccount: Bool
        public init(accessToken: String, accessExpiresAt: Int64, refreshToken: String,
                    refreshExpiresAt: Int64, account: Account, isNewAccount: Bool) {
            self.accessToken = accessToken
            self.accessExpiresAt = accessExpiresAt
            self.refreshToken = refreshToken
            self.refreshExpiresAt = refreshExpiresAt
            self.account = account
            self.isNewAccount = isNewAccount
        }
    }

    public struct UpdateAccountRequest: Codable, Equatable, Sendable {
        public var displayName: String
        public init(displayName: String) { self.displayName = displayName }
    }

    /// `POST /v1/auth/dev` — **development servers only** (`wrangler dev`; 404 elsewhere):
    /// signs in as the made-up subject without a provider token, for simulator checks.
    public struct DevSignInRequest: Codable, Equatable, Sendable {
        public var subject: String
        public var displayName: String?
        public init(subject: String, displayName: String? = nil) {
            self.subject = subject
            self.displayName = displayName
        }
    }

    // ── Matches (#286) ──────────────────────────────────────────────────────────

    /// `OnlineParticipantStatus` on the wire.
    public enum ParticipantStatus: String, Codable, Sendable, CaseIterable {
        case invited, declined, matching, active, done, unknown

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        public var online: OnlineParticipantStatus {
            switch self {
            case .invited: return .invited
            case .declined: return .declined
            case .matching: return .matching
            case .active: return .active
            case .done: return .done
            case .unknown: return .unknown
            }
        }
    }

    /// `OnlineMatchOutcome` on the wire (`none` = still playing).
    public enum MatchOutcome: String, Codable, Sendable, CaseIterable {
        case none, quit, won, lost, tied, timeExpired, other

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }

        public var online: OnlineMatchOutcome {
            switch self {
            case .none: return .none
            case .quit: return .quit
            case .won: return .won
            case .lost: return .lost
            case .tied: return .tied
            case .timeExpired: return .timeExpired
            case .other: return .other
            }
        }
    }

    public struct Participant: Codable, Equatable, Sendable {
        /// Account id, `nil` while the seat is unfilled.
        public var playerID: String?
        public var displayName: String?
        /// Raw colour for the whole match; seat 0 (the creator) is "W".
        public var color: String
        public var status: ParticipantStatus
        public var outcome: MatchOutcome

        public var colorValue: Color? { Color(rawValue: color) }

        public var online: OnlineParticipant {
            OnlineParticipant(playerID: playerID, displayName: displayName,
                              status: status.online, outcome: outcome.online)
        }
    }

    /// The shared weighted-dice slider (#272), held by the server.
    public struct DiceHandicap: Codable, Equatable, Sendable {
        /// +n favours White at level n, −n Black, 0 = fair.
        public var whiteLevel: Int
        public var rev: Int
        /// Raw colour of whoever changed it last (absent = never changed).
        public var by: String?

        public var online: OnlineDiceHandicap {
            OnlineDiceHandicap(whiteLevel: whiteLevel, rev: rev, by: by.flatMap(Color.init(rawValue:)))
        }
    }

    /// A roll the server drew; one per (gameIndex, plyIndex).
    public struct RollRecord: Codable, Equatable, Sendable {
        public var gameIndex: Int
        public var plyIndex: Int
        /// Raw colour of the roller.
        public var player: String
        public var die1: Int
        public var die2: Int
        /// Signed level vs White the roll was bent with (`PlyRecord.weighted`); `nil` = fair.
        public var weighted: Int?
        /// The tilt β_t applied (`nil` / 0 = fair draw).
        public var beta: Double?
        public var rolledAt: Int64
    }

    /// An out-of-turn message (`OnlineMatchService.sendRequest`), relayed opaquely.
    public struct OutOfTurnRequest: Codable, Equatable, Sendable {
        public var id: String
        /// Sender's account id.
        public var from: String
        public var data: Data
        public var sentAt: Int64
    }

    /// `OnlineMatchSnapshot` plus the server-held state.
    public struct MatchSnapshot: Codable, Equatable, Sendable {
        public var matchID: String
        /// Bumped by every write; writes name the revision they build on.
        public var revision: Int
        public var variant: String
        public var targetWins: Int
        /// Raw colour that starts game 1, drawn by the server at creation.
        public var startingPlayer: String
        /// The `OnlineMatchPayload` JSON, `nil` before the first write.
        public var data: Data?
        public var participants: [Participant]
        public var currentPlayerID: String?
        public var isEnded: Bool
        public var diceHandicap: DiceHandicap
        public var lastRoll: RollRecord?
        /// Out-of-turn requests addressed to the caller, oldest first.
        public var requests: [OutOfTurnRequest]
        public var createdAt: Int64
        public var updatedAt: Int64

        /// The engine's view of the match (what `OnlineMatchController` consumes).
        public var onlineSnapshot: OnlineMatchSnapshot {
            OnlineMatchSnapshot(matchID: matchID, data: data,
                                participants: participants.map(\.online),
                                currentPlayerID: currentPlayerID, isEnded: isEnded)
        }
    }

    public enum LobbyState: String, Codable, Sendable, CaseIterable {
        case invited, yourTurn, theirTurn, waitingForOpponent, ended, unknown

        public init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct MatchSummary: Codable, Equatable, Sendable {
        public struct Opponent: Codable, Equatable, Sendable {
            public var playerID: String?
            public var displayName: String?
        }
        public var matchID: String
        public var variant: String
        public var targetWins: Int
        public var state: LobbyState
        public var opponent: Opponent
        /// The caller's outcome.
        public var outcome: MatchOutcome
        public var updatedAt: Int64
    }

    public struct MatchList: Codable, Equatable, Sendable {
        public var matches: [MatchSummary]
        public var nextCursor: String?
    }

    public struct CreateMatchRequest: Codable, Equatable, Sendable {
        public var variant: String
        public var targetWins: Int
        public var opponentID: String?
        public init(variant: String, targetWins: Int, opponentID: String? = nil) {
            self.variant = variant
            self.targetWins = targetWins
            self.opponentID = opponentID
        }
    }

    /// `end-turn` / `save-turn` body.
    public struct WriteTurnRequest: Codable, Equatable, Sendable {
        public var baseRevision: Int
        public var data: Data
        public init(baseRevision: Int, data: Data) {
            self.baseRevision = baseRevision
            self.data = data
        }
    }

    public struct EndMatchRequest: Codable, Equatable, Sendable {
        /// "won" / "lost" / "tied": the caller's outcome.
        public enum Outcome: String, Codable, Sendable { case won, lost, tied }
        public var baseRevision: Int
        public var data: Data
        public var outcome: Outcome
        public init(baseRevision: Int, data: Data, outcome: Outcome) {
            self.baseRevision = baseRevision
            self.data = data
            self.outcome = outcome
        }
    }

    public struct QuitRequest: Codable, Equatable, Sendable {
        public var inTurn: Bool
        /// Required when `inTurn`.
        public var baseRevision: Int?
        /// Required when `inTurn`.
        public var data: Data?
        public init(inTurn: Bool, baseRevision: Int? = nil, data: Data? = nil) {
            self.inTurn = inTurn
            self.baseRevision = baseRevision
            self.data = data
        }
    }

    public struct SendRequestRequest: Codable, Equatable, Sendable {
        public var data: Data
        public init(data: Data) { self.data = data }
    }

    /// Change the shared dice slider (`OnlineDiceRequest` semantics, server-minted rev).
    public struct DiceChangeRequest: Codable, Equatable, Sendable {
        public var whiteLevel: Int
        public var baseRev: Int
        public init(whiteLevel: Int, baseRev: Int) {
            self.whiteLevel = OnlineDiceHandicap.clamp(whiteLevel)
            self.baseRev = baseRev
        }
    }

    /// The turn holder asks the server for its dice.
    public struct RollRequest: Codable, Equatable, Sendable {
        public var gameIndex: Int
        /// The current game's `plies.count`.
        public var plyIndex: Int
        /// The roller's 21 one-ply values (`HandicapDice.rollValues`, `outcomes` order),
        /// each in [0, 1]; required when the dice are weighted, omitted when fair.
        public var rollValues: [Double]?

        public init(gameIndex: Int, plyIndex: Int, rollValues: [Float]? = nil) {
            self.gameIndex = gameIndex
            self.plyIndex = plyIndex
            self.rollValues = rollValues?.map(Double.init)
        }
    }

    // ── Invites, auto-match, push (#287) ────────────────────────────────────────

    public struct CreateInviteRequest: Codable, Equatable, Sendable {
        public var variant: String
        public var targetWins: Int
        public init(variant: String, targetWins: Int) {
            self.variant = variant
            self.targetWins = targetWins
        }
    }

    public struct Invite: Codable, Equatable, Sendable {
        public var code: String
        /// Universal link `https://<host>/join/<code>`.
        public var url: URL
        public var expiresAt: Int64
        public var match: MatchSnapshot
    }

    public struct InvitePreview: Codable, Equatable, Sendable {
        public struct From: Codable, Equatable, Sendable {
            public var playerID: String
            public var displayName: String
        }
        public var code: String
        public var from: From
        public var variant: String
        public var targetWins: Int
        /// "open", "accepted", "declined", "cancelled", "expired".
        public var status: String
        public var expiresAt: Int64
    }

    public struct AutoMatchRequest: Codable, Equatable, Sendable {
        public var variant: String
        public var targetWins: Int
        public init(variant: String, targetWins: Int) {
            self.variant = variant
            self.targetWins = targetWins
        }
    }

    public struct PushTokenRequest: Codable, Equatable, Sendable {
        /// Lower-case hex APNs device token.
        public var token: String
        /// "sandbox" / "production".
        public var environment: String
        public var locale: String?
        public init(token: String, environment: String, locale: String? = nil) {
            self.token = token
            self.environment = environment
            self.locale = locale
        }
    }

    // ── WebSocket (#286) ────────────────────────────────────────────────────────

    /// Why a `.match` message was sent (unknown → reload).
    public enum MatchEvent: String, Sendable, CaseIterable {
        case created, joined, accepted, declined, turnEnded, turnSaved, matchEnded, quit, diceChanged
    }

    /// Server → client messages on `/v1/matches/{id}/socket`, tagged by `type`.
    public enum ServerMessage: Decodable, Equatable, Sendable {
        case hello(matchID: String, revision: Int, serverTime: Int64)
        /// `event` raw value (see `MatchEvent`) + the new state.
        case match(event: String, match: MatchSnapshot)
        case roll(matchID: String, roll: RollRecord)
        case request(matchID: String, request: OutOfTurnRequest)
        case error(code: String, message: String)
        /// A message type this build does not know: ignore it.
        case unknown(type: String)

        private enum Keys: String, CodingKey {
            case type, matchID, revision, serverTime, event, match, roll, request, error
        }

        private struct ErrorBody: Decodable { var code: String; var message: String }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "hello":
                self = .hello(matchID: try c.decode(String.self, forKey: .matchID),
                              revision: try c.decode(Int.self, forKey: .revision),
                              serverTime: try c.decode(Int64.self, forKey: .serverTime))
            case "match":
                self = .match(event: try c.decode(String.self, forKey: .event),
                              match: try c.decode(MatchSnapshot.self, forKey: .match))
            case "roll":
                self = .roll(matchID: try c.decode(String.self, forKey: .matchID),
                             roll: try c.decode(RollRecord.self, forKey: .roll))
            case "request":
                self = .request(matchID: try c.decode(String.self, forKey: .matchID),
                                request: try c.decode(OutOfTurnRequest.self, forKey: .request))
            case "error":
                let body = try c.decode(ErrorBody.self, forKey: .error)
                self = .error(code: body.code, message: body.message)
            default:
                self = .unknown(type: type)
            }
        }
    }
}

public extension ServerAPI {
    /// The decoder for server responses (base64 `Data` is the default strategy).
    static func decoder() -> JSONDecoder { JSONDecoder() }
    /// The encoder for request bodies.
    static func encoder() -> JSONEncoder { JSONEncoder() }

    /// A `...At` value as a `Date`.
    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
