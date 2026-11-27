// Fixture keys + token minting for the auth tests: locally generated RSA keys stand in
// for Apple's and Google's JWKS (served by a fake fetch), so no test calls a provider.
import { vi } from "vitest";
import { APPLE_BUNDLE_ID, APPLE_JWKS_URL, GOOGLE_JWKS_URL, identityDeps, resetJwksCache } from "../src/identity";
import { base64UrlEncode, sha256Hex, utf8 } from "../src/jwt";

export const GOOGLE_CLIENT_ID = "test-ios-client.apps.googleusercontent.com";
export const NOW = Date.UTC(2026, 10, 27, 12, 0, 0);

export interface TestKey {
  kid: string;
  privateKey: CryptoKey;
  jwk: JsonWebKey & { kid: string };
}

export async function rsaKey(kid: string): Promise<TestKey> {
  const pair = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey;
  return { kid, privateKey: pair.privateKey, jwk: { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", use: "sig", kid } };
}

export async function mintJwt(
  key: TestKey,
  claims: Record<string, unknown>,
  header: Record<string, unknown> = {},
): Promise<string> {
  const h = base64UrlEncode(utf8(JSON.stringify({ alg: "RS256", kid: key.kid, ...header })));
  const p = base64UrlEncode(utf8(JSON.stringify(claims)));
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key.privateKey, utf8(`${h}.${p}`));
  return `${h}.${p}.${base64UrlEncode(sig)}`;
}

export const RAW_NONCE = "nonce-0123456789abcdef";

export async function appleClaims(sub: string, extra: Record<string, unknown> = {}) {
  return {
    iss: "https://appleid.apple.com",
    aud: APPLE_BUNDLE_ID,
    exp: Math.floor(NOW / 1000) + 600,
    iat: Math.floor(NOW / 1000) - 5,
    sub,
    nonce: await sha256Hex(RAW_NONCE),
    nonce_supported: true,
    ...extra,
  };
}

export async function googleClaims(sub: string, extra: Record<string, unknown> = {}) {
  return {
    iss: "https://accounts.google.com",
    aud: GOOGLE_CLIENT_ID,
    azp: GOOGLE_CLIENT_ID,
    exp: Math.floor(NOW / 1000) + 3600,
    iat: Math.floor(NOW / 1000) - 5,
    sub,
    nonce: await sha256Hex(RAW_NONCE),
    ...extra,
  };
}

export interface FakeNetwork {
  fetch: ReturnType<typeof vi.fn>;
  calls: { url: string; body?: string }[];
  apple: TestKey[];
  google: TestKey[];
  /** Answers for other URLs (Apple token/revoke). */
  routes: Map<string, (body: string) => Response>;
}

/** Installs a fake network + clock into identityDeps; call `restore()` after each test. */
export async function installFakes(): Promise<FakeNetwork & { restore: () => void }> {
  const net: FakeNetwork = {
    fetch: vi.fn(),
    calls: [],
    apple: [await rsaKey("apple-1")],
    google: [await rsaKey("google-1")],
    routes: new Map(),
  };
  net.fetch.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    const body = typeof init?.body === "string" ? init.body : undefined;
    net.calls.push({ url, body });
    if (url === APPLE_JWKS_URL) return Response.json({ keys: net.apple.map((k) => k.jwk) });
    if (url === GOOGLE_JWKS_URL) {
      return Response.json({ keys: net.google.map((k) => k.jwk) }, { headers: { "cache-control": "public, max-age=19000" } });
    }
    const route = net.routes.get(url);
    if (route) return route(body ?? "");
    throw new Error(`unexpected fetch ${url}`);
  });
  const saved = { ...identityDeps };
  identityDeps.fetch = net.fetch as unknown as typeof fetch;
  identityDeps.now = () => NOW;
  resetJwksCache();
  return {
    ...net,
    restore: () => {
      Object.assign(identityDeps, saved);
      resetJwksCache();
    },
  };
}
