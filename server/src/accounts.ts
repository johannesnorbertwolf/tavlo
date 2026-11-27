// Accounts (#285): sign in with Apple / Google, refresh, logout, account get/update/delete.
// REFERENCE.md "Accounts" documents the flow; api.ts the bodies.

import {
  type Account,
  AppleSignInRequest,
  type AuthSession,
  DevSignInRequest,
  GoogleSignInRequest,
  RefreshRequest,
  UpdateAccountRequest,
} from "./api";
import { runAccountDeletionHooks } from "./account-hooks";
import { revokeAppleTokens, storeAppleRefreshToken } from "./apple-revoke";
import { HttpError, json, readJson } from "./http";
import { appleConfig, googleConfig, identityDeps, type Provider, verifyIdentityToken } from "./identity";
import { Logger } from "./log";
import type { RouteContext } from "./routes";
import { createSession, randomToken, revokeSession, rotateSession } from "./sessions";
import { SERVICE_NAME } from "./version";

export const DISPLAY_NAME_MAX = 24;

/**
 * The display-name rule (mirrored by `DisplayNameRule` in the app): NFC, runs of
 * whitespace → one space, trimmed, 1…24 UTF-16 units, no control or invisible format
 * characters except ZWNJ/ZWJ (Persian needs ZWNJ). Returns null when invalid.
 */
export function normalizeDisplayName(raw: string): string | null {
  const name = raw.normalize("NFC").replace(/\s+/gu, " ").trim();
  if (name.length < 1 || name.length > DISPLAY_NAME_MAX) return null;
  if (/[\p{Cc}\p{Co}\p{Cn}]/u.test(name)) return null;
  if (/[\p{Cf}]/u.test(name.replace(/[‌‍]/g, ""))) return null;
  return name;
}

function validName(raw: string): string {
  const name = normalizeDisplayName(raw);
  if (!name) throw new HttpError("bad_request", "Display name must be 1–24 visible characters.", { path: "displayName" });
  return name;
}

/** Placeholder until the player picks a name (`isNewAccount` makes the app ask). */
function placeholderName(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0]! % 10000;
  return `Player ${String(n).padStart(4, "0")}`;
}

function logger(rc: RouteContext): Logger {
  return new Logger({ service: SERVICE_NAME, env: rc.env.ENVIRONMENT, requestId: rc.requestId });
}

function requireAuth(rc: RouteContext) {
  if (!rc.auth) throw new HttpError("unauthorized", "Sign in first.");
  return rc.auth;
}

interface AccountRow {
  id: string;
  display_name: string;
  created_at: number;
}

export async function loadAccount(env: Env, accountID: string): Promise<Account | null> {
  const row = await env.DB.prepare("SELECT id, display_name, created_at FROM accounts WHERE id = ?")
    .bind(accountID)
    .first<AccountRow>();
  if (!row) return null;
  const { results } = await env.DB.prepare(
    "SELECT provider FROM account_identities WHERE account_id = ? ORDER BY provider",
  )
    .bind(accountID)
    .all<{ provider: Provider }>();
  return {
    id: row.id,
    displayName: row.display_name,
    providers: [...new Set(results.map((r) => r.provider))],
    createdAt: row.created_at,
  };
}

/** Finds the account for `(provider, subject)` or creates it. */
async function findOrCreate(
  env: Env,
  provider: Provider,
  subject: string,
  displayName: string | undefined,
  now: number,
): Promise<{ accountID: string; isNew: boolean }> {
  const existing = await env.DB.prepare(
    "SELECT account_id FROM account_identities WHERE provider = ? AND subject = ?",
  )
    .bind(provider, subject)
    .first<{ account_id: string }>();
  if (existing) {
    await env.DB.prepare("UPDATE accounts SET last_seen_at = ? WHERE id = ?").bind(now, existing.account_id).run();
    return { accountID: existing.account_id, isNew: false };
  }
  const accountID = randomToken("acc_", 12);
  const name = (displayName && normalizeDisplayName(displayName)) || placeholderName();
  try {
    await env.DB.batch([
      env.DB.prepare("INSERT INTO accounts (id, display_name, created_at, last_seen_at) VALUES (?, ?, ?, ?)").bind(
        accountID,
        name,
        now,
        now,
      ),
      env.DB.prepare(
        "INSERT INTO account_identities (provider, subject, account_id, created_at) VALUES (?, ?, ?, ?)",
      ).bind(provider, subject, accountID, now),
    ]);
  } catch (e) {
    // A concurrent first sign-in of the same subject won the race: use its account.
    const winner = await env.DB.prepare(
      "SELECT account_id FROM account_identities WHERE provider = ? AND subject = ?",
    )
      .bind(provider, subject)
      .first<{ account_id: string }>();
    if (!winner) throw e;
    return { accountID: winner.account_id, isNew: false };
  }
  return { accountID, isNew: true };
}

async function signIn(
  rc: RouteContext,
  provider: Provider,
  subject: string,
  displayName: string | undefined,
): Promise<Response> {
  const now = identityDeps.now();
  const { accountID, isNew } = await findOrCreate(rc.env, provider, subject, displayName, now);
  const tokens = await createSession(rc.env, accountID, now);
  const account = await loadAccount(rc.env, accountID);
  if (!account) throw new HttpError("internal", "Account vanished during sign-in.");
  logger(rc).info("auth.signed_in", { provider, newAccount: isNew });
  const body: AuthSession = { ...tokens, account, isNewAccount: isNew };
  return json(body);
}

export async function signInWithApple(rc: RouteContext): Promise<Response> {
  const req = await readJson(rc.request, AppleSignInRequest);
  const id = await verifyIdentityToken(req.identityToken, req.nonce, appleConfig());
  const response = await signIn(rc, "apple", id.subject, req.displayName);
  if (req.authorizationCode) {
    rc.ctx.waitUntil(storeAppleRefreshToken(rc.env, logger(rc), id.subject, req.authorizationCode));
  }
  return response;
}

export async function signInWithGoogle(rc: RouteContext): Promise<Response> {
  const req = await readJson(rc.request, GoogleSignInRequest);
  const config = googleConfig(rc.env);
  const id = await verifyIdentityToken(req.idToken, req.nonce, config);
  return signIn(rc, "google", id.subject, undefined);
}

/** Development only: no token, subject `dev:<subject>` (see api.ts DevSignInRequest). */
export async function signInForDevelopment(rc: RouteContext): Promise<Response> {
  if (rc.env.ENVIRONMENT !== "development") throw new HttpError("not_found", "No route for /v1/auth/dev.");
  const req = await readJson(rc.request, DevSignInRequest);
  return signIn(rc, "apple", `dev:${req.subject}`, req.displayName);
}

export async function refresh(rc: RouteContext): Promise<Response> {
  const req = await readJson(rc.request, RefreshRequest);
  const now = identityDeps.now();
  const { accountID, session } = await rotateSession(rc.env, req.refreshToken, now);
  const account = await loadAccount(rc.env, accountID);
  if (!account) throw new HttpError("unauthorized", "Account no longer exists.");
  await rc.env.DB.prepare("UPDATE accounts SET last_seen_at = ? WHERE id = ?").bind(now, accountID).run();
  const body: AuthSession = { ...session, account, isNewAccount: false };
  return json(body);
}

export async function logout(rc: RouteContext): Promise<Response> {
  const auth = requireAuth(rc);
  const req = await readJson(rc.request, RefreshRequest);
  await revokeSession(rc.env, auth, req.refreshToken);
  return new Response(null, { status: 204 });
}

export async function getAccount(rc: RouteContext): Promise<Response> {
  const auth = requireAuth(rc);
  const account = await loadAccount(rc.env, auth.accountID);
  if (!account) throw new HttpError("unauthorized", "Account no longer exists.");
  return json(account);
}

export async function updateAccount(rc: RouteContext): Promise<Response> {
  const auth = requireAuth(rc);
  const req = await readJson(rc.request, UpdateAccountRequest);
  const name = validName(req.displayName);
  const res = await rc.env.DB.prepare("UPDATE accounts SET display_name = ? WHERE id = ?")
    .bind(name, auth.accountID)
    .run();
  if (res.meta.changes !== 1) throw new HttpError("unauthorized", "Account no longer exists.");
  return json(await loadAccount(rc.env, auth.accountID));
}

/**
 * Deletes the account and its personal data: the `accounts` row (display name) and, by
 * cascade, its identities (provider subjects + Apple refresh token), sessions and lobby
 * rows. Match hooks (#286) run first; Apple tokens are revoked afterwards in the background.
 */
export async function deleteAccount(rc: RouteContext): Promise<Response> {
  const auth = requireAuth(rc);
  const log = logger(rc);
  const exists = await rc.env.DB.prepare("SELECT 1 AS ok FROM accounts WHERE id = ?").bind(auth.accountID).first();
  if (!exists) throw new HttpError("unauthorized", "Account no longer exists.");
  const { results: apple } = await rc.env.DB.prepare(
    "SELECT provider_refresh_token AS token FROM account_identities " +
      "WHERE account_id = ? AND provider = 'apple' AND provider_refresh_token IS NOT NULL",
  )
    .bind(auth.accountID)
    .all<{ token: string }>();
  await runAccountDeletionHooks(rc.env, auth.accountID, log);
  await rc.env.DB.prepare("DELETE FROM accounts WHERE id = ?").bind(auth.accountID).run();
  log.info("account.deleted", { appleTokens: apple.length });
  rc.ctx.waitUntil(revokeAppleTokens(rc.env, log, apple.map((r) => r.token)));
  return new Response(null, { status: 204 });
}

/** Hourly cron: drop sessions past their refresh expiry. */
export async function pruneSessions(env: Env, now: number): Promise<number> {
  const res = await env.DB.prepare("DELETE FROM sessions WHERE expires_at <= ?").bind(now).run();
  return res.meta.changes;
}
