import { createExecutionContext, createScheduledController, waitOnExecutionContext } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { Logger } from "../src/log";
import { checkUsage, FREE_DAILY_LIMITS, GRAPHQL_URL } from "../src/usage";
import worker from "../src/index";

const NOW = Date.UTC(2026, 10, 20, 15, 0, 0);
const quietLog = new Logger();

function analytics(workerRequests: number, doRequests: number) {
  return {
    data: {
      viewer: {
        accounts: [
          {
            workersInvocationsAdaptive: [{ sum: { requests: workerRequests - 1 } }, { sum: { requests: 1 } }],
            durableObjectsInvocationsAdaptiveGroups: [{ sum: { requests: doRequests } }],
          },
        ],
      },
    },
    errors: null,
  };
}

function fakeFetch(answer: unknown) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    calls.push({ url, init });
    return url === GRAPHQL_URL ? Response.json(answer) : new Response("ok");
  });
  return { fn: fn as unknown as typeof fetch, calls };
}

const withSecrets = (extra: Partial<Env> = {}): Env => ({
  ...env,
  CF_ANALYTICS_TOKEN: "test-token",
  CF_ACCOUNT_ID: "acct123",
  ...extra,
});

afterEach(() => vi.restoreAllMocks());

describe("structured logs", () => {
  it("writes one JSON line with level, event, base fields and serialised errors", () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    new Logger({ requestId: "r1" }).child({ env: "test" }).error("boom", { error: new Error("bad") });
    const line = JSON.parse(spy.mock.calls[0]![0] as string);
    expect(line).toMatchObject({ level: "error", event: "boom", requestId: "r1", env: "test" });
    expect(line.error).toMatchObject({ name: "Error", message: "bad" });
    expect(typeof line.ts).toBe("string");
  });

  it("logs every request", async () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => {});
    await exports.default.fetch("https://server.test/health", { headers: { "x-tavtav-client": "ios/1.0.1 (330)" } });
    const lines = spy.mock.calls.map((c) => JSON.parse(c[0] as string));
    expect(lines).toContainEqual(
      expect.objectContaining({ event: "request", method: "GET", path: "/health", status: 200, client: "ios/1.0.1 (330)" }),
    );
  });
});

describe("free-plan usage check", () => {
  it("skips without the analytics secrets", async () => {
    expect(await checkUsage(env, quietLog)).toMatchObject({ status: "skipped" });
  });

  it("queries today's UTC usage and stays quiet below the threshold", async () => {
    const { fn, calls } = fakeFetch(analytics(1200, 300));
    const result = await checkUsage(withSecrets({ ALERT_WEBHOOK_URL: "https://ntfy.sh/t" }), quietLog, {
      fetch: fn,
      now: NOW,
    });
    expect(result).toEqual({
      status: "checked",
      usage: { workerRequests: 1200, durableObjectRequests: 300 },
      alerted: [],
    });
    expect(calls).toHaveLength(1);
    const sent = JSON.parse(String(calls[0]!.init!.body));
    expect(sent.variables).toMatchObject({ account: "acct123", start: "2026-11-20T00:00:00Z", date: "2026-11-20" });
    expect(new Headers(calls[0]!.init!.headers).get("authorization")).toBe("Bearer test-token");
  });

  it("alerts once per day and metric above 70 % of the free limit", async () => {
    const high = analytics(FREE_DAILY_LIMITS.workerRequests * 0.75, 10);
    const first = fakeFetch(high);
    const e = withSecrets({ ALERT_WEBHOOK_URL: "https://ntfy.sh/tavtav-ops-test" });
    expect(await checkUsage(e, quietLog, { fetch: first.fn, now: NOW })).toMatchObject({
      alerted: ["workerRequests"],
    });
    const webhook = first.calls.find((c) => c.url.startsWith("https://ntfy.sh/"));
    expect(String(webhook?.init?.body)).toMatch(/workerRequests at 75000 of the free plan's 100000\/day \(75%/);

    const again = fakeFetch(high);
    expect(await checkUsage(e, quietLog, { fetch: again.fn, now: NOW + 3_600_000 })).toMatchObject({ alerted: [] });
    expect(again.calls).toHaveLength(1); // GraphQL only, no second alert
  });

  it("posts JSON to non-ntfy webhooks", async () => {
    const { fn, calls } = fakeFetch(analytics(10, FREE_DAILY_LIMITS.durableObjectRequests));
    const e = withSecrets({ ALERT_WEBHOOK_URL: "https://hooks.example.com/x" });
    await checkUsage(e, quietLog, { fetch: fn, now: NOW + 86_400_000 });
    const body = JSON.parse(String(calls[1]!.init!.body));
    expect(body.text).toMatch(/durableObjectRequests/);
    expect(body.content).toBe(body.text);
  });

  it("reports GraphQL errors instead of throwing", async () => {
    const { fn } = fakeFetch({ data: null, errors: [{ message: "unknown field" }] });
    expect(await checkUsage(withSecrets(), quietLog, { fetch: fn, now: NOW })).toEqual({
      status: "error",
      reason: "unknown field",
    });
  });

  it("the scheduled handler runs the check", async () => {
    const spy = vi.spyOn(console, "log").mockImplementation(() => {});
    const ctx = createExecutionContext();
    await worker.scheduled(createScheduledController({ cron: "17 * * * *", scheduledTime: NOW }), env, ctx);
    await waitOnExecutionContext(ctx);
    const lines = spy.mock.calls.map((c) => JSON.parse(c[0] as string));
    expect(lines).toContainEqual(expect.objectContaining({ event: "usage.skipped", cron: "17 * * * *" }));
  });
});
