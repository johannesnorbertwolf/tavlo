// Sign in with Apple / Google: verify the provider's identity token (RS256 JWT) against
// the provider's JWKS and check iss, aud, exp, iat and the nonce (REFERENCE.md
// "Accounts"). JWKS are cached per isolate (Cache-Control max-age, 1 h default) and
// refetched at most once a minute when a token names an unknown key id (key rotation).

import { HttpError } from "./http";
import { decodeJwt, sha256Hex, verifyRs256, type JwtClaims } from "./jwt";

export type Provider = "apple" | "google";

export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
export const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
export const APPLE_ISSUERS = ["https://appleid.apple.com"];
export const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
/** Sign in with Apple's audience: the app's bundle id (the native flow's client id). */
export const APPLE_BUNDLE_ID = "com.plakoto.TavliApp";
/** Allowed clock skew for exp / iat. */
export const CLOCK_SKEW_MS = 60_000;

/** Test seams: `fetch` for the JWKS + Apple endpoints, `now` for expiry checks. */
export const identityDeps: { fetch: typeof fetch; now: () => number } = {
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
};

interface CachedJwks {
  keys: Map<string, JsonWebKey>;
  expiresAt: number;
  fetchedAt: number;
}

const DEFAULT_JWKS_TTL_MS = 60 * 60 * 1000;
const MIN_REFETCH_MS = 60 * 1000;
const jwksCache = new Map<string, CachedJwks>();

/** Forget cached JWKS (tests). */
export function resetJwksCache(): void {
  jwksCache.clear();
}

async function fetchJwks(url: string): Promise<CachedJwks> {
  const now = identityDeps.now();
  const res = await identityDeps.fetch(url, { headers: { accept: "application/json" } });
  if (!res.ok) throw new HttpError("unavailable", "Sign-in keys are unavailable, try again.", { retryAfter: 30 });
  const body = (await res.json()) as { keys?: (JsonWebKey & { kid?: string })[] };
  const keys = new Map<string, JsonWebKey>();
  for (const k of body.keys ?? []) if (k.kid && k.kty === "RSA") keys.set(k.kid, k);
  const maxAge = /max-age=(\d+)/.exec(res.headers.get("cache-control") ?? "")?.[1];
  const ttl = maxAge ? Math.min(Number(maxAge) * 1000, 24 * DEFAULT_JWKS_TTL_MS) : DEFAULT_JWKS_TTL_MS;
  const entry = { keys, expiresAt: now + ttl, fetchedAt: now };
  jwksCache.set(url, entry);
  return entry;
}

async function jwkFor(url: string, kid: string): Promise<JsonWebKey | undefined> {
  const now = identityDeps.now();
  let entry = jwksCache.get(url);
  if (!entry || entry.expiresAt <= now) entry = await fetchJwks(url);
  else if (!entry.keys.has(kid) && now - entry.fetchedAt >= MIN_REFETCH_MS) entry = await fetchJwks(url);
  return entry.keys.get(kid);
}

export interface VerifiedIdentity {
  provider: Provider;
  subject: string;
  claims: JwtClaims;
}

const reject = (why: string): never => {
  throw new HttpError("unauthorized", `Identity token rejected: ${why}.`);
};

export interface ProviderConfig {
  provider: Provider;
  jwksUrl: string;
  issuers: string[];
  audiences: string[];
}

export function appleConfig(): ProviderConfig {
  return { provider: "apple", jwksUrl: APPLE_JWKS_URL, issuers: APPLE_ISSUERS, audiences: [APPLE_BUNDLE_ID] };
}

/** Google's audiences: the iOS OAuth client id(s), comma separated in `GOOGLE_CLIENT_IDS`. */
export function googleConfig(env: Env): ProviderConfig {
  const audiences = (env.GOOGLE_CLIENT_IDS ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (audiences.length === 0) {
    throw new HttpError("unavailable", "Sign in with Google is not configured on this server.");
  }
  return { provider: "google", jwksUrl: GOOGLE_JWKS_URL, issuers: GOOGLE_ISSUERS, audiences };
}

/**
 * Verifies `token` for `config`. `rawNonce` is the app's random nonce; both providers'
 * tokens carry its SHA-256 (lowercase hex) in the `nonce` claim, so the raw value only
 * ever travels to us.
 */
export async function verifyIdentityToken(
  token: string,
  rawNonce: string,
  config: ProviderConfig,
): Promise<VerifiedIdentity> {
  let jwt;
  try {
    jwt = decodeJwt(token);
  } catch {
    return reject("malformed");
  }
  if (jwt.header.alg !== "RS256") reject("unexpected algorithm");
  if (!jwt.header.kid) reject("no key id");
  const jwk = await jwkFor(config.jwksUrl, jwt.header.kid!);
  if (!jwk) reject("unknown key");
  if (!(await verifyRs256(jwt, jwk!))) reject("bad signature");

  const c = jwt.claims;
  const now = identityDeps.now();
  if (typeof c.iss !== "string" || !config.issuers.includes(c.iss)) reject("wrong issuer");
  const aud = Array.isArray(c.aud) ? c.aud : [c.aud];
  if (!aud.some((a) => typeof a === "string" && config.audiences.includes(a))) reject("wrong audience");
  if (typeof c.exp !== "number" || c.exp * 1000 + CLOCK_SKEW_MS <= now) reject("expired");
  if (typeof c.iat === "number" && c.iat * 1000 - CLOCK_SKEW_MS > now) reject("issued in the future");
  if (typeof c.sub !== "string" || c.sub.length === 0 || c.sub.length > 255) reject("no subject");
  if (typeof c.nonce !== "string" || c.nonce !== (await sha256Hex(rawNonce))) reject("nonce mismatch");
  return { provider: config.provider, subject: c.sub as string, claims: c };
}
