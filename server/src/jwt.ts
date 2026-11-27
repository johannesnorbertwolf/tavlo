// Minimal JWT tools on WebCrypto (no dependencies): base64url, decoding, RS256
// verification against a JWK (Apple / Google identity tokens) and ES256 signing (the
// Sign in with Apple client secret). Claims are checked by the caller (identity.ts).

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function base64UrlEncode(bytes: Uint8Array | ArrayBuffer): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = "";
  for (const b of view) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function base64UrlDecode(text: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) throw new Error("not base64url");
  const b64 = text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export const utf8 = (s: string): Uint8Array<ArrayBuffer> => encoder.encode(s) as Uint8Array<ArrayBuffer>;

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", utf8(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export interface JwtHeader {
  alg?: string;
  kid?: string;
  typ?: string;
}

export type JwtClaims = Record<string, unknown>;

export interface DecodedJwt {
  header: JwtHeader;
  claims: JwtClaims;
  /** `header.payload` bytes, what the signature covers. */
  signingInput: Uint8Array<ArrayBuffer>;
  signature: Uint8Array<ArrayBuffer>;
}

/** Splits and parses a compact JWS. Throws on anything malformed; verifies nothing. */
export function decodeJwt(token: string): DecodedJwt {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("not a compact JWT");
  const [h, p, s] = parts as [string, string, string];
  const header = JSON.parse(decoder.decode(base64UrlDecode(h))) as unknown;
  const claims = JSON.parse(decoder.decode(base64UrlDecode(p))) as unknown;
  if (typeof header !== "object" || header === null || Array.isArray(header)) throw new Error("bad header");
  if (typeof claims !== "object" || claims === null || Array.isArray(claims)) throw new Error("bad claims");
  return { header: header as JwtHeader, claims: claims as JwtClaims, signingInput: utf8(`${h}.${p}`), signature: base64UrlDecode(s) };
}

/** RS256 signature check of a decoded token against one RSA public JWK. */
export async function verifyRs256(jwt: DecodedJwt, jwk: JsonWebKey): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    "jwk",
    { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, jwt.signature, jwt.signingInput);
}

/** Imports a PKCS#8 PEM (an Apple `.p8` key) as an ECDSA P-256 signing key. */
export async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** Signs `claims` as a compact ES256 JWT (WebCrypto's P1363 r||s is JWS's format). */
export async function signEs256(header: JwtHeader, claims: JwtClaims, key: CryptoKey): Promise<string> {
  const input = `${base64UrlEncode(utf8(JSON.stringify({ ...header, alg: "ES256" })))}.${base64UrlEncode(
    utf8(JSON.stringify(claims)),
  )}`;
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(input));
  return `${input}.${base64UrlEncode(sig)}`;
}
