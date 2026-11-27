// Worker entry point: routing, rate limiting, error format, request logs, /health,
// the hourly usage check, and the MatchRoom Durable Object export.

import { API_VERSION, type HealthResponse } from "./api";
import { HttpError, errorResponse, json, withStandardHeaders } from "./http";
import { Logger } from "./log";
import { clientIP, enforceRateLimit } from "./rate-limit";
import { CONTRACT_ROUTES, Router, type Route, type RouteContext } from "./routes";
import { checkUsage } from "./usage";
import { SERVER_VERSION, SERVICE_NAME } from "./version";

export { MatchRoom } from "./match-room";

async function health(rc: RouteContext): Promise<Response> {
  const { env, url } = rc;
  const body: HealthResponse = {
    status: "ok",
    service: SERVICE_NAME,
    version: SERVER_VERSION,
    commit: env.GIT_COMMIT,
    environment: env.ENVIRONMENT,
    apiVersion: API_VERSION,
    time: Date.now(),
  };
  if (url.searchParams.get("deep") === "1") {
    const d1 = await env.DB.prepare("SELECT 1 AS ok")
      .first<{ ok: number }>()
      .then((r) => (r?.ok === 1 ? "ok" : "error"))
      .catch(() => "error" as const);
    const durableObjects = await env.MATCH_ROOM.getByName("health")
      .info()
      .then((i) => (i.storage === "sqlite" ? "ok" : "error"))
      .catch(() => "error" as const);
    body.checks = { d1, durableObjects };
    if (d1 !== "ok" || durableObjects !== "ok") body.status = "degraded";
  }
  return json(body, body.status === "ok" ? 200 : 503);
}

const HANDLERS: Partial<Record<string, Route["handler"]>> = {
  "GET /health": health,
};

export const ROUTES: Route[] = CONTRACT_ROUTES.map((route) => ({
  ...route,
  handler: HANDLERS[`${route.method} ${route.path}`] ?? route.handler,
}));

const router = new Router(ROUTES);

async function dispatch(rc: RouteContext): Promise<Response> {
  const { request, url, env } = rc;
  const found = router.match(request.method, url.pathname);
  if (found.kind === "none") throw new HttpError("not_found", `No route for ${url.pathname}.`);
  if (found.kind === "wrong_method") {
    throw new HttpError("method_not_allowed", `Use ${found.allow.join(", ")}.`, {}, {
      allow: found.allow.join(", "),
    });
  }
  const { route, params } = found;
  if (route.path !== "/health") await enforceRateLimit(env, { kind: "ip", ip: clientIP(request) });
  // #285: verify the bearer token for `auth: "required"` routes here, then
  // enforceRateLimit(env, { kind: "account", accountID }).
  if (!route.handler) {
    throw new HttpError("not_implemented", `${route.method} ${route.path} arrives with ${route.ticket}.`, {
      ticket: route.ticket,
    });
  }
  return route.handler({ ...rc, params });
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const started = Date.now();
    const url = new URL(request.url);
    const requestId = request.headers.get("cf-ray") ?? crypto.randomUUID();
    const log = new Logger({ service: SERVICE_NAME, env: env.ENVIRONMENT, requestId });
    let response: Response;
    try {
      response = await dispatch({ request, env, ctx, url, params: {}, requestId });
    } catch (e) {
      if (e instanceof HttpError) {
        response = errorResponse(e, requestId);
      } else {
        log.error("request.unhandled", { error: e, method: request.method, path: url.pathname });
        response = errorResponse(new HttpError("internal", "Something went wrong."), requestId);
      }
    }
    log.info("request", {
      method: request.method,
      path: url.pathname,
      status: response.status,
      durationMs: Date.now() - started,
      client: request.headers.get("x-tavtav-client") ?? undefined,
      colo: (request.cf as { colo?: string } | undefined)?.colo,
    });
    return withStandardHeaders(response, requestId);
  },

  async scheduled(controller, env, ctx): Promise<void> {
    const log = new Logger({ service: SERVICE_NAME, env: env.ENVIRONMENT, cron: controller.cron });
    ctx.waitUntil(checkUsage(env, log, { now: controller.scheduledTime }));
  },
} satisfies ExportedHandler<Env>;
