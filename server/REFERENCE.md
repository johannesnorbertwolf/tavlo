# server/ — reference

The Tavtav online server (Server v1, epic #278): replaces Game Center turn-based matches
with our own service on **Cloudflare Workers + Durable Objects (SQLite backend) + D1, Free
plan**. This file is the **API contract** every Server v1 ticket builds against, the
server-side design notes, and the **ops runbook**.

Ticket map: **#284** foundation (this scaffold, contract, ops) · **#285** accounts ·
**#286** matches, server dice, WebSocket · **#287** invites, auto-match, lobby, push ·
**#301** people, presence, one-tap challenges, handles, search, blocks ·
**#288** remove Game Center + release.

## Architecture

```
iOS app ──HTTPS /v1/…──► Worker (src/index.ts) ──► D1 "DB": accounts, identities, match_index, ops_alerts
        ◄──WebSocket────┘        │
                                 └──RPC / fetch──► MatchRoom Durable Object, one per match (SQLite storage):
                                                   participants, turn holder, opaque payload + revision,
                                                   dice slider, roll log, pending requests, sockets
```

- **Worker** — stateless: routing (`src/routes.ts` = the endpoint table below), auth
  (#285), rate limits, error format, request logs, `/health`, hourly usage cron.
- **MatchRoom** (`src/match-room.ts`) — the single writer for one match: every operation on
  a match is serialised by the object, so turn rules and revisions need no locks. Hibernatable
  WebSockets (no duration billing while idle; `{"type":"ping"}` → `{"type":"pong"}` is
  answered by the runtime without waking it). Storage schema is migrated in-object
  (`ROOM_MIGRATIONS`, append-only, version in table `meta`).
- **D1** — what must be queried across matches: accounts + sign-in identities and each
  player's lobby rows (`match_index`, written by the MatchRoom after each state change).
  The MatchRoom stays the source of truth; the index may lag by one write.
- The **match payload stays opaque**: the server stores the app's `OnlineMatchPayload` bytes
  as-is. What the server must know (turn holder, outcomes, dice slider, rolls) lives in the
  envelope and the room's own tables. #286 may read exactly one thing from the payload: the
  dice of newly appended plies, to check them against the roll log ("Server dice").

### Free-plan budget

| Resource | Free limit | How we stay under |
|---|---|---|
| Worker requests | 100,000 / day (account) | coalesced live-turn writes (≤1/s, 2–4 per turn), WebSocket instead of polling, poll fallback backs off 5 → 60 s |
| Durable Object requests | 100,000 / day; WebSocket messages count 20:1 | hibernation; auto-answered pings are free |
| DO duration | 13,000 GB-s / day | hibernation, no timers while idle |
| D1 | 5 M rows read, 100 k rows written / day, 5 GB | one index row per player per state change |
| Cron triggers | 5 per account | one per environment (usage check) |
| Presence (#301) | (DO requests + duration) | one hibernatable socket per **foreground** app to one `PresenceHub`; its 30 s pings are auto-answered (free, no wake); the hub wakes only for connect / close / a people lookup / a challenge event; no alarms |

## API contract

### Basics

- **Base URL**: `https://tavtav-server-staging.<subdomain>.workers.dev` (staging),
  `https://tavtav-server.<subdomain>.workers.dev` (production); a custom domain can come later
  (then also the universal-link host: today the invite links are `https://<worker host>/join/<code>`).
- **Versioning**: the major version is the path prefix (`/v1`) and the `X-Tavtav-Api: 1`
  response header. Within v1 changes are **additive only**: new endpoints, new optional
  request fields, new response fields, new enum values / error codes / WebSocket message
  types / match events. Readers ignore unknown keys and map unknown values to a fallback
  (Swift: `unknown`/`other`, raw-string error codes and events). A breaking change means
  `/v2` served alongside `/v1` until old builds are gone. Server code bumps `SERVER_VERSION`
  (`src/version.ts` = `package.json` version).
- **Client header**: every request sends `X-Tavtav-Client: ios/<version> (<build>)`. The
  server may answer `426 upgrade_required` for builds below a minimum (none yet).
- **Auth** (#285): `Authorization: Bearer <accessToken>` on every endpoint marked *auth*.
  Access tokens are short-lived (1 h); on `401 token_expired` the app calls
  `/v1/auth/refresh` once and retries. Refresh tokens rotate on every use. Missing, forged or
  revoked → `401 unauthorized` (sign in again). Details: "Accounts" below.
- **Bodies**: JSON, `Content-Type: application/json`, camelCase. Times are integer Unix
  **milliseconds** (`…At`). Opaque bytes (`data`) are standard **base64** (Swift's default
  `Data` coding); decoded size ≤ 64 KiB (`MAX_PAYLOAD_BYTES`). A key documented as optional
  is omitted, never `null`; *nullable* keys are always present.
- **Ids**: `[A-Za-z0-9_-]{1,64}`; accounts `acc_…`, matches `m_…`. The **account id is the
  player id** of the match payload's `colorByPlayerID` (replacing `gamePlayerID`).
- **Variants**: `plakoto` (house), `plakoto_standard`, `fevga`, `portes`
  (`GameVariant.id`); `targetWins` 1 (single game) or 2 (best of three).
- **Every response** carries `X-Request-Id` (Cloudflare ray id) and `Cache-Control: no-store`.

### Errors

Every error is `{"error": {"code", "message", "requestId"?, "retryAfter"?, "path"?, "ticket"?}}`
with the HTTP status below. `message` is for logs, not for players; the app maps codes to
localized copy.

| Code | HTTP | Meaning / client reaction |
|---|---|---|
| `bad_request` | 400 | Invalid JSON or field (`path` names it). Bug: don't retry. |
| `unauthorized` | 401 | No/invalid token: sign in again. |
| `token_expired` | 401 | Refresh, retry once. |
| `forbidden` | 403 | Not a participant / not allowed. |
| `not_found` | 404 | Unknown match, invite or route. |
| `method_not_allowed` | 405 | `Allow` header lists methods. |
| `stale_revision` | 409 | `baseRevision` ≠ current: `load`, re-apply, resend (the controller's unsent-turn path). |
| `not_your_turn` | 409 | In-turn op by the waiting player: `load`. |
| `match_ended` | 409 | Write to an ended match: `load`. |
| `invite_unavailable` | 410 | Invite expired, cancelled, declined or used; #301: a challenge that is no longer pending. |
| `handle_taken` | 409 | #301: someone else has that handle (case-insensitive). |
| `payload_too_large` | 413 | `data` over 64 KiB. |
| `upgrade_required` | 426 | Show "update the app". |
| `rate_limited` | 429 | Wait `retryAfter` s (also `Retry-After`). |
| `internal` | 500 | Retry with backoff. |
| `not_implemented` | 501 | Endpoint reserved; `ticket` names who builds it. |
| `unavailable` | 503 | Transient; retry with backoff. |

### Endpoints

Every endpoint is in the route table (`src/routes.ts`); until its ticket lands it answers
`501 not_implemented` with that ticket. Types are in `src/api.ts` / `ServerAPI.swift`.

| Method + path | Auth | Body → response | Mirrors | Ticket |
|---|---|---|---|---|
| `GET /health` (`?deep=1`) | – | → `HealthResponse` (503 if a deep check fails) | – | **#284 ✓** |
| `POST /v1/auth/apple` | – | `AppleSignInRequest` → `AuthSession` | – | **#285 ✓** |
| `POST /v1/auth/google` | – | `GoogleSignInRequest` → `AuthSession` (503 until `GOOGLE_CLIENT_IDS` is set) | – | **#285 ✓** |
| `POST /v1/auth/refresh` | – | `RefreshRequest` → `AuthSession` | – | **#285 ✓** |
| `POST /v1/auth/dev` | – | `DevSignInRequest` → `AuthSession`; **development only** (404 in staging/production) | – | **#285 ✓** |
| `POST /v1/auth/logout` | auth | `RefreshRequest` → 204 | – | **#285 ✓** |
| `GET /v1/account` | auth | → `Account` | – | **#285 ✓** |
| `PATCH /v1/account` | auth | `UpdateAccountRequest` → `Account` | – | **#285 ✓** |
| `DELETE /v1/account` | auth | → 204 | – | **#285 ✓** |
| `GET /v1/matches` (`?state=active\|ended&cursor=`) | auth | → `MatchListResponse` | lobby list | **#286 ✓** (index), **#287 ✓** (`invite` on waiting rows) |
| `POST /v1/matches` | auth | `CreateMatchRequest` → 201 `MatchSnapshot` (#301: 200 = the pending challenge again, or the crossed one accepted; 403 blocked / "only my people") | create (direct challenge) | **#286 ✓**, **#301 ✓** |
| `GET /v1/matches/{id}` | auth | → `MatchSnapshot` | `load` | **#286 ✓** |
| `POST /v1/matches/{id}/accept` | auth | – → `MatchSnapshot` | `acceptInvite` | **#286 ✓** |
| `POST /v1/matches/{id}/decline` | auth | – → 204 | (invite declined) | **#286 ✓** |
| `POST /v1/matches/{id}/end-turn` | auth | `WriteTurnRequest` → `MatchSnapshot` | `endTurn` | **#286 ✓** |
| `POST /v1/matches/{id}/save-turn` | auth | `WriteTurnRequest` → `MatchSnapshot` | `saveTurn` (live turn #269) | **#286 ✓** |
| `POST /v1/matches/{id}/end-match` | auth | `EndMatchRequest` → `MatchSnapshot` | `endMatch` | **#286 ✓** |
| `POST /v1/matches/{id}/quit` | auth | `QuitRequest` → `MatchSnapshot` | `quit` | **#286 ✓** |
| `POST /v1/matches/{id}/requests` | auth | `SendRequestRequest` → 202 `{id}` | `sendRequest` | **#286 ✓** |
| `POST /v1/matches/{id}/dice` | auth | `DiceChangeRequest` → `DiceHandicap` | shared slider (#272) | **#286 ✓** |
| `POST /v1/matches/{id}/roll` | auth | `RollRequest` → `RollRecord` | (was local roll) | **#286 ✓** |
| `GET /v1/matches/{id}/socket` | auth | WebSocket upgrade | GameKit turn events | **#286 ✓** |
| `DELETE /v1/matches/{id}` | auth | → 204 (hide an ended match) | lobby "Remove" | **#287 ✓** |
| `POST /v1/invites` | auth | `CreateInviteRequest` → `Invite` | invite friend | **#287 ✓** |
| `GET /v1/invites/{code}` | auth | → `InvitePreview` | – | **#287 ✓** |
| `POST /v1/invites/{code}/accept` | auth | – → `MatchSnapshot` | join by link/code | **#287 ✓** |
| `POST /v1/invites/{code}/decline` | auth | – → 204 | – | **#287 ✓** |
| `DELETE /v1/invites/{code}` | auth | → 204 (creator cancels) | – | **#287 ✓** |
| `POST /v1/automatch` | auth | `AutoMatchRequest` → `MatchSnapshot` | GameKit auto-match | **#287 ✓** |
| `PUT /v1/push-tokens` | auth | `PushTokenRequest` → 204 | – | **#287 ✓** |
| `DELETE /v1/push-tokens/{token}` | auth | → 204 | – | **#287 ✓** |
| `GET /.well-known/apple-app-site-association` | – | AASA JSON | universal links | **#287 ✓** |
| `GET /join/{code}` | – | HTML fallback (App Store link) | – | **#287 ✓** |
| `POST /v1/matches/{id}/cancel` | auth | – → 204 (challenger takes a pending challenge back) | – | **#301 ✓** |
| `GET /v1/people` | auth | → `PeopleResponse` (people + presence + pending challenges, `blocked`) | – | **#301 ✓** |
| `PATCH /v1/people/{playerID}` | auth | `UpdatePersonRequest {pinned}` → 204 (⭐; pinning someone found by handle adds them) | – | **#301 ✓** |
| `DELETE /v1/people/{playerID}` | auth | → 204 (off the list until the next game) | – | **#301 ✓** |
| `POST` / `DELETE /v1/people/{playerID}/block` | auth | → 204 (block / unblock) | – | **#301 ✓** |
| `GET /v1/players?q=` | auth | → `PlayerSearchResponse` (handle prefix, ≥ 3 chars, `SEARCH_LIMITER` 30/min) | – | **#301 ✓** |
| `GET /v1/handles/{handle}` | auth | → `HandleAvailability` | – | **#301 ✓** |
| `GET /v1/presence/socket` | auth | WebSocket upgrade (`PresenceMessage`) | – | **#301 ✓** |

### Accounts (#285)

Code: `src/accounts.ts` (handlers), `src/identity.ts` (provider token verification + JWKS
cache), `src/sessions.ts` (our tokens), `src/jwt.ts` (WebCrypto JWT helpers),
`src/apple-revoke.ts` (Apple token exchange/revocation), `src/account-hooks.ts` (deletion
hooks). App side: `ServerAuth.swift` (`AuthClient`) in TavliEngine.

- **Nonce (both providers)**: the app makes a random raw nonce and puts its **SHA-256,
  lowercase hex** into the provider request (Apple `request.nonce`; Google `nonce=` URL
  parameter). The sign-in body carries the **raw** nonce; the server requires
  `token.nonce == sha256hex(raw)`. So the raw value never appears in a provider URL.
- **Apple** (`POST /v1/auth/apple`): `identityToken` is an RS256 JWT verified against
  `https://appleid.apple.com/auth/keys`: `alg` RS256 with a known `kid`, signature, `iss`
  `https://appleid.apple.com`, `aud` = `com.plakoto.TavliApp` (`APPLE_BUNDLE_ID`), `exp` (60 s
  skew), `iat` not in the future, `sub` present, nonce. Identity key `(apple, sub)`. Apple sends
  the name only on the very first sign-in, so the app forwards it as `displayName` (used only
  when the account is created). Optional `authorizationCode`: see "Apple token revocation".
- **Google** (`POST /v1/auth/google`): the app runs OAuth (authorization code + PKCE S256,
  scope `openid`, iOS client, redirect `com.googleusercontent.apps.<id>:/oauthredirect`) in
  `ASWebAuthenticationSession`, exchanges the code at `https://oauth2.googleapis.com/token`
  itself (iOS clients have no secret) and sends the `id_token`. Verified against
  `https://www.googleapis.com/oauth2/v3/certs`: RS256, `iss` `https://accounts.google.com` or
  `accounts.google.com`, `aud` ∈ `GOOGLE_CLIENT_IDS` (var, comma separated; empty → 503
  `unavailable`), `exp`, `iat`, `sub`, nonce.
- **JWKS cache**: per isolate, `Cache-Control: max-age` (default 1 h, ≤ 24 h); a token with an
  unknown `kid` refetches at most once a minute (key rotation); JWKS fetch failure → 503.
  Any verification failure → `401 unauthorized` ("Identity token rejected: <why>").
- **Accounts**: first sign-in of a `(provider, sub)` creates `accounts` (`acc_` + 16 random
  base64url chars) + `account_identities` rows in one batch (a concurrent duplicate falls back
  to the winner's account); `isNewAccount: true` makes the app ask for a display name. Until
  then the name is `Player NNNN` (or Apple's name). Returning sign-ins update `last_seen_at`
  (also on refresh). **No e-mail is stored**; the provider token is not kept.
- **Display name rule** (`normalizeDisplayName`, mirrored by Swift `DisplayNameRule`): NFC,
  whitespace runs → one space, trimmed, 1…24 UTF-16 units, no control / private-use /
  unassigned / format characters except ZWNJ + ZWJ (Persian). Invalid → 400 `path:
  "displayName"`.
- **Sessions** (`src/sessions.ts`, table `sessions`, migration `0002`):
  - Access token `at_<base64url(JSON {v:1, sub: accountID, sid: sessionID, exp: ms})>.<base64url
    HMAC-SHA256>`, 1 h, **stateless** (verified with `SESSION_KEY`; no D1 read per request).
    Consequence: after logout or deletion an access token keeps passing the signature check
    until it expires (≤ 1 h); the account endpoints read the account row and answer 401 when it
    is gone. The match endpoints (#286) do the same where it matters: create reads the
    caller's account row (401 when gone); every other match op is refused by the room once
    the deletion hook marked the seat deleted (401 `unauthorized`); logout leaves the token
    working on that device for ≤ 1 h (same player, accepted).
  - Refresh token `rt_<32 random bytes base64url>`, 60 days, stored only as SHA-256 hex
    (`refresh_hash`). `POST /v1/auth/refresh` rotates it (new access + refresh token, same
    session row, `previous_hash` = the old hash; the update is conditional on the old hash, so
    two concurrent refreshes cannot both win). Presenting a rotated token again (theft signal,
    or a lost response) deletes the session → 401, the app signs in again. Expired → 401.
  - `POST /v1/auth/logout` (auth + body `refreshToken`) deletes the caller's session (by `sid`
    and by the refresh token's hash, only rows of the caller's account); other devices stay
    signed in. The hourly cron also deletes expired sessions (`pruneSessions`).
  - Missing `SESSION_KEY` → 503 in staging/production; `ENVIRONMENT=development`
    (`wrangler dev`, tests) falls back to a fixed development key.
  - The per-account limiter (`ACCOUNT_LIMITER`, 240/min) runs right after token verification
    for every `auth: "required"` route. Unbuilt routes still answer 501 before auth.
- **`DELETE /v1/account`**: 401 if the account is gone; reads the Apple refresh tokens; runs
  `ACCOUNT_DELETION_HOOKS` with `{accountID, matchIDs}` (from `match_index`; a throwing hook
  aborts with 500 and deletes nothing); deletes the `accounts` row, which cascades identities
  (provider subjects + Apple token), sessions and the account's `match_index` rows; then
  revokes Apple tokens in the background. **#286's hook** (`endMatchesOfDeletedAccount`,
  `src/matches.ts`) calls `MatchRoom.accountDeleted` for each match: a running match ends as
  the player's quit (the opponent wins, event `quit`), the seat's `displayName` → null and
  `deleted` (refused from then on), its sockets close with 4403, and the opponent of a match
  that ended gets the "opponent left" push; **#287's** `deletePushTokensOfDeletedAccount`
  (`src/push.ts`) then deletes the account's device tokens. Signing in again with the same
  Apple/Google identity afterwards creates a new, empty account.
- **Apple token revocation** (App Review 5.1.1(v); `src/apple-revoke.ts`), behind config:
  with the secrets `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` (Sign in with Apple
  key `.p8`) the server, after an Apple sign-in that carried `authorizationCode`, exchanges it
  in the background (`POST https://appleid.apple.com/auth/token`, client secret = ES256 JWT
  `iss` team, `sub` bundle id, `aud` `https://appleid.apple.com`, 5 min) and stores Apple's
  refresh token in `account_identities.provider_refresh_token`; on deletion it calls
  `POST https://appleid.apple.com/auth/revoke` (`token_type_hint=refresh_token`). Without the
  secrets both steps are skipped and logged (`apple.exchange.skipped` / `apple.revoke.skipped`);
  everything else works the same. Accounts created before the key existed have no stored
  token until their next Apple sign-in.
- **Development sign-in** (`POST /v1/auth/dev {subject, displayName?}`): only when
  `ENVIRONMENT=development` (else 404). Signs in as the Apple identity `dev:<subject>` without
  a token, so the app (DEBUG, simulator) can be checked against `npm run dev`.

### Match operations (#286) — `OnlineMatchService` semantics

The server keeps per match: two **seats** (`participants`, seat 0 = creator = White, seat 1 =
Black), `currentPlayerID`, `isEnded`, the opaque `data`, a **revision** (the version of
`data`: +1 per data write — end-turn, save-turn, end-match, in-turn quit; accept/decline, dice
changes, requests, rolls and out-of-turn quits leave it), the **dice slider**, the **roll
log** and pending out-of-turn **requests**. The snapshot is `OnlineMatchSnapshot` + these
extras, so `ServerMatchService` maps it 1:1 (`ServerAPI.MatchSnapshot.onlineSnapshot`, which
also carries `startingPlayer` and the server's `diceHandicap` as `serverDice`).

Implementation (`src/match-room.ts`): the room is addressed by match id
(`MATCH_ROOM.getByName(id)`); storage = `ROOM_MIGRATIONS` step 2 (`match` one row, `seats`,
`rolls`, `requests`). Each operation is one synchronous SQLite transaction (nothing
interleaves), then the room fans the event out to its sockets and upserts the lobby rows in
D1 (`match_index`, `WHERE excluded.updated_at >= updated_at`, so a late index write never
overwrites a newer one; a failed index write is logged, the op still succeeds). RPC methods
return `RoomResult` (`{ok, value} | {ok: false, error: {code, message, path?}}`) because
exceptions lose their fields over RPC; `src/matches.ts` turns it into the error response.
Checks, in order: match exists (404) → caller is a seat (403) → seat not deleted (401) →
match running (409 `match_ended`) → holds the turn (409 `not_your_turn`) → seat accepted (403)
→ `baseRevision` (409 `stale_revision`) → payload size/shape + dice (400/413).

- **Create** (`POST /v1/matches` → **201**, also used internally by invites/auto-match): caller
  in seat 0, `currentPlayerID` = caller, `data = null`, `revision 0`; the server draws
  `startingPlayer` (W/B, crypto RNG; house `plakoto` always W, as `GameVariant.startingPlayer`)
  which the creator writes into its first payload. Seat 1 is `invited` (direct challenge
  `opponentID` / invite) or `matching` (no opponent, `playerID null`). The Worker reads both
  account rows from D1 first (caller gone → 401, unknown opponent → 404 `path: opponentID`,
  yourself → 400). As with GameKit the creator may play its first turn before the seat is
  filled or accepted; the turn then waits on the seat.
- **Optimistic concurrency**: every write carries `baseRevision` = the revision it builds on.
  Mismatch → `409 stale_revision` (no change). **Idempotent retry**: if the same caller resends
  the identical write that produced the current revision (`baseRevision == revision − 1`, same
  bytes, same op), the server answers 200 with the current snapshot instead of 409 (also after
  the turn passed or the match ended — that is the lost-reply case). Only the turn holder
  writes data, so a stale write means the writer missed its own last answer.
- **end-turn**: caller must hold the turn and the match must be running; stores `data`, hands
  the turn to the other seat (unfilled seat → `currentPlayerID null` until it is filled),
  clears requests addressed to the caller. Event `turnEnded`; push "your turn" (#287).
- **save-turn**: same checks, stores `data`, keeps the turn (live turn #269: the payload's
  `liveTurn`). Event `turnSaved`; no push. The app's `LiveTurnTiming` coalescing stays.
- **end-match**: caller holds the turn; stores `data`; caller's outcome = `outcome`, the other
  seat gets the opposite (`won`↔`lost`, `tied`↔`tied`), except a seat that already quit keeps
  `quit`; `isEnded = true`, `currentPlayerID = null`. Event `matchEnded`.
- **quit**: `inTurn: true` requires the turn plus `baseRevision`/`data` (the final state),
  `inTurn: false` requires *not* holding it; the caller's outcome becomes `quit`, status
  `done`. With two seats the match then ends (opponent `won`, `isEnded`) — the opponent's
  controller sees `.quit` and shows `opponentLeft`. Event `quit`.
  Out of turn with a seat still `invited`/`matching`, that seat keeps outcome `none`.
- **accept** / **decline**: only the invited seat; accept → `active`, event `accepted` (again
  on an active seat = 200, no change); decline → `declined`, the other seat `done`, match
  ends, outcomes stay `none` (not a forfeit), event `declined`. A seat must be `active` to
  write or roll (the controller accepts before opening).
- **requests** (`sendRequest`): opaque `data` from either participant to the other, kept in the
  room until the recipient's turn ends (then dropped) and delivered over the socket at once
  (`request` message) and in `snapshot.requests` (recipient only). Max 50 pending (then 429
  `rate_limited`). With our server the app no longer needs them for the dice (see **dice**).
- **dice** (shared weighted-dice slider #272): the **server** is now the single writer, so the
  turn-holder/exchange dance is unnecessary. Either player may change it at any time with
  `{whiteLevel, baseRev}`; accepted iff `baseRev >= current.rev || current.by == caller's
  colour` (`OnlineDiceRequest.isAccepted(over:)`), then `rev + 1`, `by` = caller's colour.
  Refused → 409 `stale_revision` with the current value in a reload. Event `diceChanged`.
  The same value again is answered without a new rev.
  The payload's `diceHandicap` key may still be written by the app but the server's value wins.
- **load** returns the snapshot; **list** returns `MatchSummary` rows from D1, newest first
  (`updated_at DESC, match_id DESC`), 50 per page, `nextCursor` = `<updatedAt>~<matchID>`;
  `?state=active` = not ended, `ended` = ended; the opponent's name is joined from `accounts`
  (null once deleted). Lobby state per player: `ended` (match over / declined), `invited`
  (my seat not accepted), `yourTurn` (I hold the turn, even before the seat is accepted),
  `waitingForOpponent` (other seat unfilled / invited), else `theirTurn`.

### Server dice (#286)

The roller asks the server for its dice; no client can choose them.

- `POST /v1/matches/{id}/roll {gameIndex, plyIndex, rollValues?}` — only the turn holder,
  only while the match runs. `plyIndex` = the current game's `plies.count`. **Idempotent per
  `(gameIndex, plyIndex)`**: asking again returns the recorded roll (a reconnect never
  rerolls; another player's roll for that ply → 400 `path: plyIndex`). A new roll only for
  the ply the game waits for: the next ply of the stored last game
  (`gameIndex = games − 1, plyIndex = its plies`) or the first ply of the game the caller is
  starting (`gameIndex = games, plyIndex 0`, its write may still be on the way); anything
  else → 400 `path: plyIndex` (no rolling ahead). The snapshot's `lastRoll` is the newest
  roll; the `roll` socket message tells the sockets at once (the app shows the dice from the
  mover's live write, which follows immediately).
- **Fair dice** (`diceHandicap.whiteLevel == 0`): two independent faces from
  `crypto.getRandomValues` (rejection sampling, no modulo bias); `rollValues` ignored.
- **Weighted dice**: `rollValues` is **required** — the roller's 21 one-ply values
  (`HandicapDice.rollValues`) in canonical order `11 12 13 14 15 16 22 23 24 25 26 33 34 35
  36 44 45 46 55 56 66` (`HandicapDice.outcomes`), each finite and in [0, 1] (validated: else
  400). The server ports the app's hybrid bend (`src/dice.ts`; `HandicapDice`, keep in sync —
  `test/dice.test.ts` checks every hybrid row of the Python parity table,
  `test/data/weighted-dice-parity.json`, written by `ios/scripts/make_weighted_dice_parity.py`
  together with the Swift `WeightedDiceModesTests` table):
  - `level = |whiteLevel|`, favoured = White if `whiteLevel > 0`, else Black; mode hybrid,
    g = `[0.1, 0.2, 0.35, 0.5][level−1]` pp (`WeightedDiceMode.hybrid.strengths`);
    `maxPoints` per variant (`VARIANT_MAX_POINTS`: plakoto 1, others 2).
  - β = `hybridBeta(values, g, maxPoints)` = min(fixed-gain bisection β with cap 3×, κ_max 0.3
    / max(σ, 0.01/maxPoints)) when the roller is the favoured side; the **mirrored** β =
    −hybridBeta(−values) for the other side (#271).
  - Draw: `weightedFaces(u1, u2, values, β)` — inverse CDF over the 36 ordered outcomes
    weighted by `exp(β·(v − vmax))`, with `u1, u2` uniform from `crypto.getRandomValues`.
  - Recorded as `RollRecord {die1, die2, weighted: whiteLevel, beta}`; the app stamps
    `weighted` into its `PlyRecord.weighted`, so the log shows the bend every roll used.
  - The values come from the roller's own model, so a modified client could skew its β by
    lying about values; bounds: values in [0, 1], β capped by the hybrid rule. Accepted risk
    for v1 (the slider is a friendly handicap both players see). The room keeps the values
    per roll (`rolls.roll_values`) and logs them with each weighted roll (`match.roll`).
- **Enforcement** (`src/payload.ts` reads only `games[g].plies[p].die1/die2`): on **every**
  data write (`end-turn`, `save-turn` — a finished game rolls into the next one with a
  save-turn when the winner starts it —, `end-match`, in-turn `quit`) every ply must match the
  roll log for its `(game, ply)` (either order of the two dice) and a ply new since the
  stored data must be the caller's own roll; else `400 bad_request`, `path: "data"`. Forced
  passes are plies too and need a roll. Rewriting an older ply's dice fails the same way.

### WebSocket (#286)

`GET /v1/matches/{id}/socket` with `Upgrade: websocket` and the bearer header
(`URLSessionWebSocketTask` with a `URLRequest`). One socket per open match; the room accepts
it with the hibernation API, tagged with the account id. All writes stay on HTTPS (one path
for ordering, idempotency and errors); the socket only pushes. The Worker verifies the token
and hands the upgrade to the room with `x-tavtav-account` / `x-tavtav-token-exp` (the client's
`Authorization` header is dropped); no `Upgrade: websocket` → 400, unknown match → 404 before
the upgrade. A non-participant (or deleted seat) gets the `error` message + close 4403. The
attachment keeps the token's expiry: the first event after it closes that socket with
`error` `token_expired` + 4401 (hibernating sockets have no timers). Each socket gets its own
viewer's snapshot (`requests` are per recipient).

Server → client (JSON text, `type`-tagged, `ServerMessage`):

| `type` | Fields | When |
|---|---|---|
| `hello` | `matchID, revision, serverTime` | right after connecting (the app reloads once: whatever happened while it was away) |
| `match` | `event, match: MatchSnapshot` | after every state change: `created`, `joined` (seat filled, #287), `accepted`, `declined`, `turnEnded`, `turnSaved`, `matchEnded`, `quit` (also the deletion hook), `diceChanged` (unknown event → treat as a reload) |
| `roll` | `matchID, roll: RollRecord` | the turn holder rolled |
| `request` | `matchID, request: OutOfTurnRequest` | to the recipient only |
| `error` | `error: {code, message}` | before the server closes the socket (e.g. `forbidden`) |

Client → server: only the keepalive text `{"type":"ping"}` every ~30 s, answered
`{"type":"pong"}` by the runtime without waking the room. Anything else is ignored.
Close codes: 1000 normal, 4401 auth expired (refresh + reconnect), 4403 not a participant,
4410 match gone. The app reconnects with backoff and keeps `LiveTurnTiming`'s poll as the
fallback while the socket is down.

### Invites, auto-match, lobby, push (#287)

Code: `src/invites.ts`, `src/match-queue.ts` (`MatchQueue` DO), `src/push.ts`, `src/web.ts`,
`removeMatch` / `autoMatch` in `src/matches.ts`; D1 migration `0003_invites_push.sql`
(`invites`, `push_tokens`). App side: `ServerLobby.swift` (engine) + the lobby views.

- **Open seat.** `MatchRoom.create` takes `openSeat`: seat 1 without a player is `matching`
  (auto-match) or `invited` (invite code). The creator holds the turn and may play first (as
  with GameKit); its end-turn hands the turn to the empty seat (`currentPlayerID null`,
  creator's lobby row `waitingForOpponent`). `MatchRoom.join(player)` fills the seat (status
  `active` at once, event `joined`; the joiner holds the turn if the creator already moved);
  refused for the creator (403), a taken seat (403) or an ended match (409).
  `MatchRoom.closeOpenSeat()` ends a match still waiting for its seat (seat 1 `declined`,
  seat 0 `done`, outcomes `none`, event `declined`). **Cancel** while the seat is open =
  `quit` with `inTurn: false` (allowed then even for the turn holder: nobody plays on).
- **Invite codes** (`POST /v1/invites` → 201 `Invite`): 6 characters from
  `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (no `0 O 1 I L`; `crypto.getRandomValues` with rejection
  sampling, no modulo bias; 31⁶ ≈ 887 M), stored in D1 `invites` (`status` open / accepted /
  declined / cancelled / expired), valid **7 days** (`INVITE_TTL_MS`); a code collision
  retries (5×). `url` = `<request origin>/join/<code>`. Codes are read case-insensitively,
  spaces and dashes dropped (`normalizeInviteCode`, mirrored by Swift `InviteCode`).
  - `GET /v1/invites/{code}` → `InvitePreview` (200 also for closed invites — `status` says
    which; an `open` one past its expiry reads `expired`); unknown → 404.
  - `POST …/accept`: the creator → 403; not open / expired → 410 `invite_unavailable`; the
    **claim is one conditional D1 `UPDATE … WHERE status = 'open' AND expires_at > now`**, so
    of two players accepting at once exactly one wins (the other 410). Then `join`; if the
    creator left meanwhile the code is marked `cancelled` and the answer is 410. The same
    player accepting again (lost reply) gets the match (200). Push `inviteAccepted` → creator.
  - `POST …/decline` (anyone but the creator) and `DELETE /v1/invites/{code}` (creator only,
    else 403) close an open invite (`declined` / `cancelled`) and `closeOpenSeat` the match;
    again → 204; any other closed state → 410.
  - **Expiry**: the hourly cron (`expireInvites`, ≤ 100 per run) marks open invites past
    `expires_at` `expired` and closes their matches.
  - **Lobby**: `GET /v1/matches` adds `invite {code, url, expiresAt}` to the creator's row of a
    running match with an open invite (share again / cancel).
- **Auto-match** (`POST /v1/automatch {variant, targetWins}` → 200 `MatchSnapshot`): one
  `MatchQueue` Durable Object per queue, `getByName("<variant>:<targetWins>")`, table
  `waiting (match_id, creator_id, created_at)`. `enter` runs inside `blockConcurrencyWhile`,
  so concurrent requests are served one after another (a D1 "find, else create" would let two
  simultaneous players both create and wait): (1) the oldest waiting match of **someone else**
  is removed from the queue and joined (`join`); an entry whose match ended (creator
  cancelled / deleted) or whose seat is taken is dropped and the next tried; (2) else the
  caller's own waiting match is answered again (double tap); (3) else a new match with a
  `matching` seat is created and queued. Entries older than 7 days are dropped. Push
  `inviteAccepted` → the creator when someone joined. (New DO class → `migrations` tag `v2`
  `new_sqlite_classes: ["MatchQueue"]` in every environment.)
- **Lobby removal** (`DELETE /v1/matches/{id}` → 204): sets `match_index.hidden = 1` for the
  caller only; a running match → 403 `forbidden`; not the caller's / unknown → 404. The
  room's later index writes keep `hidden`.
- **Push** (`src/push.ts`). `PUT /v1/push-tokens {token, environment, locale?}` upserts
  `push_tokens` (a token moves to the newest account that registers it; ≤ 10 newest per
  account); `DELETE /v1/push-tokens/{token}` removes it for the caller (204 also when absent;
  the app calls it before signing out). Which operation pushes whom (`pushesAfter`, pure):
  | Operation | To | `kind` | `loc-key` |
  |---|---|---|---|
  | create with `opponentID` (#301: a challenge) | the challenged player | `challengeReceived` (category `CHALLENGE`) | title `PUSH_CHALLENGE_RECEIVED` + body `PUSH_GAME_<VARIANT>_<1\|2>` |
  | accept of a challenge (#301) | the challenger | `challengeAccepted` | `PUSH_CHALLENGE_ACCEPTED` |
  | decline of a challenge (#301; not after a block, not on expiry) | the challenger | `challengeDeclined` | `PUSH_CHALLENGE_DECLINED` |
  | invite accept, auto-match join | the creator | `inviteAccepted` | `PUSH_INVITE_ACCEPTED` |
  | end-turn (the other player now holds the turn) | the other | `yourTurn` | `PUSH_YOUR_TURN` |
  | end-match | the other | `matchEnded` | `PUSH_MATCH_WON` / `_LOST` / `_ENDED` (their outcome) |
  | quit (the other wins), account deletion | the other | `opponentLeft` | `PUSH_OPPONENT_LEFT` |
  Save-turn, rolls, slider and declines push nothing; a lost-reply resend may push twice.
  Handlers send with `ctx.waitUntil` (never delays or fails the request). Payload
  (`PushPayload`, fixture `push-payload.json`): `{"aps": {"alert": {"loc-key", "loc-args":
  [<sender's name>]}, "sound": "default", "thread-id": <matchID>}, "matchID", "kind"}` — iOS
  renders the text from the app's `Localizable.xcstrings` (`PUSH_*`, en/de/nl/el/fa), so the
  server never translates; `locale` is stored for later use. Request: `POST
  https://api.push.apple.com/3/device/<token>` (`api.sandbox.push.apple.com` for `sandbox`
  tokens), headers `authorization: bearer <provider JWT>`, `apns-topic: com.plakoto.TavliApp`,
  `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: now + 1 day`,
  `apns-collapse-id: turn-<matchID>` for "your turn". **Provider JWT**: ES256 (WebCrypto,
  `jwt.ts` `importP8` + `signEs256`), header `{alg, kid: APNS_KEY_ID}`, claims `{iss:
  APNS_TEAM_ID, iat}`, cached per isolate for 50 min (APNs: refresh after 20, before 60);
  dropped at once on `ExpiredProviderToken` / `InvalidProviderToken`. A 410 or `BadDeviceToken`
  / `Unregistered` / `DeviceTokenNotForTopic` deletes the token. **Behind config**: without
  `APNS_KEY_ID` + `APNS_PRIVATE_KEY` (secrets) and `APNS_TEAM_ID` (var) every push logs
  `push.skipped` and nothing is sent. Logs never contain tokens. Unverified until a real key
  exists: that Workers' `fetch` reaches APNs over HTTP/2 (APNs refuses HTTP/1.1; Workers
  negotiates the protocol itself — the `@fivesheepco/cloudflare-apns2` library uses plain
  `fetch` the same way). After setup, check the logs for `push.sent` vs `push.rejected` /
  `push.error`.

### People, presence, challenges (#301)

Code: `src/people.ts`, `src/presence-hub.ts` (`PresenceHub` DO), `src/handles.ts`; D1
migration `0004_people.sql`. App side: `ServerPeople.swift` (engine) + `Views/PeopleViews.swift`.

- **Who your people are.** `match_index.played` = both seats played in that match (written by
  the MatchRoom with every index row: both seats filled and each `active`, or `done` with an
  outcome; sticky via `max()`; the migration backfills it). A declined / cancelled / expired
  challenge never counts. `GET /v1/people` = every opponent with `played = 1` (newest game =
  `lastPlayedAt`) **plus** everyone the caller pinned (⭐; how someone found by handle is
  added, `lastPlayedAt null`), pinned first then newest game, ≤ 100. An **unpinned** person
  drops off 90 days after the last game (`PEOPLE_MAX_AGE_MS`); `DELETE /v1/people/{id}` sets
  `contact_prefs.removed_at` (and unpins) — they come back only with a newer game. Blocks in
  either direction hide a person. Pins live on the server (survive relaunch / other devices).
- **Presence.** Each app in the **foreground** keeps one socket `GET /v1/presence/socket` to
  the one `PresenceHub` (`PRESENCE.getByName("global")`; shard later if needed). The Worker
  verifies the token and passes `x-tavtav-account` / `-token-exp` / `-hidden`. Online = a live
  socket whose last keepalive (`getWebSocketAutoResponseTimestamp`, app pings every 30 s) or
  connect is < 2 min old (`PRESENCE_ONLINE_MS`) — a phone that vanished without a close shows
  offline after ≤ 2 min on the next lookup (live watchers learn it at their next refresh).
  `lastSeenAt` = the newest of the stored last-seen (connect / close) and the sockets'
  keepalives. **Visibility**: a person's `presence` is included only when they played with the
  caller or both ⭐-added each other, and only while they don't hide it (`PATCH /v1/account
  {hidePresence}`; the hub stores the flag too and never reports or broadcasts a hidden
  account). The people lookup (`hub.lookup(watcher, ids)`) also replaces the caller's watch
  list (those ids, hidden or not), so presence changes reach its open app live: `{"type":
  "presence", playerID, online, lastSeenAt}` when someone's first socket opens / last one
  closes, or the hide switch flips. Deletion: `forget` (sockets closed 4403, rows gone); a
  block: `unwatch` both ways.
- **Challenges** = a direct-challenge match (`POST /v1/matches` with `opponentID`, seat 1
  `invited`) + a D1 `challenges` row: `pending` → `accepted` / `declined` / `expired` (24 h,
  `CHALLENGE_TTL_MS`) / `cancelled`. Every transition is **one conditional UPDATE `WHERE
  status = 'pending'`** (accept / decline / cancel also `AND expires_at > now`, expiry `<=`),
  so of racing accept / decline / cancel / expiry exactly one wins; then the room follows
  (`accept`, `decline`, `closeInvitedSeat`). Create: refused (403) when either blocked the
  other or the opponent's `whoCanChallenge` is `people` and the caller isn't one of theirs
  (played, or ⭐ by them); the same game again → the pending match (200; a unique partial
  index allows one pending per direction, so two taps at once give one challenge); another
  game → the old one is cancelled; the opponent's pending challenge to the caller for the same
  game → accepted instead (crossed taps, 200). Accept (`/v1/matches/{id}/accept`) of an
  expired / declined / cancelled challenge → 410 `invite_unavailable` (a pending one past its
  expiry is expired on the spot); again after accepting → the match (no second push). Decline
  → 204 (again 204). Cancel (`/v1/matches/{id}/cancel`, challenger only) → 204, answered →
  410. Cron: `expireChallenges` (≤ 100 per run). The lobby row carries `challenge {status,
  expiresAt}` (a pending one past expiry reads `expired`); `Person.challenge` = the pending one
  between caller and person (`incoming` / `outgoing`).
- **Live events** (`sendLive`, through the hub, `ctx.waitUntil`): `{"type": "challenge",
  event, challenge}` — `received` → challenged, `accepted` / `declined` → challenger,
  `expired` → both, `cancelled` → challenged. The **push goes out anyway** (`challengeReceived`
  with `aps.category = "CHALLENGE"`, `apns-collapse-id: challenge-<matchID>`); the app shows a
  card instead of the banner while it is in front.
- **Handles** (`src/handles.ts`): every account has one, separate from the display name: 3–20
  of `[A-Za-z0-9_]`, shown as typed, unique ignoring case (`accounts.handle_key` = lower case,
  UNIQUE index: two players taking one at once → one 200, one 409 `handle_taken`), reserved
  words refused (`RESERVED_HANDLES`, anything starting with `tavtav`) with 400 `path: handle`.
  Generated on the account's first load (`ensureHandle`: from the display name, else
  `player` + digits; the migration gave existing accounts `player_<8 hex>`), changeable
  **once** (`PATCH /v1/account {handle}` while `handleChangeable`; again → 403). `GET
  /v1/handles/{h}` → `{available, reason?: taken | reserved | invalid | yours}`.
- **Search** `GET /v1/players?q=`: ≥ 3 characters (a leading `@` dropped, case-insensitive),
  prefix of the handle (`handle_key` range), exact match first, ≤ 20, never the caller nor
  anyone blocked either way; strangers get only `handle` + `displayName` (+ `isPerson`,
  `canChallenge`). Rate-limited per account: `SEARCH_LIMITER` 30/min (429).
- **Blocking** `POST /v1/people/{id}/block`: the blocked account can't challenge (403), find
  the blocker or see its status, neither shows in the other's list; the blocked one's pending
  challenges to the blocker are declined **quietly** (live event, no push), the blocker's to
  them cancelled. `GET /v1/people` lists `blocked` (unblock: `DELETE …/block`).
- **"Who can challenge me"** (`PATCH /v1/account {whoCanChallenge: everyone | people}`,
  default everyone).
- **Account deletion** (`deletePeopleOfDeletedAccount`, after the matches hook): pending
  challenges → live `cancelled` to the other side, `challenges` / `contact_prefs` / `blocks`
  rows of both directions deleted, `hub.forget`.

### Universal links (#287, `src/web.ts`)

- `GET /.well-known/apple-app-site-association` → `{"applinks": {"details": [{"appIDs":
  ["8XRKL83C4V.com.plakoto.TavliApp"], "components": [{"/": "/join/*"}]}]}}`,
  `application/json`, no redirect, `Cache-Control: public, max-age=3600`. Apple's CDN fetches
  it (app-site-association.cdn-apple.com) when the app is installed and caches it for hours to
  days, so a changed file takes time to reach devices.
- The app's Associated Domains: `applinks:tavtav-server-staging.tavtav.workers.dev` (Debug) /
  `applinks:tavtav-server.tavtav.workers.dev` (Release); a production build only opens
  production links, a debug build only staging links.
- `GET /join/{code}`: the fallback page when the link opens in a browser (app not installed,
  or opened from a context that skips universal links): the Tavtav mark, "Alex invites you to
  a game of Fevga." + length, the code to type ("Play Online → Join with a code") and the App
  Store button (`https://apps.apple.com/app/id6838396758`) + a Smart App Banner (`app-argument`
  = the link). Language from `Accept-Language` (q-values): en / de / nl / el (else en).
  Unknown code → 404 page "This invite link isn’t valid…"; a closed invite → "This invite isn’t
  open any more…" without the code. Caramel colours, light + dark (`prefers-color-scheme`),
  no scripts; CSP `default-src 'none'; style-src 'unsafe-inline'`, names HTML-escaped.

### Shared fixtures

`server/fixtures/*.json` are canonical examples of every request, response and socket
message. `test/fixtures.test.ts` parses each with its schema and
`ios/TavliEngine/Tests/TavliEngineTests/ServerAPITests.swift` decodes each with its
`ServerAPI` type (reading the files from the repo); both fail if a fixture has no decoder.
`match-snapshot.json`'s `data` is a real `OnlineMatchPayload` (schema v2 with `liveTurn`,
`diceHandicap`, a weighted ply) that the engine decodes. Change the TS schema, the Swift type
and the fixture together.

## Code map

| File | What |
|---|---|
| `src/index.ts` | Entry: dispatch, rate limit, error → response, request log, `/health`, `scheduled` |
| `src/routes.ts` | Route table (`CONTRACT_ROUTES`, ticket per endpoint) + tiny router |
| `src/api.ts` | Wire contract: schemas + types, error codes, constants |
| `src/schema.ts` | Mini runtime schema kit (`parse` + `Infer`), unknown keys dropped |
| `src/http.ts` | `json`, `HttpError`, error format, standard headers, `readJson` |
| `src/log.ts` | JSON-line `Logger` |
| `src/rate-limit.ts` | `enforceRateLimit` over the two Rate Limiting bindings |
| `src/usage.ts` | Hourly free-plan usage check + alert webhook |
| `src/match-room.ts` | `MatchRoom` DO (#286): storage migrations, the match state + every operation (`RoomResult`), dice verification, lobby index writes, hibernatable sockets + fan-out, `accountDeleted`, keepalive auto-response, `info()`; test seams `random` / `now` |
| `src/matches.ts` | #286 match handlers (validate → room → response), lobby list from D1 (+ #287 open invites), socket hand-off, the account-deletion hook; #287 pushes after create / accept / end-turn / end-match / quit, `removeMatch`, `autoMatch` |
| `src/dice.ts` | #286 server dice: crypto fair dice, the hybrid bend port (`turnBeta`, `mirroredBeta`, `rollBeta`, `weightedFaces`), `drawRoll` |
| `src/payload.ts` | #286 reads the plies' dice from a base64 payload (the only payload read) + size check |
| `src/accounts.ts` | #285 handlers: sign-in (Apple/Google/dev), refresh, logout, account get/update/delete, display-name rule, session pruning |
| `src/identity.ts` | Apple/Google identity-token verification (JWKS cache, claims, nonce); `identityDeps` = test seam for `fetch`/`now` |
| `src/sessions.ts` | Access tokens (HMAC), refresh-token rotation + reuse detection, `authenticate` |
| `src/jwt.ts` | base64url, JWT decode, RS256 verify, ES256 sign, `.p8` import (WebCrypto) |
| `src/apple-revoke.ts` | Apple code exchange + token revocation (skipped without the `APPLE_*` secrets) |
| `src/account-hooks.ts` | `ACCOUNT_DELETION_HOOKS`: #286's `endMatchesOfDeletedAccount` (+ "opponent left" pushes), #287's `deletePushTokensOfDeletedAccount` |
| `src/invites.ts` | #287 invite codes: generate (`newInviteCode`), normalize, create / preview / accept (conditional claim) / decline / revoke, `expireInvites` (cron) |
| `src/match-queue.ts` | #287 `MatchQueue` DO: one auto-match queue per variant + length, `enter` serialised with `blockConcurrencyWhile` |
| `src/push.ts` | #287 device-token endpoints, `pushesAfter` (who gets which push), APNs payload + request, ES256 provider JWT cache, `sendPushes` (dead-token cleanup, skipped without the key), deletion hook; `pushDeps` = test seam |
| `src/web.ts` | #287 AASA + the `/join/{code}` fallback page (`joinPage`, `pageLanguage`) |
| `src/people.ts` | #301 people list, presence lookup, pin / remove / block, search, challenge permission + lifecycle helpers (`transition`, `expireOne`, `expireChallenges`), live events (`sendLive`), presence socket hand-off, deletion hook |
| `src/presence-hub.ts` | #301 `PresenceHub` DO: presence sockets (hibernation, auto-response), `lookup` (+ watch list), `setHidden`, `send`, `unwatch`, `forget`; `now` test seam |
| `src/handles.ts` | #301 handle rule, suggestion, `ensureHandle`, `chooseHandle` (once, 409 on a taken one), `GET /v1/handles/{h}` |
| `src/version.ts` | `SERVER_VERSION` (= package.json), service name |
| `src/secrets.d.ts` | Types for the optional secrets |
| `migrations/` | D1 migrations (`0001_initial.sql`; `0002_sessions.sql`: `sessions`, `account_identities.provider_refresh_token`; `0003_invites_push.sql`: `invites`, `push_tokens`; `0004_people.sql`: `match_index.played` (+ backfill), `accounts.hide_presence` / `challenge_policy` / `handle` / `handle_key` / `handle_chosen` (+ generated handles), `contact_prefs`, `challenges`, `blocks`) |
| `worker-configuration.d.ts` | Generated by `npm run types` (`wrangler types --strict-vars=false`); CI checks it is current |

**Tests** (`npm test`, vitest + `@cloudflare/vitest-plugin` — the renamed
`@cloudflare/vitest-pool-workers` — running in workerd/Miniflare with local D1, DO and
rate-limit bindings; migrations applied in `test/setup.ts`): health + headers + errors,
every reserved route → 501 with its ticket, router, rate limiting, D1 schema constraints and
cascades, MatchRoom SQLite + migrations, logging, usage check (mocked GraphQL/webhook,
once-per-day dedupe), shared fixtures + request validation. **Accounts** (`test/auth.test.ts`,
helpers in `test/auth-helpers.ts`): locally generated RSA keys stand in for Apple's and
Google's JWKS (fake `fetch` via `identityDeps`, fixed clock), tokens minted per test; covers
account creation/return, every rejection (wrong aud/iss, expired, future iat, nonce
mismatch/raw nonce, unknown kid, foreign key under a known kid, `alg` none/HS256, the other
provider's token, garbage), JWKS caching + rotation, Google unconfigured, access-token
forgery/expiry, refresh rotation + reuse revocation, logout scope, per-account rate limit,
name rule, deletion (cascade, hooks, failing hook, re-sign-in = new account), Apple
exchange + revocation with a generated `.p8` (client secret verified), dev sign-in gating.
Vitest sets `GOOGLE_CLIENT_IDS` = the test client id (`vitest.config.ts`).
**Matches** (`test/matches.test.ts`, players from the dev sign-in, a fresh `cf-connecting-ip`
per request so the IP limiter stays out of the way): create (seats, starter, index rows,
random starter for Fevga, open seat), strangers / unknown match / unknown opponent / yourself,
accept + decline, turn rules (only the turn holder rolls and writes), idempotent rolls, the
"next ply only" roll rule, refused dice (wrong, missing, rewritten, someone else's), stale
revision + identical resend, next game's first roll, payload checks, end-match outcomes and
locking, quit in/out of turn, requests (recipient only, dropped after its turn), the dice
slider rule + weighted rolls (values required, mirrored β, deterministic draw via
`runInDurableObject`, values stored), lobby list paging/filter/cursor, WebSocket (hello,
roll/match/request fan-out, 4403 refusal, 4401 after token expiry, upgrade/auth checks),
account deletion (quit + anonymised + stale token refused).
**Lobby, invites, auto-match** (`test/lobby.test.ts`, helpers `test/lobby-helpers.ts`): code
alphabet + uniformity + rejection sampling, normalisation; create (open `invited` seat, lobby
row with the invite), preview (any case, unknown, unauthenticated), accept (own invite 403,
one use, lost reply, joiner holds the turn after the creator's first move), **four players
accepting at once → exactly one 200**, decline / revoke (who may, idempotent, match ended),
expiry (preview, accept 410, cron), creator left meanwhile; auto-match (wait, double tap, other
length = other queue, join, queue emptied), **four players entering at once → two pairs, empty
queue**, cancelled and week-old waiting matches skipped, deleted creator; lobby removal (only
ended, only for the caller). **Push** (`test/push.test.ts`, generated P-256 `.p8`, fake
APNs `fetch`): token register / move / unregister / cap / validation / deletion hook;
provider JWT (header, claims, signature verified with the public key, 64-byte JOSE signature,
50-min cache, escaped one-line PEM); payload + loc-keys = the fixture; request host per token
environment + headers + collapse id; dead tokens deleted, 500 kept; skipped (and logged)
without the key; refused provider token re-signed; `pushesAfter` per operation; end-to-end
through the Worker (challenge → `PUSH_INVITE_RECEIVED`, end-turn → `PUSH_YOUR_TURN` to the
sandbox host), invite accept → creator, account deletion → "opponent left". **Web**
(`test/web.test.ts`): AASA body + headers, `pageLanguage`, the join page in en/de/nl/el,
unknown (404) / closed invites, escaping. **Dice** (`test/dice.test.ts`):
parity with the Python/Swift table (β, mirrored β, faces for 8 uniform pairs × 4 vectors × 4
levels × 2 maxPoints), fair at level 0 / flat values, χ² of crypto fair dice and of the bent
distribution against `p·exp(βv)` for both sides.

**People, presence, challenges, handles** (`test/people.test.ts`, #301): the list (played
only — a declined challenge doesn't count —, newest first, handles), pin / 90-day drop-off /
remove until the next game, ⭐-adding a stranger (no presence unless mutual); presence (live to
an open app's socket, last seen after close, a stale socket offline after 2 min via the hub's
`now`, the hide switch live both ways, upgrade/auth checks); challenges (pending on both
sides, second tap = same match, another game replaces it, accept → push + live, lost-reply
accept, decline → push + live, 204 again, cancel → live + accept 410, cron + lazy expiry,
accept vs decline vs cancel racing → exactly one wins, two taps at once → one challenge,
crossed taps accepted); handles (generated, one change, unique ignoring case, reserved, two
players racing for one → 200 + 409, availability, suggestion); search (prefix, exact first,
not yourself, ≥ 3 chars, rate limit 429 after 30); blocking (quiet decline, no challenges /
search / list, unblock) and "only my people"; account deletion (live cancel, rows, hub).
Also the #301 fixtures (`people.json`, `presence-messages.json`, `push-payload-challenge.json`, …).

**Rate limits**: `IP_LIMITER` 120 req/min per IP on everything but `/health`;
`ACCOUNT_LIMITER` 240 req/min per account (after token verification, #285); `SEARCH_LIMITER`
30 req/min per account on `GET /v1/players` (#301).
Counted per Cloudflare location (approximate by design), 429 + `Retry-After: 60`.

**Logs**: one JSON object per line (`level`, `event`, `ts`, `service`, `env`, `requestId`, …);
every request logs `event: "request"` with method, path, status, durationMs, client header,
colo. Never tokens, payloads or IPs. Workers Logs (`observability.enabled`) keeps them
(free plan: 3 days); live: `npx wrangler tail --env staging`.

## Runbook

### First-time setup (the user, once)

1. **Cloudflare account**: sign up at dash.cloudflare.com (Free plan). Workers & Pages →
   pick the `workers.dev` subdomain (e.g. `tavtav`). Note the **Account ID** (Workers &
   Pages overview, right column).
2. **Local login** (for the one-time commands below): `cd server && npm ci && npx wrangler login`.
3. **D1 databases**:
   ```bash
   npx wrangler d1 create tavtav-staging
   npx wrangler d1 create tavtav-production
   ```
   Paste each printed `database_id` into `server/wrangler.jsonc` in place of
   `REPLACE_WITH_STAGING_D1_ID` / `REPLACE_WITH_PRODUCTION_D1_ID` and commit (ids are not
   secrets). Until then the deploy jobs skip with a notice.
4. **API token for CI**: My Profile → API Tokens → Create Token → template **"Edit
   Cloudflare Workers"**, then *add* the permission Account · **D1: Edit**. Make sure the
   list contains at least: Account · Workers Scripts: Edit, Account · D1: Edit, Account ·
   Account Settings: Read, User · Memberships: Read, User · User Details: Read (the template's
   KV/Routes/Pages/Tail rows may stay). Account Resources: *Include → your account*; Zone
   Resources: *All zones* is fine (no zone is used yet). TTL: none, or 1 year with a reminder.
5. **GitHub secrets** (repo → Settings → Secrets and variables → Actions):
   `CLOUDFLARE_API_TOKEN` (step 4) and `CLOUDFLARE_ACCOUNT_ID` (step 1). Optionally add a
   required reviewer to the `production` environment (Settings → Environments), created by
   the first workflow run.
6. **First deploy**: merge to `main` (or run the *server* workflow → *staging*). The job
   applies migrations, deploys and checks `/health?deep=1` for the commit. Then Actions →
   *server* → Run workflow → `production` (from `main`).
7. **Ops secrets** (optional, per environment, below) + uptime monitor.

### Deploy

- CI: push to `main` touching `server/` → staging; production = manual *Run workflow* on
  `main`. Both run `scripts/deploy.sh <env>`: placeholder check → `wrangler d1 migrations
  apply DB --env <env> --remote` → `wrangler deploy --env <env> --var GIT_COMMIT:<sha>` →
  poll `/health?deep=1` until it reports that commit.
- Local (with `wrangler login`): `npm run deploy:staging` / `npm run deploy:production`
  (a dirty tree deploys as `<sha>-dirty`).
- Check: `curl https://tavtav-server-staging.<subdomain>.workers.dev/health?deep=1`.
- Durable Object class changes (new/renamed/deleted classes) need a new `migrations` tag in
  **every** environment of `wrangler.jsonc` (`new_sqlite_classes` only; free plan supports
  only SQLite-backed objects). Renames/deletes are destructive: plan them.

### Rollback

- Code: `npx wrangler deployments list --env production` → `npx wrangler rollback
  <version-id> --env production` (or dashboard → Worker → Deployments → Rollback). Instant;
  does **not** undo D1 migrations or DO storage changes, so migrations must stay
  backward-compatible with the previous release (add columns/tables; drop only a release later).
- Bad migration / data: D1 Time Travel (below). DO storage: SQLite-backed objects keep 30 days
  of point-in-time history (`ctx.storage.getBookmarkForTime` + `onNextSessionRestoreBookmark`);
  no admin path yet (add one when a restore is needed).

### Secrets

`npx wrangler secret put <NAME> --env staging|production` (never in `wrangler.jsonc`;
listed in `src/secrets.d.ts`; `npx wrangler secret list --env …`). Local dev: `server/.dev.vars`
(gitignored).

| Secret | Used by | Notes |
|---|---|---|
| `CF_ANALYTICS_TOKEN` | usage check | separate token with only Account · **Account Analytics: Read** |
| `CF_ACCOUNT_ID` | usage check | the account id |
| `ALERT_WEBHOOK_URL` | usage alert | e.g. `https://ntfy.sh/<long-random-topic>` (free, phone app) or a Slack/Discord webhook |
| `SESSION_KEY` | #285 sessions | **required** in staging/production (sign-in answers 503 without it). `openssl rand -base64 48`; one per environment. Rotating it signs every access token out (refresh tokens keep working, so apps refresh transparently) |
| `APPLE_TEAM_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` | #285 Apple revocation | optional; the Sign in with Apple key (see "Accounts setup"); `APPLE_PRIVATE_KEY` = the `.p8` file's whole text (`npx wrangler secret put APPLE_PRIVATE_KEY --env production < AuthKey_XXXX.p8`) |
| `APNS_KEY_ID` / `APNS_PRIVATE_KEY` | #287 push | optional (pushes are skipped and logged without them); the APNs auth key id + the `.p8` file's whole text. Copied from the **GitHub repository secrets** of the same names by the `server-secrets` workflow — see "Push + universal links setup". The team id is the var `APNS_TEAM_ID` (`8XRKL83C4V`, in `wrangler.jsonc`) |

Non-secret config lives in `wrangler.jsonc` `vars` (per environment): `GOOGLE_CLIENT_IDS` (#285)
= the iOS OAuth client id(s), comma separated, empty until the Google client exists;
`APNS_TEAM_ID` (#287) = `8XRKL83C4V`.

### Accounts setup (the user, once, #285)

1. **Sign in with Apple capability**: Xcode → TavliApp target → Signing & Capabilities shows
   "Sign in with Apple" (from `TavliApp.entitlements`); with automatic signing Xcode adds it to
   the App ID `com.plakoto.TavliApp` (or developer.apple.com → Identifiers → the App ID →
   enable *Sign in with Apple*, "Enable as a primary App ID"). Nothing else is needed for
   sign-in itself.
2. **Google OAuth client** (Google Cloud console → APIs & Services): OAuth consent screen
   (External, app name Tavtav, scopes: only `openid`; publish it), then Credentials → Create
   credentials → OAuth client ID → **iOS**, bundle id `com.plakoto.TavliApp`. Copy the client
   id (`…apps.googleusercontent.com`, public) into
   - `ios/TavliApp/project.yml` → `GOOGLE_IOS_CLIENT_ID` (then `xcodegen generate`), and
   - `server/wrangler.jsonc` → `GOOGLE_CLIENT_IDS` in `env.staging` and `env.production`
     (and the top level for `wrangler dev`), then `npm run types`.
   No client secret and no URL-scheme registration are needed (ASWebAuthenticationSession
   catches the `com.googleusercontent.apps.<id>` redirect itself).
3. **`SESSION_KEY`** for each environment: run the GitHub Actions workflow
   **server-secrets** (Actions → server-secrets → Run workflow → environment; it was called
   `server-session-key` before #287). It generates the key on the runner and pipes it into
   `wrangler secret put`, so nobody sees it, and only sets it when missing (tick
   `rotate_session_key` to replace it, which signs every access token out). The same run copies
   the APNs key when the repository has it (below). Locally the equivalent is
   `openssl rand -base64 48 | npx wrangler secret put SESSION_KEY --env staging`. Without it
   sign-in answers 503. Production needs a first deploy before its secret can be set.
4. **Sign in with Apple key** (for revocation on account deletion, optional but recommended for
   App Review): developer.apple.com → Certificates, Identifiers & Profiles → Keys → **+** →
   enable *Sign in with Apple* → Configure → primary App ID `com.plakoto.TavliApp` → Register →
   download `AuthKey_<KEYID>.p8` (once only; keep it safe). Then per environment:
   `npx wrangler secret put APPLE_TEAM_ID` (the 10-char team id), `… APPLE_KEY_ID` (the key id),
   `… APPLE_PRIVATE_KEY < AuthKey_<KEYID>.p8`. Check the logs for `apple.revoke.done` after
   deleting a test account.
5. **App server URLs**: once the Worker is deployed, replace `REPLACE_WITH_SUBDOMAIN` in
   `TAVTAV_SERVER_URL_STAGING` / `TAVTAV_SERVER_URL_PRODUCTION` in `ios/TavliApp/project.yml`.

### Push + universal links setup (the user, once, #287)

Until these steps are done everything else works: pushes are skipped (`push.skipped` in the
logs) and invite links open the web page instead of the app.

1. **App ID capabilities** (developer.apple.com → Certificates, Identifiers & Profiles →
   Identifiers → `com.plakoto.TavliApp`): tick **Push Notifications** and **Associated
   Domains**, Save. (With automatic signing Xcode offers the same from the entitlements file:
   `aps-environment` + `com.apple.developer.associated-domains`; the provisioning profiles are
   regenerated on the next build / archive.) A free (personal) team cannot sign either
   capability.
2. **APNs auth key**: Certificates, Identifiers & Profiles → **Keys** → **+** → name
   "Tavtav APNs", tick **Apple Push Notifications service (APNs)** (environment: *Sandbox &
   Production*) → Continue → Register → **Download** `AuthKey_<KEYID>.p8` (only once; keep it
   safe) and note the **Key ID** (10 characters). One key serves every app of the team, both
   APNs environments, staging and production.
3. **GitHub repository secrets** (nobody runs `wrangler secret put` locally):
   ```bash
   gh secret set APNS_KEY_ID --repo johannesnorbertwolf/tavlo          # paste the Key ID
   gh secret set APNS_PRIVATE_KEY --repo johannesnorbertwolf/tavlo < AuthKey_<KEYID>.p8
   ```
4. **Run the workflow** per environment: Actions → **server-secrets** → Run workflow →
   `staging` (and later `production`, after its first deploy). Its "Copy the APNs key" step
   writes both secrets into the Worker (`wrangler secret bulk`, one new version); without the
   repository secrets it skips with a notice. Re-run it after replacing the key.
5. **Check**: sign in on a device with a debug build (sandbox token) against staging, start a
   game, let the other player end a turn: `npx wrangler tail --env staging` shows `push.sent`
   (or `push.rejected` with APNs' `reason`). TestFlight / App Store builds register
   `production` tokens and are pushed through api.push.apple.com.
6. **Universal links**: nothing to configure on the server (the AASA is served by the Worker).
   After installing a build with the Associated Domains entitlement, a link
   `https://tavtav-server-staging.tavtav.workers.dev/join/<code>` (debug) /
   `https://tavtav-server.tavtav.workers.dev/join/<code>` (release) tapped in Messages opens
   the app; Apple's CDN may need a while to pick up the AASA of a fresh deploy. Long-press a
   link → "Open in Tavtav" re-enables it if a user once chose the browser.

### Local check with the simulator (#285)

`npm run db:migrate:local && npm run dev` (port 8787), then a DEBUG app build with the Developer card's server picker
set to Local (`http://localhost:8787`, `NSAllowsLocalNetworking`; Debug builds default to staging): Settings → Online account →
Developer → "Development sign-in", or launch arguments `-debugAccount
-debugAccountDevSubject sim-a -debugAccountName "Alex K."` (see `AccountViews.swift`).
Sign in with Apple / Google need a signed build and real provider setup.

### Lobby, invites and push against the local server (#287)

- `TAVTAV_E2E_SERVER=http://127.0.0.1:8787 swift test --filter ServerE2ETests` also runs
  `testInviteByCodeThroughTheLocalServer` (invite → typed code → two turns → the spent code
  and its web page → forfeit → remove) and `testRandomOpponentThroughTheLocalServer`. The
  three E2E tests together send ~150 requests from one IP: run them one at a time (or wait a
  minute) so the per-IP limiter (120/min) does not answer 429.
- Two simulators: launch each DEBUG build with `-debugServerLobby -debugAccountDevSubject sim-a
  -debugAccountName Alex` (and `sim-b` / `Sam`): New game → Invite a friend on one, Join with a
  code on the other. `-debugServerLobbySheet newMatch|join|invite` opens a sheet,
  `-debugJoinURL https://…/join/<code>` behaves like an opened invite link.
- A push on the simulator without APNs: `xcrun simctl push <udid> com.plakoto.TavliApp
  payload.apns` with the `push-payload.json` fixture (plus `"Simulator Target Bundle"`): the
  banner shows the localized `PUSH_*` text, tapping it opens the match.

### Online play against the local server (#286)

- **Engine end to end** (two "devices" = `AuthClient` + `ServerMatchService` +
  `OnlineMatchController` + `GameSession`, real HTTP + WebSocket):
  `npm run db:migrate:local && npm run dev`, then in `ios/TavliEngine`
  `TAVTAV_E2E_SERVER=http://127.0.0.1:8787 swift test --filter ServerE2ETests` (8 turns, the
  dice on the other device, a stale write, the slider + a weighted roll, a forfeit).
- **Two simulators**: launch each DEBUG build with `-debug.onlineViaServer YES -debugAccount
  -debugAccountDevSubject sim-a -debugAccountName "Alex K."` (and `sim-b` / `"Sam"`), or turn
  on Settings → Online account → "Play online via the server". Play Online then opens the
  server lobby: copy one player's ID ("Your player ID") into the other's "Challenge a player".
  The id of a dev subject: `curl -s -X POST localhost:8787/v1/auth/dev -H 'content-type:
  application/json' -d '{"subject":"sim-b"}'`.

### Migrations (D1)

- New file `migrations/000N_<what>.sql` (`npx wrangler d1 migrations create DB <what>`); never
  edit a shipped one. Forward-only and backward-compatible with the running code.
- Local: `npm run db:migrate:local`; tests apply them automatically.
- Remote: applied by `scripts/deploy.sh` before every deploy (wrangler records them in
  `d1_migrations` and takes a backup bookmark first). Manual:
  `npx wrangler d1 migrations apply DB --env staging --remote`; list with `… migrations list`.
- MatchRoom storage migrations: append to `ROOM_MIGRATIONS` in `src/match-room.ts`; each
  object migrates itself on first use after the deploy.

### Backups

- **D1 Time Travel** (always on; 7 days on Free, 30 on Paid): `npx wrangler d1 time-travel
  info tavtav-production --env production` shows the current bookmark;
  `npx wrangler d1 time-travel restore tavtav-production --env production --timestamp
  <RFC3339|unix>` (or `--bookmark`) restores in place (prints an undo bookmark).
- **Export** (off-Cloudflare copy): `npm run backup:production` → `server/backups/
  tavtav-production-<UTC>.sql.gz` + bookmark (gitignored; copy it somewhere safe). Weekly and
  before risky migrations. An export blocks the database while it runs: off-peak.
- Restore an export into a fresh database: `npx wrangler d1 create tavtav-restore` →
  `npx wrangler d1 execute tavtav-restore --remote --file <dump.sql>` → point the binding at it.

### Monitoring and alerts

- **Usage alert**: cron `17 * * * *` (staging) / `23 * * * *` (production) runs
  `checkUsage`: GraphQL Analytics for today's account-wide Worker and DO requests; at ≥70 % of
  100k/day it logs `usage.alert` (warn) and posts once per UTC day per metric to
  `ALERT_WEBHOOK_URL`. Both environments share the account quota, so either alerting is
  enough. Without the analytics secrets it logs `usage.skipped`. The GraphQL field names
  (`workersInvocationsAdaptive`, `durableObjectsInvocationsAdaptiveGroups`) are unverified
  until the first real run: check the logs for `usage.checked` / `usage.error` after setup.
- **Cloudflare notifications**: dashboard → Notifications lists what the account's plan
  offers; nothing is required beyond the cron check on Free.
- **Uptime**: a free external monitor (e.g. UptimeRobot or Better Stack free tier) on
  `GET /health?deep=1` for production (5-min interval ≈ 288 Worker + 288 DO requests/day),
  alerting to e-mail or the same ntfy topic. Staging needs none.
- **Logs**: dashboard → Worker → Logs (Workers Logs), or `npx wrangler tail --env production
  --format json`. Useful filters: `event = "request.unhandled"`, `status >= 500`,
  `event = "usage.alert"`.
