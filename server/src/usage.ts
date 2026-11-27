// Free-plan usage alert (cron, hourly per environment; wrangler.jsonc "triggers").
// Asks Cloudflare's GraphQL Analytics API for today's (UTC) account-wide Worker and
// Durable Object requests and alerts once per day and metric when one passes
// ALERT_FRACTION of the free daily limit. Needs the CF_ANALYTICS_TOKEN + CF_ACCOUNT_ID
// secrets (skipped without them); ALERT_WEBHOOK_URL is where the alert goes (the
// warn log line is always written). Dedupe lives in D1 (`ops_alerts`).

import type { Logger } from "./log";

export const GRAPHQL_URL = "https://api.cloudflare.com/client/v4/graphql";
/** Free plan, per account per UTC day. */
export const FREE_DAILY_LIMITS = { workerRequests: 100_000, durableObjectRequests: 100_000 } as const;
export const ALERT_FRACTION = 0.7;

export type UsageMetric = keyof typeof FREE_DAILY_LIMITS;

export type UsageResult =
  | { status: "skipped"; reason: string }
  | { status: "error"; reason: string }
  | { status: "checked"; usage: Record<UsageMetric, number>; alerted: UsageMetric[] };

// Field names per Cloudflare's GraphQL schema; unverified until the first real run
// (a wrong field shows up as a `usage.error` log line with the API's message).
const QUERY = `query TavtavUsage($account: String!, $start: Time!, $end: Time!, $date: Date!) {
  viewer {
    accounts(filter: { accountTag: $account }) {
      workersInvocationsAdaptive(limit: 10000, filter: { datetime_geq: $start, datetime_lt: $end }) {
        sum { requests }
      }
      durableObjectsInvocationsAdaptiveGroups(limit: 10000, filter: { date: $date }) {
        sum { requests }
      }
    }
  }
}`;

interface GraphQLAnswer {
  data?: {
    viewer?: {
      accounts?: {
        workersInvocationsAdaptive?: { sum?: { requests?: number } }[];
        durableObjectsInvocationsAdaptiveGroups?: { sum?: { requests?: number } }[];
      }[];
    };
  };
  errors?: { message: string }[] | null;
}

const sumRequests = (rows: { sum?: { requests?: number } }[] | undefined) =>
  (rows ?? []).reduce((n, r) => n + (r.sum?.requests ?? 0), 0);

export interface UsageDeps {
  fetch?: typeof fetch;
  now?: number;
}

export async function checkUsage(env: Env, log: Logger, deps: UsageDeps = {}): Promise<UsageResult> {
  if (!env.CF_ANALYTICS_TOKEN || !env.CF_ACCOUNT_ID) {
    const result = { status: "skipped", reason: "CF_ANALYTICS_TOKEN / CF_ACCOUNT_ID not set" } as const;
    log.info("usage.skipped", { reason: result.reason });
    return result;
  }
  const doFetch = deps.fetch ?? fetch;
  const now = new Date(deps.now ?? Date.now());
  const day = now.toISOString().slice(0, 10);
  const variables = { account: env.CF_ACCOUNT_ID, start: `${day}T00:00:00Z`, end: now.toISOString(), date: day };

  let answer: GraphQLAnswer;
  try {
    const res = await doFetch(GRAPHQL_URL, {
      method: "POST",
      headers: { authorization: `Bearer ${env.CF_ANALYTICS_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ query: QUERY, variables }),
    });
    if (!res.ok) throw new Error(`GraphQL HTTP ${res.status}`);
    answer = (await res.json()) as GraphQLAnswer;
  } catch (e) {
    log.error("usage.error", { error: e });
    return { status: "error", reason: (e as Error).message };
  }
  if (answer.errors?.length) {
    const reason = answer.errors.map((e) => e.message).join("; ");
    log.error("usage.error", { reason });
    return { status: "error", reason };
  }
  const account = answer.data?.viewer?.accounts?.[0];
  const usage: Record<UsageMetric, number> = {
    workerRequests: sumRequests(account?.workersInvocationsAdaptive),
    durableObjectRequests: sumRequests(account?.durableObjectsInvocationsAdaptiveGroups),
  };
  log.info("usage.checked", { day, ...usage });

  const alerted: UsageMetric[] = [];
  for (const metric of Object.keys(FREE_DAILY_LIMITS) as UsageMetric[]) {
    const limit = FREE_DAILY_LIMITS[metric];
    if (usage[metric] < limit * ALERT_FRACTION) continue;
    const inserted = await env.DB.prepare(
      "INSERT OR IGNORE INTO ops_alerts (day, kind, created_at) VALUES (?, ?, ?)",
    )
      .bind(day, `usage:${metric}`, now.getTime())
      .run();
    if (!inserted.meta.changes) continue; // already alerted today
    alerted.push(metric);
    const text =
      `Tavtav ${env.ENVIRONMENT}: ${metric} at ${usage[metric]} of the free plan's ` +
      `${limit}/day (${Math.round((100 * usage[metric]) / limit)}%, ${day} UTC).`;
    log.warn("usage.alert", { metric, value: usage[metric], limit, day });
    await sendAlert(env, log, text, doFetch);
  }
  return { status: "checked", usage, alerted };
}

/** POST the alert: plain text to ntfy.sh, `{text, content}` JSON (Slack/Discord) elsewhere. */
export async function sendAlert(env: Env, log: Logger, text: string, doFetch: typeof fetch = fetch): Promise<void> {
  const url = env.ALERT_WEBHOOK_URL;
  if (!url) return;
  const ntfy = new URL(url).hostname === "ntfy.sh";
  try {
    const res = await doFetch(url, {
      method: "POST",
      headers: { "content-type": ntfy ? "text/plain; charset=utf-8" : "application/json" },
      body: ntfy ? text : JSON.stringify({ text, content: text }),
    });
    if (!res.ok) throw new Error(`webhook HTTP ${res.status}`);
  } catch (e) {
    log.error("alert.failed", { error: e });
  }
}
