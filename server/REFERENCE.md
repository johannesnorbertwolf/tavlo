# server/ — reference

The Tavtav online server (Server v1, epic #278): replaces Game Center turn-based matches
with our own service on **Cloudflare Workers + Durable Objects (SQLite backend) + D1, Free
plan**. This file is the **API contract** every Server v1 ticket builds against, the
server-side design notes, and the **ops runbook**.

Ticket map: **#284** foundation (this scaffold, contract, ops) · **#285** accounts ·
**#286** matches, server dice, WebSocket · **#287** invites, auto-match, lobby, push ·
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

## API contract

### Basics

- **Base URL**: `https://tavtav-server-staging.<subdomain>.workers.dev` (staging),
  `https://tavtav-server.<subdomain>.workers.dev` (production); a custom domain can come later
  (then also the universal-link host, #287).
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
  Access tokens are short-lived (≈1 h); on `401 token_expired` the app calls
  `/v1/auth/refresh` once and retries. Refresh tokens rotate on every use.
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
| `invite_unavailable` | 410 | Invite expired, cancelled, declined or used. |
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
| `POST /v1/auth/apple` | – | `AppleSignInRequest` → `AuthSession` | – | #285 |
| `POST /v1/auth/google` | – | `GoogleSignInRequest` → `AuthSession` | – | #285 |
| `POST /v1/auth/refresh` | – | `RefreshRequest` → `AuthSession` | – | #285 |
| `POST /v1/auth/logout` | auth | `RefreshRequest` → 204 | – | #285 |
| `GET /v1/account` | auth | → `Account` | – | #285 |
| `PATCH /v1/account` | auth | `UpdateAccountRequest` → `Account` | – | #285 |
| `DELETE /v1/account` | auth | → 204 | – | #285 |
| `GET /v1/matches` (`?state=active\|ended&cursor=`) | auth | → `MatchListResponse` | lobby list | #286 (index), #287 (lobby UI) |
| `POST /v1/matches` | auth | `CreateMatchRequest` → `MatchSnapshot` | create (direct challenge) | #286 |
| `GET /v1/matches/{id}` | auth | → `MatchSnapshot` | `load` | #286 |
| `POST /v1/matches/{id}/accept` | auth | – → `MatchSnapshot` | `acceptInvite` | #286 |
| `POST /v1/matches/{id}/decline` | auth | – → 204 | (invite declined) | #286 |
| `POST /v1/matches/{id}/end-turn` | auth | `WriteTurnRequest` → `MatchSnapshot` | `endTurn` | #286 |
| `POST /v1/matches/{id}/save-turn` | auth | `WriteTurnRequest` → `MatchSnapshot` | `saveTurn` (live turn #269) | #286 |
| `POST /v1/matches/{id}/end-match` | auth | `EndMatchRequest` → `MatchSnapshot` | `endMatch` | #286 |
| `POST /v1/matches/{id}/quit` | auth | `QuitRequest` → `MatchSnapshot` | `quit` | #286 |
| `POST /v1/matches/{id}/requests` | auth | `SendRequestRequest` → 202 `{id}` | `sendRequest` | #286 |
| `POST /v1/matches/{id}/dice` | auth | `DiceChangeRequest` → `DiceHandicap` | shared slider (#272) | #286 |
| `POST /v1/matches/{id}/roll` | auth | `RollRequest` → `RollRecord` | (was local roll) | #286 |
| `GET /v1/matches/{id}/socket` | auth | WebSocket upgrade | GameKit turn events | #286 |
| `DELETE /v1/matches/{id}` | auth | → 204 (hide an ended match) | lobby "Remove" | #287 |
| `POST /v1/invites` | auth | `CreateInviteRequest` → `Invite` | invite friend | #287 |
| `GET /v1/invites/{code}` | auth | → `InvitePreview` | – | #287 |
| `POST /v1/invites/{code}/accept` | auth | – → `MatchSnapshot` | join by link/code | #287 |
| `POST /v1/invites/{code}/decline` | auth | – → 204 | – | #287 |
| `DELETE /v1/invites/{code}` | auth | → 204 (creator cancels) | – | #287 |
| `POST /v1/automatch` | auth | `AutoMatchRequest` → `MatchSnapshot` | GameKit auto-match | #287 |
| `PUT /v1/push-tokens` | auth | `PushTokenRequest` → 204 | – | #287 |
| `DELETE /v1/push-tokens/{token}` | auth | → 204 | – | #287 |
| `GET /.well-known/apple-app-site-association` | – | AASA JSON | universal links | #287 |
| `GET /join/{code}` | – | HTML fallback (App Store link) | – | #287 |

### Accounts (#285)

- **Apple**: the app sends Apple's `identityToken` and the raw `nonce` (the request carried
  its SHA-256). The server verifies the JWT against Apple's JWKS (`iss`
  `https://appleid.apple.com`, `aud` = bundle id, `exp`, nonce hash) and keys the identity by
  `(apple, sub)`. Apple sends the name only once, so the app forwards it as `displayName`.
- **Google**: ASWebAuthenticationSession + PKCE with the iOS client id; the app exchanges the
  code itself and sends the `id_token` + nonce. Verified against Google's JWKS (`iss`, `aud` =
  iOS client id, `exp`, `nonce`).
- First sign-in creates an `accounts` row + `account_identities` row; `isNewAccount: true`
  makes the app ask for a display name (1–24 chars). No e-mail is stored.
- `DELETE /v1/account`: deletes the account (identities and own `match_index` rows cascade),
  ends running matches as a quit, anonymises the player in finished matches
  (`displayName` → null), revokes sessions and push tokens.
- Session tables (refresh tokens) arrive as migration `0002_…` with #285.

### Match operations (#286) — `OnlineMatchService` semantics

The server keeps per match: two **seats** (`participants`, seat 0 = creator = White, seat 1 =
Black), `currentPlayerID`, `isEnded`, the opaque `data`, a **revision** (+1 per write), the
**dice slider**, the **roll log** and pending out-of-turn **requests**. The snapshot is
`OnlineMatchSnapshot` + these extras, so `ServerMatchService` maps it 1:1
(`ServerAPI.MatchSnapshot.onlineSnapshot`).

- **Create** (`POST /v1/matches`, also used internally by invites/auto-match): caller in seat 0,
  `currentPlayerID` = caller, `data = null`, `revision 0`; the server draws `startingPlayer`
  (W/B, crypto RNG) which the creator writes into its first payload. Seat 1 is `invited`
  (direct challenge / invite) or `matching` (auto-match, `playerID null`). As with GameKit the
  creator may play its first turn before the seat is filled; the turn then waits on the seat.
- **Optimistic concurrency**: every write carries `baseRevision` = the revision it builds on.
  Mismatch → `409 stale_revision` (no change). **Idempotent retry**: if the same caller resends
  the identical write that produced the current revision (`baseRevision == revision − 1`, same
  bytes, same op), the server answers 200 with the current snapshot instead of 409.
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
- **accept** / **decline**: only the invited seat; accept → `active`, event `accepted`;
  decline → `declined`, match ends, event `declined`.
- **requests** (`sendRequest`): opaque `data` from either participant to the other, kept in the
  room until the recipient's turn ends (then dropped) and delivered over the socket at once
  (`request` message) and in `snapshot.requests` (recipient only). Max 50 pending.
- **dice** (shared weighted-dice slider #272): the **server** is now the single writer, so the
  turn-holder/exchange dance is unnecessary. Either player may change it at any time with
  `{whiteLevel, baseRev}`; accepted iff `baseRev >= current.rev || current.by == caller's
  colour` (`OnlineDiceRequest.isAccepted(over:)`), then `rev + 1`, `by` = caller's colour.
  Refused → 409 `stale_revision` with the current value in a reload. Event `diceChanged`.
  The payload's `diceHandicap` key may still be written by the app but the server's value wins.
- **load** returns the snapshot; **list** returns `MatchSummary` rows from D1 (your turn,
  their turn, waiting, invited, ended; newest first; cursor-paged).

### Server dice (#286)

The roller asks the server for its dice; no client can choose them.

- `POST /v1/matches/{id}/roll {gameIndex, plyIndex, rollValues?}` — only the turn holder,
  only while the match runs. `plyIndex` = the current game's `plies.count`. **Idempotent per
  `(gameIndex, plyIndex)`**: asking again returns the recorded roll (a reconnect never
  rerolls). The snapshot's `lastRoll` is the newest roll; the `roll` socket message shows the
  opponent the dice immediately.
- **Fair dice** (`diceHandicap.whiteLevel == 0`): two independent faces from
  `crypto.getRandomValues` (rejection sampling, no modulo bias); `rollValues` ignored.
- **Weighted dice**: `rollValues` is **required** — the roller's 21 one-ply values
  (`HandicapDice.rollValues`) in canonical order `11 12 13 14 15 16 22 23 24 25 26 33 34 35
  36 44 45 46 55 56 66` (`HandicapDice.outcomes`), each finite and in [0, 1] (validated: else
  400). The server ports the app's hybrid bend (`HandicapDice`, keep in sync):
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
    for v1 (the slider is a friendly handicap both players see); #286 logs the values per roll.
- **Enforcement**: on `end-turn` / `end-match` / in-turn `quit` the room reads the dice of
  the plies appended since the last write (`games[g].plies[p].die1/die2`, the only payload
  fields the server reads) and rejects (`400 bad_request`, `path: "data"`) any ply whose
  dice differ from the roll log or that has no server roll. Forced passes are plies too and
  need a roll.

### WebSocket (#286)

`GET /v1/matches/{id}/socket` with `Upgrade: websocket` and the bearer header
(`URLSessionWebSocketTask` with a `URLRequest`). One socket per open match; the room accepts
it with the hibernation API, tagged with the account id. All writes stay on HTTPS (one path
for ordering, idempotency and errors); the socket only pushes.

Server → client (JSON text, `type`-tagged, `ServerMessage`):

| `type` | Fields | When |
|---|---|---|
| `hello` | `matchID, revision, serverTime` | right after connecting (client reloads if its revision differs) |
| `match` | `event, match: MatchSnapshot` | after every state change: `created`, `joined` (seat filled), `accepted`, `declined`, `turnEnded`, `turnSaved`, `matchEnded`, `quit`, `diceChanged` (unknown event → treat as a reload) |
| `roll` | `matchID, roll: RollRecord` | the turn holder rolled |
| `request` | `matchID, request: OutOfTurnRequest` | to the recipient only |
| `error` | `error: {code, message}` | before the server closes the socket (e.g. `forbidden`) |

Client → server: only the keepalive text `{"type":"ping"}` every ~30 s, answered
`{"type":"pong"}` by the runtime without waking the room. Anything else is ignored.
Close codes: 1000 normal, 4401 auth expired (refresh + reconnect), 4403 not a participant,
4410 match gone. The app reconnects with backoff and keeps `LiveTurnTiming`'s poll as the
fallback while the socket is down.

### Invites, auto-match, lobby, push (#287)

- **Invite**: `POST /v1/invites` creates a match (seat 1 `invited`, open) and a 6-character
  code (`[A-Z0-9]`, no look-alikes), valid 7 days; `url` = `https://<worker host>/join/<code>`
  (universal link; `/join/<code>` serves a small page with the App Store link when the app is
  not installed). `GET /v1/invites/{code}` previews it; accept fills seat 1 with the caller
  (not the creator; one use); decline / creator cancel / expiry close it (410 afterwards).
- **Auto-match**: `POST /v1/automatch {variant, targetWins}` mirrors GameKit: joins the oldest
  waiting match with the same variant + length (seat 1 `matching`, not your own) or creates
  one and returns it at once; the creator can start playing. Cancel = `quit` out of turn.
  Queue = D1 rows / a singleton DO per (variant, length), decided in #287.
- **Push**: `PUT /v1/push-tokens` registers an APNs token (`sandbox` for debug builds,
  `production` for TestFlight/App Store) with the locale for the text. The Worker signs an
  ES256 provider JWT (APNs key secret) with WebCrypto and sends: your turn, invite received,
  match ended, opponent left. Payload carries `matchID` so a tap opens the match. Tokens
  that APNs reports as unregistered are deleted.

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
| `src/match-room.ts` | `MatchRoom` DO: storage migrations, keepalive auto-response, `info()` |
| `src/version.ts` | `SERVER_VERSION` (= package.json), service name |
| `src/secrets.d.ts` | Types for the optional secrets |
| `migrations/` | D1 migrations (`0001_initial.sql`) |
| `worker-configuration.d.ts` | Generated by `npm run types` (`wrangler types --strict-vars=false`); CI checks it is current |

**Tests** (`npm test`, vitest + `@cloudflare/vitest-plugin` — the renamed
`@cloudflare/vitest-pool-workers` — running in workerd/Miniflare with local D1, DO and
rate-limit bindings; migrations applied in `test/setup.ts`): health + headers + errors,
every reserved route → 501 with its ticket, router, rate limiting, D1 schema constraints and
cascades, MatchRoom SQLite + migrations, logging, usage check (mocked GraphQL/webhook,
once-per-day dedupe), shared fixtures + request validation.

**Rate limits**: `IP_LIMITER` 120 req/min per IP on everything but `/health`;
`ACCOUNT_LIMITER` 240 req/min per account (wired in by #285 after token verification).
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
  #286 adds an admin path if needed.

### Secrets

`npx wrangler secret put <NAME> --env staging|production` (never in `wrangler.jsonc`;
listed in `src/secrets.d.ts`; `npx wrangler secret list --env …`). Local dev: `server/.dev.vars`
(gitignored).

| Secret | Used by | Notes |
|---|---|---|
| `CF_ANALYTICS_TOKEN` | usage check | separate token with only Account · **Account Analytics: Read** |
| `CF_ACCOUNT_ID` | usage check | the account id |
| `ALERT_WEBHOOK_URL` | usage alert | e.g. `https://ntfy.sh/<long-random-topic>` (free, phone app) or a Slack/Discord webhook |
| session signing key | #285 | e.g. `SESSION_KEY` |
| APNs `.p8` key, key id, team id | #287 | e.g. `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID` |

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
