# server/ — Tavtav online server (TypeScript, Cloudflare)

Our own replacement for Game Center online play (epic #278): a Cloudflare **Worker** +
one **Durable Object per match** (SQLite storage) + **D1**, on the Free plan.
**The API contract, design notes and the ops runbook are in [`REFERENCE.md`](./REFERENCE.md)**
— read it before adding or changing an endpoint, a message or a migration.

Tickets: #284 foundation (scaffold, contract, ops) · #285 accounts · #286 matches + server
dice + WebSocket · #287 invites/auto-match/lobby/push · #288 remove Game Center.

## Files

| Path | What |
|---|---|
| `src/index.ts` | Worker entry: dispatch, rate limit, error format, request log, `/health`, hourly `scheduled` (usage check, session pruning, invite expiry); exports `MatchRoom` + `MatchQueue` |
| `src/routes.ts` | Route table = every contract endpoint + its ticket; unbuilt ones answer 501 `not_implemented` |
| `src/api.ts` | **Wire contract**: runtime schemas + types for every body and WebSocket message, error codes |
| `src/schema.ts` | Mini schema kit (`parse` validates, `Infer` types; unknown keys dropped) |
| `src/match-room.ts` | `MatchRoom` Durable Object (#286): the match (seats, turn, payload + revision, slider, roll log, requests), every operation as `RoomResult`, dice verification, `match_index` writes, hibernatable sockets, deletion hook; append-only storage migrations |
| `src/matches.ts` · `src/dice.ts` · `src/payload.ts` | #286 match handlers + lobby list + socket hand-off + deletion hook (#287: pushes, lobby removal, auto-match handler) · server dice (crypto + hybrid bend port) · reads the plies' dice from a payload |
| `src/invites.ts` · `src/match-queue.ts` | #287 invite codes (create/preview/accept/decline/revoke, cron expiry; the accept is one conditional D1 UPDATE) · `MatchQueue` DO, one auto-match queue per variant + length (serialised with `blockConcurrencyWhile`) |
| `src/push.ts` · `src/web.ts` | #287 device tokens + APNs sender (ES256 provider JWT, `loc-key` payloads, skipped without the `APNS_*` key) · AASA + `/join/{code}` fallback page (en/de/nl/el) |
| `src/accounts.ts` · `src/sessions.ts` | #285 account handlers + display-name rule · our access/refresh tokens |
| `src/identity.ts` · `src/jwt.ts` | Apple/Google token verification (JWKS cache, nonce) · WebCrypto JWT helpers |
| `src/apple-revoke.ts` · `src/account-hooks.ts` | Apple token exchange/revocation (only with `APPLE_*` secrets) · deletion hooks (#286 matches + "opponent left" pushes; #287 push tokens) |
| `src/http.ts` · `src/log.ts` · `src/rate-limit.ts` | Error format/JSON helpers · JSON-line logger · per-IP/per-account limiter |
| `src/usage.ts` | Free-plan usage check (GraphQL Analytics) + once-a-day webhook alert |
| `migrations/` | D1 migrations (`0001_initial.sql`: accounts, identities, match_index, ops_alerts; `0002_sessions.sql`; `0003_invites_push.sql`: invites, push_tokens) |
| `fixtures/` | Shared JSON fixtures, decoded by `test/fixtures.test.ts` **and** Swift `ServerAPITests` |
| `scripts/deploy.sh` · `scripts/d1-backup.sh` | Migrate + deploy + health check · D1 export |
| `wrangler.jsonc` | Top level = local/test; `env.staging` / `env.production` |
| `worker-configuration.d.ts` | Generated (`npm run types`); don't edit |

Swift mirror: `ios/TavliEngine/Sources/TavliEngine/ServerAPI.swift` (`ServerAPI.*`).
CI: `.github/workflows/server.yml`; `server-secrets.yml` (manual, per environment) sets `SESSION_KEY`
and copies the APNs key from the GitHub secrets `APNS_KEY_ID` / `APNS_PRIVATE_KEY` (REFERENCE.md
"Push + universal links setup"). Nobody runs `wrangler secret put` locally.

## Commands (run in `server/`)

```bash
npm ci                    # once
npm test                  # vitest in workerd (Miniflare): local D1 + DO + rate limits
npm run lint              # generated types current + tsc --noEmit
npm run build:check       # bundle the staging Worker without uploading
npm run dev               # local server on :8787
npm run types             # regenerate worker-configuration.d.ts after editing wrangler.jsonc
npm run deploy:staging    # needs wrangler login or CLOUDFLARE_API_TOKEN (CI does this on main)
```

## Conventions / gotchas

- **Contract changes touch three places together**: `src/api.ts`, `ServerAPI.swift`, and a
  fixture in `fixtures/` (both test suites fail on a fixture without a decoder). Within `/v1`
  changes are additive only; readers ignore unknown keys and values.
- **Building an endpoint**: add its handler in `src/index.ts` (`HANDLERS`), keep the row in
  `routes.ts` and the REFERENCE.md table in sync, remove nothing from the contract silently.
- **The match payload is opaque** (base64 `OnlineMatchPayload`); the server reads only the
  plies' dice (`payload.ts`) to enforce server rolls (#286). Server-held state lives in the envelope.
- **MatchRoom** changes state synchronously (one SQLite transaction), then fans out + writes
  the D1 index; RPC methods return `RoomResult` (exceptions lose fields over RPC). Its
  `random` / `now` are test seams (`runInDurableObject`).
- **Dice bend = the app's** (`dice.ts` ↔ `HandicapDice.swift` ↔ `domain/handicap.py`): change
  them together and rerun `ios/scripts/make_weighted_dice_parity.py` (writes the Swift table
  and `test/data/weighted-dice-parity.json`).
- **Bindings are not inherited** by wrangler environments: every `env.*` block repeats vars,
  D1, DO, ratelimits and `migrations`. Rerun `npm run types` after editing.
- **Migrations are append-only** (D1 files and `ROOM_MIGRATIONS`) and must stay compatible with
  the previous release (rollback does not undo them).
- **No remote calls in tests**; inject `fetch` (see `usage.ts`, `identityDeps` in
  `identity.ts`). Logs never contain tokens, payloads or IPs.
- **Auth** (#285): routes with `auth: "required"` get `rc.auth` (`accountID`, `sessionID`)
  from the entry point; access tokens are stateless, so check the account/participant row
  where a revoked caller must be refused. Secrets/vars + setup: REFERENCE.md "Accounts setup".
- **Pushes never fail a request**: build them with `pushesAfter` (pure) and hand them to
  `notify(rc, …)` (`ctx.waitUntil`); the text is a `loc-key` the app localizes (`PUSH_*` in
  `Localizable.xcstrings`) — a new kind needs a new key there in all five languages.
- **New Durable Object classes** need a `migrations` tag in every environment (`v2` added
  `MatchQueue`).
- Dependencies are pinned exactly (no `^`), each ≥ 2 weeks old when added.
