// People, presence, one-tap challenges (#301, REFERENCE.md "People, presence, challenges").
//
// - The people list is derived from D1 `match_index` (rows with `played = 1`: both seats
//   accepted), one entry per opponent, newest game first; `contact_prefs` holds the
//   caller's pin / remove choices. Unpinned people drop off after 90 days without a game.
// - Presence lives in the `PresenceHub` Durable Object (presence-hub.ts): a person's online
//   status / last seen is asked only for the caller's people who don't hide it, which is
//   also the watch list for live updates.
// - A challenge is a direct-challenge match (`POST /v1/matches` with `opponentID`) plus a
//   D1 `challenges` row for its lifecycle (pending → accepted / declined / expired after 24 h
//   / cancelled). Every transition is one conditional UPDATE `WHERE status = 'pending'`, so
//   of an accept, a decline, a cancel and the expiry racing exactly one wins; the MatchRoom
//   then follows (accept / decline / closeInvitedSeat). Events reach open apps live over the
//   presence socket; pushes go out as for every match operation (push.ts).

import {
  CHALLENGE_TTL_MS,
  type Challenge,
  type ChallengeStatus,
  type MatchSnapshot,
  PEOPLE_LIMIT,
  PEOPLE_MAX_AGE_MS,
  type PeopleResponse,
  type Person,
  type PlayerCard,
  type PlayerResult,
  type PlayerSearchResponse,
  type Presence,
  SEARCH_LIMIT,
  SEARCH_MIN_CHARS,
  UpdatePersonRequest,
  type VariantID,
} from "./api";
import type { AccountDeletionHook } from "./account-hooks";
import { HttpError, json, readJson } from "./http";
import type { Logger } from "./log";
import { enforceRateLimit } from "./rate-limit";
import type { RouteContext } from "./routes";

/** Test seam: the clock of the people list and the challenge lifecycle. */
export const peopleDeps: { now: () => number } = { now: () => Date.now() };

const ID = /^[A-Za-z0-9_-]{1,64}$/;

export function presenceHub(env: Env) {
  return env.PRESENCE.getByName("global");
}

function caller(rc: RouteContext) {
  if (!rc.auth) throw new HttpError("unauthorized", "Sign in first.");
  return rc.auth;
}

// ── People list ─────────────────────────────────────────────────────────────────

interface PersonRow {
  id: string;
  handle: string;
  display_name: string;
  last_played: number | null;
  hide_presence: number;
  pinned: number;
  added_me: number;
}

interface ChallengeRow {
  match_id: string;
  challenger_id: string;
  challenged_id: string;
  variant: string;
  target_wins: number;
  status: ChallengeStatus;
  created_at: number;
  expires_at: number;
}

/** Neither has blocked the other (SQL fragment over `?1` = the caller and `a.id`). */
const NOT_BLOCKED =
  "NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = ?1 AND b.blocked_id = a.id) OR (b.blocker_id = a.id AND b.blocked_id = ?1))";

/**
 * The caller's people: everyone played with (both accepted) plus everyone pinned (⭐, also
 * how a player found by handle is added); pinned first, then the newest game. An unpinned
 * person drops off after 90 days without a game or once removed (until a newer game).
 * Blocks in either direction hide them.
 */
export async function peopleRows(env: Env, accountID: string, now: number): Promise<PersonRow[]> {
  const { results } = await env.DB.prepare(
    "WITH played AS (SELECT opponent_id AS id, MAX(updated_at) AS last FROM match_index " +
      "WHERE account_id = ?1 AND played = 1 AND opponent_id IS NOT NULL GROUP BY opponent_id), " +
      "cand AS (SELECT id FROM played UNION SELECT contact_id FROM contact_prefs WHERE account_id = ?1 AND pinned = 1) " +
      "SELECT a.id, a.handle, a.display_name, a.hide_presence, p.last AS last_played, coalesce(cp.pinned, 0) AS pinned, " +
      "EXISTS (SELECT 1 FROM contact_prefs r WHERE r.account_id = a.id AND r.contact_id = ?1 AND r.pinned = 1) AS added_me " +
      "FROM cand JOIN accounts a ON a.id = cand.id LEFT JOIN played p ON p.id = a.id " +
      "LEFT JOIN contact_prefs cp ON cp.account_id = ?1 AND cp.contact_id = a.id " +
      "WHERE a.id != ?1 AND a.handle IS NOT NULL " +
      "AND (coalesce(cp.pinned, 0) = 1 OR (p.last >= ?2 AND (cp.removed_at IS NULL OR p.last > cp.removed_at))) " +
      `AND ${NOT_BLOCKED} ` +
      "ORDER BY pinned DESC, coalesce(p.last, 0) DESC, a.id LIMIT ?3",
  )
    .bind(accountID, now - PEOPLE_MAX_AGE_MS, PEOPLE_LIMIT)
    .all<PersonRow>();
  return results;
}

/**
 * Who may see a person's online status: people you've played with, or who added you while
 * you added them (both ⭐) — and only while they don't hide it.
 */
export function presenceVisible(r: Pick<PersonRow, "last_played" | "pinned" | "added_me" | "hide_presence">): boolean {
  if (r.hide_presence) return false;
  return r.last_played !== null || (r.pinned === 1 && r.added_me === 1);
}

/** GET /v1/people — the people list with presence and pending challenges (+ whom you blocked). */
export async function listPeople(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const now = peopleDeps.now();
  const rows = await peopleRows(rc.env, auth.accountID, now);
  // Watch everyone allowed to be seen, hidden or not (the hub never reports or broadcasts a
  // hidden account, and so un-hiding reaches the open apps at once).
  const visible = rows.filter((r) => presenceVisible({ ...r, hide_presence: 0 })).map((r) => r.id);
  let presence: Record<string, Presence> = {};
  try {
    presence = await presenceHub(rc.env).lookup(auth.accountID, visible);
  } catch {
    // Presence is a nicety: the list still works without it.
  }
  const { results: pending } = await rc.env.DB.prepare(
    "SELECT * FROM challenges WHERE status = 'pending' AND expires_at > ? AND (challenger_id = ? OR challenged_id = ?) " +
      "ORDER BY created_at DESC",
  )
    .bind(now, auth.accountID, auth.accountID)
    .all<ChallengeRow>();
  const people = rows.map((r): Person => {
    const person: Person = {
      playerID: r.id,
      handle: r.handle,
      displayName: r.display_name,
      pinned: r.pinned === 1,
      lastPlayedAt: r.last_played,
    };
    const p = presence[r.id];
    if (p && presenceVisible(r)) person.presence = p;
    // The newest pending challenge with this person (either direction).
    const c = pending.find((x) => x.challenger_id === r.id || x.challenged_id === r.id);
    if (c) {
      person.challenge = {
        matchID: c.match_id,
        direction: c.challenger_id === auth.accountID ? "outgoing" : "incoming",
        variant: c.variant as VariantID,
        targetWins: c.target_wins,
        expiresAt: c.expires_at,
      };
    }
    return person;
  });
  const { results: blocked } = await rc.env.DB.prepare(
    "SELECT a.id AS playerID, a.handle, a.display_name AS displayName FROM blocks b JOIN accounts a ON a.id = b.blocked_id " +
      "WHERE b.blocker_id = ? AND a.handle IS NOT NULL ORDER BY b.created_at DESC LIMIT 200",
  )
    .bind(auth.accountID)
    .all<PlayerCard>();
  const body: PeopleResponse = { people, blocked };
  return json(body);
}

function personParam(rc: RouteContext, self?: string): string {
  const id = rc.params.playerID ?? "";
  if (!ID.test(id) || id === self) throw new HttpError("not_found", "No such person.");
  return id;
}

/** The account exists and neither blocked the other (404 otherwise: nothing to tell apart). */
async function requireReachable(env: Env, accountID: string, personID: string): Promise<void> {
  const row = await env.DB.prepare(`SELECT 1 AS ok FROM accounts a WHERE a.id = ?2 AND ${NOT_BLOCKED}`)
    .bind(accountID, personID)
    .first();
  if (!row) throw new HttpError("not_found", "No such person.");
}

/**
 * PATCH /v1/people/{playerID} {pinned} — ⭐ keeps them on top (and back after a removal);
 * pinning someone found by handle adds them to your people.
 */
export async function updatePerson(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const id = personParam(rc, auth.accountID);
  const req = await readJson(rc.request, UpdatePersonRequest);
  await requireReachable(rc.env, auth.accountID, id);
  const now = peopleDeps.now();
  await rc.env.DB.prepare(
    "INSERT INTO contact_prefs (account_id, contact_id, pinned, removed_at, updated_at) VALUES (?, ?, ?, NULL, ?) " +
      "ON CONFLICT (account_id, contact_id) DO UPDATE SET pinned = excluded.pinned, updated_at = excluded.updated_at, " +
      "removed_at = CASE WHEN excluded.pinned = 1 THEN NULL ELSE contact_prefs.removed_at END",
  )
    .bind(auth.accountID, id, req.pinned ? 1 : 0, now)
    .run();
  return new Response(null, { status: 204 });
}

/** DELETE /v1/people/{playerID} — off the list (unpinned) until you play again. */
export async function removePerson(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const id = personParam(rc, auth.accountID);
  const exists = await rc.env.DB.prepare("SELECT 1 AS ok FROM accounts WHERE id = ?").bind(id).first();
  if (!exists) throw new HttpError("not_found", "No such person.");
  const now = peopleDeps.now();
  await rc.env.DB.prepare(
    "INSERT INTO contact_prefs (account_id, contact_id, pinned, removed_at, updated_at) VALUES (?, ?, 0, ?, ?) " +
      "ON CONFLICT (account_id, contact_id) DO UPDATE SET pinned = 0, removed_at = excluded.removed_at, updated_at = excluded.updated_at",
  )
    .bind(auth.accountID, id, now, now)
    .run();
  return new Response(null, { status: 204 });
}

// ── Blocking, challenge permission ────────────────────────────────────────────────

/**
 * POST /v1/people/{playerID}/block — they can't challenge you, find you or see your status
 * any more; their pending challenges to you are declined quietly (no push), yours to them
 * cancelled, and neither shows in the other's people list. Idempotent.
 */
export async function blockPerson(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const id = personParam(rc, auth.accountID);
  const exists = await rc.env.DB.prepare("SELECT 1 AS ok FROM accounts WHERE id = ?").bind(id).first();
  if (!exists) throw new HttpError("not_found", "No such person.");
  const now = peopleDeps.now();
  await rc.env.DB.batch([
    rc.env.DB.prepare("INSERT OR IGNORE INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)").bind(auth.accountID, id, now),
    rc.env.DB.prepare("UPDATE contact_prefs SET pinned = 0, updated_at = ? WHERE account_id = ? AND contact_id = ?").bind(now, auth.accountID, id),
  ]);
  const { results: pending } = await rc.env.DB.prepare(
    "SELECT * FROM challenges WHERE status = 'pending' AND ((challenger_id = ?1 AND challenged_id = ?2) OR (challenger_id = ?2 AND challenged_id = ?1))",
  )
    .bind(id, auth.accountID)
    .all<ChallengeRow>();
  for (const row of pending) {
    const incoming = row.challenger_id === id;
    const status = incoming ? "declined" : "cancelled";
    if (!(await transition(rc.env, row.match_id, status, now))) continue;
    const room = rc.env.MATCH_ROOM.getByName(row.match_id);
    if (incoming) await room.decline(auth.accountID);
    else await room.closeInvitedSeat();
    sendLive(rc, [id], status, await challengeView(rc.env, row, status));
  }
  rc.ctx.waitUntil(presenceHub(rc.env).unwatch(auth.accountID, id).catch(() => undefined));
  return new Response(null, { status: 204 });
}

/** DELETE /v1/people/{playerID}/block — unblock (204, also when not blocked). */
export async function unblockPerson(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const id = personParam(rc, auth.accountID);
  await rc.env.DB.prepare("DELETE FROM blocks WHERE blocker_id = ? AND blocked_id = ?").bind(auth.accountID, id).run();
  return new Response(null, { status: 204 });
}

export type ChallengePermission = "ok" | "missing" | "blocked" | "notPeople";

/**
 * May `from` challenge `to`? Not when either blocked the other; with `to`'s "only my
 * people" only someone `to` played with or pinned.
 */
export async function challengePermission(env: Env, from: string, to: string): Promise<ChallengePermission> {
  const row = await env.DB.prepare(
    "SELECT a.challenge_policy, " +
      "EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker_id = ?1 AND b.blocked_id = ?2) OR (b.blocker_id = ?2 AND b.blocked_id = ?1)) AS blocked, " +
      "EXISTS (SELECT 1 FROM match_index WHERE account_id = ?2 AND opponent_id = ?1 AND played = 1) AS played, " +
      "EXISTS (SELECT 1 FROM contact_prefs WHERE account_id = ?2 AND contact_id = ?1 AND pinned = 1) AS pinned " +
      "FROM accounts a WHERE a.id = ?2",
  )
    .bind(from, to)
    .first<{ challenge_policy: string; blocked: number; played: number; pinned: number }>();
  if (!row) return "missing";
  if (row.blocked) return "blocked";
  if (row.challenge_policy === "people" && !row.played && !row.pinned) return "notPeople";
  return "ok";
}

// ── Search by handle ────────────────────────────────────────────────────────────

/**
 * GET /v1/players?q= — prefix search on the handle (≥ 3 characters, a leading `@` is
 * ignored, case-insensitive), exact match first, `SEARCH_LIMIT` results; never yourself or
 * anyone who blocked you (or whom you blocked). Strangers show only handle + display name.
 * Rate-limited per account (`SEARCH_LIMITER`, 30/min).
 */
export async function searchPlayers(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  await enforceRateLimit(rc.env, { kind: "search", accountID: auth.accountID });
  const q = (rc.url.searchParams.get("q") ?? "").trim().replace(/^@/, "").toLowerCase();
  if (q.length < SEARCH_MIN_CHARS || q.length > 20 || !/^[a-z0-9_]+$/.test(q)) {
    throw new HttpError("bad_request", `Type at least ${SEARCH_MIN_CHARS} letters, digits or _.`, { path: "q" });
  }
  const { results } = await rc.env.DB.prepare(
    "SELECT a.id, a.handle, a.display_name, a.challenge_policy, " +
      "EXISTS (SELECT 1 FROM match_index WHERE account_id = a.id AND opponent_id = ?1 AND played = 1) AS played, " +
      "EXISTS (SELECT 1 FROM contact_prefs WHERE account_id = a.id AND contact_id = ?1 AND pinned = 1) AS pinned_me " +
      "FROM accounts a WHERE a.handle_key >= ?2 AND a.handle_key < ?3 AND a.id != ?1 " +
      `AND ${NOT_BLOCKED} ORDER BY (a.handle_key = ?2) DESC, a.handle_key LIMIT ?4`,
  )
    .bind(auth.accountID, q, `${q}~`, SEARCH_LIMIT)
    .all<{ id: string; handle: string; display_name: string; challenge_policy: string; played: number; pinned_me: number }>();
  const mine = new Set((await peopleRows(rc.env, auth.accountID, peopleDeps.now())).map((r) => r.id));
  const body: PlayerSearchResponse = {
    players: results.map(
      (r): PlayerResult => ({
        playerID: r.id,
        handle: r.handle,
        displayName: r.display_name,
        isPerson: mine.has(r.id),
        canChallenge: r.challenge_policy !== "people" || r.played === 1 || r.pinned_me === 1,
      }),
    ),
  };
  return json(body);
}

// ── Presence socket ─────────────────────────────────────────────────────────────

/** GET /v1/presence/socket — the app's one foreground socket (presence + live challenges). */
export async function presenceSocket(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  if (rc.request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new HttpError("bad_request", "Expected a WebSocket upgrade.", { path: "upgrade" });
  }
  const row = await rc.env.DB.prepare("SELECT hide_presence FROM accounts WHERE id = ?")
    .bind(auth.accountID)
    .first<{ hide_presence: number }>();
  if (!row) throw new HttpError("unauthorized", "Account no longer exists.");
  const headers = new Headers(rc.request.headers);
  headers.delete("authorization");
  headers.set("x-tavtav-account", auth.accountID);
  headers.set("x-tavtav-token-exp", String(auth.expiresAt ?? 0));
  headers.set("x-tavtav-hidden", row.hide_presence ? "1" : "0");
  return presenceHub(rc.env).fetch(new Request(rc.request.url, { method: "GET", headers }));
}

/** Tells the open apps of `to` about a challenge (never fails the request). */
export function sendLive(rc: { env: Env; ctx: ExecutionContext }, to: string[], event: string, challenge: Challenge): void {
  if (!to.length) return;
  const message = { type: "challenge", event, challenge };
  rc.ctx.waitUntil(
    Promise.all(to.map((id) => presenceHub(rc.env).send(id, message))).catch(() => undefined),
  );
}

// ── Challenge lifecycle ─────────────────────────────────────────────────────────

export async function loadChallenge(env: Env, matchID: string): Promise<ChallengeRow | null> {
  return env.DB.prepare("SELECT * FROM challenges WHERE match_id = ?").bind(matchID).first<ChallengeRow>();
}

/** The challenge as the socket reports it (names from `accounts`; "?" once deleted). */
export async function challengeView(env: Env, row: ChallengeRow, status?: ChallengeStatus): Promise<Challenge> {
  const { results } = await env.DB.prepare("SELECT id, display_name FROM accounts WHERE id IN (?, ?)")
    .bind(row.challenger_id, row.challenged_id)
    .all<{ id: string; display_name: string }>();
  const name = (id: string) => results.find((r) => r.id === id)?.display_name ?? "?";
  return {
    matchID: row.match_id,
    from: { playerID: row.challenger_id, displayName: name(row.challenger_id) },
    to: { playerID: row.challenged_id, displayName: name(row.challenged_id) },
    variant: row.variant as VariantID,
    targetWins: row.target_wins,
    status: status ?? row.status,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
  };
}

/**
 * Moves a pending challenge to `status` (one conditional UPDATE: of racing transitions
 * exactly one gets `true`). `accepted` also needs it unexpired.
 */
export async function transition(env: Env, matchID: string, status: Exclude<ChallengeStatus, "pending">, now: number) {
  const res = await env.DB.prepare(
    "UPDATE challenges SET status = ?, answered_at = ? WHERE match_id = ? AND status = 'pending'" +
      (status === "accepted" || status === "declined" || status === "cancelled" ? " AND expires_at > ?" : " AND expires_at <= ?"),
  )
    .bind(status, now, matchID, now)
    .run();
  return res.meta.changes === 1;
}

/**
 * A pending challenge past its expiry: marked expired, its match closed, both apps told.
 * True when this call expired it.
 */
export async function expireOne(rc: { env: Env; ctx: ExecutionContext }, row: ChallengeRow, now: number): Promise<boolean> {
  if (!(await transition(rc.env, row.match_id, "expired", now))) return false;
  await rc.env.MATCH_ROOM.getByName(row.match_id).closeInvitedSeat();
  sendLive(rc, [row.challenger_id, row.challenged_id], "expired", await challengeView(rc.env, row, "expired"));
  return true;
}

/** Records a new direct challenge (the match is created next). False: one is already pending. */
export async function insertChallenge(
  env: Env,
  row: Omit<ChallengeRow, "status" | "created_at" | "expires_at">,
  now: number,
): Promise<boolean> {
  try {
    await env.DB.prepare(
      "INSERT INTO challenges (match_id, challenger_id, challenged_id, variant, target_wins, created_at, expires_at) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
      .bind(row.match_id, row.challenger_id, row.challenged_id, row.variant, row.target_wins, now, now + CHALLENGE_TTL_MS)
      .run();
    return true;
  } catch (e) {
    if (String(e).includes("UNIQUE")) return false;
    throw e;
  }
}

/** The pending challenge from → to (null when none or expired). */
export async function pendingBetween(env: Env, from: string, to: string): Promise<ChallengeRow | null> {
  return env.DB.prepare("SELECT * FROM challenges WHERE challenger_id = ? AND challenged_id = ? AND status = 'pending'")
    .bind(from, to)
    .first<ChallengeRow>();
}

/** Hourly cron: unanswered challenges past their 24 h end (≤ `limit` per run). */
export async function expireChallenges(env: Env, ctx: ExecutionContext, now: number, log: Logger, limit = 100) {
  const { results } = await env.DB.prepare(
    "SELECT * FROM challenges WHERE status = 'pending' AND expires_at <= ? ORDER BY expires_at LIMIT ?",
  )
    .bind(now, limit)
    .all<ChallengeRow>();
  let expired = 0;
  for (const row of results) if (await expireOne({ env, ctx }, row, now)) expired++;
  if (expired) log.info("challenges.expired", { expired });
  return expired;
}

/** The challenge view for a freshly created match (no D1 read for the names). */
export function challengeOf(snap: MatchSnapshot, row: Pick<ChallengeRow, "created_at" | "expires_at">): Challenge | null {
  const [a, b] = snap.participants;
  if (!a?.playerID || !b?.playerID) return null;
  return {
    matchID: snap.matchID,
    from: { playerID: a.playerID, displayName: a.displayName ?? "?" },
    to: { playerID: b.playerID, displayName: b.displayName ?? "?" },
    variant: snap.variant,
    targetWins: snap.targetWins,
    status: "pending",
    createdAt: row.created_at,
    expiresAt: row.expires_at,
  };
}

// ── Account deletion (#301 hook) ─────────────────────────────────────────────────

/**
 * The deleted account's pending challenges are cancelled (the other app's card goes; the
 * matches themselves were ended by the matches hook), its people choices and the choices
 * others made about it are deleted, and the presence hub forgets it (sockets closed).
 */
export const deletePeopleOfDeletedAccount: AccountDeletionHook = async (env, deletion, log) => {
  const now = peopleDeps.now();
  const { results: pending } = await env.DB.prepare(
    "SELECT * FROM challenges WHERE status = 'pending' AND (challenger_id = ? OR challenged_id = ?)",
  )
    .bind(deletion.accountID, deletion.accountID)
    .all<ChallengeRow>();
  for (const row of pending) {
    const other = row.challenger_id === deletion.accountID ? row.challenged_id : row.challenger_id;
    const view = await challengeView(env, row, "cancelled");
    await presenceHub(env)
      .send(other, { type: "challenge", event: "cancelled", challenge: view })
      .catch(() => 0);
  }
  await env.DB.batch([
    env.DB.prepare("DELETE FROM challenges WHERE challenger_id = ? OR challenged_id = ?").bind(deletion.accountID, deletion.accountID),
    env.DB.prepare("DELETE FROM contact_prefs WHERE account_id = ? OR contact_id = ?").bind(deletion.accountID, deletion.accountID),
  ]);
  await presenceHub(env).forget(deletion.accountID);
  log.info("account.people_deleted", { pendingChallenges: pending.length, at: now });
};
