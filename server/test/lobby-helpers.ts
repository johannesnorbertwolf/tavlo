// Helpers for the #287 tests (invites, auto-match, lobby, push): players from the dev
// sign-in, requests with a fresh client IP each (keeps the per-IP limiter out of the way).
import { exports } from "cloudflare:workers";
import { expect } from "vitest";
import { ApiError, AuthSession, MatchSnapshot, RollRecord } from "../src/api";

export const BASE = "https://server.test";
const octet = () => Math.floor(Math.random() * 250);
let seq = 0;

export function call(method: string, path: string, body?: unknown, token?: string, headers: Record<string, string> = {}) {
  const h: Record<string, string> = { "cf-connecting-ip": `10.${octet()}.${octet()}.${octet()}`, ...headers };
  if (body !== undefined) h["content-type"] = "application/json";
  if (token) h.authorization = `Bearer ${token}`;
  return exports.default.fetch(`${BASE}${path}`, {
    method,
    headers: h,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export async function ok<T>(res: Response, schema: { parse: (v: unknown) => T }, status = 200): Promise<T> {
  const body = await res.json();
  expect(res.status, JSON.stringify(body)).toBe(status);
  return schema.parse(body);
}

export async function fails(res: Response, status: number, code: string) {
  const body = ApiError.parse(await res.json()).error;
  expect({ status: res.status, code: body.code }).toEqual({ status, code });
  return body;
}

export interface Player {
  id: string;
  token: string;
  name: string;
}

export async function player(name: string): Promise<Player> {
  const s = await ok(
    await call("POST", "/v1/auth/dev", { subject: `l${Date.now()}-${seq++}`, displayName: name }),
    AuthSession,
  );
  return { id: s.account.id, token: s.accessToken, name };
}

const b64 = (value: unknown) => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))));

/** An OnlineMatchPayload-shaped blob with these plies' dice (the server reads only those). */
export function payload(games: [number, number][][]): string {
  return b64({
    schemaVersion: 2,
    targetWins: 1,
    startingPlayer: "W",
    colorByPlayerID: {},
    variant: "plakoto",
    games: games.map((plies) => ({ plies: plies.map(([die1, die2]) => ({ die1, die2, halfMoves: [] })) })),
  });
}

/** `p` rolls the first ply and ends its turn: the turn passes to seat 1. */
export async function playFirstTurn(p: Player, matchID: string): Promise<MatchSnapshot> {
  const r = await ok(await call("POST", `/v1/matches/${matchID}/roll`, { gameIndex: 0, plyIndex: 0 }, p.token), RollRecord);
  return ok(
    await call("POST", `/v1/matches/${matchID}/end-turn`, { baseRevision: 0, data: payload([[[r.die1, r.die2]]]) }, p.token),
    MatchSnapshot,
  );
}

export const indexRow = (env: Env, id: string, account: string) =>
  env.DB.prepare("SELECT state, outcome, opponent_id, hidden FROM match_index WHERE match_id = ? AND account_id = ?")
    .bind(id, account)
    .first<{ state: string; outcome: string; opponent_id: string | null; hidden: number }>();
