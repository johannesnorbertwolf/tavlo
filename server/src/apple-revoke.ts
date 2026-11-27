// Sign in with Apple token revocation on account deletion (App Review 5.1.1(v)).
// Needs a Sign in with Apple key (.p8): secrets APPLE_TEAM_ID, APPLE_KEY_ID,
// APPLE_PRIVATE_KEY. Without them every step here is skipped (logged), so sign-in and
// deletion work the same, only the Apple-side grant stays until the user removes it in
// Settings → Apple ID → Sign in with Apple.
//
// Flow: at sign-in the app sends Apple's one-time `authorizationCode`; when configured,
// the server exchanges it (`/auth/token`) in the background and keeps Apple's refresh
// token in `account_identities.provider_refresh_token`. On DELETE /v1/account that token
// is revoked (`/auth/revoke`) after the rows are gone.

import { identityDeps, APPLE_BUNDLE_ID } from "./identity";
import { importP8, signEs256 } from "./jwt";
import type { Logger } from "./log";

export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";

export function appleRevocationConfigured(env: Env): boolean {
  return Boolean(env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY);
}

/** The ES256 client secret Apple's REST endpoints want (valid 5 minutes). */
export async function appleClientSecret(env: Env, now: number): Promise<string> {
  const key = await importP8(env.APPLE_PRIVATE_KEY!);
  const iat = Math.floor(now / 1000);
  return signEs256(
    { kid: env.APPLE_KEY_ID!, typ: "JWT" },
    { iss: env.APPLE_TEAM_ID!, iat, exp: iat + 300, aud: "https://appleid.apple.com", sub: APPLE_BUNDLE_ID },
    key,
  );
}

async function postForm(url: string, form: Record<string, string>): Promise<Response> {
  return identityDeps.fetch(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });
}

/** Exchanges a sign-in authorization code and stores Apple's refresh token. Never throws. */
export async function storeAppleRefreshToken(
  env: Env,
  log: Logger,
  subject: string,
  authorizationCode: string,
): Promise<"stored" | "skipped" | "failed"> {
  if (!appleRevocationConfigured(env)) {
    log.info("apple.exchange.skipped", { reason: "APPLE_* secrets not set" });
    return "skipped";
  }
  try {
    const res = await postForm(APPLE_TOKEN_URL, {
      client_id: APPLE_BUNDLE_ID,
      client_secret: await appleClientSecret(env, identityDeps.now()),
      code: authorizationCode,
      grant_type: "authorization_code",
    });
    if (!res.ok) {
      log.warn("apple.exchange.failed", { status: res.status });
      return "failed";
    }
    const body = (await res.json()) as { refresh_token?: string };
    if (!body.refresh_token) {
      log.warn("apple.exchange.failed", { reason: "no refresh_token" });
      return "failed";
    }
    await env.DB.prepare(
      "UPDATE account_identities SET provider_refresh_token = ? WHERE provider = 'apple' AND subject = ?",
    )
      .bind(body.refresh_token, subject)
      .run();
    return "stored";
  } catch (error) {
    log.warn("apple.exchange.failed", { error });
    return "failed";
  }
}

/** Revokes Apple refresh tokens of a deleted account. Never throws. */
export async function revokeAppleTokens(env: Env, log: Logger, tokens: string[]): Promise<number> {
  if (tokens.length === 0) return 0;
  if (!appleRevocationConfigured(env)) {
    log.info("apple.revoke.skipped", { reason: "APPLE_* secrets not set", tokens: tokens.length });
    return 0;
  }
  let revoked = 0;
  for (const token of tokens) {
    try {
      const res = await postForm(APPLE_REVOKE_URL, {
        client_id: APPLE_BUNDLE_ID,
        client_secret: await appleClientSecret(env, identityDeps.now()),
        token,
        token_type_hint: "refresh_token",
      });
      if (res.ok) revoked++;
      else log.warn("apple.revoke.failed", { status: res.status });
    } catch (error) {
      log.warn("apple.revoke.failed", { error });
    }
  }
  log.info("apple.revoke.done", { revoked, of: tokens.length });
  return revoked;
}
