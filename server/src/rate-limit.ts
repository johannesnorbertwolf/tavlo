// Rate-limit middleware (skeleton, #284). Two Workers Rate Limiting bindings
// (wrangler.jsonc "ratelimits", 60 s windows, counted per Cloudflare location):
//   IP_LIMITER       every request except /health, keyed by client IP
//   ACCOUNT_LIMITER  authenticated requests, keyed by account id (wired in by #285)
// A missing binding never blocks (local tools, or a plan without the binding).
// Limits are abuse brakes, not quota guards: a blocked request still counts as a
// Worker request on the free plan.

import { HttpError } from "./http";

export const RATE_LIMIT_WINDOW_SECONDS = 60;

export type RateLimitKey = { kind: "ip"; ip: string } | { kind: "account"; accountID: string };

export function clientIP(req: Request): string {
  return req.headers.get("cf-connecting-ip") ?? "unknown";
}

/** Throws `rate_limited` (429 + Retry-After) when the key is over its limit. */
export async function enforceRateLimit(
  limiters: { IP_LIMITER?: RateLimit; ACCOUNT_LIMITER?: RateLimit },
  key: RateLimitKey,
): Promise<void> {
  const limiter = key.kind === "ip" ? limiters.IP_LIMITER : limiters.ACCOUNT_LIMITER;
  if (!limiter) return;
  const id = key.kind === "ip" ? `ip:${key.ip}` : `acc:${key.accountID}`;
  const { success } = await limiter.limit({ key: id });
  if (!success) {
    throw new HttpError("rate_limited", "Too many requests, slow down.", {
      retryAfter: RATE_LIMIT_WINDOW_SECONDS,
    });
  }
}
