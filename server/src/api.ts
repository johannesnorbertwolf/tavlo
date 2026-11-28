// The Server v1 wire contract (REFERENCE.md "API contract"): every request body,
// response body and WebSocket message, as runtime schemas + their static types.
// Mirrored in Swift by ios/TavliEngine/Sources/TavliEngine/ServerAPI.swift; both sides
// decode the same server/fixtures/*.json. Change all three together.
//
// Conventions: camelCase keys; times are integer Unix milliseconds (`...At`); opaque
// binary (the match payload, out-of-turn requests) is standard base64; unknown keys are
// ignored by every reader; a key documented as optional is omitted, not null.

import {
  array,
  bool,
  int,
  literal,
  nullable,
  num,
  object,
  optional,
  str,
  tagged,
  type Infer,
} from "./schema";

/** Bumped only for breaking changes; also the `/v1` path prefix. */
export const API_VERSION = 1;
/** Max decoded size of a match payload or an out-of-turn request. */
export const MAX_PAYLOAD_BYTES = 64 * 1024;
/** Number of distinct dice rolls (d1 <= d2), the length of `RollRequest.rollValues`. */
export const ROLL_COUNT = 21;
/** Weighted-dice levels per side (WeightedDice.levels in the app). */
export const DICE_LEVELS = 4;

// ── Shared scalars ────────────────────────────────────────────────────────────

const ID = str({ min: 1, max: 64, pattern: /^[A-Za-z0-9_-]+$/ });
const BASE64 = str({ max: Math.ceil(MAX_PAYLOAD_BYTES / 3) * 4, pattern: /^[A-Za-z0-9+/]*={0,2}$/ });
const MILLIS = int({ min: 0 });

export const Color = literal("W", "B");
export type Color = Infer<typeof Color>;

export const VariantID = literal("plakoto", "plakoto_standard", "fevga", "portes");
export type VariantID = Infer<typeof VariantID>;

/** Games a side must win: 1 = single game, 2 = best-of-three. */
export const TargetWins = int({ min: 1, max: 2 });

/** Points a game can be worth (GameVariant.maxPoints); scales the weighted-dice bend. */
export const VARIANT_MAX_POINTS: Record<VariantID, number> = {
  plakoto: 1,
  plakoto_standard: 2,
  fevga: 2,
  portes: 2,
};

// ── Errors ────────────────────────────────────────────────────────────────────

export const ERROR_CODES = [
  "bad_request", // 400 malformed JSON or a field failed validation (details.path)
  "unauthorized", // 401 missing/invalid access token
  "token_expired", // 401 access token expired: refresh, then retry once
  "forbidden", // 403 not a participant / not allowed
  "not_found", // 404
  "method_not_allowed", // 405
  "stale_revision", // 409 baseRevision is not the match's current revision: reload
  "not_your_turn", // 409 in-turn operation by the waiting player
  "match_ended", // 409 write to an ended match
  "invite_unavailable", // 410 invite expired, cancelled, declined or already used
  "handle_taken", // 409 #301: someone else has that handle (case-insensitive)
  "payload_too_large", // 413
  "upgrade_required", // 426 client build below the server's minimum
  "rate_limited", // 429 see Retry-After
  "internal", // 500
  "not_implemented", // 501 endpoint reserved by the contract, not built yet
  "unavailable", // 503 transient; retry with backoff
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export const ApiError = object({
  error: object({
    code: str({ min: 1, max: 64 }), // an ErrorCode; readers must tolerate unknown codes
    message: str({ max: 500 }),
    requestId: optional(str({ max: 128 })),
    retryAfter: optional(int({ min: 0 })), // seconds (429 / 503), same as Retry-After
    path: optional(str({ max: 200 })), // bad_request: the offending field
    ticket: optional(str({ max: 16 })), // not_implemented: the issue that builds it, e.g. "#286"
  }),
});
export type ApiError = Infer<typeof ApiError>;

// ── Health (#284) ─────────────────────────────────────────────────────────────

const CheckResult = literal("ok", "error");
export const HealthResponse = object({
  /** "degraded" (HTTP 503) only from a deep check with a failing dependency. */
  status: literal("ok", "degraded"),
  service: str(),
  version: str(),
  commit: str(),
  environment: str(),
  apiVersion: int({ min: 1 }),
  time: MILLIS,
  /** Only with `?deep=1`: one D1 query + one Durable Object call. */
  checks: optional(object({ d1: CheckResult, durableObjects: CheckResult })),
});
export type HealthResponse = Infer<typeof HealthResponse>;

// ── Accounts (#285) ───────────────────────────────────────────────────────────

export const DisplayName = str({ min: 1, max: 24 });

/** #301: a handle (find each other by it): 3–20 letters, digits or `_`, unique ignoring case. */
export const HANDLE_PATTERN = /^[A-Za-z0-9_]{3,20}$/;
export const Handle = str({ min: 3, max: 20, pattern: HANDLE_PATTERN });
/** Handles nobody can take (compared lower-case; also anything starting with "tavtav"). */
export const RESERVED_HANDLES = [
  "admin", "administrator", "anonymous", "api", "apple", "computer", "everyone", "google", "help",
  "me", "mod", "moderator", "nobody", "null", "official", "owner", "player", "root", "server",
  "staff", "support", "system", "tavli", "tavlo", "team", "undefined", "you",
] as const;
/** "Who can challenge me" (#301). */
export const ChallengePolicy = literal("everyone", "people");
export type ChallengePolicy = Infer<typeof ChallengePolicy>;
export const AuthProvider = literal("apple", "google");

export const Account = object({
  id: ID, // = the playerID used in matches and in the payload's colorByPlayerID
  displayName: DisplayName,
  providers: array(AuthProvider, { max: 2 }),
  createdAt: MILLIS,
  /** #301: "Show when I'm online" is off — nobody sees this account's presence (always sent). */
  hidePresence: optional(bool()),
  /** #301: the account's handle (always sent). */
  handle: optional(Handle),
  /** #301: true while the (generated) handle may still be changed — once. */
  handleChangeable: optional(bool()),
  /** #301: who may challenge this account (always sent). */
  whoCanChallenge: optional(ChallengePolicy),
});
export type Account = Infer<typeof Account>;

export const AppleSignInRequest = object({
  identityToken: str({ min: 1, max: 8192 }),
  /** The raw nonce whose SHA-256 the app put in the Apple request. */
  nonce: str({ min: 16, max: 128 }),
  /** Apple sends the name only on the very first sign-in; the app forwards it. */
  displayName: optional(DisplayName),
  /**
   * Apple's one-time authorization code (ASAuthorizationAppleIDCredential). With the
   * APPLE_* secrets set the server exchanges it for an Apple refresh token, revoked when
   * the account is deleted; without them it is ignored.
   */
  authorizationCode: optional(str({ min: 1, max: 2048 })),
});
export type AppleSignInRequest = Infer<typeof AppleSignInRequest>;

export const GoogleSignInRequest = object({
  /** The id_token from Google's token endpoint (app-side PKCE code exchange). */
  idToken: str({ min: 1, max: 8192 }),
  nonce: str({ min: 16, max: 128 }),
});
export type GoogleSignInRequest = Infer<typeof GoogleSignInRequest>;

export const RefreshRequest = object({ refreshToken: str({ min: 16, max: 512 }) });
export type RefreshRequest = Infer<typeof RefreshRequest>;

export const AuthSession = object({
  accessToken: str({ min: 16, max: 2048 }),
  accessExpiresAt: MILLIS,
  refreshToken: str({ min: 16, max: 512 }),
  refreshExpiresAt: MILLIS,
  account: Account,
  /** true when this sign-in created the account (the app then asks for a name). */
  isNewAccount: bool(),
});
export type AuthSession = Infer<typeof AuthSession>;

/** PATCH /v1/account: any of the fields (at least one). `hidePresence` since #301. */
export const UpdateAccountRequest = object({
  displayName: optional(DisplayName),
  hidePresence: optional(bool()),
  /** Once, while `handleChangeable` (else 403); taken → 409 `handle_taken`. */
  handle: optional(Handle),
  whoCanChallenge: optional(ChallengePolicy),
});

/** GET /v1/handles/{handle} → can I take it? (`reason` when not). */
export const HandleAvailability = object({
  handle: str({ max: 64 }),
  available: bool(),
  reason: optional(literal("taken", "reserved", "invalid", "yours")),
});
export type HandleAvailability = Infer<typeof HandleAvailability>;
export type UpdateAccountRequest = Infer<typeof UpdateAccountRequest>;

/**
 * `POST /v1/auth/dev` body — **development only** (`ENVIRONMENT = "development"`, i.e.
 * `wrangler dev` and tests; 404 everywhere else): signs in as a made-up Apple subject
 * `dev:<subject>` without a token, so the app can be checked against a local server.
 */
export const DevSignInRequest = object({
  subject: ID,
  displayName: optional(DisplayName),
});
export type DevSignInRequest = Infer<typeof DevSignInRequest>;

// ── Matches (#286) ────────────────────────────────────────────────────────────

/** OnlineParticipantStatus in the app. */
export const ParticipantStatus = literal("invited", "declined", "matching", "active", "done", "unknown");
/** OnlineMatchOutcome in the app (`none` = still playing). */
export const MatchOutcome = literal("none", "quit", "won", "lost", "tied", "timeExpired", "other");

export const Participant = object({
  /** Account id, or null while the seat is unfilled (auto-match, open invite). */
  playerID: nullable(ID),
  displayName: nullable(DisplayName),
  /** Colour for the whole match, fixed when the seat is created: seat 0 (creator) = W. */
  color: Color,
  status: ParticipantStatus,
  outcome: MatchOutcome,
});
export type Participant = Infer<typeof Participant>;

/** The shared weighted-dice slider (#272), held by the server (OnlineDiceHandicap). */
export const DiceHandicap = object({
  /** +n favours White at level n, -n Black, 0 = fair. */
  whiteLevel: int({ min: -DICE_LEVELS, max: DICE_LEVELS }),
  /** Grows by one with every change; 0 = never changed. */
  rev: int({ min: 0 }),
  /** Colour of whoever made the latest change (absent = never changed). */
  by: optional(Color),
});
export type DiceHandicap = Infer<typeof DiceHandicap>;

/** A roll the server drew (RollRequest → this). One per (gameIndex, plyIndex). */
export const RollRecord = object({
  gameIndex: int({ min: 0, max: 2 }),
  plyIndex: int({ min: 0, max: 2000 }),
  player: Color,
  die1: int({ min: 1, max: 6 }),
  die2: int({ min: 1, max: 6 }),
  /** Signed level vs White the roll was bent with (PlyRecord.weighted); absent = fair. */
  weighted: optional(int({ min: -DICE_LEVELS, max: DICE_LEVELS })),
  /** The tilt β_t actually applied (0 / absent = fair draw). For the record and tests. */
  beta: optional(num()),
  rolledAt: MILLIS,
});
export type RollRecord = Infer<typeof RollRecord>;

/** An out-of-turn message (OnlineMatchService.sendRequest), kept until the turn passes. */
export const OutOfTurnRequest = object({
  id: ID,
  from: ID,
  data: BASE64,
  sentAt: MILLIS,
});
export type OutOfTurnRequest = Infer<typeof OutOfTurnRequest>;

/** OnlineMatchSnapshot plus the server-held state. */
export const MatchSnapshot = object({
  matchID: ID,
  /** Increments on every write; writes name the revision they build on. */
  revision: int({ min: 0 }),
  variant: VariantID,
  targetWins: TargetWins,
  /** Who starts game 1, drawn by the server at creation; the payload must agree. */
  startingPlayer: Color,
  /** base64 of the OnlineMatchPayload JSON (opaque), null before the first write. */
  data: nullable(BASE64),
  participants: array(Participant, { min: 2, max: 2 }),
  /** Account id of the turn holder; null when ended or the seat on turn is unfilled. */
  currentPlayerID: nullable(ID),
  isEnded: bool(),
  diceHandicap: DiceHandicap,
  /** The newest server roll (a reconnecting roller reuses it instead of rolling again). */
  lastRoll: nullable(RollRecord),
  /** Out-of-turn requests addressed to the caller, oldest first. */
  requests: array(OutOfTurnRequest, { max: 50 }),
  createdAt: MILLIS,
  updatedAt: MILLIS,
});
export type MatchSnapshot = Infer<typeof MatchSnapshot>;

/** A lobby row, from the caller's point of view (#286 index, #287 lobby). */
export const LobbyState = literal("invited", "yourTurn", "theirTurn", "waitingForOpponent", "ended");

/** Invite codes (#287): 6 characters from an alphabet without look-alikes (no 0 O 1 I L). */
export const INVITE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export const INVITE_CODE_LENGTH = 6;
/** How long an invite stays open. */
export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
export const InviteCode = str({ min: 6, max: 12, pattern: /^[A-Z0-9]+$/ });

/** The open invite of a lobby row, shown to its creator (#287) so it can be shared again. */
export const InviteRef = object({
  code: InviteCode,
  url: str({ max: 300 }),
  expiresAt: MILLIS,
});
export type InviteRef = Infer<typeof InviteRef>;

/** #301: a direct challenge's lifecycle (pending → accepted / declined / expired / cancelled). */
export const ChallengeStatus = literal("pending", "accepted", "declined", "expired", "cancelled");
export type ChallengeStatus = Infer<typeof ChallengeStatus>;
/** An unanswered challenge expires this long after it was sent. */
export const CHALLENGE_TTL_MS = 24 * 60 * 60 * 1000;

/** The challenge behind a lobby row (#301; absent for invites, auto-match and old matches). */
export const ChallengeState = object({
  /** A pending challenge past `expiresAt` reads `expired`. */
  status: ChallengeStatus,
  expiresAt: MILLIS,
});
export type ChallengeState = Infer<typeof ChallengeState>;

export const MatchSummary = object({
  matchID: ID,
  variant: VariantID,
  targetWins: TargetWins,
  state: LobbyState,
  opponent: object({ playerID: nullable(ID), displayName: nullable(DisplayName) }),
  /** The caller's outcome (`none` while running). */
  outcome: MatchOutcome,
  updatedAt: MILLIS,
  /** #287: the caller's open invite for this match's empty seat (absent otherwise). */
  invite: optional(InviteRef),
  /** #301: the direct challenge this match started as (both players see it). */
  challenge: optional(ChallengeState),
});
export type MatchSummary = Infer<typeof MatchSummary>;

export const MatchListResponse = object({
  matches: array(MatchSummary, { max: 200 }),
  /** Opaque; pass as `?cursor=` for the next page. null = no more. */
  nextCursor: nullable(str({ max: 200 })),
});
export type MatchListResponse = Infer<typeof MatchListResponse>;

export const CreateMatchRequest = object({
  variant: VariantID,
  targetWins: TargetWins,
  /**
   * Direct challenge of a known account (#286; the one-tap challenge of the people list,
   * #301: pending for 24 h, a second identical challenge answers the pending one).
   */
  opponentID: optional(ID),
});
export type CreateMatchRequest = Infer<typeof CreateMatchRequest>;

/** end-turn / save-turn body (endTurn / saveTurn). */
export const WriteTurnRequest = object({
  baseRevision: int({ min: 0 }),
  data: BASE64,
});
export type WriteTurnRequest = Infer<typeof WriteTurnRequest>;

/** end-match body (endMatch): the caller's outcome; the opponent gets the opposite. */
export const EndMatchRequest = object({
  baseRevision: int({ min: 0 }),
  data: BASE64,
  outcome: literal("won", "lost", "tied"),
});
export type EndMatchRequest = Infer<typeof EndMatchRequest>;

/** quit body (quit): forfeit in turn (with the final data) or out of turn. */
export const QuitRequest = object({
  inTurn: bool(),
  baseRevision: optional(int({ min: 0 })), // required when inTurn
  data: optional(BASE64), // required when inTurn
});
export type QuitRequest = Infer<typeof QuitRequest>;

/** requests body (sendRequest): opaque, relayed to the other participant. */
export const SendRequestRequest = object({ data: BASE64 });
export type SendRequestRequest = Infer<typeof SendRequestRequest>;

/** dice body: change the shared slider (OnlineDiceRequest semantics). */
export const DiceChangeRequest = object({
  whiteLevel: int({ min: -DICE_LEVELS, max: DICE_LEVELS }),
  /** The newest rev the caller had seen when it started changing. */
  baseRev: int({ min: 0 }),
});
export type DiceChangeRequest = Infer<typeof DiceChangeRequest>;

/** roll body: the turn holder asks the server for its dice. */
export const RollRequest = object({
  gameIndex: int({ min: 0, max: 2 }),
  /** = the current game's plies.count: the ply this roll starts. */
  plyIndex: int({ min: 0, max: 2000 }),
  /**
   * The roller's 21 per-roll 1-ply values (HandicapDice.rollValues), in canonical
   * order 11,12,13,14,15,16,22,23,…,66; each in [0, 1]. Required when the match's
   * dice are weighted (diceHandicap.whiteLevel != 0), ignored when fair.
   */
  rollValues: optional(array(num({ min: 0, max: 1 }), { min: ROLL_COUNT, max: ROLL_COUNT })),
});
export type RollRequest = Infer<typeof RollRequest>;

// ── Invites, auto-match, lobby, push (#287) ──────────────────────────────────

export const CreateInviteRequest = object({ variant: VariantID, targetWins: TargetWins });
export type CreateInviteRequest = Infer<typeof CreateInviteRequest>;

export const Invite = object({
  code: InviteCode,
  /** Universal link: https://<worker host>/join/<code>. */
  url: str({ max: 300 }),
  expiresAt: MILLIS,
  match: MatchSnapshot,
});
export type Invite = Infer<typeof Invite>;

export const InvitePreview = object({
  code: InviteCode,
  from: object({ playerID: ID, displayName: DisplayName }),
  variant: VariantID,
  targetWins: TargetWins,
  status: literal("open", "accepted", "declined", "cancelled", "expired"),
  expiresAt: MILLIS,
});
export type InvitePreview = Infer<typeof InvitePreview>;

export const AutoMatchRequest = object({ variant: VariantID, targetWins: TargetWins });
export type AutoMatchRequest = Infer<typeof AutoMatchRequest>;

export const PushTokenRequest = object({
  /** APNs device token, hex. */
  token: str({ min: 32, max: 200, pattern: /^[0-9a-f]+$/ }),
  environment: literal("sandbox", "production"),
  /** BCP 47, for localized push text (en, el, de, nl, fa). */
  locale: optional(str({ max: 35 })),
});
export type PushTokenRequest = Infer<typeof PushTokenRequest>;

/** Why a push was sent. Readers must tolerate unknown kinds (open the match). */
export const PushKind = literal(
  "yourTurn",
  "inviteReceived",
  "inviteAccepted",
  "matchEnded",
  "opponentLeft",
  // #301: one-tap challenges.
  "challengeReceived",
  "challengeAccepted",
  "challengeDeclined",
);
export type PushKind = Infer<typeof PushKind>;

/**
 * The APNs payload the server sends (#287). The text is localized on the device: `loc-key`
 * names a string in the app's Localizable strings (`PUSH_*`), `loc-args` fills its `%@`
 * (the other player's name). `matchID` opens the match when the push is tapped.
 */
export const PushPayload = object({
  aps: object({
    alert: object({
      "loc-key": str({ max: 64 }),
      "loc-args": array(str({ max: 64 }), { max: 4 }),
      /** #301 (challengeReceived): bold first line, e.g. PUSH_CHALLENGE_RECEIVED "%@ wants to play". */
      "title-loc-key": optional(str({ max: 64 })),
      "title-loc-args": optional(array(str({ max: 64 }), { max: 4 })),
    }),
    sound: optional(str({ max: 32 })),
    "thread-id": optional(str({ max: 64 })),
    /** #301: the notification category (CHALLENGE = Accept / Decline action buttons). */
    category: optional(str({ max: 64 })),
  }),
  matchID: ID,
  /** A PushKind; readers tolerate unknown values. */
  kind: str({ max: 32 }),
});
export type PushPayload = Infer<typeof PushPayload>;

/** #301: the APNs category of an incoming challenge (the app registers Accept / Decline). */
export const CHALLENGE_CATEGORY = "CHALLENGE";

// ── People, presence, challenges (#301) ──────────────────────────────────────

/** An unpinned person drops off the list after this long without a game. */
export const PEOPLE_MAX_AGE_MS = 90 * 24 * 60 * 60 * 1000;
/** At most this many people are listed (pinned first, then the most recent). */
export const PEOPLE_LIMIT = 100;
/** "Online now" = a presence socket with a keepalive this recent (the app pings every 30 s). */
export const PRESENCE_ONLINE_MS = 2 * 60 * 1000;

/** Someone's online status, only for people you've played with who don't hide it. */
export const Presence = object({
  online: bool(),
  /** When the app was last in front (null = never seen since presence exists). */
  lastSeenAt: nullable(MILLIS),
});
export type Presence = Infer<typeof Presence>;

/** A pending challenge between the caller and this person. */
export const PersonChallenge = object({
  matchID: ID,
  /** incoming = they challenged you; outgoing = you are waiting for them. */
  direction: literal("incoming", "outgoing"),
  variant: VariantID,
  targetWins: TargetWins,
  expiresAt: MILLIS,
});
export type PersonChallenge = Infer<typeof PersonChallenge>;

export const Person = object({
  playerID: ID,
  handle: Handle,
  displayName: DisplayName,
  /** ⭐ — kept on top (also how someone found by handle is added). */
  pinned: bool(),
  /** The newest game with this person (any activity); null = added, never played. */
  lastPlayedAt: nullable(MILLIS),
  /** Absent when the person hides it. */
  presence: optional(Presence),
  challenge: optional(PersonChallenge),
});
export type Person = Infer<typeof Person>;

/** A player as strangers see them: handle + display name, nothing else. */
export const PlayerCard = object({ playerID: ID, handle: Handle, displayName: DisplayName });
export type PlayerCard = Infer<typeof PlayerCard>;

/** GET /v1/people: pinned first, then the most recent game first; `blocked` = whom you blocked. */
export const PeopleResponse = object({
  people: array(Person, { max: PEOPLE_LIMIT }),
  blocked: optional(array(PlayerCard, { max: 200 })),
});

/** Search results per query (prefix of the handle, exact match first). */
export const SEARCH_LIMIT = 20;
export const SEARCH_MIN_CHARS = 3;

export const PlayerResult = object({
  playerID: ID,
  handle: Handle,
  displayName: DisplayName,
  /** Already in your people list. */
  isPerson: bool(),
  /** Their "who can challenge me" lets you. */
  canChallenge: bool(),
});
export type PlayerResult = Infer<typeof PlayerResult>;

/** GET /v1/players?q=<≥3 chars> (rate-limited per account). */
export const PlayerSearchResponse = object({ players: array(PlayerResult, { max: SEARCH_LIMIT }) });
export type PlayerSearchResponse = Infer<typeof PlayerSearchResponse>;
export type PeopleResponse = Infer<typeof PeopleResponse>;

/** PATCH /v1/people/{playerID}. */
export const UpdatePersonRequest = object({ pinned: bool() });
export type UpdatePersonRequest = Infer<typeof UpdatePersonRequest>;

const PlayerRef = object({ playerID: ID, displayName: DisplayName });

/** A challenge as the presence socket reports it. */
export const Challenge = object({
  matchID: ID,
  from: PlayerRef,
  to: PlayerRef,
  variant: VariantID,
  targetWins: TargetWins,
  status: ChallengeStatus,
  createdAt: MILLIS,
  expiresAt: MILLIS,
});
export type Challenge = Infer<typeof Challenge>;

/**
 * Server → client on /v1/presence/socket (one per app in the foreground). `challenge.event`:
 * received (to the challenged), accepted / declined (to the challenger), expired (both),
 * cancelled (to the challenged). Readers ignore unknown types and events.
 */
export const PresenceMessage = tagged("type", {
  hello: object({ serverTime: MILLIS }),
  presence: object({ playerID: ID, online: bool(), lastSeenAt: nullable(MILLIS) }),
  challenge: object({ event: str({ max: 32 }), challenge: Challenge }),
  error: object({ error: object({ code: str({ max: 64 }), message: str({ max: 500 }) }) }),
});
export type PresenceMessage = Infer<typeof PresenceMessage>;

// ── WebSocket (#286) ──────────────────────────────────────────────────────────

/** Why a `match` message was sent. Readers must tolerate unknown events (reload). */
export const MatchEvent = literal(
  "created",
  "joined",
  "accepted",
  "declined",
  "turnEnded",
  "turnSaved",
  "matchEnded",
  "quit",
  "diceChanged",
);

/** Server → client messages on /v1/matches/{id}/socket. */
export const ServerMessage = tagged("type", {
  hello: object({ matchID: ID, revision: int({ min: 0 }), serverTime: MILLIS }),
  match: object({ event: str({ max: 32 }), match: MatchSnapshot }),
  roll: object({ matchID: ID, roll: RollRecord }),
  request: object({ matchID: ID, request: OutOfTurnRequest }),
  error: object({ error: object({ code: str({ max: 64 }), message: str({ max: 500 }) }) }),
});
export type ServerMessage = Infer<typeof ServerMessage>;

/** Client → server keepalive, answered by the runtime without waking the DO. */
export const WS_PING = '{"type":"ping"}';
export const WS_PONG = '{"type":"pong"}';
