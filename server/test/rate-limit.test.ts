import { describe, expect, it, vi } from "vitest";
import { env } from "cloudflare:workers";
import { HttpError } from "../src/http";
import { clientIP, enforceRateLimit } from "../src/rate-limit";

const limiter = (success: boolean) => ({ limit: vi.fn(async (_: RateLimitOptions) => ({ success })) });

describe("rate limiting", () => {
  it("keys by IP or account on the matching binding", async () => {
    const ip = limiter(true);
    const acc = limiter(true);
    await enforceRateLimit({ IP_LIMITER: ip, ACCOUNT_LIMITER: acc }, { kind: "ip", ip: "203.0.113.9" });
    await enforceRateLimit({ IP_LIMITER: ip, ACCOUNT_LIMITER: acc }, { kind: "account", accountID: "acc_1" });
    expect(ip.limit).toHaveBeenCalledWith({ key: "ip:203.0.113.9" });
    expect(acc.limit).toHaveBeenCalledWith({ key: "acc:acc_1" });
  });

  it("throws rate_limited with Retry-After when over the limit", async () => {
    const err = await enforceRateLimit({ IP_LIMITER: limiter(false) }, { kind: "ip", ip: "x" }).catch((e) => e);
    expect(err).toBeInstanceOf(HttpError);
    expect(err).toMatchObject({ code: "rate_limited", extras: { retryAfter: 60 } });
  });

  it("never blocks without a binding", async () => {
    await expect(enforceRateLimit({}, { kind: "account", accountID: "a" })).resolves.toBeUndefined();
  });

  it("reads the client IP from CF-Connecting-IP", () => {
    expect(clientIP(new Request("https://x", { headers: { "cf-connecting-ip": "198.51.100.4" } }))).toBe(
      "198.51.100.4",
    );
    expect(clientIP(new Request("https://x"))).toBe("unknown");
  });

  it("the configured bindings work in Miniflare", async () => {
    const { success } = await env.IP_LIMITER.limit({ key: "test" });
    expect(success).toBe(true);
  });
});
