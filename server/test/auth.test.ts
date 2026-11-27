import { createExecutionContext, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { deleteAccount, normalizeDisplayName, signInForDevelopment } from "../src/accounts";
import { ACCOUNT_DELETION_HOOKS } from "../src/account-hooks";
import { Account, ApiError, AuthSession } from "../src/api";
import { APPLE_REVOKE_URL, APPLE_TOKEN_URL, revokeAppleTokens, storeAppleRefreshToken } from "../src/apple-revoke";
import { HttpError } from "../src/http";
import { googleConfig, identityDeps } from "../src/identity";
import worker from "../src/index";
import { base64UrlDecode, base64UrlEncode, decodeJwt, utf8 } from "../src/jwt";
import { Logger } from "../src/log";
import type { RouteContext } from "../src/routes";
import { ACCESS_TTL_MS, REFRESH_TTL_MS, verifyAccessToken } from "../src/sessions";
import {
  appleClaims,
  GOOGLE_CLIENT_ID,
  googleClaims,
  installFakes,
  mintJwt,
  NOW,
  RAW_NONCE,
  rsaKey,
} from "./auth-helpers";

const BASE = "https://server.test";
const quiet = new Logger();
let fakes: Awaited<ReturnType<typeof installFakes>>;
let subjectSeq = 0;
const freshSub = (p: string) => `${p}.${Date.now()}.${subjectSeq++}`;

beforeEach(async () => {
  fakes = await installFakes();
  vi.spyOn(console, "log").mockImplementation(() => {});
  vi.spyOn(console, "warn").mockImplementation(() => {});
});
afterEach(() => {
  fakes.restore();
  vi.restoreAllMocks();
});

function call(method: string, path: string, body?: unknown, token?: string): Promise<Response> {
  const headers: Record<string, string> = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (token) headers.authorization = `Bearer ${token}`;
  return exports.default.fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

async function errorOf(res: Response) {
  return ApiError.parse(await res.json()).error;
}

async function appleSignIn(sub: string, extra: Record<string, unknown> = {}) {
  const identityToken = await mintJwt(fakes.apple[0]!, await appleClaims(sub));
  return call("POST", "/v1/auth/apple", { identityToken, nonce: RAW_NONCE, ...extra });
}

async function session(res: Response): Promise<AuthSession> {
  expect(res.status).toBe(200);
  return AuthSession.parse(await res.json());
}

describe("Sign in with Apple", () => {
  it("creates an account once, then signs into the same one", async () => {
    const sub = freshSub("apple");
    const first = await session(await appleSignIn(sub, { displayName: "  Alice   K. " }));
    expect(first.isNewAccount).toBe(true);
    expect(first.account).toMatchObject({ displayName: "Alice K.", providers: ["apple"], createdAt: NOW });
    expect(first.account.id).toMatch(/^acc_[A-Za-z0-9_-]{16}$/);
    expect(first.accessExpiresAt).toBe(NOW + ACCESS_TTL_MS);
    expect(first.refreshExpiresAt).toBe(NOW + REFRESH_TTL_MS);

    const second = await session(await appleSignIn(sub, { displayName: "Ignored" }));
    expect(second.isNewAccount).toBe(false);
    expect(second.account).toEqual(first.account);
    expect(second.refreshToken).not.toBe(first.refreshToken);
  });

  it("gives a new account without a name a placeholder", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    expect(s.account.displayName).toMatch(/^Player \d{4}$/);
  });

  const cases: [string, () => Promise<string>][] = [
    ["wrong audience", async () => mintJwt(fakes.apple[0]!, await appleClaims("x", { aud: "com.other.app" }))],
    ["wrong issuer", async () => mintJwt(fakes.apple[0]!, await appleClaims("x", { iss: "https://evil.example" }))],
    ["expired", async () => mintJwt(fakes.apple[0]!, await appleClaims("x", { exp: Math.floor(NOW / 1000) - 120 }))],
    ["issued in the future", async () => mintJwt(fakes.apple[0]!, await appleClaims("x", { iat: Math.floor(NOW / 1000) + 600 }))],
    ["nonce mismatch", async () => mintJwt(fakes.apple[0]!, await appleClaims("x", { nonce: "f".repeat(64) }))],
    ["raw nonce instead of its hash", async () => mintJwt(fakes.apple[0]!, await appleClaims("x", { nonce: RAW_NONCE }))],
    ["no subject", async () => mintJwt(fakes.apple[0]!, await appleClaims("", {}))],
    ["unknown key id", async () => mintJwt(await rsaKey("apple-unknown"), await appleClaims("x"))],
    [
      "signed by another key under a known kid",
      async () => mintJwt({ ...(await rsaKey("apple-1")) }, await appleClaims("x")),
    ],
    ["alg none", async () => {
      const t = await mintJwt(fakes.apple[0]!, await appleClaims("x"), { alg: "none" });
      return t.replace(/\.[^.]+$/, ".");
    }],
    ["HS256 header", async () => mintJwt(fakes.apple[0]!, await appleClaims("x"), { alg: "HS256" })],
    ["a Google token", async () => mintJwt(fakes.google[0]!, await googleClaims("x"))],
    ["garbage", async () => "not.a.jwt"],
  ];
  for (const [name, token] of cases) {
    it(`rejects: ${name}`, async () => {
      const res = await call("POST", "/v1/auth/apple", { identityToken: await token(), nonce: RAW_NONCE });
      expect(res.status).toBe(401);
      expect((await errorOf(res)).code).toBe("unauthorized");
    });
  }

  it("rejects a malformed body with the field path", async () => {
    const res = await call("POST", "/v1/auth/apple", { identityToken: "x", nonce: "short" });
    expect(res.status).toBe(400);
    expect(await errorOf(res)).toMatchObject({ code: "bad_request", path: "nonce" });
  });

  it("caches the JWKS and refetches once for a rotated key", async () => {
    await session(await appleSignIn(freshSub("apple")));
    await session(await appleSignIn(freshSub("apple")));
    const jwksCalls = () => fakes.calls.filter((c) => c.url.includes("appleid.apple.com/auth/keys")).length;
    expect(jwksCalls()).toBe(1);

    // Apple rotates: a token under the new kid triggers one refetch (after the 60 s floor).
    const rotated = await rsaKey("apple-2");
    fakes.apple.push(rotated);
    identityDeps.now = () => NOW + 61_000;
    const token = await mintJwt(rotated, await appleClaims(freshSub("apple")));
    await session(await call("POST", "/v1/auth/apple", { identityToken: token, nonce: RAW_NONCE }));
    expect(jwksCalls()).toBe(2);
  });

  it("answers 503 when the JWKS cannot be fetched", async () => {
    fakes.fetch.mockImplementation(async () => new Response("down", { status: 500 }));
    const res = await appleSignIn(freshSub("apple"));
    expect(res.status).toBe(503);
  });
});

describe("Sign in with Google", () => {
  it("creates an account and verifies aud = the iOS client id", async () => {
    const sub = freshSub("google");
    const idToken = await mintJwt(fakes.google[0]!, await googleClaims(sub));
    const s = await session(await call("POST", "/v1/auth/google", { idToken, nonce: RAW_NONCE }));
    expect(s.isNewAccount).toBe(true);
    expect(s.account.providers).toEqual(["google"]);

    const bare = await mintJwt(fakes.google[0]!, await googleClaims(sub, { iss: "accounts.google.com" }));
    const again = await session(await call("POST", "/v1/auth/google", { idToken: bare, nonce: RAW_NONCE }));
    expect(again.account.id).toBe(s.account.id);
  });

  it("rejects another client's token and an Apple token", async () => {
    for (const idToken of [
      await mintJwt(fakes.google[0]!, await googleClaims("g", { aud: "web-client.apps.googleusercontent.com" })),
      await mintJwt(fakes.apple[0]!, await appleClaims("g")),
    ]) {
      const res = await call("POST", "/v1/auth/google", { idToken, nonce: RAW_NONCE });
      expect(res.status).toBe(401);
    }
  });

  it("is unavailable until a client id is configured", () => {
    expect(() => googleConfig({ ...env, GOOGLE_CLIENT_IDS: "" })).toThrow(HttpError);
    expect(googleConfig({ ...env, GOOGLE_CLIENT_IDS: ` a , ${GOOGLE_CLIENT_ID} ` }).audiences).toEqual([
      "a",
      GOOGLE_CLIENT_ID,
    ]);
  });
});

describe("sessions", () => {
  it("authorizes the account endpoints with the access token", async () => {
    const s = await session(await appleSignIn(freshSub("apple"), { displayName: "Bob" }));
    const res = await call("GET", "/v1/account", undefined, s.accessToken);
    expect(res.status).toBe(200);
    expect(Account.parse(await res.json())).toEqual(s.account);
  });

  it("rejects missing, forged and expired access tokens", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    expect((await errorOf(await call("GET", "/v1/account"))).code).toBe("unauthorized");

    const [payload, sig] = s.accessToken.slice(3).split(".") as [string, string];
    const claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(payload)));
    const forged = `at_${base64UrlEncode(utf8(JSON.stringify({ ...claims, sub: "acc_someoneelse" })))}.${sig}`;
    const r1 = await call("GET", "/v1/account", undefined, forged);
    expect(r1.status).toBe(401);
    expect((await errorOf(r1)).code).toBe("unauthorized");

    identityDeps.now = () => NOW + ACCESS_TTL_MS + 1;
    const r2 = await call("GET", "/v1/account", undefined, s.accessToken);
    expect(r2.status).toBe(401);
    expect((await errorOf(r2)).code).toBe("token_expired");
  });

  it("needs SESSION_KEY outside development", async () => {
    const err = await verifyAccessToken({ ...env, ENVIRONMENT: "staging", SESSION_KEY: undefined }, "at_a.b", NOW).catch(
      (e) => e,
    );
    expect(err).toMatchObject({ code: "unavailable" });
  });

  it("rotates refresh tokens and revokes the session when an old one comes back", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    identityDeps.now = () => NOW + ACCESS_TTL_MS + 10;
    const r1 = await session(await call("POST", "/v1/auth/refresh", { refreshToken: s.refreshToken }));
    expect(r1.isNewAccount).toBe(false);
    expect(r1.account.id).toBe(s.account.id);
    expect(r1.refreshToken).not.toBe(s.refreshToken);
    expect(r1.accessExpiresAt).toBe(NOW + ACCESS_TTL_MS + 10 + ACCESS_TTL_MS);
    expect((await call("GET", "/v1/account", undefined, r1.accessToken)).status).toBe(200);

    // Reuse of the rotated token: rejected, and the whole session (r1 too) is gone.
    const reuse = await call("POST", "/v1/auth/refresh", { refreshToken: s.refreshToken });
    expect(reuse.status).toBe(401);
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: r1.refreshToken })).status).toBe(401);
  });

  it("rejects an unknown or expired refresh token", async () => {
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: "rt_unknownunknownunknown" })).status).toBe(401);
    const s = await session(await appleSignIn(freshSub("apple")));
    identityDeps.now = () => NOW + REFRESH_TTL_MS + 1;
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: s.refreshToken })).status).toBe(401);
  });

  it("logout revokes the refresh token; other devices stay signed in", async () => {
    const sub = freshSub("apple");
    const phone = await session(await appleSignIn(sub));
    const pad = await session(await appleSignIn(sub));
    const res = await call("POST", "/v1/auth/logout", { refreshToken: phone.refreshToken }, phone.accessToken);
    expect(res.status).toBe(204);
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: phone.refreshToken })).status).toBe(401);
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: pad.refreshToken })).status).toBe(200);
  });

  it("logout cannot revoke someone else's session", async () => {
    const a = await session(await appleSignIn(freshSub("apple")));
    const b = await session(await appleSignIn(freshSub("apple")));
    await call("POST", "/v1/auth/logout", { refreshToken: b.refreshToken }, a.accessToken);
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: b.refreshToken })).status).toBe(200);
  });

  it("rate-limits per account after verifying the token", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    const limit = vi.fn(async (_: RateLimitOptions) => ({ success: false }));
    const ctx = createExecutionContext();
    const res = await worker.fetch(
      new Request(`${BASE}/v1/account`, { headers: { authorization: `Bearer ${s.accessToken}` } }) as never,
      { ...env, ACCOUNT_LIMITER: { limit } },
      ctx,
    );
    await waitOnExecutionContext(ctx);
    expect(res.status).toBe(429);
    expect(limit).toHaveBeenCalledWith({ key: `acc:${s.account.id}` });
  });
});

describe("account", () => {
  it("changes the display name", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    const res = await call("PATCH", "/v1/account", { displayName: " Βασίλης  Π. " }, s.accessToken);
    expect(res.status).toBe(200);
    expect(Account.parse(await res.json()).displayName).toBe("Βασίλης Π.");
    const got = Account.parse(await (await call("GET", "/v1/account", undefined, s.accessToken)).json());
    expect(got.displayName).toBe("Βασίλης Π.");
  });

  it("rejects invalid names with the field path", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    for (const displayName of ["   ", "", "x".repeat(25), "bad\u0007name", "hid​den"]) {
      const res = await call("PATCH", "/v1/account", { displayName }, s.accessToken);
      expect(res.status, JSON.stringify(displayName)).toBe(400);
      expect((await errorOf(res)).path).toBe("displayName");
    }
  });

  it("normalizes names like the app", () => {
    expect(normalizeDisplayName("  a\t b \n")).toBe("a b");
    expect(normalizeDisplayName("می‌خواهم")).toBe("می‌خواهم"); // ZWNJ kept (Persian)
    expect(normalizeDisplayName("é")).toBe("é");
    expect(normalizeDisplayName("x".repeat(24))).toHaveLength(24);
    expect(normalizeDisplayName("x".repeat(25))).toBeNull();
    expect(normalizeDisplayName("‮evil")).toBeNull();
  });

  it("deletes the account and everything personal; the subject starts over", async () => {
    const sub = freshSub("apple");
    const s = await session(await appleSignIn(sub, { displayName: "Gone" }));
    const id = s.account.id;
    await env.DB.prepare(
      "INSERT INTO match_index (match_id, account_id, variant, target_wins, state, created_at, updated_at) " +
        "VALUES ('m_del', ?, 'plakoto', 2, 'yourTurn', ?, ?)",
    )
      .bind(id, NOW, NOW)
      .run();
    const seen: unknown[] = [];
    ACCOUNT_DELETION_HOOKS.push(async (_env, deletion) => void seen.push(deletion));
    try {
      expect((await call("DELETE", "/v1/account", undefined, s.accessToken)).status).toBe(204);
    } finally {
      ACCOUNT_DELETION_HOOKS.pop();
    }
    expect(seen).toEqual([{ accountID: id, matchIDs: ["m_del"] }]);

    const left = await env.DB.prepare(
      "SELECT (SELECT count(*) FROM accounts WHERE id = ?1) + (SELECT count(*) FROM account_identities WHERE account_id = ?1) + " +
        "(SELECT count(*) FROM sessions WHERE account_id = ?1) + (SELECT count(*) FROM match_index WHERE account_id = ?1) AS n",
    )
      .bind(id)
      .first<{ n: number }>();
    expect(left?.n).toBe(0);

    expect((await call("GET", "/v1/account", undefined, s.accessToken)).status).toBe(401);
    expect((await call("PATCH", "/v1/account", { displayName: "x" }, s.accessToken)).status).toBe(401);
    expect((await call("DELETE", "/v1/account", undefined, s.accessToken)).status).toBe(401);
    expect((await call("POST", "/v1/auth/refresh", { refreshToken: s.refreshToken })).status).toBe(401);

    const again = await session(await appleSignIn(sub));
    expect(again.isNewAccount).toBe(true);
    expect(again.account.id).not.toBe(id);
  });

  it("a failing deletion hook deletes nothing", async () => {
    const s = await session(await appleSignIn(freshSub("apple")));
    vi.spyOn(console, "error").mockImplementation(() => {});
    ACCOUNT_DELETION_HOOKS.push(async () => {
      throw new Error("room unreachable");
    });
    try {
      expect((await call("DELETE", "/v1/account", undefined, s.accessToken)).status).toBe(500);
    } finally {
      ACCOUNT_DELETION_HOOKS.pop();
    }
    expect((await call("GET", "/v1/account", undefined, s.accessToken)).status).toBe(200);
  });
});

describe("Apple token revocation", () => {
  async function p8(): Promise<{ pem: string; publicKey: CryptoKey }> {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
      "sign",
      "verify",
    ])) as CryptoKeyPair;
    const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
    const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n");
    return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
  }

  it("is skipped without the APPLE_* secrets", async () => {
    expect(await storeAppleRefreshToken(env, quiet, "s", "code")).toBe("skipped");
    expect(await revokeAppleTokens(env, quiet, ["t"])).toBe(0);
    expect(fakes.calls).toHaveLength(0);
  });

  it("exchanges the code at sign-in and revokes the token on deletion", async () => {
    const { pem, publicKey } = await p8();
    const secrets = { ...env, APPLE_TEAM_ID: "TEAM123456", APPLE_KEY_ID: "KEY1234567", APPLE_PRIVATE_KEY: pem };
    fakes.routes.set(APPLE_TOKEN_URL, () => Response.json({ refresh_token: "apple-refresh-1", access_token: "a" }));
    fakes.routes.set(APPLE_REVOKE_URL, () => new Response(null, { status: 200 }));

    const sub = freshSub("apple");
    const s = await session(await appleSignIn(sub));
    expect(await storeAppleRefreshToken(secrets, quiet, sub, "one-time-code")).toBe("stored");
    const exchange = new URLSearchParams(fakes.calls.find((c) => c.url === APPLE_TOKEN_URL)!.body);
    expect(exchange.get("code")).toBe("one-time-code");
    expect(exchange.get("client_id")).toBe("com.plakoto.TavliApp");
    expect(exchange.get("grant_type")).toBe("authorization_code");

    // The client secret is an ES256 JWT our .p8 public key verifies.
    const secret = decodeJwt(exchange.get("client_secret")!);
    expect(secret.header).toMatchObject({ alg: "ES256", kid: "KEY1234567" });
    expect(secret.claims).toMatchObject({ iss: "TEAM123456", sub: "com.plakoto.TavliApp", aud: "https://appleid.apple.com" });
    expect(
      await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, secret.signature, secret.signingInput),
    ).toBe(true);

    const ctx = createExecutionContext();
    const rc: RouteContext = {
      request: new Request(`${BASE}/v1/account`, { method: "DELETE" }),
      env: secrets,
      ctx,
      params: {},
      url: new URL(`${BASE}/v1/account`),
      requestId: "t",
      auth: { accountID: s.account.id, sessionID: "x" },
    };
    expect((await deleteAccount(rc)).status).toBe(204);
    await waitOnExecutionContext(ctx);
    const revoke = new URLSearchParams(fakes.calls.find((c) => c.url === APPLE_REVOKE_URL)!.body);
    expect(revoke.get("token")).toBe("apple-refresh-1");
    expect(revoke.get("token_type_hint")).toBe("refresh_token");
  });

  it("the sign-in request's authorizationCode is accepted (and ignored without secrets)", async () => {
    const s = await session(await appleSignIn(freshSub("apple"), { authorizationCode: "abc" }));
    expect(s.isNewAccount).toBe(true);
  });
});

describe("development sign-in", () => {
  it("works under wrangler dev and is 404 elsewhere", async () => {
    const s = await session(await call("POST", "/v1/auth/dev", { subject: freshSub("dev").replace(/\./g, "-"), displayName: "Dev" }));
    expect(s.account.displayName).toBe("Dev");

    const ctx = createExecutionContext();
    const err = await signInForDevelopment({
      request: new Request(`${BASE}/v1/auth/dev`, { method: "POST", body: "{}" }),
      env: { ...env, ENVIRONMENT: "production" },
      ctx,
      params: {},
      url: new URL(`${BASE}/v1/auth/dev`),
      requestId: "t",
    }).catch((e) => e);
    expect(err).toMatchObject({ code: "not_found" });
  });
});
