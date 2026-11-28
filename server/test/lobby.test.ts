// #287: invites by code (create, preview, accept, decline, revoke, expiry, the accept race),
// auto-match (queue per variant + length, concurrent entries, cancelled / stale waiting
// matches) and removing ended matches from the lobby.
import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  INVITE_ALPHABET,
  INVITE_TTL_MS,
  Invite,
  InvitePreview,
  MatchListResponse,
  MatchSnapshot,
} from "../src/api";
import { expireInvites, inviteDeps, newInviteCode, normalizeInviteCode } from "../src/invites";
import { Logger } from "../src/log";
import type { MatchQueue } from "../src/match-queue";
import { BASE, call, fails, indexRow, ok, player, playFirstTurn, type Player } from "./lobby-helpers";

beforeEach(() => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "debug").mockImplementation(() => {});
});
const savedNow = inviteDeps.now;
afterEach(() => {
  inviteDeps.now = savedNow;
  vi.restoreAllMocks();
});

const list = async (p: Player) => ok(await call("GET", "/v1/matches", undefined, p.token), MatchListResponse);

async function invite(p: Player, variant = "plakoto_standard", targetWins = 2) {
  return ok(await call("POST", "/v1/invites", { variant, targetWins }, p.token), Invite, 201);
}

describe("invite codes", () => {
  it("are 6 characters without look-alikes, uniform over the alphabet", () => {
    expect(INVITE_ALPHABET).not.toMatch(/[01IOL]/);
    const counts = new Map<string, number>();
    for (let i = 0; i < 2000; i++) {
      const code = newInviteCode();
      expect(code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$/);
      for (const c of code) counts.set(c, (counts.get(c) ?? 0) + 1);
    }
    expect(counts.size).toBe(INVITE_ALPHABET.length);
    // 12000 characters over 31 symbols ≈ 387 each; a biased modulo would show up here.
    for (const n of counts.values()) expect(n).toBeGreaterThan(250);
    // Rejection sampling: bytes ≥ 248 are skipped (248 = 8 × 31).
    const bytes = [255, 250, 248, 0, 1, 2, 3, 4, 5, 6, 7, 8];
    expect(newInviteCode(() => Uint8Array.from(bytes))).toBe("234567");
  });

  it("normalize typed input: case, spaces and dashes", () => {
    expect(normalizeInviteCode(" k7q-4mz ")).toBe("K7Q4MZ");
    expect(normalizeInviteCode("abc")).toBeNull();
    expect(normalizeInviteCode("K7Q4MZ<script>")).toBeNull();
  });
});

describe("invites", () => {
  it("creates a match with an open invited seat, listed with its invite for the creator", async () => {
    const a = await player("Alice");
    const before = Date.now();
    const inv = await invite(a, "fevga", 1);
    expect(inv.code).toMatch(/^[23456789A-HJKMNP-Z]{6}$/);
    expect(inv.url).toBe(`${BASE}/join/${inv.code}`);
    expect(inv.expiresAt).toBeGreaterThanOrEqual(before + INVITE_TTL_MS);
    expect(inv.match).toMatchObject({ variant: "fevga", targetWins: 1, currentPlayerID: a.id, data: null, isEnded: false });
    expect(inv.match.participants[1]).toEqual({ playerID: null, displayName: null, color: "B", status: "invited", outcome: "none" });
    const lobby = await list(a);
    const row = lobby.matches.find((m) => m.matchID === inv.match.matchID)!;
    // The creator may play first (yourTurn until it ends its turn, then waitingForOpponent).
    expect(row).toMatchObject({ state: "yourTurn", invite: { code: inv.code, url: inv.url, expiresAt: inv.expiresAt } });

    // Preview (any case), from anyone signed in.
    const b = await player("Bob");
    const preview = await ok(await call("GET", `/v1/invites/${inv.code.toLowerCase()}`, undefined, b.token), InvitePreview);
    expect(preview).toEqual({
      code: inv.code,
      from: { playerID: a.id, displayName: "Alice" },
      variant: "fevga",
      targetWins: 1,
      status: "open",
      expiresAt: inv.expiresAt,
    });
    await fails(await call("GET", "/v1/invites/ZZZZZZ", undefined, b.token), 404, "not_found");
    await fails(await call("GET", `/v1/invites/${inv.code}`), 401, "unauthorized");
  });

  it("accept: one use, the joiner takes seat 1; the creator can't accept its own", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const c = await player("Sam");
    const inv = await invite(a);
    await fails(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, a.token), 403, "forbidden");

    const joined = await ok(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), MatchSnapshot);
    expect(joined.matchID).toBe(inv.match.matchID);
    expect(joined.participants[1]).toEqual({ playerID: b.id, displayName: "Bob", color: "B", status: "active", outcome: "none" });
    expect(await indexRow(env, joined.matchID, a.id)).toMatchObject({ state: "yourTurn", opponent_id: b.id });
    expect(await indexRow(env, joined.matchID, b.id)).toMatchObject({ state: "theirTurn", opponent_id: a.id });
    expect((await list(a)).matches.find((m) => m.matchID === joined.matchID)?.invite).toBeUndefined();

    // A lost reply: the same player again gets the match; anyone else: 410.
    const again = await ok(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), MatchSnapshot);
    expect(again.matchID).toBe(joined.matchID);
    await fails(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, c.token), 410, "invite_unavailable");
    const preview = await ok(await call("GET", `/v1/invites/${inv.code}`, undefined, c.token), InvitePreview);
    expect(preview.status).toBe("accepted");
  });

  it("the joiner holds the turn when the creator already played its first one", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const inv = await invite(a, "plakoto", 1);
    const afterTurn = await playFirstTurn(a, inv.match.matchID);
    expect(afterTurn.currentPlayerID).toBeNull(); // seat 1 still open
    const joined = await ok(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), MatchSnapshot);
    expect(joined.currentPlayerID).toBe(b.id);
    expect(await indexRow(env, joined.matchID, b.id)).toMatchObject({ state: "yourTurn" });
  });

  it("two players accepting at the same moment: exactly one joins", async () => {
    const a = await player("Alice");
    const inv = await invite(a);
    const rivals = await Promise.all(["Bob", "Sam", "Alex", "Robin"].map((n) => player(n)));
    const answers = await Promise.all(
      rivals.map((p) => call("POST", `/v1/invites/${inv.code}/accept`, undefined, p.token)),
    );
    const statuses = answers.map((r) => r.status).sort();
    expect(statuses).toEqual([200, 410, 410, 410]);
    const winner = rivals[answers.findIndex((r) => r.status === 200)]!;
    const snap = await ok(await call("GET", `/v1/matches/${inv.match.matchID}`, undefined, a.token), MatchSnapshot);
    expect(snap.participants[1]!.playerID).toBe(winner.id);
  });

  it("decline closes the invite and ends the waiting match", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const inv = await invite(a);
    await fails(await call("POST", `/v1/invites/${inv.code}/decline`, undefined, a.token), 403, "forbidden");
    expect((await call("POST", `/v1/invites/${inv.code}/decline`, undefined, b.token)).status).toBe(204);
    expect((await call("POST", `/v1/invites/${inv.code}/decline`, undefined, b.token)).status).toBe(204);
    const snap = await ok(await call("GET", `/v1/matches/${inv.match.matchID}`, undefined, a.token), MatchSnapshot);
    expect(snap.isEnded).toBe(true);
    expect(snap.participants.map((p) => [p.status, p.outcome])).toEqual([
      ["done", "none"],
      ["declined", "none"],
    ]);
    expect(await indexRow(env, inv.match.matchID, a.id)).toMatchObject({ state: "ended", outcome: "none" });
    await fails(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), 410, "invite_unavailable");
  });

  it("revoke: only the creator; afterwards nobody can join", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const inv = await invite(a);
    await fails(await call("DELETE", `/v1/invites/${inv.code}`, undefined, b.token), 403, "forbidden");
    expect((await call("DELETE", `/v1/invites/${inv.code}`, undefined, a.token)).status).toBe(204);
    expect((await call("DELETE", `/v1/invites/${inv.code}`, undefined, a.token)).status).toBe(204);
    const preview = await ok(await call("GET", `/v1/invites/${inv.code}`, undefined, b.token), InvitePreview);
    expect(preview.status).toBe("cancelled");
    await fails(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), 410, "invite_unavailable");
    expect((await ok(await call("GET", `/v1/matches/${inv.match.matchID}`, undefined, a.token), MatchSnapshot)).isEnded).toBe(true);

    // An accepted invite can't be revoked any more.
    const inv2 = await invite(a);
    await ok(await call("POST", `/v1/invites/${inv2.code}/accept`, undefined, b.token), MatchSnapshot);
    await fails(await call("DELETE", `/v1/invites/${inv2.code}`, undefined, a.token), 410, "invite_unavailable");
  });

  it("expires after 7 days; the cron marks it and ends the match", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const inv = await invite(a);
    inviteDeps.now = () => inv.expiresAt + 1;
    const preview = await ok(await call("GET", `/v1/invites/${inv.code}`, undefined, b.token), InvitePreview);
    expect(preview.status).toBe("expired");
    await fails(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), 410, "invite_unavailable");
    expect((await list(a)).matches.find((m) => m.matchID === inv.match.matchID)?.invite).toBeUndefined();

    const expired = await expireInvites(env, inv.expiresAt + 1, new Logger());
    expect(expired).toBeGreaterThanOrEqual(1);
    const row = await env.DB.prepare("SELECT status FROM invites WHERE code = ?").bind(inv.code).first<{ status: string }>();
    expect(row?.status).toBe("expired");
    expect((await ok(await call("GET", `/v1/matches/${inv.match.matchID}`, undefined, a.token), MatchSnapshot)).isEnded).toBe(true);
  });

  it("a creator who left meanwhile: accepting answers 410 and spends the code", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const inv = await invite(a);
    await ok(await call("POST", `/v1/matches/${inv.match.matchID}/quit`, { inTurn: false }, a.token), MatchSnapshot);
    await fails(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), 410, "invite_unavailable");
    const preview = await ok(await call("GET", `/v1/invites/${inv.code}`, undefined, b.token), InvitePreview);
    expect(preview.status).toBe("cancelled");
  });

  it("validates the body", async () => {
    const a = await player("Alice");
    await fails(await call("POST", "/v1/invites", { variant: "chess", targetWins: 1 }, a.token), 400, "bad_request");
    await fails(await call("POST", "/v1/invites", { variant: "fevga", targetWins: 3 }, a.token), 400, "bad_request");
  });
});

describe("auto-match", () => {
  const enter = async (p: Player, variant: string, targetWins: number) =>
    ok(await call("POST", "/v1/automatch", { variant, targetWins }, p.token), MatchSnapshot);

  it("waits in a new match, a second tap answers the same one, the next player joins it", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const c = await player("Sam");
    const waiting = await enter(a, "plakoto", 1);
    expect(waiting.participants[1]).toMatchObject({ playerID: null, status: "matching" });
    expect(waiting.currentPlayerID).toBe(a.id); // the creator may start at once
    expect((await enter(a, "plakoto", 1)).matchID).toBe(waiting.matchID);

    // Another length is another queue.
    const other = await enter(c, "plakoto", 2);
    expect(other.matchID).not.toBe(waiting.matchID);

    const joined = await enter(b, "plakoto", 1);
    expect(joined.matchID).toBe(waiting.matchID);
    expect(joined.participants[1]).toMatchObject({ playerID: b.id, displayName: "Bob", status: "active" });
    expect(await indexRow(env, waiting.matchID, a.id)).toMatchObject({ state: "yourTurn", opponent_id: b.id });
    // Matched matches leave the queue.
    const entries = await runInDurableObject(env.MATCH_QUEUE.getByName("plakoto:1"), (q: MatchQueue) => q.entries());
    expect(entries.map((e) => e.match_id)).not.toContain(waiting.matchID);
  });

  it("players entering at the same moment are paired, never left in two waiting matches", async () => {
    const players = await Promise.all(["Alice", "Bob", "Sam", "Alex"].map((n) => player(n)));
    const snaps = await Promise.all(players.map((p) => enter(p, "fevga", 2)));
    const byMatch = new Map<string, number>();
    for (const s of snaps) byMatch.set(s.matchID, (byMatch.get(s.matchID) ?? 0) + 1);
    expect([...byMatch.values()].sort()).toEqual([2, 2]);
    const entries = await runInDurableObject(env.MATCH_QUEUE.getByName("fevga:2"), (q: MatchQueue) => q.entries());
    expect(entries).toEqual([]);
  });

  it("skips a waiting match its creator cancelled (quit while the seat is open)", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const waiting = await enter(a, "portes", 1);
    // Cancel: quit out of turn is allowed while the opponent seat is still open.
    const cancelled = await ok(await call("POST", `/v1/matches/${waiting.matchID}/quit`, { inTurn: false }, a.token), MatchSnapshot);
    expect(cancelled.isEnded).toBe(true);
    const mine = await enter(b, "portes", 1);
    expect(mine.matchID).not.toBe(waiting.matchID);
    expect(mine.participants[1]!.playerID).toBeNull();
    const entries = await runInDurableObject(env.MATCH_QUEUE.getByName("portes:1"), (q: MatchQueue) => q.entries());
    expect(entries.map((e) => e.match_id)).toEqual([mine.matchID]);
  });

  it("drops waiting matches older than a week", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const stub = env.MATCH_QUEUE.getByName("portes:2");
    const old = await enter(a, "portes", 2);
    await runInDurableObject(stub, (q: MatchQueue) => {
      q.now = () => Date.now() + 8 * 24 * 60 * 60 * 1000;
    });
    const fresh = await enter(b, "portes", 2);
    expect(fresh.matchID).not.toBe(old.matchID);
  });

  it("a deleted creator's waiting match is skipped", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const waiting = await enter(a, "plakoto_standard", 1);
    expect((await call("DELETE", "/v1/account", undefined, a.token)).status).toBe(204);
    const mine = await enter(b, "plakoto_standard", 1);
    expect(mine.matchID).not.toBe(waiting.matchID);
  });

  it("validates the body", async () => {
    const a = await player("Alice");
    await fails(await call("POST", "/v1/automatch", { variant: "fevga" }, a.token), 400, "bad_request");
  });
});

describe("lobby removal", () => {
  it("hides an ended match for the caller only; running or unknown ones can't be removed", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const c = await player("Sam");
    const inv = await invite(a);
    await ok(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), MatchSnapshot);
    const id = inv.match.matchID;
    await fails(await call("DELETE", `/v1/matches/${id}`, undefined, a.token), 403, "forbidden");
    await ok(await call("POST", `/v1/matches/${id}/quit`, { inTurn: false }, b.token), MatchSnapshot);
    await fails(await call("DELETE", `/v1/matches/${id}`, undefined, c.token), 404, "not_found");
    await fails(await call("DELETE", "/v1/matches/m_unknown", undefined, a.token), 404, "not_found");
    expect((await call("DELETE", `/v1/matches/${id}`, undefined, a.token)).status).toBe(204);
    expect((await list(a)).matches.map((m) => m.matchID)).not.toContain(id);
    expect((await list(b)).matches.map((m) => m.matchID)).toContain(id);
    expect(await indexRow(env, id, a.id)).toMatchObject({ hidden: 1, state: "ended" });
  });
});
