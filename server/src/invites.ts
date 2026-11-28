// Invites by link or code (#287, REFERENCE.md "Invites"): `POST /v1/invites` creates a
// match whose seat 1 is open (`invited`, no player) plus a short code; whoever accepts the
// code joins that seat (single use). Decline, the creator's cancel and expiry close it and
// end the waiting match. Codes live in D1 (`invites`, migration 0003); claiming one is a
// single conditional UPDATE, so two players accepting at once cannot both win.

import {
  CreateInviteRequest,
  INVITE_ALPHABET,
  INVITE_CODE_LENGTH,
  INVITE_TTL_MS,
  type Invite,
  type InvitePreview,
  type VariantID,
} from "./api";
import { HttpError, json, readJson } from "./http";
import type { Logger } from "./log";
import type { RoomResult } from "./match-room";
import { notify, pushesAfter } from "./push";
import type { RouteContext } from "./routes";
import { randomToken } from "./sessions";

/** Test seam: the clock for expiry. */
export const inviteDeps: { now: () => number } = { now: () => Date.now() };

/** A random code: `INVITE_CODE_LENGTH` characters of `INVITE_ALPHABET`, uniform (rejection sampling). */
export function newInviteCode(random: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
  const n = INVITE_ALPHABET.length;
  const limit = 256 - (256 % n); // bytes >= limit would bias the first characters
  let out = "";
  while (out.length < INVITE_CODE_LENGTH) {
    for (const b of random(INVITE_CODE_LENGTH * 2)) {
      if (b >= limit) continue;
      out += INVITE_ALPHABET[b % n];
      if (out.length === INVITE_CODE_LENGTH) break;
    }
  }
  return out;
}

/**
 * A typed or linked code as the server stores it: upper case, spaces and dashes dropped.
 * Look-alikes are not in the alphabet, so a typed O / 0 / I / 1 / L simply finds nothing.
 */
export function normalizeInviteCode(raw: string): string | null {
  const code = raw.toUpperCase().replace(/[\s-]/g, "");
  return /^[A-Z0-9]{6,12}$/.test(code) ? code : null;
}

export function inviteURL(origin: string, code: string): string {
  return `${origin}/join/${code}`;
}

interface InviteRow {
  code: string;
  match_id: string;
  creator_id: string;
  creator_name: string | null;
  variant: string;
  target_wins: number;
  status: InvitePreview["status"];
  accepted_by: string | null;
  expires_at: number;
}

/** The invite row (with the creator's name), `open` past its expiry reads `expired`. */
export async function loadInvite(env: Env, code: string, now: number): Promise<InviteRow | null> {
  const row = await env.DB.prepare(
    "SELECT i.code, i.match_id, i.creator_id, a.display_name AS creator_name, i.variant, i.target_wins, i.status, " +
      "i.accepted_by, i.expires_at FROM invites i LEFT JOIN accounts a ON a.id = i.creator_id WHERE i.code = ?",
  )
    .bind(code)
    .first<InviteRow>();
  if (!row) return null;
  if (row.status === "open" && row.expires_at <= now) row.status = "expired";
  return row;
}

function caller(rc: RouteContext) {
  if (!rc.auth) throw new HttpError("unauthorized", "Sign in first.");
  return rc.auth;
}

function codeParam(rc: RouteContext): string {
  const code = normalizeInviteCode(rc.params.code ?? "");
  if (!code) throw new HttpError("not_found", "No such invite.");
  return code;
}

function unwrap<T>(result: RoomResult<T>): T {
  if (result.ok) return result.value;
  const { code, message, path } = result.error;
  throw new HttpError(code, message, path ? { path } : {});
}

async function accountName(env: Env, accountID: string): Promise<string> {
  const row = await env.DB.prepare("SELECT display_name FROM accounts WHERE id = ?")
    .bind(accountID)
    .first<{ display_name: string }>();
  if (!row) throw new HttpError("unauthorized", "Account no longer exists.");
  return row.display_name;
}

/** POST /v1/invites — a new match with an open seat and its code. */
export async function createInvite(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, CreateInviteRequest);
  const name = await accountName(rc.env, auth.accountID);
  const matchID = randomToken("m_", 9);
  const snap = unwrap(
    await rc.env.MATCH_ROOM.getByName(matchID).create({
      matchID,
      variant: req.variant,
      targetWins: req.targetWins,
      creator: { id: auth.accountID, displayName: name },
      openSeat: "invited",
    }),
  );
  const now = inviteDeps.now();
  const expiresAt = now + INVITE_TTL_MS;
  // 31^6 ≈ 887 M codes: a collision is rare, but retry a few times rather than fail.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = newInviteCode();
    const res = await rc.env.DB.prepare(
      "INSERT INTO invites (code, match_id, creator_id, variant, target_wins, created_at, expires_at) " +
        "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (code) DO NOTHING",
    )
      .bind(code, matchID, auth.accountID, req.variant, req.targetWins, now, expiresAt)
      .run();
    if (res.meta.changes === 1) {
      const body: Invite = { code, url: inviteURL(rc.url.origin, code), expiresAt, match: snap };
      return json(body, 201);
    }
  }
  await rc.env.MATCH_ROOM.getByName(matchID).closeOpenSeat();
  throw new HttpError("unavailable", "Couldn't make an invite code; try again.", { retryAfter: 1 });
}

/** GET /v1/invites/{code} — who invites to what, and whether it is still open. */
export async function previewInvite(rc: RouteContext): Promise<Response> {
  caller(rc);
  const row = await loadInvite(rc.env, codeParam(rc), inviteDeps.now());
  if (!row || !row.creator_name) throw new HttpError("not_found", "No such invite.");
  const body: InvitePreview = {
    code: row.code,
    from: { playerID: row.creator_id, displayName: row.creator_name },
    variant: row.variant as VariantID,
    targetWins: row.target_wins,
    status: row.status,
    expiresAt: row.expires_at,
  };
  return json(body);
}

/** POST /v1/invites/{code}/accept — join the invite's match (single use). */
export async function acceptInvite(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const code = codeParam(rc);
  const now = inviteDeps.now();
  const row = await loadInvite(rc.env, code, now);
  if (!row) throw new HttpError("not_found", "No such invite.");
  if (row.creator_id === auth.accountID) throw new HttpError("forbidden", "That is your own invite.");
  const room = rc.env.MATCH_ROOM.getByName(row.match_id);
  // A lost reply: the same player accepting again gets the match.
  if (row.status === "accepted" && row.accepted_by === auth.accountID) {
    return json(unwrap(await room.load(auth.accountID)));
  }
  if (row.status !== "open") throw new HttpError("invite_unavailable", `The invite is ${row.status}.`);
  const name = await accountName(rc.env, auth.accountID);
  const claimed = await rc.env.DB.prepare(
    "UPDATE invites SET status = 'accepted', accepted_by = ?, closed_at = ? " +
      "WHERE code = ? AND status = 'open' AND expires_at > ?",
  )
    .bind(auth.accountID, now, code, now)
    .run();
  if (claimed.meta.changes !== 1) throw new HttpError("invite_unavailable", "The invite was just used.");
  const joined = await room.join({ id: auth.accountID, displayName: name });
  if (!joined.ok) {
    // The creator left meanwhile (or the seat is gone): the code is spent.
    await rc.env.DB.prepare("UPDATE invites SET status = 'cancelled' WHERE code = ?").bind(code).run();
    throw new HttpError("invite_unavailable", "The game is no longer waiting for you.");
  }
  notify(rc, pushesAfter("join", auth.accountID, joined.value));
  return json(joined.value);
}

/** Closes an open invite with `status` and ends its waiting match. */
async function closeInvite(env: Env, row: InviteRow, status: "declined" | "cancelled" | "expired", now: number) {
  const res = await env.DB.prepare("UPDATE invites SET status = ?, closed_at = ? WHERE code = ? AND status = 'open'")
    .bind(status, now, row.code)
    .run();
  if (res.meta.changes === 1) await env.MATCH_ROOM.getByName(row.match_id).closeOpenSeat();
  return res.meta.changes === 1;
}

/** POST /v1/invites/{code}/decline — not playing: the invite closes (204, also again). */
export async function declineInvite(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const now = inviteDeps.now();
  const row = await loadInvite(rc.env, codeParam(rc), now);
  if (!row) throw new HttpError("not_found", "No such invite.");
  if (row.creator_id === auth.accountID) throw new HttpError("forbidden", "Cancel your own invite instead.");
  if (row.status === "declined") return new Response(null, { status: 204 });
  if (row.status !== "open") throw new HttpError("invite_unavailable", `The invite is ${row.status}.`);
  if (!(await closeInvite(rc.env, row, "declined", now))) {
    throw new HttpError("invite_unavailable", "The invite was just used.");
  }
  return new Response(null, { status: 204 });
}

/** DELETE /v1/invites/{code} — the creator takes the invite back (204, also again). */
export async function revokeInvite(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const now = inviteDeps.now();
  const row = await loadInvite(rc.env, codeParam(rc), now);
  if (!row) throw new HttpError("not_found", "No such invite.");
  if (row.creator_id !== auth.accountID) throw new HttpError("forbidden", "Not your invite.");
  if (row.status === "cancelled") return new Response(null, { status: 204 });
  if (row.status !== "open") throw new HttpError("invite_unavailable", `The invite is ${row.status}.`);
  if (!(await closeInvite(rc.env, row, "cancelled", now))) {
    throw new HttpError("invite_unavailable", "The invite was just used.");
  }
  return new Response(null, { status: 204 });
}

/** Hourly cron: mark open invites past their expiry and end their waiting matches. */
export async function expireInvites(env: Env, now: number, log: Logger, limit = 100): Promise<number> {
  const { results } = await env.DB.prepare(
    "SELECT code, match_id FROM invites WHERE status = 'open' AND expires_at <= ? LIMIT ?",
  )
    .bind(now, limit)
    .all<{ code: string; match_id: string }>();
  let expired = 0;
  for (const r of results) {
    const row = { code: r.code, match_id: r.match_id } as InviteRow;
    if (await closeInvite(env, row, "expired", now)) expired++;
  }
  if (expired) log.info("invites.expired", { expired });
  return expired;
}
