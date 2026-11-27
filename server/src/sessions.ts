// Our own sessions (REFERENCE.md "Accounts → Sessions"):
//   access token  `at_<base64url(JSON {v, sub, sid, exp})>.<base64url(HMAC-SHA256)>`,
//                 stateless, 1 h, signed with the SESSION_KEY secret.
//   refresh token `rt_<32 random bytes, base64url>`, 60 days, rotated on every use; D1
//                 table `sessions` keeps only SHA-256 hashes (current + previous). Presenting
//                 an already-rotated token revokes the whole session (token theft signal).

import type { Account } from "./api";
import { HttpError } from "./http";
import { base64UrlDecode, base64UrlEncode, sha256Hex, utf8 } from "./jwt";

export const ACCESS_TTL_MS = 60 * 60 * 1000;
export const REFRESH_TTL_MS = 60 * 24 * 60 * 60 * 1000;
/** Used only when ENVIRONMENT is "development" and no SESSION_KEY is set (wrangler dev). */
const DEV_SESSION_KEY = "tavtav-development-session-key-not-a-secret";

export interface AccessClaims {
  v: 1;
  /** Account id. */
  sub: string;
  /** Session id (row in `sessions`). */
  sid: string;
  /** Expiry, Unix ms. */
  exp: number;
}

export interface AuthContext {
  accountID: string;
  sessionID: string;
  /** Access-token expiry (ms): the match socket closes with 4401 after it (#286). */
  expiresAt?: number;
}

const keyCache = new Map<string, Promise<CryptoKey>>();

function sessionKey(env: Env): Promise<CryptoKey> {
  const secret = env.SESSION_KEY || (env.ENVIRONMENT === "development" ? DEV_SESSION_KEY : undefined);
  if (!secret) throw new HttpError("unavailable", "Sessions are not configured on this server (SESSION_KEY).");
  let key = keyCache.get(secret);
  if (!key) {
    key = crypto.subtle.importKey("raw", utf8(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
    keyCache.set(secret, key);
  }
  return key;
}

export function randomToken(prefix: string, bytes = 32): string {
  return prefix + base64UrlEncode(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function signAccessToken(env: Env, claims: AccessClaims): Promise<string> {
  const payload = base64UrlEncode(utf8(JSON.stringify(claims)));
  const sig = await crypto.subtle.sign("HMAC", await sessionKey(env), utf8(payload));
  return `at_${payload}.${base64UrlEncode(sig)}`;
}

/** Verifies a bearer access token: `unauthorized` if forged/malformed, `token_expired` if old. */
export async function verifyAccessToken(env: Env, token: string, now: number): Promise<AuthContext> {
  const bad = () => new HttpError("unauthorized", "Invalid access token.");
  const m = /^at_([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(token);
  if (!m) throw bad();
  let claims: AccessClaims;
  try {
    const ok = await crypto.subtle.verify("HMAC", await sessionKey(env), base64UrlDecode(m[2]!), utf8(m[1]!));
    if (!ok) throw bad();
    claims = JSON.parse(new TextDecoder().decode(base64UrlDecode(m[1]!))) as AccessClaims;
  } catch (e) {
    if (e instanceof HttpError && e.code === "unavailable") throw e;
    throw bad();
  }
  if (claims.v !== 1 || typeof claims.sub !== "string" || typeof claims.sid !== "string") throw bad();
  if (typeof claims.exp !== "number" || claims.exp <= now) {
    throw new HttpError("token_expired", "Access token expired; refresh it.");
  }
  return { accountID: claims.sub, sessionID: claims.sid, expiresAt: claims.exp };
}

/** Reads `Authorization: Bearer …` and verifies it. */
export async function authenticate(env: Env, request: Request, now: number): Promise<AuthContext> {
  const header = request.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(\S+)$/i.exec(header);
  if (!m) throw new HttpError("unauthorized", "Sign in first (no bearer token).");
  return verifyAccessToken(env, m[1]!, now);
}

export interface IssuedSession {
  accessToken: string;
  accessExpiresAt: number;
  refreshToken: string;
  refreshExpiresAt: number;
}

async function issue(env: Env, accountID: string, sessionID: string, now: number) {
  const refreshToken = randomToken("rt_");
  const accessExpiresAt = now + ACCESS_TTL_MS;
  return {
    session: {
      accessToken: await signAccessToken(env, { v: 1, sub: accountID, sid: sessionID, exp: accessExpiresAt }),
      accessExpiresAt,
      refreshToken,
      refreshExpiresAt: now + REFRESH_TTL_MS,
    } satisfies IssuedSession,
    refreshHash: await sha256Hex(refreshToken),
  };
}

/** A new session (sign-in) for `accountID`. */
export async function createSession(env: Env, accountID: string, now: number): Promise<IssuedSession> {
  const sessionID = randomToken("ses_", 16);
  const { session, refreshHash } = await issue(env, accountID, sessionID, now);
  await env.DB.prepare(
    "INSERT INTO sessions (id, account_id, refresh_hash, previous_hash, created_at, refreshed_at, expires_at) " +
      "VALUES (?, ?, ?, NULL, ?, ?, ?)",
  )
    .bind(sessionID, accountID, refreshHash, now, now, session.refreshExpiresAt)
    .run();
  return session;
}

interface SessionRow {
  id: string;
  account_id: string;
  refresh_hash: string;
  expires_at: number;
}

/** Rotates a refresh token. Unknown/expired → `unauthorized`; a reused old token revokes the session. */
export async function rotateSession(
  env: Env,
  refreshToken: string,
  now: number,
): Promise<{ accountID: string; session: IssuedSession }> {
  const hash = await sha256Hex(refreshToken);
  const row = await env.DB.prepare(
    "SELECT id, account_id, refresh_hash, expires_at FROM sessions WHERE refresh_hash = ?1 OR previous_hash = ?1",
  )
    .bind(hash)
    .first<SessionRow>();
  if (!row) throw new HttpError("unauthorized", "Unknown refresh token; sign in again.");
  if (row.refresh_hash !== hash) {
    await env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(row.id).run();
    throw new HttpError("unauthorized", "Refresh token was already used; session revoked.");
  }
  if (row.expires_at <= now) {
    await env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(row.id).run();
    throw new HttpError("unauthorized", "Session expired; sign in again.");
  }
  const { session, refreshHash } = await issue(env, row.account_id, row.id, now);
  // Conditional on the hash we read, so two concurrent refreshes cannot both win.
  const res = await env.DB.prepare(
    "UPDATE sessions SET refresh_hash = ?, previous_hash = ?, refreshed_at = ?, expires_at = ? " +
      "WHERE id = ? AND refresh_hash = ?",
  )
    .bind(refreshHash, hash, now, session.refreshExpiresAt, row.id, hash)
    .run();
  if (res.meta.changes !== 1) throw new HttpError("unauthorized", "Refresh token was already used.");
  return { accountID: row.account_id, session };
}

/** Logout: drops the session the refresh token belongs to (only if it is the caller's). */
export async function revokeSession(env: Env, auth: AuthContext, refreshToken: string): Promise<void> {
  const hash = await sha256Hex(refreshToken);
  await env.DB.prepare(
    "DELETE FROM sessions WHERE account_id = ?1 AND (id = ?2 OR refresh_hash = ?3 OR previous_hash = ?3)",
  )
    .bind(auth.accountID, auth.sessionID, hash)
    .run();
}

export type SessionWithAccount = IssuedSession & { account: Account; isNewAccount: boolean };
