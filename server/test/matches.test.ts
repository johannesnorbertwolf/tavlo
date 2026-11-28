// Matches (#286): the OnlineMatchService operations through the Worker + MatchRoom
// (turn rules, optimistic concurrency, outcomes, requests, the dice slider, server
// rolls + verification, lobby index, WebSocket events, account deletion).
import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiError,
  AuthSession,
  DiceHandicap,
  MatchListResponse,
  MatchSnapshot,
  RollRecord,
  ServerMessage,
} from "../src/api";
import { face } from "../src/dice";
import type { MatchRoom } from "../src/match-room";

const BASE = "https://server.test";
// A fresh client IP per request keeps the per-IP limiter (120/min) out of the way.
const octet = () => Math.floor(Math.random() * 250);
let seq = 0;

beforeEach(() => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());

function call(method: string, path: string, body?: unknown, token?: string, headers: Record<string, string> = {}) {
  const h: Record<string, string> = { "cf-connecting-ip": `10.${octet()}.${octet()}.${octet()}`, ...headers };
  if (body !== undefined) h["content-type"] = "application/json";
  if (token) h.authorization = `Bearer ${token}`;
  return exports.default.fetch(`${BASE}${path}`, {
    method,
    headers: h,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function ok<T>(res: Response, schema: { parse: (v: unknown) => T }, status = 200): Promise<T> {
  const body = await res.json();
  expect(res.status, JSON.stringify(body)).toBe(status);
  return schema.parse(body);
}

async function fails(res: Response, status: number, code: string, path?: string) {
  const body = ApiError.parse(await res.json()).error;
  expect({ status: res.status, code: body.code }).toEqual({ status, code });
  if (path) expect(body.path).toBe(path);
  return body;
}

interface Player {
  id: string;
  token: string;
  name: string;
}

async function player(name: string): Promise<Player> {
  const s = await ok(
    await call("POST", "/v1/auth/dev", { subject: `m${Date.now()}-${seq++}`, displayName: name }),
    AuthSession,
  );
  return { id: s.account.id, token: s.accessToken, name };
}

const b64 = (value: unknown) => btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(value))));

/** An OnlineMatchPayload-shaped blob with these plies' dice (the server reads only those). */
function payload(games: [number, number][][], extra: Record<string, unknown> = {}): string {
  return b64({
    schemaVersion: 2,
    targetWins: 2,
    startingPlayer: "W",
    colorByPlayerID: {},
    variant: "plakoto",
    games: games.map((plies) => ({ plies: plies.map(([die1, die2]) => ({ die1, die2, halfMoves: [] })) })),
    ...extra,
  });
}

/** A and B in an accepted plakoto best-of-three (A = White, holding the turn). */
async function started(variant = "plakoto") {
  const a = await player("Alice");
  const b = await player("Βασίλης");
  const snap = await ok(
    await call("POST", "/v1/matches", { variant, targetWins: 2, opponentID: b.id }, a.token),
    MatchSnapshot,
    201,
  );
  await ok(await call("POST", `/v1/matches/${snap.matchID}/accept`, undefined, b.token), MatchSnapshot);
  return { a, b, id: snap.matchID, snap };
}

const roll = async (p: Player, id: string, gameIndex: number, plyIndex: number, rollValues?: number[]) =>
  ok(await call("POST", `/v1/matches/${id}/roll`, { gameIndex, plyIndex, rollValues }, p.token), RollRecord);

const write = (p: Player, id: string, op: string, baseRevision: number, data: string, extra = {}) =>
  call("POST", `/v1/matches/${id}/${op}`, { baseRevision, data, ...extra }, p.token);

const load = async (p: Player, id: string) => ok(await call("GET", `/v1/matches/${id}`, undefined, p.token), MatchSnapshot);

const indexRow = (id: string, account: string) =>
  env.DB.prepare("SELECT state, outcome, opponent_id FROM match_index WHERE match_id = ? AND account_id = ?")
    .bind(id, account)
    .first<{ state: string; outcome: string; opponent_id: string | null }>();

describe("create, load, accept, decline", () => {
  it("creates a direct challenge: creator White on turn, opponent invited, both indexed", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const snap = await ok(
      await call("POST", "/v1/matches", { variant: "plakoto", targetWins: 2, opponentID: b.id }, a.token),
      MatchSnapshot,
      201,
    );
    expect(snap).toMatchObject({
      revision: 0,
      variant: "plakoto",
      targetWins: 2,
      startingPlayer: "W", // house Plakoto: White starts
      data: null,
      currentPlayerID: a.id,
      isEnded: false,
      diceHandicap: { whiteLevel: 0, rev: 0 },
      lastRoll: null,
      requests: [],
    });
    expect(snap.matchID).toMatch(/^m_[A-Za-z0-9_-]{12}$/);
    expect(snap.participants).toEqual([
      { playerID: a.id, displayName: "Alice", color: "W", status: "active", outcome: "none" },
      { playerID: b.id, displayName: "Bob", color: "B", status: "invited", outcome: "none" },
    ]);
    // The creator may play its first turn before the seat is accepted (as with GameKit).
    expect(await indexRow(snap.matchID, a.id)).toEqual({ state: "yourTurn", outcome: "none", opponent_id: b.id });
    expect(await indexRow(snap.matchID, b.id)).toMatchObject({ state: "invited", opponent_id: a.id });

    // Seat 1 accepts (twice is fine); the creator's lobby row turns to "your turn".
    const accepted = await ok(await call("POST", `/v1/matches/${snap.matchID}/accept`, undefined, b.token), MatchSnapshot);
    expect(accepted.participants[1]!.status).toBe("active");
    await ok(await call("POST", `/v1/matches/${snap.matchID}/accept`, undefined, b.token), MatchSnapshot);
    expect(await indexRow(snap.matchID, a.id)).toMatchObject({ state: "yourTurn" });
    expect(await indexRow(snap.matchID, b.id)).toMatchObject({ state: "theirTurn" });
  });

  it("draws the starter for variants with a random first move, and opens a matching seat", async () => {
    const a = await player("Alice");
    const starters = new Set<string>();
    for (let i = 0; i < 24 && starters.size < 2; i++) {
      const s = await ok(await call("POST", "/v1/matches", { variant: "fevga", targetWins: 1 }, a.token), MatchSnapshot, 201);
      starters.add(s.startingPlayer);
      expect(s.participants[1]).toEqual({ playerID: null, displayName: null, color: "B", status: "matching", outcome: "none" });
    }
    expect([...starters].sort()).toEqual(["B", "W"]);
  });

  it("refuses strangers, unknown matches, unknown opponents and yourself", async () => {
    const { id } = await started();
    const c = await player("Eve");
    await fails(await call("GET", `/v1/matches/${id}`, undefined, c.token), 403, "forbidden");
    await fails(await call("GET", "/v1/matches/m_nope00000000", undefined, c.token), 404, "not_found");
    await fails(await call("GET", "/v1/matches/bad.id", undefined, c.token), 404, "not_found");
    await fails(await call("GET", `/v1/matches/${id}`), 401, "unauthorized");
    await fails(
      await call("POST", "/v1/matches", { variant: "plakoto", targetWins: 1, opponentID: "acc_nobody" }, c.token),
      404,
      "not_found",
      "opponentID",
    );
    await fails(
      await call("POST", "/v1/matches", { variant: "plakoto", targetWins: 1, opponentID: c.id }, c.token),
      400,
      "bad_request",
      "opponentID",
    );
  });

  it("decline ends the match", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const snap = await ok(
      await call("POST", "/v1/matches", { variant: "portes", targetWins: 1, opponentID: b.id }, a.token),
      MatchSnapshot,
      201,
    );
    expect((await call("POST", `/v1/matches/${snap.matchID}/decline`, undefined, b.token)).status).toBe(204);
    const after = await load(a, snap.matchID);
    expect(after).toMatchObject({ isEnded: true, currentPlayerID: null });
    expect(after.participants[1]!.status).toBe("declined");
    // #301: a declined challenge can't be accepted any more.
    await fails(await call("POST", `/v1/matches/${snap.matchID}/accept`, undefined, b.token), 410, "invite_unavailable");
    expect(await indexRow(snap.matchID, a.id)).toMatchObject({ state: "ended" });
  });
});

describe("turns, revisions, server rolls", () => {
  it("plays turns: only the turn holder rolls and writes; dice must be the server's", async () => {
    const { a, b, id } = await started();
    await fails(await call("POST", `/v1/matches/${id}/roll`, { gameIndex: 0, plyIndex: 0 }, b.token), 409, "not_your_turn");
    await fails(await write(b, id, "end-turn", 0, payload([[]])), 409, "not_your_turn");

    // Opening write, then A's first roll; asking again never rerolls.
    const opened = await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    expect(opened.revision).toBe(1);
    const r0 = await roll(a, id, 0, 0);
    expect(r0).toMatchObject({ gameIndex: 0, plyIndex: 0, player: "W" });
    expect(r0.weighted).toBeUndefined();
    expect(await roll(a, id, 0, 0)).toEqual(r0);
    expect((await load(b, id)).lastRoll).toEqual(r0);

    // Only the ply the game waits for.
    await fails(await call("POST", `/v1/matches/${id}/roll`, { gameIndex: 0, plyIndex: 3 }, a.token), 400, "bad_request", "plyIndex");

    // Wrong dice, a ply without a roll: refused.
    const wrong: [number, number] = [r0.die1 === 6 ? 5 : 6, r0.die2 === 6 ? 5 : 6];
    await fails(await write(a, id, "end-turn", 1, payload([[wrong]])), 400, "bad_request", "data");
    await fails(await write(a, id, "end-turn", 1, payload([[[r0.die1, r0.die2], [1, 1]]])), 400, "bad_request", "data");

    const ended = await ok(await write(a, id, "end-turn", 1, payload([[[r0.die1, r0.die2]]])), MatchSnapshot);
    expect(ended).toMatchObject({ revision: 2, currentPlayerID: b.id });
    expect(await indexRow(id, a.id)).toMatchObject({ state: "theirTurn" });
    expect(await indexRow(id, b.id)).toMatchObject({ state: "yourTurn" });

    // The same end-turn again (lost reply) is answered, not refused.
    const again = await ok(await write(a, id, "end-turn", 1, payload([[[r0.die1, r0.die2]]])), MatchSnapshot);
    expect(again.revision).toBe(2);

    // B can't rewrite A's ply, nor claim A's roll as its own.
    const r1 = await roll(b, id, 0, 1);
    expect(r1.player).toBe("B");
    await fails(await call("POST", `/v1/matches/${id}/roll`, { gameIndex: 0, plyIndex: 0 }, b.token), 400, "bad_request", "plyIndex");
    await fails(await write(b, id, "end-turn", 2, payload([[wrong, [r1.die1, r1.die2]]])), 400, "bad_request", "data");
    const b1 = await ok(await write(b, id, "end-turn", 2, payload([[[r0.die1, r0.die2], [r1.die1, r1.die2]]])), MatchSnapshot);
    expect(b1).toMatchObject({ revision: 3, currentPlayerID: a.id });
  });

  it("rejects a stale revision and keeps the state", async () => {
    const { a, id } = await started();
    await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    const r = await roll(a, id, 0, 0);
    const live = payload([[]], { liveTurn: { gameIndex: 0, plyIndex: 0, player: "W", die1: r.die1, die2: r.die2, halfMoves: [], seq: 1 } });
    const body = await fails(await write(a, id, "save-turn", 0, live), 409, "stale_revision");
    expect(body.message).toMatch(/baseRevision 0/);
    expect((await load(a, id)).revision).toBe(1);
    await ok(await write(a, id, "save-turn", 1, live), MatchSnapshot);
  });

  it("lets the starter of the next game roll its first ply before its write lands", async () => {
    const { a, id } = await started();
    await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    const next = await roll(a, id, 1, 0);
    expect(next).toMatchObject({ gameIndex: 1, plyIndex: 0 });
    // Game 0's first ply now has no roll: a payload with it is refused, game 1's is fine.
    await fails(await write(a, id, "save-turn", 1, payload([[[1, 1]], []])), 400, "bad_request", "data");
  });

  it("checks the body and the payload", async () => {
    const { a, id } = await started();
    await fails(await write(a, id, "end-turn", 0, "not base64!"), 400, "bad_request", "data");
    await fails(await write(a, id, "end-turn", 0, b64({ games: "x" })), 400, "bad_request", "data");
    await fails(await write(a, id, "end-turn", 0, btoa("{")), 400, "bad_request", "data");
  });
});

describe("match end and quit", () => {
  it("end-match gives the opponent the opposite outcome and locks the match", async () => {
    const { a, b, id } = await started();
    await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    const r = await roll(a, id, 0, 0);
    const done = await ok(
      await write(a, id, "end-match", 1, payload([[[r.die1, r.die2]]]), { outcome: "won" }),
      MatchSnapshot,
    );
    expect(done).toMatchObject({ isEnded: true, currentPlayerID: null });
    expect(done.participants.map((p) => [p.status, p.outcome])).toEqual([
      ["done", "won"],
      ["done", "lost"],
    ]);
    await fails(await write(a, id, "save-turn", 2, payload([[]])), 409, "match_ended");
    await fails(await call("POST", `/v1/matches/${id}/dice`, { whiteLevel: 1, baseRev: 0 }, b.token), 409, "match_ended");
    expect(await indexRow(id, b.id)).toEqual({ state: "ended", outcome: "lost", opponent_id: a.id });
  });

  it("quit out of turn: the quitter's outcome is quit, the other seat wins", async () => {
    const { a, b, id } = await started();
    await fails(await call("POST", `/v1/matches/${id}/quit`, { inTurn: false }, a.token), 400, "bad_request", "inTurn");
    await fails(await call("POST", `/v1/matches/${id}/quit`, { inTurn: true }, a.token), 400, "bad_request", "baseRevision");
    const q = await ok(await call("POST", `/v1/matches/${id}/quit`, { inTurn: false }, b.token), MatchSnapshot);
    expect(q.isEnded).toBe(true);
    expect(q.participants.map((p) => p.outcome)).toEqual(["won", "quit"]);
    await fails(await call("POST", `/v1/matches/${id}/quit`, { inTurn: false }, b.token), 409, "match_ended");
  });

  it("quit in turn stores the final state (dice checked)", async () => {
    const { a, id } = await started();
    const q = await ok(await call("POST", `/v1/matches/${id}/quit`, { inTurn: true, baseRevision: 0, data: payload([[]]) }, a.token), MatchSnapshot);
    expect(q).toMatchObject({ revision: 1, isEnded: true });
    expect(q.participants.map((p) => p.outcome)).toEqual(["quit", "won"]);
  });
});

describe("out-of-turn requests", () => {
  it("delivers to the other player until its turn ends", async () => {
    const { a, b, id } = await started();
    const data = b64({ kind: "dice", whiteLevel: 1, baseRev: 0, by: "B" });
    const sent = await call("POST", `/v1/matches/${id}/requests`, { data }, b.token);
    expect(sent.status).toBe(202);
    const { id: rq } = (await sent.json()) as { id: string };
    expect((await load(a, id)).requests).toEqual([expect.objectContaining({ id: rq, from: b.id, data })]);
    expect((await load(b, id)).requests).toEqual([]);
    await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    expect((await load(a, id)).requests).toHaveLength(1);
    const r = await roll(a, id, 0, 0);
    await ok(await write(a, id, "end-turn", 1, payload([[[r.die1, r.die2]]])), MatchSnapshot);
    expect((await load(a, id)).requests).toEqual([]);
  });
});

describe("shared dice slider and weighted rolls", () => {
  const values = [0.3, 0.32, 0.34, 0.9, 0.38, 0.4, 0.42, 0.44, 0.46, 0.48, 0.05, 0.52, 0.54, 0.56, 0.58, 0.6, 0.62, 0.64, 0.66, 0.68, 0.7];

  it("either player changes it; never over the other's unseen change", async () => {
    const { a, b, id } = await started();
    const dice = (p: Player, whiteLevel: number, baseRev: number) =>
      call("POST", `/v1/matches/${id}/dice`, { whiteLevel, baseRev }, p.token);
    expect(await ok(await dice(a, 2, 0), DiceHandicap)).toEqual({ whiteLevel: 2, rev: 1, by: "W" });
    // A again, quickly, on its old base: its own change doesn't block it.
    expect(await ok(await dice(a, 3, 0), DiceHandicap)).toEqual({ whiteLevel: 3, rev: 2, by: "W" });
    // B hadn't seen those: refused (reload), then accepted on the new base.
    await fails(await dice(b, -1, 0), 409, "stale_revision");
    expect(await ok(await dice(b, -1, 2), DiceHandicap)).toEqual({ whiteLevel: -1, rev: 3, by: "B" });
    expect((await load(a, id)).diceHandicap).toEqual({ whiteLevel: -1, rev: 3, by: "B" });
    // Same value again: no new rev.
    expect(await ok(await dice(b, -1, 3), DiceHandicap)).toEqual({ whiteLevel: -1, rev: 3, by: "B" });

    // Weighted now: the roller must send its 21 values; the record carries the bend.
    await fails(await call("POST", `/v1/matches/${id}/roll`, { gameIndex: 0, plyIndex: 0 }, a.token), 400, "bad_request", "rollValues");
    await fails(
      await call("POST", `/v1/matches/${id}/roll`, { gameIndex: 0, plyIndex: 0, rollValues: values.slice(1) }, a.token),
      400,
      "bad_request",
    );
    const r = await roll(a, id, 0, 0, values);
    expect(r.weighted).toBe(-1); // favours Black: A's (White's) roll gets the mirrored bend
    expect(r.beta).toBeLessThan(0);
  });

  it("a fair slider ignores the values", async () => {
    const { a, id } = await started();
    const r = await roll(a, id, 0, 0, values);
    expect(r.weighted).toBeUndefined();
    expect(r.beta).toBeUndefined();
  });

  it("draws with the room's random source (deterministic in a test)", async () => {
    const { a, id } = await started("plakoto_standard");
    await ok(await call("POST", `/v1/matches/${id}/dice`, { whiteLevel: 4, baseRev: 0 }, a.token), DiceHandicap);
    await runInDurableObject(env.MATCH_ROOM.getByName(id), async (room: MatchRoom) => {
      room.random = { uniform: () => 0.999, die: () => 2 };
    });
    const r = await roll(a, id, 0, 0, values);
    // u1 = u2 ≈ 1 → the last ordered outcome (6, 6) for any bend.
    expect([r.die1, r.die2, r.weighted]).toEqual([6, 6, 4]);
    expect(r.beta).toBeGreaterThan(0);
    await runInDurableObject(env.MATCH_ROOM.getByName(id), async (room: MatchRoom, state) => {
      const row = state.storage.sql.exec<{ roll_values: string }>("SELECT roll_values FROM rolls").one();
      expect(JSON.parse(row.roll_values)).toEqual(values);
      room.random = { uniform: () => 0, die: () => face(0.5) };
    });
  });
});

describe("lobby list", () => {
  it("lists newest first with paging and a state filter", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const ids: string[] = [];
    // #301: one pending challenge per pair — three opponents here.
    const others = [b, await player("Sam"), await player("Alex")];
    for (const o of others) {
      const s = await ok(await call("POST", "/v1/matches", { variant: "fevga", targetWins: 1, opponentID: o.id }, a.token), MatchSnapshot, 201);
      ids.push(s.matchID);
      await new Promise((r) => setTimeout(r, 3));
    }
    await call("POST", `/v1/matches/${ids[0]}/decline`, undefined, b.token);
    const all = await ok(await call("GET", "/v1/matches", undefined, a.token), MatchListResponse);
    expect(all.matches.map((m) => m.matchID)).toEqual([ids[0], ids[2], ids[1]]);
    expect(all.matches[1]).toMatchObject({
      state: "yourTurn",
      opponent: { playerID: others[2]!.id, displayName: "Alex" },
      challenge: { status: "pending" },
    });
    expect(all.matches[0]!.challenge?.status).toBe("declined");
    const active = await ok(await call("GET", "/v1/matches?state=active", undefined, a.token), MatchListResponse);
    expect(active.matches.map((m) => m.matchID)).toEqual([ids[2], ids[1]]);
    const ended = await ok(await call("GET", "/v1/matches?state=ended", undefined, b.token), MatchListResponse);
    expect(ended.matches.map((m) => [m.matchID, m.state])).toEqual([[ids[0], "ended"]]);
    await fails(await call("GET", "/v1/matches?state=weird", undefined, a.token), 400, "bad_request", "state");
    await fails(await call("GET", "/v1/matches?cursor=nope", undefined, a.token), 400, "bad_request", "cursor");
  });
});

describe("WebSocket", () => {
  async function socket(p: Player, id: string) {
    const res = await call("GET", `/v1/matches/${id}/socket`, undefined, p.token, { upgrade: "websocket" });
    expect(res.status).toBe(101);
    const ws = res.webSocket!;
    const messages: ServerMessage[] = [];
    const closed: { code?: number } = {};
    ws.addEventListener("message", (e) => {
      messages.push(ServerMessage.parse(JSON.parse(e.data as string)));
    });
    ws.addEventListener("close", (e) => {
      closed.code = e.code;
    });
    ws.accept();
    return { ws, messages, closed };
  }

  const settle = () => new Promise((r) => setTimeout(r, 50));

  it("says hello, pushes rolls, match events and requests (to the recipient only)", async () => {
    const { a, b, id } = await started();
    const sa = await socket(a, id);
    const sb = await socket(b, id);
    await settle();
    expect(sa.messages[0]).toMatchObject({ type: "hello", matchID: id, revision: 0 });

    await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    const r = await roll(a, id, 0, 0);
    await ok(await write(a, id, "end-turn", 1, payload([[[r.die1, r.die2]]])), MatchSnapshot);
    await call("POST", `/v1/matches/${id}/requests`, { data: b64({ hi: 1 }) }, a.token);
    await ok(await call("POST", `/v1/matches/${id}/dice`, { whiteLevel: 1, baseRev: 0 }, b.token), DiceHandicap);
    await settle();

    const summary = (m: ServerMessage[]) =>
      m.map((x) => (x.type === "match" ? `match:${x.event}` : x.type));
    expect(summary(sb.messages)).toEqual(["hello", "match:turnSaved", "roll", "match:turnEnded", "request", "match:diceChanged"]);
    expect(summary(sa.messages)).toEqual(["hello", "match:turnSaved", "roll", "match:turnEnded", "match:diceChanged"]);
    const ended = sb.messages[3]!;
    expect(ended.type === "match" && ended.match.currentPlayerID).toBe(b.id);
    sa.ws.close(1000);
    sb.ws.close(1000);
  });

  it("refuses a non-participant with an error and close code 4403", async () => {
    const { id } = await started();
    const c = await player("Eve");
    const sc = await socket(c, id);
    await settle();
    expect(sc.messages).toEqual([{ type: "error", error: { code: "forbidden", message: "Not a participant." } }]);
    expect(sc.closed.code).toBe(4403);
  });

  it("closes a socket whose access token expired with 4401 on the next event", async () => {
    const { a, b, id } = await started();
    const sb = await socket(b, id);
    await settle();
    await runInDurableObject(env.MATCH_ROOM.getByName(id), async (room: MatchRoom) => {
      room.now = () => Date.now() + 2 * 60 * 60 * 1000;
    });
    await ok(await write(a, id, "save-turn", 0, payload([[]])), MatchSnapshot);
    await settle();
    expect(sb.messages.map((m) => m.type)).toEqual(["hello", "error"]);
    expect(sb.closed.code).toBe(4401);
  });

  it("needs an upgrade header and a token", async () => {
    const { a, id } = await started();
    await fails(await call("GET", `/v1/matches/${id}/socket`, undefined, a.token), 400, "bad_request");
    await fails(await call("GET", `/v1/matches/${id}/socket`, undefined, undefined, { upgrade: "websocket" }), 401, "unauthorized");
  });
});

describe("account deletion", () => {
  it("ends running matches as the deleted player's quit and anonymises them", async () => {
    const { a, b, id } = await started();
    expect((await call("DELETE", "/v1/account", undefined, b.token)).status).toBe(204);
    const snap = await load(a, id);
    expect(snap.isEnded).toBe(true);
    expect(snap.participants[1]).toMatchObject({ playerID: b.id, displayName: null, outcome: "quit" });
    expect(snap.participants[0]!.outcome).toBe("won");
    // The deleted player's still-valid access token is refused by the room.
    await fails(await call("GET", `/v1/matches/${id}`, undefined, b.token), 401, "unauthorized");
    await fails(await call("POST", "/v1/matches", { variant: "plakoto", targetWins: 1 }, b.token), 401, "unauthorized");
    const list = await ok(await call("GET", "/v1/matches", undefined, a.token), MatchListResponse);
    expect(list.matches.find((m) => m.matchID === id)).toMatchObject({
      state: "ended",
      outcome: "won",
      opponent: { playerID: b.id, displayName: null },
    });
  });
});
