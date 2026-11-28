// Match endpoints (#286, REFERENCE.md "Match operations", "Server dice", "WebSocket"):
// thin Worker handlers that validate the body, then ask the match's MatchRoom Durable
// Object (the single writer) and turn its `RoomResult` into a response. The lobby list
// reads D1's `match_index`, which the rooms keep up to date. #287: pushes after the
// operations that concern the other player (push.ts; a lost-reply resend may push twice),
// removing ended matches from the lobby, auto-match through the MatchQueue objects.

import {
  AutoMatchRequest,
  CHALLENGE_TTL_MS,
  type ChallengeStatus,
  type MatchSnapshot,
  CreateMatchRequest,
  DiceChangeRequest,
  EndMatchRequest,
  type MatchListResponse,
  type MatchSummary,
  QuitRequest,
  RollRequest,
  SendRequestRequest,
  WriteTurnRequest,
} from "./api";
import type { AccountDeletionHook } from "./account-hooks";
import { HttpError, json, readJson } from "./http";
import { inviteDeps, inviteURL } from "./invites";
import type { RoomResult, WriteOp } from "./match-room";
import { queueName } from "./match-queue";
import { notify, type PushMessage, pushesAfter, sendPushes } from "./push";
import type { RouteContext } from "./routes";
import {
  challengeOf,
  challengePermission,
  challengeView,
  expireOne,
  insertChallenge,
  loadChallenge,
  peopleDeps,
  pendingBetween,
  sendLive,
  transition,
} from "./people";
import { randomToken } from "./sessions";

const MATCH_ID = /^[A-Za-z0-9_-]{1,64}$/;
/** Lobby page size. */
export const LIST_PAGE = 50;

function caller(rc: RouteContext) {
  if (!rc.auth) throw new HttpError("unauthorized", "Sign in first.");
  return rc.auth;
}

function room(rc: RouteContext) {
  const id = rc.params.matchID ?? "";
  if (!MATCH_ID.test(id)) throw new HttpError("not_found", "No such match.");
  return rc.env.MATCH_ROOM.getByName(id);
}

function unwrap<T>(result: RoomResult<T>): T {
  if (result.ok) return result.value;
  const { code, message, path } = result.error;
  throw new HttpError(code, message, path ? { path } : {});
}

async function displayNames(env: Env, ids: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (!ids.length) return out;
  const { results } = await env.DB.prepare(
    `SELECT id, display_name FROM accounts WHERE id IN (${ids.map(() => "?").join(", ")})`,
  )
    .bind(...ids)
    .all<{ id: string; display_name: string }>();
  for (const r of results) out.set(r.id, r.display_name);
  return out;
}

/**
 * POST /v1/matches — a direct challenge (`opponentID`, #301 lifecycle) or an open seat.
 *
 * A challenge (people.ts): refused when either blocked the other or the opponent takes
 * challenges only from its people (403); the same challenge again answers the pending one
 * (200), a different one replaces it; when the opponent already challenged the caller to
 * the same game, that challenge is accepted instead (crossed taps, 200). Otherwise a new
 * match (201) + `challenges` row, the "challenge" push with Accept / Decline, and the live
 * `received` event to the opponent's open app.
 */
export async function createMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, CreateMatchRequest);
  if (req.opponentID === auth.accountID) {
    throw new HttpError("bad_request", "You can't challenge yourself.", { path: "opponentID" });
  }
  // The caller's account must still exist (an access token outlives a deletion by ≤ 1 h).
  const names = await displayNames(rc.env, req.opponentID ? [auth.accountID, req.opponentID] : [auth.accountID]);
  const me = names.get(auth.accountID);
  if (!me) throw new HttpError("unauthorized", "Account no longer exists.");
  const opponentName = req.opponentID ? names.get(req.opponentID) : undefined;
  if (req.opponentID && !opponentName) throw new HttpError("not_found", "No such player.", { path: "opponentID" });
  const matchID = randomToken("m_", 9);
  if (req.opponentID) return challenge(rc, auth.accountID, me, req.opponentID, opponentName!, req.variant, req.targetWins, matchID);
  const snap = unwrap(
    await rc.env.MATCH_ROOM.getByName(matchID).create({
      matchID,
      variant: req.variant,
      targetWins: req.targetWins,
      creator: { id: auth.accountID, displayName: me },
    }),
  );
  return json(snap, 201);
}

async function challenge(
  rc: RouteContext,
  me: string,
  myName: string,
  opponent: string,
  opponentName: string,
  variant: MatchSnapshot["variant"],
  targetWins: number,
  matchID: string,
): Promise<Response> {
  const permission = await challengePermission(rc.env, me, opponent);
  if (permission === "blocked") throw new HttpError("forbidden", "You can't challenge this player.", { path: "opponentID" });
  if (permission === "notPeople") {
    throw new HttpError("forbidden", "This player takes challenges only from people they know.", { path: "opponentID" });
  }
  const now = peopleDeps.now();
  // Crossed taps: they already challenged me to the same game → that one is accepted.
  const reverse = await pendingBetween(rc.env, opponent, me);
  if (reverse && reverse.expires_at <= now) await expireOne(rc, reverse, now);
  else if (reverse && reverse.variant === variant && reverse.target_wins === targetWins) {
    return json(await acceptChallenge(rc, me, reverse.match_id));
  }
  for (let attempt = 0; attempt < 3; attempt++) {
    const existing = await pendingBetween(rc.env, me, opponent);
    if (existing) {
      if (existing.expires_at <= now) {
        await expireOne(rc, existing, now);
      } else if (existing.variant === variant && existing.target_wins === targetWins) {
        // The same challenge again (a second tap): the pending one.
        return json(unwrap(await rc.env.MATCH_ROOM.getByName(existing.match_id).load(me)));
      } else if (await transition(rc.env, existing.match_id, "cancelled", now)) {
        // Another game this time: the pending one is taken back.
        await rc.env.MATCH_ROOM.getByName(existing.match_id).closeInvitedSeat();
        sendLive(rc, [opponent], "cancelled", await challengeView(rc.env, existing, "cancelled"));
      }
      continue;
    }
    const row = { match_id: matchID, challenger_id: me, challenged_id: opponent, variant, target_wins: targetWins };
    if (!(await insertChallenge(rc.env, row, now))) continue; // a concurrent tap won: answer its challenge
    const created = await rc.env.MATCH_ROOM.getByName(matchID).create({
      matchID,
      variant,
      targetWins,
      creator: { id: me, displayName: myName },
      opponent: { id: opponent, displayName: opponentName },
    });
    if (!created.ok) {
      await transition(rc.env, matchID, "cancelled", now);
      return json(unwrap(created));
    }
    const snap = created.value;
    notify(rc, pushesAfter("create", me, snap));
    const view = challengeOf(snap, { created_at: now, expires_at: now + CHALLENGE_TTL_MS });
    if (view) sendLive(rc, [opponent], "received", view);
    return json(snap, 201);
  }
  throw new HttpError("unavailable", "Couldn't send the challenge; try again.");
}

/**
 * Accept a direct challenge as `me` (the challenged player): the pending row is claimed
 * (one conditional UPDATE: of an accept, a decline, a cancel and the expiry exactly one
 * wins), then the room's seat accepts. A lost reply (already accepted) answers the match;
 * anything closed → 410 `invite_unavailable`.
 */
async function acceptChallenge(rc: RouteContext, me: string, matchID: string): Promise<MatchSnapshot> {
  const now = peopleDeps.now();
  const row = await loadChallenge(rc.env, matchID);
  const stub = rc.env.MATCH_ROOM.getByName(matchID);
  if (!row || row.challenged_id !== me) {
    const snap = unwrap(await stub.accept(me)); // not a challenge (or not to me): the room decides
    notify(rc, pushesAfter("accept", me, snap));
    return snap;
  }
  if (row.status === "pending" && row.expires_at <= now) {
    await expireOne(rc, row, now);
    throw new HttpError("invite_unavailable", "The challenge expired.");
  }
  if (row.status === "pending" && !(await transition(rc.env, matchID, "accepted", now))) {
    const again = await loadChallenge(rc.env, matchID);
    if (again?.status !== "accepted") throw new HttpError("invite_unavailable", `The challenge is ${again?.status ?? "gone"}.`);
  } else if (row.status !== "pending" && row.status !== "accepted") {
    throw new HttpError("invite_unavailable", `The challenge is ${row.status}.`);
  }
  const accepted = await stub.accept(me);
  if (!accepted.ok) {
    // The challenger left meanwhile (quit): the challenge is over.
    if (accepted.error.code === "match_ended") {
      await rc.env.DB.prepare("UPDATE challenges SET status = 'cancelled' WHERE match_id = ? AND status = 'accepted'")
        .bind(matchID)
        .run();
      throw new HttpError("invite_unavailable", "The challenge was taken back.");
    }
    return unwrap(accepted);
  }
  if (row.status === "pending") {
    notify(rc, pushesAfter("accept", me, accepted.value));
    sendLive(rc, [row.challenger_id], "accepted", await challengeView(rc.env, row, "accepted"));
  }
  return accepted.value;
}

/** GET /v1/matches/{id} — load. */
export async function loadMatch(rc: RouteContext): Promise<Response> {
  return json(unwrap(await room(rc).load(caller(rc).accountID)));
}

export async function acceptMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  room(rc); // validates the id
  return json(await acceptChallenge(rc, auth.accountID, rc.params.matchID!));
}

/**
 * Decline a direct challenge (also from the notification's Decline button, without
 * opening the app): pending → declined, the match ends, the challenger is told (push +
 * live). Again → 204; already accepted → 409 `match_ended` (from the room).
 */
export async function declineMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const stub = room(rc);
  const matchID = rc.params.matchID!;
  const now = peopleDeps.now();
  const row = await loadChallenge(rc.env, matchID);
  if (row && row.challenged_id === auth.accountID) {
    if (row.status === "declined") return new Response(null, { status: 204 });
    if (row.status === "pending" && row.expires_at <= now) {
      await expireOne(rc, row, now);
      return new Response(null, { status: 204 });
    }
    if (row.status === "pending" && !(await transition(rc.env, matchID, "declined", now))) {
      const again = await loadChallenge(rc.env, matchID);
      if (again?.status === "declined" || again?.status === "expired" || again?.status === "cancelled") {
        return new Response(null, { status: 204 });
      }
    } else if (row.status === "pending") {
      unwrap(await stub.decline(auth.accountID));
      const snap = await stub.load(row.challenger_id);
      if (snap.ok) notify(rc, pushesAfter("decline", auth.accountID, snap.value));
      sendLive(rc, [row.challenger_id], "declined", await challengeView(rc.env, row, "declined"));
      return new Response(null, { status: 204 });
    } else if (row.status === "expired" || row.status === "cancelled") {
      return new Response(null, { status: 204 });
    }
  }
  unwrap(await stub.decline(auth.accountID));
  return new Response(null, { status: 204 });
}

/**
 * POST /v1/matches/{id}/cancel (#301) — the challenger takes a pending challenge back: the
 * match ends, the challenged app's card goes (live `cancelled`). Again → 204; answered
 * already → 410 `invite_unavailable` (an accepted one: open the match instead).
 */
export async function cancelChallenge(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const stub = room(rc);
  const matchID = rc.params.matchID!;
  const now = peopleDeps.now();
  const row = await loadChallenge(rc.env, matchID);
  if (!row) throw new HttpError("not_found", "No such challenge.");
  if (row.challenger_id !== auth.accountID) throw new HttpError("forbidden", "Not your challenge.");
  if (row.status === "cancelled") return new Response(null, { status: 204 });
  if (row.status === "pending" && row.expires_at <= now) {
    await expireOne(rc, row, now);
    return new Response(null, { status: 204 });
  }
  if (row.status !== "pending" || !(await transition(rc.env, matchID, "cancelled", now))) {
    const again = await loadChallenge(rc.env, matchID);
    if (again?.status === "cancelled" || again?.status === "expired") return new Response(null, { status: 204 });
    throw new HttpError("invite_unavailable", `The challenge is ${again?.status ?? row.status}.`);
  }
  await stub.closeInvitedSeat();
  sendLive(rc, [row.challenged_id], "cancelled", await challengeView(rc.env, row, "cancelled"));
  return new Response(null, { status: 204 });
}

function writeHandler(op: WriteOp) {
  return async (rc: RouteContext): Promise<Response> => {
    const auth = caller(rc);
    const stub = room(rc);
    if (op === "endMatch") {
      const req = await readJson(rc.request, EndMatchRequest);
      const snap = unwrap(await stub.write(auth.accountID, op, req));
      notify(rc, pushesAfter("endMatch", auth.accountID, snap));
      return json(snap);
    }
    const req = await readJson(rc.request, WriteTurnRequest);
    const snap = unwrap(await stub.write(auth.accountID, op, req));
    if (op === "endTurn") notify(rc, pushesAfter("endTurn", auth.accountID, snap));
    return json(snap);
  };
}

export const endTurn = writeHandler("endTurn");
export const saveTurn = writeHandler("saveTurn");
export const endMatch = writeHandler("endMatch");

export async function quitMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, QuitRequest);
  const snap = unwrap(await room(rc).quit(auth.accountID, req));
  notify(rc, pushesAfter("quit", auth.accountID, snap));
  return json(snap);
}

/** DELETE /v1/matches/{id} — hide an ended match from the caller's lobby (#287). */
export async function removeMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const id = rc.params.matchID ?? "";
  if (!MATCH_ID.test(id)) throw new HttpError("not_found", "No such match.");
  const row = await rc.env.DB.prepare("SELECT state FROM match_index WHERE match_id = ? AND account_id = ?")
    .bind(id, auth.accountID)
    .first<{ state: string }>();
  if (!row) throw new HttpError("not_found", "No such match.");
  if (row.state !== "ended") throw new HttpError("forbidden", "Only finished games can be removed.");
  await rc.env.DB.prepare("UPDATE match_index SET hidden = 1 WHERE match_id = ? AND account_id = ?")
    .bind(id, auth.accountID)
    .run();
  return new Response(null, { status: 204 });
}

/**
 * POST /v1/automatch — a random opponent for the same variant + length (GameKit
 * auto-match): joins the oldest waiting match of someone else, or creates one and waits
 * in it (the creator may start playing). Cancel = quit out of turn.
 */
export async function autoMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, AutoMatchRequest);
  const me = (await displayNames(rc.env, [auth.accountID])).get(auth.accountID);
  if (!me) throw new HttpError("unauthorized", "Account no longer exists.");
  const result = unwrap(
    await rc.env.MATCH_QUEUE.getByName(queueName(req.variant, req.targetWins)).enter({
      player: { id: auth.accountID, displayName: me },
      variant: req.variant,
      targetWins: req.targetWins,
    }),
  );
  if (result.joined) notify(rc, pushesAfter("join", auth.accountID, result.match));
  return json(result.match);
}

export async function sendRequest(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, SendRequestRequest);
  return json(unwrap(await room(rc).sendRequest(auth.accountID, req.data)), 202);
}

export async function changeDice(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, DiceChangeRequest);
  return json(unwrap(await room(rc).changeDice(auth.accountID, req.whiteLevel, req.baseRev)));
}

export async function rollDice(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, RollRequest);
  return json(unwrap(await room(rc).roll(auth.accountID, req)));
}

/** GET /v1/matches/{id}/socket — hand the upgrade to the room with the verified caller. */
export async function matchSocket(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  if (rc.request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
    throw new HttpError("bad_request", "Expected a WebSocket upgrade.", { path: "upgrade" });
  }
  const headers = new Headers(rc.request.headers);
  headers.delete("authorization");
  headers.set("x-tavtav-account", auth.accountID);
  headers.set("x-tavtav-token-exp", String(auth.expiresAt ?? 0));
  return room(rc).fetch(new Request(rc.request.url, { method: "GET", headers }));
}

// ── Lobby list ──────────────────────────────────────────────────────────────────

interface IndexRow {
  match_id: string;
  variant: string;
  target_wins: number;
  state: string;
  opponent_id: string | null;
  opponent_name: string | null;
  outcome: string;
  updated_at: number;
  invite_code: string | null;
  invite_expires_at: number | null;
  challenge_status: string | null;
  challenge_expires_at: number | null;
}

/** GET /v1/matches?state=active|ended&cursor= — newest first, `LIST_PAGE` per page. */
export async function listMatches(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const state = rc.url.searchParams.get("state");
  if (state !== null && state !== "active" && state !== "ended") {
    throw new HttpError("bad_request", "state must be active or ended.", { path: "state" });
  }
  const cursor = rc.url.searchParams.get("cursor");
  const where = ["mi.account_id = ?", "mi.hidden = 0"];
  const binds: unknown[] = [auth.accountID];
  if (state === "active") where.push("mi.state != 'ended'");
  if (state === "ended") where.push("mi.state = 'ended'");
  if (cursor) {
    const m = /^(\d+)~([A-Za-z0-9_-]{1,64})$/.exec(cursor);
    if (!m) throw new HttpError("bad_request", "Invalid cursor.", { path: "cursor" });
    where.push("(mi.updated_at < ? OR (mi.updated_at = ? AND mi.match_id < ?))");
    binds.push(Number(m[1]), Number(m[1]), m[2]);
  }
  // #287: the caller's open invite for a waiting match (to share it again or cancel it).
  const { results } = await rc.env.DB.prepare(
    "SELECT mi.match_id, mi.variant, mi.target_wins, mi.state, mi.opponent_id, a.display_name AS opponent_name, " +
      "mi.outcome, mi.updated_at, i.code AS invite_code, i.expires_at AS invite_expires_at, " +
      "c.status AS challenge_status, c.expires_at AS challenge_expires_at " +
      "FROM match_index mi LEFT JOIN accounts a ON a.id = mi.opponent_id " +
      "LEFT JOIN challenges c ON c.match_id = mi.match_id " +
      "LEFT JOIN invites i ON i.match_id = mi.match_id AND i.creator_id = mi.account_id AND i.status = 'open' " +
      "AND i.expires_at > ? AND mi.state != 'ended' " +
      `WHERE ${where.join(" AND ")} ORDER BY mi.updated_at DESC, mi.match_id DESC LIMIT ?`,
  )
    .bind(inviteDeps.now(), ...binds, LIST_PAGE + 1)
    .all<IndexRow>();
  const page = results.slice(0, LIST_PAGE);
  const matches = page.map((r): MatchSummary => {
    const row: MatchSummary = {
      matchID: r.match_id,
      variant: r.variant as MatchSummary["variant"],
      targetWins: r.target_wins,
      state: r.state as MatchSummary["state"],
      opponent: { playerID: r.opponent_id, displayName: r.opponent_name },
      outcome: r.outcome as MatchSummary["outcome"],
      updatedAt: r.updated_at,
    };
    if (r.challenge_status && r.challenge_expires_at !== null) {
      // #301: a pending challenge past its expiry reads expired (the cron closes it).
      const expired = r.challenge_status === "pending" && r.challenge_expires_at <= peopleDeps.now();
      row.challenge = {
        status: (expired ? "expired" : r.challenge_status) as ChallengeStatus,
        expiresAt: r.challenge_expires_at,
      };
    }
    if (r.invite_code && r.invite_expires_at !== null) {
      row.invite = { code: r.invite_code, url: inviteURL(rc.url.origin, r.invite_code), expiresAt: r.invite_expires_at };
    }
    return row;
  });
  const last = page[page.length - 1];
  const body: MatchListResponse = {
    matches,
    nextCursor: results.length > LIST_PAGE && last ? `${last.updated_at}~${last.match_id}` : null,
  };
  return json(body);
}

// ── Account deletion (#285 hook) ───────────────────────────────────────────────

/**
 * Ends the deleted player's running matches as a quit and anonymises them in all; the
 * opponents of matches that ended get the "opponent left" push (#287).
 */
export const endMatchesOfDeletedAccount: AccountDeletionHook = async (env, deletion, log) => {
  const name = (await displayNames(env, [deletion.accountID])).get(deletion.accountID) ?? "?";
  const pushes: PushMessage[] = [];
  for (const matchID of deletion.matchIDs) {
    const opponent = await env.MATCH_ROOM.getByName(matchID).accountDeleted(deletion.accountID);
    if (opponent) pushes.push({ to: opponent, kind: "opponentLeft", matchID, name });
  }
  if (deletion.matchIDs.length) log.info("account.matches_closed", { matches: deletion.matchIDs.length });
  await sendPushes(env, pushes, log);
};
