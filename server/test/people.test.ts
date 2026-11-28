// #301: people list (derived from the match index, pin / remove / 90-day drop-off, added by
// handle), presence (PresenceHub sockets, visibility, hide switch, live updates, staleness),
// one-tap challenges (pending → accepted / declined / cancelled / expired, dedupe, crossed
// taps, races, pushes with the CHALLENGE category, live events), handles (generated, one
// change, unique ignoring case, races, reserved), search, blocking, "who can challenge me",
// and the account-deletion hook.
import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  Account,
  CHALLENGE_TTL_MS,
  HandleAvailability,
  MatchListResponse,
  MatchSnapshot,
  PEOPLE_MAX_AGE_MS,
  PeopleResponse,
  PlayerSearchResponse,
  PresenceMessage,
} from "../src/api";
import { suggestHandle, handleProblem } from "../src/handles";
import { Logger } from "../src/log";
import { expireChallenges, peopleDeps } from "../src/people";
import type { PresenceHub } from "../src/presence-hub";
import { pushDeps, resetProviderToken } from "../src/push";
import { call, fails, ok, player, type Player } from "./lobby-helpers";

const saved = { ...pushDeps };
const savedPeople = { ...peopleDeps };
let apns: { body: Record<string, unknown>; headers: Record<string, string> }[];

beforeEach(async () => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "debug").mockImplementation(() => {});
  apns = [];
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----\n`;
  pushDeps.credentials = () => ({ keyId: "ABC123DEFG", teamId: "8XRKL83C4V", privateKey: pem });
  pushDeps.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
    apns.push({ body: JSON.parse(String(init?.body)), headers: Object.fromEntries(new Headers(init?.headers).entries()) });
    return new Response(null, { status: 200 });
  }) as typeof fetch;
  resetProviderToken();
});
afterEach(() => {
  Object.assign(pushDeps, saved);
  Object.assign(peopleDeps, savedPeople);
  resetProviderToken();
  vi.restoreAllMocks();
});

const settle = () => new Promise((r) => setTimeout(r, 60));
let tokenSeq = 0;
async function device(p: Player) {
  const token = (++tokenSeq).toString(16).padStart(64, "c");
  expect((await call("PUT", "/v1/push-tokens", { token, environment: "sandbox" }, p.token)).status).toBe(204);
}

const people = async (p: Player) => ok(await call("GET", "/v1/people", undefined, p.token), PeopleResponse);
const challenge = (from: Player, to: Player, variant = "fevga", targetWins = 2) =>
  call("POST", "/v1/matches", { variant, targetWins, opponentID: to.id }, from.token);
const accept = (p: Player, id: string) => call("POST", `/v1/matches/${id}/accept`, undefined, p.token);
const decline = (p: Player, id: string) => call("POST", `/v1/matches/${id}/decline`, undefined, p.token);
const cancel = (p: Player, id: string) => call("POST", `/v1/matches/${id}/cancel`, undefined, p.token);
const account = async (p: Player) => ok(await call("GET", "/v1/account", undefined, p.token), Account);
const patchAccount = (p: Player, body: unknown) => call("PATCH", "/v1/account", body, p.token);

/** a challenges b, b accepts: they have played (both seats active). */
async function played(a: Player, b: Player, variant = "fevga"): Promise<string> {
  const snap = await ok(await challenge(a, b, variant), MatchSnapshot, 201);
  await ok(await accept(b, snap.matchID), MatchSnapshot);
  return snap.matchID;
}

async function presenceSocket(p: Player) {
  const res = await call("GET", "/v1/presence/socket", undefined, p.token, { upgrade: "websocket" });
  expect(res.status).toBe(101);
  const ws = res.webSocket!;
  const messages: PresenceMessage[] = [];
  const closed: { code?: number } = {};
  ws.addEventListener("message", (e) => messages.push(PresenceMessage.parse(JSON.parse(e.data as string))));
  ws.addEventListener("close", (e) => (closed.code = e.code));
  ws.accept();
  return { ws, messages, closed };
}

const hub = () => env.PRESENCE.getByName("global");

describe("people list", () => {
  it("lists everyone you've played, newest first, with handles — a declined challenge doesn't count", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const c = await player("Sam");
    const d = await player("Alex");
    await played(a, b);
    await new Promise((r) => setTimeout(r, 5));
    await played(c, a, "portes");
    const declined = await ok(await challenge(a, d), MatchSnapshot, 201);
    expect((await decline(d, declined.matchID)).status).toBe(204);
    const list = await people(a);
    expect(list.people.map((p) => p.displayName)).toEqual(["Sam", "Bob"]);
    expect(list.people[0]).toMatchObject({ playerID: c.id, pinned: false, handle: (await account(c)).handle });
    expect((await people(b)).people.map((p) => p.playerID)).toEqual([a.id]);
    expect((await people(d)).people).toEqual([]);
  });

  it("pins keep someone on top; remove hides until the next game; unpinned drop off after 90 days", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const c = await player("Sam");
    await played(a, b);
    await new Promise((r) => setTimeout(r, 5));
    await played(a, c);
    expect((await people(a)).people.map((p) => p.playerID)).toEqual([c.id, b.id]);
    expect((await call("PATCH", `/v1/people/${b.id}`, { pinned: true }, a.token)).status).toBe(204);
    expect((await people(a)).people.map((p) => [p.playerID, p.pinned])).toEqual([
      [b.id, true],
      [c.id, false],
    ]);
    // 91 days later: only the pinned one stays.
    const later = Date.now() + PEOPLE_MAX_AGE_MS + 86_400_000;
    peopleDeps.now = () => later;
    expect((await people(a)).people.map((p) => p.playerID)).toEqual([b.id]);
    peopleDeps.now = savedPeople.now;
    // Remove: gone (and unpinned) …
    expect((await call("DELETE", `/v1/people/${b.id}`, undefined, a.token)).status).toBe(204);
    expect((await people(a)).people.map((p) => p.playerID)).toEqual([c.id]);
    // … until they play again.
    await new Promise((r) => setTimeout(r, 5));
    await played(b, a, "portes");
    expect((await people(a)).people.map((p) => [p.playerID, p.pinned])).toEqual([
      [b.id, false],
      [c.id, false],
    ]);
    await fails(await call("PATCH", `/v1/people/nobody_here`, { pinned: true }, a.token), 404, "not_found");
    await fails(await call("PATCH", `/v1/people/${a.id}`, { pinned: true }, a.token), 404, "not_found");
  });

  it("adds someone found by handle with ⭐ (never played: no presence unless both added each other)", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    expect((await call("PATCH", `/v1/people/${b.id}`, { pinned: true }, a.token)).status).toBe(204);
    const sb = await presenceSocket(b);
    await settle();
    let list = await people(a);
    expect(list.people).toHaveLength(1);
    expect(list.people[0]).toMatchObject({ playerID: b.id, pinned: true, lastPlayedAt: null });
    expect(list.people[0]).not.toHaveProperty("presence");
    // b adds a back: mutual → presence.
    expect((await call("PATCH", `/v1/people/${a.id}`, { pinned: true }, b.token)).status).toBe(204);
    list = await people(a);
    expect(list.people[0]!.presence).toMatchObject({ online: true });
    sb.ws.close(1000);
  });
});

describe("presence", () => {
  it("shows online to people you've played, last seen after closing, live to an open app", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const stranger = await player("Sam");
    await played(a, b);
    expect((await people(a)).people[0]!.presence).toEqual({ online: false, lastSeenAt: null });
    const sa = await presenceSocket(a); // a's app is open: watches b (looked up below)
    await settle();
    await people(a);
    const sb = await presenceSocket(b);
    await settle();
    expect(sa.messages.map((m) => m.type)).toEqual(["hello", "presence"]);
    expect(sa.messages[1]).toMatchObject({ type: "presence", playerID: b.id, online: true });
    expect((await people(a)).people[0]!.presence?.online).toBe(true);
    // A stranger never sees b (not in the list, nothing to look up).
    expect((await people(stranger)).people).toEqual([]);
    sb.ws.close(1000);
    await settle();
    expect(sa.messages.at(-1)).toMatchObject({ type: "presence", playerID: b.id, online: false });
    const after = (await people(a)).people[0]!.presence!;
    expect(after.online).toBe(false);
    expect(after.lastSeenAt).toBeGreaterThan(Date.now() - 10_000);
    sa.ws.close(1000);
  });

  it("a socket without keepalives for 2 minutes is not online", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await played(a, b);
    const sb = await presenceSocket(b);
    await settle();
    expect((await people(a)).people[0]!.presence?.online).toBe(true);
    await runInDurableObject(hub(), async (h: PresenceHub) => {
      h.now = () => Date.now() + 3 * 60 * 1000;
    });
    const stale = (await people(a)).people[0]!.presence!;
    expect(stale.online).toBe(false);
    expect(stale.lastSeenAt).toBeLessThan(Date.now() + 1000);
    await runInDurableObject(hub(), async (h: PresenceHub) => {
      h.now = () => Date.now();
    });
    sb.ws.close(1000);
  });

  it("the hide switch hides the status from everyone, live", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await played(a, b);
    const sa = await presenceSocket(a);
    await settle();
    await people(a);
    const sb = await presenceSocket(b);
    await settle();
    const hidden = await ok(await patchAccount(b, { hidePresence: true }), Account);
    expect(hidden.hidePresence).toBe(true);
    await settle();
    expect(sa.messages.at(-1)).toMatchObject({ type: "presence", playerID: b.id, online: false });
    expect((await people(a)).people[0]).not.toHaveProperty("presence");
    // Reconnecting while hidden tells nobody.
    sb.ws.close(1000);
    await settle();
    const count = sa.messages.length;
    const sb2 = await presenceSocket(b);
    await settle();
    expect(sa.messages.length).toBe(count);
    await ok(await patchAccount(b, { hidePresence: false }), Account);
    await settle();
    expect(sa.messages.at(-1)).toMatchObject({ type: "presence", playerID: b.id, online: true });
    sa.ws.close(1000);
    sb2.ws.close(1000);
  });

  it("needs an upgrade and a token", async () => {
    const a = await player("Alice");
    await fails(await call("GET", "/v1/presence/socket", undefined, a.token), 400, "bad_request");
    await fails(await call("GET", "/v1/presence/socket", undefined, undefined, { upgrade: "websocket" }), 401, "unauthorized");
  });
});

describe("challenges", () => {
  it("pending: both see it; a second tap answers it; another game replaces it", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await played(a, b, "portes"); // so they are people
    const first = await ok(await challenge(a, b), MatchSnapshot, 201);
    expect((await people(a)).people[0]!.challenge).toMatchObject({ matchID: first.matchID, direction: "outgoing", variant: "fevga", targetWins: 2 });
    expect((await people(b)).people[0]!.challenge).toMatchObject({ matchID: first.matchID, direction: "incoming" });
    const again = await ok(await challenge(a, b), MatchSnapshot, 200);
    expect(again.matchID).toBe(first.matchID);
    const other = await ok(await challenge(a, b, "plakoto", 1), MatchSnapshot, 201);
    expect(other.matchID).not.toBe(first.matchID);
    const lobby = await ok(await call("GET", "/v1/matches", undefined, b.token), MatchListResponse);
    expect(lobby.matches.find((m) => m.matchID === first.matchID)).toMatchObject({ state: "ended", challenge: { status: "cancelled" } });
    expect(lobby.matches.find((m) => m.matchID === other.matchID)).toMatchObject({ state: "invited", challenge: { status: "pending" } });
  });

  it("accept: the challenger gets the push and the live event; the challenged gets the CHALLENGE push", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await device(a);
    await device(b);
    const sa = await presenceSocket(a);
    const sb = await presenceSocket(b);
    await settle();
    const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
    await vi.waitFor(() => expect(apns.length).toBe(1));
    expect(apns[0]!.body).toMatchObject({ kind: "challengeReceived", aps: { category: "CHALLENGE", alert: { "loc-key": "PUSH_GAME_FEVGA_2" } } });
    await settle();
    expect(sb.messages.at(-1)).toMatchObject({ type: "challenge", event: "received", challenge: { matchID: snap.matchID, status: "pending", from: { playerID: a.id } } });
    const accepted = await ok(await accept(b, snap.matchID), MatchSnapshot);
    expect(accepted.participants[1]!.status).toBe("active");
    await vi.waitFor(() => expect(apns.length).toBe(2));
    expect(apns[1]!.body).toMatchObject({ kind: "challengeAccepted", aps: { alert: { "loc-key": "PUSH_CHALLENGE_ACCEPTED", "loc-args": ["Bob"] } } });
    await settle();
    expect(sa.messages.at(-1)).toMatchObject({ type: "challenge", event: "accepted", challenge: { matchID: snap.matchID, status: "accepted" } });
    // A lost reply: accepting again answers the match, no second push.
    await ok(await accept(b, snap.matchID), MatchSnapshot);
    await settle();
    expect(apns.length).toBe(2);
    sa.ws.close(1000);
    sb.ws.close(1000);
  });

  it("decline: pushed + live to the challenger; again is 204; accept afterwards 410", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await device(a);
    const sa = await presenceSocket(a);
    await settle();
    const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
    expect((await decline(b, snap.matchID)).status).toBe(204);
    expect((await decline(b, snap.matchID)).status).toBe(204);
    await vi.waitFor(() => expect(apns.some((x) => x.body.kind === "challengeDeclined")).toBe(true));
    await settle();
    expect(sa.messages.at(-1)).toMatchObject({ type: "challenge", event: "declined" });
    await fails(await accept(b, snap.matchID), 410, "invite_unavailable");
    sa.ws.close(1000);
  });

  it("cancel: the challenged app's card goes; only the challenger; again 204; accept 410", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const sb = await presenceSocket(b);
    await settle();
    const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
    await fails(await cancel(b, snap.matchID), 403, "forbidden");
    expect((await cancel(a, snap.matchID)).status).toBe(204);
    expect((await cancel(a, snap.matchID)).status).toBe(204);
    await settle();
    expect(sb.messages.at(-1)).toMatchObject({ type: "challenge", event: "cancelled" });
    await fails(await accept(b, snap.matchID), 410, "invite_unavailable");
    const loaded = await ok(await call("GET", `/v1/matches/${snap.matchID}`, undefined, a.token), MatchSnapshot);
    expect(loaded.isEnded).toBe(true);
  });

  it("expires after 24 h (cron + lazily on accept)", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const c = await player("Sam");
    const sa = await presenceSocket(a);
    await settle();
    const one = await ok(await challenge(a, b), MatchSnapshot, 201);
    const two = await ok(await challenge(a, c), MatchSnapshot, 201);
    const later = Date.now() + CHALLENGE_TTL_MS + 1000;
    peopleDeps.now = () => later;
    const ctx = { waitUntil: (p: Promise<unknown>) => void p.catch(() => {}), passThroughOnException: () => {} } as unknown as ExecutionContext;
    expect(await expireChallenges(env, ctx, later, new Logger({}))).toBeGreaterThanOrEqual(2);
    await fails(await accept(b, one.matchID), 410, "invite_unavailable");
    const lobby = await ok(await call("GET", "/v1/matches", undefined, c.token), MatchListResponse);
    expect(lobby.matches.find((m) => m.matchID === two.matchID)).toMatchObject({ state: "ended", challenge: { status: "expired" } });
    await settle();
    const expiredIDs = sa.messages.flatMap((m) => (m.type === "challenge" && m.event === "expired" ? [m.challenge.matchID] : []));
    expect(expiredIDs.sort()).toEqual([one.matchID, two.matchID].sort());
    // A new challenge to b after expiry is a fresh one.
    const fresh = await ok(await challenge(a, b), MatchSnapshot, 201);
    expect(fresh.matchID).not.toBe(one.matchID);
    sa.ws.close(1000);
  });

  it("lazily expires on accept without the cron", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
    peopleDeps.now = () => Date.now() + CHALLENGE_TTL_MS + 1000;
    await fails(await accept(b, snap.matchID), 410, "invite_unavailable");
    peopleDeps.now = savedPeople.now;
    const loaded = await ok(await call("GET", `/v1/matches/${snap.matchID}`, undefined, a.token), MatchSnapshot);
    expect(loaded.isEnded).toBe(true);
  });

  it("races: accept vs decline vs cancel — exactly one wins", async () => {
    for (let round = 0; round < 3; round++) {
      const a = await player("Alice");
      const b = await player("Bob");
      const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
      const results = await Promise.all([accept(b, snap.matchID), decline(b, snap.matchID), cancel(a, snap.matchID)]);
      const [acc, dec, can] = results.map((r) => r.status);
      const row = await env.DB.prepare("SELECT status FROM challenges WHERE match_id = ?").bind(snap.matchID).first<{ status: string }>();
      const loaded = await ok(await call("GET", `/v1/matches/${snap.matchID}`, undefined, a.token), MatchSnapshot);
      if (row!.status === "accepted") {
        expect(acc).toBe(200);
        expect(loaded.isEnded).toBe(false);
        expect(dec).not.toBe(204);
        expect(can).not.toBe(204);
      } else {
        expect(acc).toBe(410);
        expect(loaded.isEnded).toBe(true);
        expect(["declined", "cancelled"]).toContain(row!.status);
      }
    }
  });

  it("two taps at once send one challenge", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const [x, y] = await Promise.all([challenge(a, b), challenge(a, b)]);
    const ids = [((await x.json()) as { matchID: string }).matchID, ((await y.json()) as { matchID: string }).matchID];
    expect(ids[0]).toBe(ids[1]);
    expect([x.status, y.status].sort()).toEqual([200, 201]);
  });

  it("crossed taps for the same game: the second accepts the first", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const first = await ok(await challenge(a, b), MatchSnapshot, 201);
    const crossed = await ok(await challenge(b, a), MatchSnapshot, 200);
    expect(crossed.matchID).toBe(first.matchID);
    expect(crossed.participants[1]!.status).toBe("active");
  });
});

describe("handles", () => {
  it("every account has one; it can be changed once; unique ignoring case; reserved refused", async () => {
    const a = await player("Alice K.");
    const b = await player("Bob");
    const acc = await account(a);
    expect(acc.handle).toMatch(/^[A-Za-z0-9_]{3,20}$/);
    expect(acc.handleChangeable).toBe(true);
    expect(acc.whoCanChallenge).toBe("everyone");
    const name = `alice_${Date.now() % 100000}`;
    await fails(await patchAccount(b, { handle: "Admin" }), 400, "bad_request");
    await fails(await patchAccount(b, { handle: "tavtav_team" }), 400, "bad_request");
    const changed = await ok(await patchAccount(a, { handle: name }), Account);
    expect(changed).toMatchObject({ handle: name, handleChangeable: false });
    await fails(await patchAccount(a, { handle: `${name}x` }), 403, "forbidden");
    await fails(await patchAccount(b, { handle: name.toUpperCase() }), 409, "handle_taken");
    expect((await account(b)).handleChangeable).toBe(true); // a refused change isn't the one
    expect(await ok(await call("GET", `/v1/handles/${name.toUpperCase()}`, undefined, b.token), HandleAvailability)).toMatchObject({ available: false, reason: "taken" });
    expect(await ok(await call("GET", `/v1/handles/${name}`, undefined, a.token), HandleAvailability)).toMatchObject({ available: true, reason: "yours" });
    expect(await ok(await call("GET", `/v1/handles/root`, undefined, a.token), HandleAvailability)).toMatchObject({ reason: "reserved" });
    expect(await ok(await call("GET", `/v1/handles/a%20b`, undefined, a.token), HandleAvailability)).toMatchObject({ reason: "invalid" });
  });

  it("two players taking the same handle at once: one gets it, the other 409", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const want = `race_${Date.now() % 1000000}`;
    const [x, y] = await Promise.all([patchAccount(a, { handle: want }), patchAccount(b, { handle: want.toUpperCase() })]);
    expect([x.status, y.status].sort()).toEqual([200, 409]);
  });

  it("suggests a handle from a display name", () => {
    expect(suggestHandle("Alice K.")).toBe("Alice_K");
    expect(suggestHandle("Ζωή")).toBe("player");
    expect(suggestHandle("José María")).toBe("Jose_Maria");
    expect(suggestHandle("ab")).toBe("player");
    expect(suggestHandle("Admin")).toBe("player");
    expect(handleProblem("TavTav1")).toBe("reserved");
    expect(handleProblem("ok_name")).toBeNull();
  });
});

describe("search", () => {
  it("prefix on the handle, exact first, never yourself; strangers just handle + name", async () => {
    const tag = `s${Date.now() % 1000000}`;
    const me = await player("Alice");
    const exact = await player("Bob");
    const longer = await player("Sam");
    await ok(await patchAccount(exact, { handle: tag }), Account);
    await ok(await patchAccount(longer, { handle: `${tag}_2` }), Account);
    await ok(await patchAccount(me, { handle: `${tag}_me` }), Account);
    const res = await ok(await call("GET", `/v1/players?q=@${tag.toUpperCase()}`, undefined, me.token), PlayerSearchResponse);
    expect(res.players.map((p) => p.playerID)).toEqual([exact.id, longer.id]);
    expect(res.players[0]).toEqual({ playerID: exact.id, handle: tag, displayName: "Bob", isPerson: false, canChallenge: true });
    await fails(await call("GET", "/v1/players?q=ab", undefined, me.token), 400, "bad_request");
    await fails(await call("GET", "/v1/players?q=a%20bc", undefined, me.token), 400, "bad_request");
  });

  it("is rate-limited per account", async () => {
    const me = await player("Alice");
    const statuses: number[] = [];
    for (let i = 0; i < 32; i++) statuses.push((await call("GET", "/v1/players?q=zzzq", undefined, me.token)).status);
    expect(statuses.slice(0, 30).every((s) => s === 200)).toBe(true);
    expect(statuses.at(-1)).toBe(429);
  });
});

describe("blocking and who can challenge", () => {
  it("block on an incoming challenge: declined quietly, no more challenges, search or presence", async () => {
    const tag = `b${Date.now() % 1000000}`;
    const a = await player("Alice");
    const b = await player("Bob");
    await ok(await patchAccount(b, { handle: tag }), Account);
    await played(a, b, "portes");
    await device(a);
    const sa = await presenceSocket(a);
    await settle();
    await people(a);
    const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
    const pushesBefore = apns.length;
    expect((await call("POST", `/v1/people/${a.id}/block`, undefined, b.token)).status).toBe(204);
    expect((await call("POST", `/v1/people/${a.id}/block`, undefined, b.token)).status).toBe(204);
    await settle();
    expect(sa.messages.at(-1)).toMatchObject({ type: "challenge", event: "declined", challenge: { matchID: snap.matchID } });
    expect(apns.length).toBe(pushesBefore); // quietly: no "declined" push
    await fails(await challenge(a, b), 403, "forbidden");
    expect((await ok(await call("GET", `/v1/players?q=${tag}`, undefined, a.token), PlayerSearchResponse)).players).toEqual([]);
    expect((await people(a)).people).toEqual([]);
    const mine = await people(b);
    expect(mine.people).toEqual([]);
    expect(mine.blocked?.map((x) => x.playerID)).toEqual([a.id]);
    // Unblock: back to normal.
    expect((await call("DELETE", `/v1/people/${a.id}/block`, undefined, b.token)).status).toBe(204);
    expect((await people(a)).people.map((p) => p.playerID)).toEqual([b.id]);
    await ok(await challenge(a, b), MatchSnapshot, 201);
    sa.ws.close(1000);
  });

  it("only my people: strangers can't challenge, people (played or ⭐) can", async () => {
    const tag = `p${Date.now() % 1000000}`;
    const a = await player("Alice");
    const friend = await player("Bob");
    const stranger = await player("Sam");
    await played(friend, a, "portes");
    await ok(await patchAccount(a, { whoCanChallenge: "people", handle: tag }), Account);
    expect((await account(a)).whoCanChallenge).toBe("people");
    await fails(await challenge(stranger, a), 403, "forbidden");
    const found = await ok(await call("GET", `/v1/players?q=${tag}`, undefined, stranger.token), PlayerSearchResponse);
    expect(found.players[0]).toMatchObject({ playerID: a.id, canChallenge: false, isPerson: false });
    await ok(await challenge(friend, a), MatchSnapshot, 201);
    // a adds the stranger: now they may.
    expect((await call("PATCH", `/v1/people/${stranger.id}`, { pinned: true }, a.token)).status).toBe(204);
    await ok(await challenge(stranger, a), MatchSnapshot, 201);
  });
});

describe("account deletion", () => {
  it("cancels pending challenges live, deletes people choices, blocks and presence", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await played(a, b, "portes");
    await call("PATCH", `/v1/people/${b.id}`, { pinned: true }, a.token);
    await call("PATCH", `/v1/people/${a.id}`, { pinned: true }, b.token);
    await call("POST", `/v1/people/${b.id}/block`, undefined, a.token);
    await call("DELETE", `/v1/people/${b.id}/block`, undefined, a.token);
    const sb = await presenceSocket(b);
    const sa = await presenceSocket(a);
    await settle();
    await people(b);
    const snap = await ok(await challenge(a, b), MatchSnapshot, 201);
    expect((await call("DELETE", "/v1/account", undefined, a.token)).status).toBe(204);
    await settle();
    expect(sb.messages.some((m) => m.type === "challenge" && m.event === "cancelled" && m.challenge.matchID === snap.matchID)).toBe(true);
    expect(sa.closed.code).toBe(4403);
    const left = await env.DB.prepare(
      "SELECT (SELECT count(*) FROM challenges WHERE challenger_id = ?1 OR challenged_id = ?1) + " +
        "(SELECT count(*) FROM contact_prefs WHERE account_id = ?1 OR contact_id = ?1) + " +
        "(SELECT count(*) FROM blocks WHERE blocker_id = ?1 OR blocked_id = ?1) AS n",
    )
      .bind(a.id)
      .first<{ n: number }>();
    expect(left?.n).toBe(0);
    const rows = await hub().rows();
    expect(rows.seen.some((r) => r.account_id === a.id)).toBe(false);
    expect(rows.watch.some((r) => r.target === a.id || r.watcher === a.id)).toBe(false);
    expect((await people(b)).people).toEqual([]);
    sb.ws.close(1000);
  });
});
