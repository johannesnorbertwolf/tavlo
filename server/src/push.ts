// Push notifications (#287, REFERENCE.md "Push"): device-token registration and the APNs
// sender. Token-based provider auth: an ES256 JWT (`kid` = APNS_KEY_ID, `iss` =
// APNS_TEAM_ID, `iat`) signed with WebCrypto from the APNs auth key (.p8), cached per
// isolate for 50 minutes (APNs wants it refreshed between 20 and 60 minutes). One HTTPS
// POST per device token to api.push.apple.com, or api.sandbox.push.apple.com for tokens
// registered as `sandbox` (debug builds). The text is localized on the device (`loc-key`
// + `loc-args`, strings `PUSH_*` in the app's Localizable strings).
//
// Behind config: without the APNS_KEY_ID / APNS_PRIVATE_KEY secrets (and the APNS_TEAM_ID
// var) every push is skipped and logged (`push.skipped`); everything else works the same.
// Sending never fails the request that caused it (handlers hand it to `ctx.waitUntil`).

import { CHALLENGE_CATEGORY, PushTokenRequest, type MatchSnapshot, type PushKind, type PushPayload } from "./api";
import type { AccountDeletionHook } from "./account-hooks";
import { HttpError, readJson } from "./http";
import { APPLE_BUNDLE_ID } from "./identity";
import { importP8, signEs256 } from "./jwt";
import { Logger } from "./log";
import type { RouteContext } from "./routes";
import { SERVICE_NAME } from "./version";

export const APNS_HOSTS = {
  production: "https://api.push.apple.com",
  sandbox: "https://api.sandbox.push.apple.com",
} as const;
/** The app's bundle id: every push names it as `apns-topic`. */
export const APNS_TOPIC = APPLE_BUNDLE_ID;
/** Reuse a provider token this long (APNs: refresh after 20, before 60 minutes). */
export const PROVIDER_TOKEN_TTL_MS = 50 * 60 * 1000;
/** Keep this many newest device tokens per account. */
export const MAX_TOKENS_PER_ACCOUNT = 10;
/** APNs keeps an undelivered push this long (device offline). */
export const PUSH_EXPIRY_S = 24 * 60 * 60;

/** One push to one player (all of the player's devices). */
export interface PushMessage {
  /** Recipient account id. */
  to: string;
  kind: PushKind;
  matchID: string;
  /** The other player's display name (`loc-args[0]`). */
  name: string;
  /** matchEnded: the recipient's outcome. */
  outcome?: "won" | "lost" | "tied";
  /** challengeReceived (#301): what the challenge is for (the notification's body). */
  variant?: string;
  targetWins?: number;
}

/** #301: the body of a challenge push, e.g. `PUSH_GAME_FEVGA_2` = "Fevga · Best of 3". */
export function gameLocKey(variant: string, targetWins: number): string {
  return `PUSH_GAME_${variant.toUpperCase()}_${targetWins >= 2 ? 2 : 1}`;
}

/** The `loc-key` per push (the app's Localizable strings render it with the name). */
export function locKey(msg: PushMessage): string {
  switch (msg.kind) {
    case "yourTurn":
      return "PUSH_YOUR_TURN";
    case "inviteReceived":
      return "PUSH_INVITE_RECEIVED";
    case "inviteAccepted":
      return "PUSH_INVITE_ACCEPTED";
    case "opponentLeft":
      return "PUSH_OPPONENT_LEFT";
    case "challengeReceived":
      return gameLocKey(msg.variant ?? "plakoto", msg.targetWins ?? 1);
    case "challengeAccepted":
      return "PUSH_CHALLENGE_ACCEPTED";
    case "challengeDeclined":
      return "PUSH_CHALLENGE_DECLINED";
    case "matchEnded":
      return msg.outcome === "won" ? "PUSH_MATCH_WON" : msg.outcome === "lost" ? "PUSH_MATCH_LOST" : "PUSH_MATCH_ENDED";
  }
}

export function apnsPayload(msg: PushMessage): PushPayload {
  const name = msg.name.slice(0, 64);
  if (msg.kind === "challengeReceived") {
    // "Alex wants to play" / "Fevga · Best of 3", with Accept / Decline buttons (#301).
    return {
      aps: {
        alert: {
          "title-loc-key": "PUSH_CHALLENGE_RECEIVED",
          "title-loc-args": [name],
          "loc-key": locKey(msg),
          "loc-args": [],
        },
        sound: "default",
        "thread-id": msg.matchID,
        category: CHALLENGE_CATEGORY,
      },
      matchID: msg.matchID,
      kind: msg.kind,
    };
  }
  return {
    aps: {
      alert: { "loc-key": locKey(msg), "loc-args": [name] },
      sound: "default",
      "thread-id": msg.matchID,
    },
    matchID: msg.matchID,
    kind: msg.kind,
  };
}

// ── Which pushes a match operation causes ─────────────────────────────────────

export type PushOp = "create" | "accept" | "decline" | "join" | "endTurn" | "endMatch" | "quit";

/**
 * The pushes after `callerID` did `op` and the match is now `snap` (pure; the handler
 * sends them). `create` / `accept` / `join` / `endTurn` / `endMatch` / `quit`: see
 * REFERENCE.md "Push". Nobody is told about their own action.
 */
export function pushesAfter(op: PushOp, callerID: string, snap: MatchSnapshot): PushMessage[] {
  const me = snap.participants.find((p) => p.playerID === callerID);
  const other = snap.participants.find((p) => p.playerID !== null && p.playerID !== callerID);
  if (!me || !other?.playerID) return [];
  const base = { matchID: snap.matchID, name: me.displayName ?? "?" };
  switch (op) {
    case "create":
      // #301: a direct challenge, with Accept / Decline buttons.
      return other.status === "invited"
        ? [{ ...base, to: other.playerID, kind: "challengeReceived", variant: snap.variant, targetWins: snap.targetWins }]
        : [];
    case "accept":
      return [{ ...base, to: other.playerID, kind: "challengeAccepted" }];
    case "decline":
      return [{ ...base, to: other.playerID, kind: "challengeDeclined" }];
    case "join":
      return [{ ...base, to: other.playerID, kind: "inviteAccepted" }];
    case "endTurn":
      return !snap.isEnded && snap.currentPlayerID === other.playerID && other.status === "active"
        ? [{ ...base, to: other.playerID, kind: "yourTurn" }]
        : [];
    case "endMatch": {
      const outcome = other.outcome;
      if (!snap.isEnded || other.outcome === "quit") return [];
      return [
        {
          ...base,
          to: other.playerID,
          kind: "matchEnded",
          ...(outcome === "won" || outcome === "lost" || outcome === "tied" ? { outcome } : {}),
        },
      ];
    }
    case "quit":
      // The opponent wins by the forfeit (an invited seat that never accepted is not told).
      return snap.isEnded && other.outcome === "won" ? [{ ...base, to: other.playerID, kind: "opponentLeft" }] : [];
  }
}

// ── APNs sender ─────────────────────────────────────────────────────────────────

export interface ApnsCredentials {
  keyId: string;
  teamId: string;
  privateKey: string;
}

/** Test seams: the network, the clock and where the APNs key comes from. */
export const pushDeps: {
  fetch: typeof fetch;
  now: () => number;
  credentials: (env: Env) => ApnsCredentials | null;
} = {
  fetch: (input, init) => fetch(input, init),
  now: () => Date.now(),
  credentials: (env) =>
    env.APNS_KEY_ID && env.APNS_PRIVATE_KEY && env.APNS_TEAM_ID
      ? { keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, privateKey: env.APNS_PRIVATE_KEY }
      : null,
};

let cachedToken: { keyId: string; teamId: string; token: string; issuedAt: number } | null = null;

/** Forget the cached provider token (tests; APNs refused it). */
export function resetProviderToken(): void {
  cachedToken = null;
}

/** The provider JWT: `{alg ES256, kid}` + `{iss: team, iat}`, reused for 50 minutes. */
export async function providerToken(creds: ApnsCredentials, now: number): Promise<string> {
  const c = cachedToken;
  if (c && c.keyId === creds.keyId && c.teamId === creds.teamId && now - c.issuedAt < PROVIDER_TOKEN_TTL_MS && now >= c.issuedAt) {
    return c.token;
  }
  const key = await importP8(creds.privateKey);
  const token = await signEs256({ kid: creds.keyId }, { iss: creds.teamId, iat: Math.floor(now / 1000) }, key);
  cachedToken = { keyId: creds.keyId, teamId: creds.teamId, token, issuedAt: now };
  return token;
}

/** The APNs request for one device (exported for tests). */
export function apnsRequest(
  token: string,
  environment: "sandbox" | "production",
  msg: PushMessage,
  jwt: string,
  now: number,
): { url: string; init: RequestInit } {
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`,
    "apns-topic": APNS_TOPIC,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": String(Math.floor(now / 1000) + PUSH_EXPIRY_S),
    "content-type": "application/json",
  };
  // Several "your turn" pushes of one match replace each other on the lock screen.
  if (msg.kind === "yourTurn") headers["apns-collapse-id"] = `turn-${msg.matchID}`;
  // A challenge sent again (or answered elsewhere) replaces its notification.
  if (msg.kind === "challengeReceived") headers["apns-collapse-id"] = `challenge-${msg.matchID}`;
  return {
    url: `${APNS_HOSTS[environment]}/3/device/${token}`,
    init: { method: "POST", headers, body: JSON.stringify(apnsPayload(msg)) },
  };
}

/** APNs reasons that mean "this token is dead": delete it. */
const DEAD_TOKEN_REASONS = new Set(["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken"]);

export interface PushReport {
  skipped?: string;
  sent: number;
  failed: number;
  removed: number;
}

interface TokenRow {
  token: string;
  account_id: string;
  environment: "sandbox" | "production";
}

/** Sends `messages` to every device of their recipients. Never throws. */
export async function sendPushes(env: Env, messages: PushMessage[], log: Logger): Promise<PushReport> {
  const report: PushReport = { sent: 0, failed: 0, removed: 0 };
  if (!messages.length) return report;
  try {
    const creds = pushDeps.credentials(env);
    if (!creds) {
      log.info("push.skipped", { reason: "APNs key not configured", kinds: messages.map((m) => m.kind) });
      return { ...report, skipped: "not_configured" };
    }
    const recipients = [...new Set(messages.map((m) => m.to))];
    const { results } = await env.DB.prepare(
      `SELECT token, account_id, environment FROM push_tokens WHERE account_id IN (${recipients.map(() => "?").join(", ")})`,
    )
      .bind(...recipients)
      .all<TokenRow>();
    if (!results.length) {
      log.debug("push.no_devices", { kinds: messages.map((m) => m.kind) });
      return { ...report, skipped: "no_devices" };
    }
    const now = pushDeps.now();
    const jwt = await providerToken(creds, now);
    const dead: string[] = [];
    await Promise.all(
      messages.flatMap((msg) =>
        results
          .filter((r) => r.account_id === msg.to)
          .map(async (row) => {
            const { url, init } = apnsRequest(row.token, row.environment, msg, jwt, now);
            try {
              const res = await pushDeps.fetch(url, { ...init, signal: AbortSignal.timeout(10_000) });
              if (res.status === 200) {
                report.sent++;
                return;
              }
              const reason = ((await res.json().catch(() => ({}))) as { reason?: string }).reason ?? "";
              report.failed++;
              if (res.status === 410 || DEAD_TOKEN_REASONS.has(reason)) dead.push(row.token);
              if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") resetProviderToken();
              log.warn("push.rejected", { kind: msg.kind, status: res.status, reason, environment: row.environment });
            } catch (error) {
              report.failed++;
              log.warn("push.error", { kind: msg.kind, error, environment: row.environment });
            }
          }),
      ),
    );
    if (dead.length) {
      await env.DB.batch(dead.map((t) => env.DB.prepare("DELETE FROM push_tokens WHERE token = ?").bind(t)));
      report.removed = dead.length;
    }
    log.info("push.sent", { kinds: messages.map((m) => m.kind), ...report });
  } catch (error) {
    log.error("push.failed", { error });
  }
  return report;
}

function requestLogger(rc: RouteContext): Logger {
  return new Logger({ service: SERVICE_NAME, env: rc.env.ENVIRONMENT, requestId: rc.requestId });
}

/** Sends in the background after the response (never delays or fails the request). */
export function notify(rc: RouteContext, messages: PushMessage[]): void {
  if (!messages.length) return;
  rc.ctx.waitUntil(sendPushes(rc.env, messages, requestLogger(rc)));
}

// ── Device tokens ───────────────────────────────────────────────────────────────

function caller(rc: RouteContext) {
  if (!rc.auth) throw new HttpError("unauthorized", "Sign in first.");
  return rc.auth;
}

/** PUT /v1/push-tokens — register (or move to this account / refresh) a device token. */
export async function registerPushToken(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const req = await readJson(rc.request, PushTokenRequest);
  const exists = await rc.env.DB.prepare("SELECT 1 AS ok FROM accounts WHERE id = ?").bind(auth.accountID).first();
  if (!exists) throw new HttpError("unauthorized", "Account no longer exists.");
  const now = pushDeps.now();
  await rc.env.DB.batch([
    rc.env.DB.prepare(
      "INSERT INTO push_tokens (token, account_id, environment, locale, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) " +
        "ON CONFLICT (token) DO UPDATE SET account_id = excluded.account_id, environment = excluded.environment, " +
        "locale = excluded.locale, updated_at = excluded.updated_at",
    ).bind(req.token, auth.accountID, req.environment, req.locale ?? null, now, now),
    rc.env.DB.prepare(
      "DELETE FROM push_tokens WHERE account_id = ? AND token NOT IN " +
        "(SELECT token FROM push_tokens WHERE account_id = ? ORDER BY updated_at DESC, token DESC LIMIT ?)",
    ).bind(auth.accountID, auth.accountID, MAX_TOKENS_PER_ACCOUNT),
  ]);
  return new Response(null, { status: 204 });
}

/** DELETE /v1/push-tokens/{token} — this device stops getting the account's pushes. */
export async function unregisterPushToken(rc: RouteContext): Promise<Response> {
  const auth = caller(rc);
  const token = (rc.params.token ?? "").toLowerCase();
  if (!/^[0-9a-f]{32,200}$/.test(token)) throw new HttpError("bad_request", "Not a device token.", { path: "token" });
  await rc.env.DB.prepare("DELETE FROM push_tokens WHERE token = ? AND account_id = ?").bind(token, auth.accountID).run();
  return new Response(null, { status: 204 });
}

/** Account deletion hook (#285 → #287): the account's device tokens go first. */
export const deletePushTokensOfDeletedAccount: AccountDeletionHook = async (env, deletion, log) => {
  const res = await env.DB.prepare("DELETE FROM push_tokens WHERE account_id = ?").bind(deletion.accountID).run();
  if (res.meta.changes) log.info("account.push_tokens_deleted", { tokens: res.meta.changes });
};
