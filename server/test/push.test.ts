// #287 push: device-token endpoints, the APNs provider JWT (ES256 over WebCrypto) and its
// cache, request + payload building, dead-token cleanup, "skipped without the key", which
// operations push whom, and the account-deletion hook. A fake fetch stands in for APNs.
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type MatchSnapshot, MatchSnapshot as MatchSnapshotSchema, PushPayload } from "../src/api";
import { decodeJwt } from "../src/jwt";
import { Logger } from "../src/log";
import {
  APNS_TOPIC,
  apnsPayload,
  apnsRequest,
  MAX_TOKENS_PER_ACCOUNT,
  PROVIDER_TOKEN_TTL_MS,
  providerToken,
  pushDeps,
  pushesAfter,
  resetProviderToken,
  sendPushes,
} from "../src/push";
import { call, fails, ok, player, playFirstTurn, type Player } from "./lobby-helpers";

const NOW = Date.UTC(2026, 10, 28, 12, 0, 0);
const KEY_ID = "ABC123DEFG";
const TEAM_ID = "8XRKL83C4V";

async function p8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

const hexToken = (n: number) => n.toString(16).padStart(64, "a");

interface Apns {
  calls: { url: string; headers: Record<string, string>; body: unknown }[];
  answer: (url: string) => Response;
}

let apns: Apns;
let key: { pem: string; publicKey: CryptoKey };
const saved = { ...pushDeps };

beforeEach(async () => {
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
  vi.spyOn(console, "debug").mockImplementation(() => {});
  key = await p8();
  apns = { calls: [], answer: () => new Response(null, { status: 200 }) };
  pushDeps.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    apns.calls.push({
      url,
      headers: Object.fromEntries(new Headers(init?.headers).entries()),
      body: JSON.parse(String(init?.body)),
    });
    return apns.answer(url);
  }) as typeof fetch;
  pushDeps.now = () => NOW;
  pushDeps.credentials = () => ({ keyId: KEY_ID, teamId: TEAM_ID, privateKey: key.pem });
  resetProviderToken();
});
afterEach(() => {
  Object.assign(pushDeps, saved);
  resetProviderToken();
  vi.restoreAllMocks();
});

async function register(p: Player, token: string, environment = "sandbox", locale = "de-DE") {
  const res = await call("PUT", "/v1/push-tokens", { token, environment, locale }, p.token);
  expect(res.status).toBe(204);
}

const tokensOf = async (accountID: string) =>
  (
    await env.DB.prepare("SELECT token, environment, locale FROM push_tokens WHERE account_id = ? ORDER BY token")
      .bind(accountID)
      .all<{ token: string; environment: string; locale: string | null }>()
  ).results;

describe("device tokens", () => {
  it("register, refresh, move to another account, unregister", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    const t = hexToken(1);
    await register(a, t, "sandbox", "el-GR");
    await register(a, t, "production", "nl-NL");
    expect(await tokensOf(a.id)).toEqual([{ token: t, environment: "production", locale: "nl-NL" }]);
    // The device signed in with another account: the token follows the newest account.
    await register(b, t);
    expect(await tokensOf(a.id)).toEqual([]);
    expect((await tokensOf(b.id)).map((r) => r.token)).toEqual([t]);
    // Only the owner removes it; removing an unknown token is fine.
    expect((await call("DELETE", `/v1/push-tokens/${t}`, undefined, a.token)).status).toBe(204);
    expect((await tokensOf(b.id)).length).toBe(1);
    expect((await call("DELETE", `/v1/push-tokens/${t}`, undefined, b.token)).status).toBe(204);
    expect(await tokensOf(b.id)).toEqual([]);
  });

  it("keeps the newest tokens per account and validates", async () => {
    const a = await player("Alice");
    for (let i = 0; i < MAX_TOKENS_PER_ACCOUNT + 2; i++) {
      pushDeps.now = () => NOW + i;
      await register(a, hexToken(100 + i));
    }
    const kept = (await tokensOf(a.id)).map((r) => r.token);
    expect(kept.length).toBe(MAX_TOKENS_PER_ACCOUNT);
    expect(kept).not.toContain(hexToken(100));
    expect(kept).toContain(hexToken(100 + MAX_TOKENS_PER_ACCOUNT + 1));
    await fails(await call("PUT", "/v1/push-tokens", { token: "XYZ", environment: "sandbox" }, a.token), 400, "bad_request");
    await fails(await call("PUT", "/v1/push-tokens", { token: hexToken(1), environment: "dev" }, a.token), 400, "bad_request");
    await fails(await call("DELETE", "/v1/push-tokens/nothex", undefined, a.token), 400, "bad_request");
    await fails(await call("PUT", "/v1/push-tokens", { token: hexToken(1), environment: "sandbox" }), 401, "unauthorized");
  });

  it("go with the account (deletion hook)", async () => {
    const a = await player("Alice");
    await register(a, hexToken(7));
    expect((await call("DELETE", "/v1/account", undefined, a.token)).status).toBe(204);
    expect(await tokensOf(a.id)).toEqual([]);
  });
});

describe("APNs provider token", () => {
  it("is an ES256 JWT {kid} + {iss: team, iat} the key verifies, reused for 50 minutes", async () => {
    const creds = { keyId: KEY_ID, teamId: TEAM_ID, privateKey: key.pem };
    const jwt = await providerToken(creds, NOW);
    const decoded = decodeJwt(jwt);
    expect(decoded.header).toEqual({ kid: KEY_ID, alg: "ES256" });
    expect(decoded.claims).toEqual({ iss: TEAM_ID, iat: Math.floor(NOW / 1000) });
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key.publicKey,
      decoded.signature,
      decoded.signingInput,
    );
    expect(valid).toBe(true);
    expect(decoded.signature.length).toBe(64); // JOSE r||s, not DER
    expect(await providerToken(creds, NOW + PROVIDER_TOKEN_TTL_MS - 1)).toBe(jwt);
    const renewed = await providerToken(creds, NOW + PROVIDER_TOKEN_TTL_MS);
    expect(renewed).not.toBe(jwt);
    expect(decodeJwt(renewed).claims.iat).toBe(Math.floor((NOW + PROVIDER_TOKEN_TTL_MS) / 1000));
    // Another key id → a new token at once.
    expect(await providerToken({ ...creds, keyId: "OTHERKEY12" }, NOW + PROVIDER_TOKEN_TTL_MS + 1)).not.toBe(renewed);
    // An escaped one-line PEM (as some secret stores keep it) imports too.
    const oneLine = key.pem.replace(/\n/g, "\\n");
    resetProviderToken();
    expect(decodeJwt(await providerToken({ ...creds, privateKey: oneLine }, NOW)).header.kid).toBe(KEY_ID);
  });
});

describe("APNs requests", () => {
  const msg = { to: "acc_x", kind: "yourTurn" as const, matchID: "m_7f3a9c21d4e5", name: "Alex" };

  it("payload: loc-key + loc-args, matchID, kind (= the shared fixture)", () => {
    const payload = apnsPayload(msg);
    expect(PushPayload.parse(payload)).toEqual(payload);
    expect(payload).toEqual({
      aps: { alert: { "loc-key": "PUSH_YOUR_TURN", "loc-args": ["Alex"] }, sound: "default", "thread-id": msg.matchID },
      matchID: msg.matchID,
      kind: "yourTurn",
    });
    const keys = [
      apnsPayload({ ...msg, kind: "inviteReceived" }),
      apnsPayload({ ...msg, kind: "inviteAccepted" }),
      apnsPayload({ ...msg, kind: "opponentLeft" }),
      apnsPayload({ ...msg, kind: "matchEnded", outcome: "won" }),
      apnsPayload({ ...msg, kind: "matchEnded", outcome: "lost" }),
      apnsPayload({ ...msg, kind: "matchEnded", outcome: "tied" }),
    ].map((p) => p.aps.alert["loc-key"]);
    expect(keys).toEqual([
      "PUSH_INVITE_RECEIVED",
      "PUSH_INVITE_ACCEPTED",
      "PUSH_OPPONENT_LEFT",
      "PUSH_MATCH_WON",
      "PUSH_MATCH_LOST",
      "PUSH_MATCH_ENDED",
    ]);
  });

  it("host per token environment, provider auth + topic headers, collapse id for turns", () => {
    const prod = apnsRequest("ab".repeat(32), "production", msg, "JWT", NOW);
    expect(prod.url).toBe(`https://api.push.apple.com/3/device/${"ab".repeat(32)}`);
    expect(prod.init.headers).toMatchObject({
      authorization: "bearer JWT",
      "apns-topic": APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-collapse-id": "turn-m_7f3a9c21d4e5",
      "apns-expiration": String(Math.floor(NOW / 1000) + 86400),
    });
    const sandbox = apnsRequest("cd".repeat(32), "sandbox", { ...msg, kind: "inviteAccepted" }, "JWT", NOW);
    expect(sandbox.url).toBe(`https://api.sandbox.push.apple.com/3/device/${"cd".repeat(32)}`);
    expect(sandbox.init.headers).not.toHaveProperty("apns-collapse-id");
    expect(APNS_TOPIC).toBe("com.plakoto.TavliApp");
  });

  it("sends to every device of the recipient and deletes tokens APNs calls dead", async () => {
    const b = await player("Bob");
    const live = hexToken(11);
    const gone = hexToken(12);
    const bad = hexToken(13);
    const flaky = hexToken(14);
    await register(b, live, "sandbox");
    await register(b, gone, "production");
    await register(b, bad, "production");
    await register(b, flaky, "production");
    apns.answer = (url) => {
      if (url.endsWith(gone)) return Response.json({ reason: "Unregistered" }, { status: 410 });
      if (url.endsWith(bad)) return Response.json({ reason: "BadDeviceToken" }, { status: 400 });
      if (url.endsWith(flaky)) return Response.json({ reason: "InternalServerError" }, { status: 500 });
      return new Response(null, { status: 200 });
    };
    const report = await sendPushes(env, [{ ...msg, to: b.id }], new Logger());
    expect(report).toEqual({ sent: 1, failed: 3, removed: 2 });
    expect(apns.calls.map((c) => c.url.split("/3/")[0]).sort()).toEqual([
      "https://api.push.apple.com",
      "https://api.push.apple.com",
      "https://api.push.apple.com",
      "https://api.sandbox.push.apple.com",
    ]);
    const jwt = apns.calls[0]!.headers.authorization!.replace("bearer ", "");
    expect(decodeJwt(jwt).header.kid).toBe(KEY_ID);
    expect(apns.calls.every((c) => c.headers.authorization === `bearer ${jwt}`)).toBe(true); // one JWT for all
    expect((await tokensOf(b.id)).map((r) => r.token).sort()).toEqual([live, flaky].sort());
  });

  it("is skipped (and logged) without the APNs key", async () => {
    const log = vi.spyOn(console, "log");
    pushDeps.credentials = saved.credentials; // the test env has APNS_TEAM_ID only
    const b = await player("Bob");
    await register(b, hexToken(21));
    const report = await sendPushes(env, [{ ...msg, to: b.id }], new Logger());
    expect(report.skipped).toBe("not_configured");
    expect(apns.calls).toEqual([]);
    expect(log.mock.calls.some(([line]) => String(line).includes('"event":"push.skipped"'))).toBe(true);
    expect(saved.credentials({ ...env, APNS_KEY_ID: "K", APNS_PRIVATE_KEY: "P" } as Env)).toEqual({
      keyId: "K",
      teamId: "8XRKL83C4V",
      privateKey: "P",
    });
  });

  it("a refused provider token is dropped from the cache; a network error never throws", async () => {
    const b = await player("Bob");
    await register(b, hexToken(31), "production");
    apns.answer = () => Response.json({ reason: "ExpiredProviderToken" }, { status: 403 });
    await sendPushes(env, [{ ...msg, to: b.id }], new Logger());
    const first = apns.calls[0]!.headers.authorization;
    pushDeps.now = () => NOW + 1000; // within the TTL, but the cache was reset
    apns.answer = () => {
      throw new TypeError("network down");
    };
    const report = await sendPushes(env, [{ ...msg, to: b.id }], new Logger());
    expect(report).toMatchObject({ sent: 0, failed: 1 });
    expect(apns.calls[1]!.headers.authorization).not.toBe(first);
  });
});

describe("who gets which push", () => {
  const snap = (over: Partial<MatchSnapshot> = {}): MatchSnapshot =>
    MatchSnapshotSchema.parse({
      matchID: "m_1",
      revision: 1,
      variant: "plakoto",
      targetWins: 1,
      startingPlayer: "W",
      data: null,
      participants: [
        { playerID: "acc_a", displayName: "Alice", color: "W", status: "active", outcome: "none" },
        { playerID: "acc_b", displayName: "Bob", color: "B", status: "active", outcome: "none" },
      ],
      currentPlayerID: "acc_b",
      isEnded: false,
      diceHandicap: { whiteLevel: 0, rev: 0 },
      lastRoll: null,
      requests: [],
      createdAt: 1,
      updatedAt: 2,
      ...over,
    });

  it("maps each operation to the other player", () => {
    expect(pushesAfter("endTurn", "acc_a", snap())).toEqual([{ to: "acc_b", kind: "yourTurn", matchID: "m_1", name: "Alice" }]);
    // The turn did not pass to them (an open seat): nobody.
    expect(pushesAfter("endTurn", "acc_a", snap({ currentPlayerID: null }))).toEqual([]);
    const ended = snap({ isEnded: true, currentPlayerID: null });
    ended.participants[1]!.outcome = "lost";
    expect(pushesAfter("endMatch", "acc_a", ended)).toEqual([
      { to: "acc_b", kind: "matchEnded", matchID: "m_1", name: "Alice", outcome: "lost" },
    ]);
    const quit = snap({ isEnded: true, currentPlayerID: null });
    quit.participants[0]!.outcome = "quit";
    quit.participants[1]!.outcome = "won";
    expect(pushesAfter("quit", "acc_a", quit)).toEqual([{ to: "acc_b", kind: "opponentLeft", matchID: "m_1", name: "Alice" }]);
    expect(pushesAfter("join", "acc_b", snap())).toEqual([{ to: "acc_a", kind: "inviteAccepted", matchID: "m_1", name: "Bob" }]);
    const challenge = snap({ currentPlayerID: "acc_a" });
    challenge.participants[1]!.status = "invited";
    expect(pushesAfter("create", "acc_a", challenge)).toEqual([
      { to: "acc_b", kind: "inviteReceived", matchID: "m_1", name: "Alice" },
    ]);
    // Open seat (auto-match / invite code): nobody to tell.
    const open = snap({ currentPlayerID: "acc_a" });
    open.participants[1] = { playerID: null, displayName: null, color: "B", status: "matching", outcome: "none" };
    expect(pushesAfter("create", "acc_a", open)).toEqual([]);
    expect(pushesAfter("quit", "acc_a", open)).toEqual([]);
  });

  it("end-turn through the Worker pushes 'your turn' to the opponent's device", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await register(b, hexToken(41), "sandbox");
    const challenge = await ok(
      await call("POST", "/v1/matches", { variant: "plakoto", targetWins: 1, opponentID: b.id }, a.token),
      MatchSnapshotSchema,
      201,
    );
    await vi.waitFor(() => expect(apns.calls.length).toBe(1));
    expect(apns.calls[0]!.body).toMatchObject({ aps: { alert: { "loc-key": "PUSH_INVITE_RECEIVED", "loc-args": ["Alice"] } } });
    await ok(await call("POST", `/v1/matches/${challenge.matchID}/accept`, undefined, b.token), MatchSnapshotSchema);
    await playFirstTurn(a, challenge.matchID);
    await vi.waitFor(() => expect(apns.calls.length).toBe(2));
    expect(apns.calls[1]!.url).toBe(`https://api.sandbox.push.apple.com/3/device/${hexToken(41)}`);
    expect(apns.calls[1]!.body).toEqual({
      aps: { alert: { "loc-key": "PUSH_YOUR_TURN", "loc-args": ["Alice"] }, sound: "default", "thread-id": challenge.matchID },
      matchID: challenge.matchID,
      kind: "yourTurn",
    });
  });

  it("joining by invite code tells the creator; deleting an account tells the opponent", async () => {
    const a = await player("Alice");
    const b = await player("Bob");
    await register(a, hexToken(51), "production");
    const inv = await ok(await call("POST", "/v1/invites", { variant: "fevga", targetWins: 1 }, a.token), {
      parse: (v: unknown) => v as { code: string; match: { matchID: string } },
    }, 201);
    await ok(await call("POST", `/v1/invites/${inv.code}/accept`, undefined, b.token), MatchSnapshotSchema);
    await vi.waitFor(() => expect(apns.calls.length).toBe(1));
    expect(apns.calls[0]!.body).toMatchObject({ kind: "inviteAccepted", aps: { alert: { "loc-args": ["Bob"] } } });

    expect((await call("DELETE", "/v1/account", undefined, b.token)).status).toBe(204);
    await vi.waitFor(() => expect(apns.calls.length).toBe(2));
    expect(apns.calls[1]!.body).toMatchObject({
      kind: "opponentLeft",
      matchID: inv.match.matchID,
      aps: { alert: { "loc-key": "PUSH_OPPONENT_LEFT", "loc-args": ["Bob"] } },
    });
  });
});
