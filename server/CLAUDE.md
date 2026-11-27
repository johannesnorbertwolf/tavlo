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
| `src/index.ts` | Worker entry: dispatch, rate limit, error format, request log, `/health`, hourly `scheduled` usage check; exports `MatchRoom` |
| `src/routes.ts` | Route table = every contract endpoint + its ticket; unbuilt ones answer 501 `not_implemented` |
| `src/api.ts` | **Wire contract**: runtime schemas + types for every body and WebSocket message, error codes |
| `src/schema.ts` | Mini schema kit (`parse` validates, `Infer` types; unknown keys dropped) |
| `src/match-room.ts` | `MatchRoom` Durable Object: append-only storage migrations, ping/pong auto-response |
| `src/http.ts` · `src/log.ts` · `src/rate-limit.ts` | Error format/JSON helpers · JSON-line logger · per-IP/per-account limiter |
| `src/usage.ts` | Free-plan usage check (GraphQL Analytics) + once-a-day webhook alert |
| `migrations/` | D1 migrations (`0001_initial.sql`: accounts, identities, match_index, ops_alerts) |
| `fixtures/` | Shared JSON fixtures, decoded by `test/fixtures.test.ts` **and** Swift `ServerAPITests` |
| `scripts/deploy.sh` · `scripts/d1-backup.sh` | Migrate + deploy + health check · D1 export |
| `wrangler.jsonc` | Top level = local/test; `env.staging` / `env.production` |
| `worker-configuration.d.ts` | Generated (`npm run types`); don't edit |

Swift mirror: `ios/TavliEngine/Sources/TavliEngine/ServerAPI.swift` (`ServerAPI.*`).
CI: `.github/workflows/server.yml`.

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
- **The match payload is opaque** (base64 `OnlineMatchPayload`); the server reads only new
  plies' dice to enforce server rolls (#286). Server-held state lives in the envelope.
- **Bindings are not inherited** by wrangler environments: every `env.*` block repeats vars,
  D1, DO, ratelimits and `migrations`. Rerun `npm run types` after editing.
- **Migrations are append-only** (D1 files and `ROOM_MIGRATIONS`) and must stay compatible with
  the previous release (rollback does not undo them).
- **No remote calls in tests**; inject `fetch` (see `usage.ts`). Logs never contain tokens,
  payloads or IPs.
- Dependencies are pinned exactly (no `^`), each ≥ 2 weeks old when added.
