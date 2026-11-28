// Match endpoints (#286, REFERENCE.md "Match operations", "Server dice", "WebSocket"):
// thin Worker handlers that validate the body, then ask the match's MatchRoom Durable
// Object (the single writer) and turn its `RoomResult` into a response. The lobby list
// reads D1's `match_index`, which the rooms keep up to date. #287: pushes after the
// operations that concern the other player (push.ts; a lost-reply resend may push twice),
// removing ended matches from the lobby, auto-match through the MatchQueue objects.

import {
  AutoMatchRequest,
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

/** POST /v1/matches — a direct challenge (`opponentID`) or an open seat. */
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
  const result = await rc.env.MATCH_ROOM.getByName(matchID).create({
    matchID,
    variant: req.variant,
    targetWins: req.targetWins,
    creator: { id: auth.accountID, displayName: me },
    opponent: req.opponentID ? { id: req.opponentID, displayName: opponentName! } : undefined,
  });
  const snap = unwrap(result);
  notify(rc, pushesAfter("create", auth.accountID, snap));
  return json(snap, 201);
}

/** GET /v1/matches/{id} — load. */
export async function loadMatch(rc: RouteContext): Promise<Response> {
  return json(unwrap(await room(rc).load(caller(rc).accountID)));
}

export async function acceptMatch(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const snap = unwrap(await room(rc).accept(auth.accountID));
  notify(rc, pushesAfter("accept", auth.accountID, snap));
  return json(snap);
}

export async function declineMatch(rc: RouteContext): Promise<Response> {
  unwrap(await room(rc).decline(caller(rc).accountID));
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
      "mi.outcome, mi.updated_at, i.code AS invite_code, i.expires_at AS invite_expires_at " +
      "FROM match_index mi LEFT JOIN accounts a ON a.id = mi.opponent_id " +
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
