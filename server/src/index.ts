// Worker entry point: routing, rate limiting, error format, request logs, /health,
// the hourly usage check, and the MatchRoom Durable Object export.

import {
  deleteAccount,
  getAccount,
  logout,
  pruneSessions,
  refresh,
  signInForDevelopment,
  signInWithApple,
  signInWithGoogle,
  updateAccount,
} from "./accounts";
import { API_VERSION, type HealthResponse } from "./api";
import { HttpError, errorResponse, json, withStandardHeaders } from "./http";
import { Logger } from "./log";
import { clientIP, enforceRateLimit } from "./rate-limit";
import { CONTRACT_ROUTES, Router, type Route, type RouteContext } from "./routes";
import { identityDeps } from "./identity";
import { authenticate } from "./sessions";
import { acceptInvite, createInvite, declineInvite, expireInvites, previewInvite, revokeInvite } from "./invites";
import { checkHandle } from "./handles";
import {
  blockPerson,
  expireChallenges,
  listPeople,
  presenceSocket,
  removePerson,
  searchPlayers,
  unblockPerson,
  updatePerson,
} from "./people";
import {
  acceptMatch,
  autoMatch,
  cancelChallenge,
  changeDice,
  createMatch,
  declineMatch,
  endMatch,
  endTurn,
  listMatches,
  loadMatch,
  matchSocket,
  quitMatch,
  removeMatch,
  rollDice,
  saveTurn,
  sendRequest,
} from "./matches";
import { registerPushToken, unregisterPushToken } from "./push";
import { checkUsage } from "./usage";
import { appSiteAssociation, joinFallback } from "./web";
import { SERVER_VERSION, SERVICE_NAME } from "./version";

export { MatchQueue } from "./match-queue";
export { MatchRoom } from "./match-room";
export { PresenceHub } from "./presence-hub";

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
  "POST /v1/auth/apple": signInWithApple,
  "POST /v1/auth/google": signInWithGoogle,
  "POST /v1/auth/refresh": refresh,
  "POST /v1/auth/dev": signInForDevelopment,
  "POST /v1/auth/logout": logout,
  "GET /v1/account": getAccount,
  "PATCH /v1/account": updateAccount,
  "DELETE /v1/account": deleteAccount,
  "GET /v1/matches": listMatches,
  "POST /v1/matches": createMatch,
  "GET /v1/matches/:matchID": loadMatch,
  "POST /v1/matches/:matchID/accept": acceptMatch,
  "POST /v1/matches/:matchID/decline": declineMatch,
  "POST /v1/matches/:matchID/end-turn": endTurn,
  "POST /v1/matches/:matchID/save-turn": saveTurn,
  "POST /v1/matches/:matchID/end-match": endMatch,
  "POST /v1/matches/:matchID/quit": quitMatch,
  "POST /v1/matches/:matchID/requests": sendRequest,
  "POST /v1/matches/:matchID/dice": changeDice,
  "POST /v1/matches/:matchID/roll": rollDice,
  "GET /v1/matches/:matchID/socket": matchSocket,
  "DELETE /v1/matches/:matchID": removeMatch,
  "POST /v1/invites": createInvite,
  "GET /v1/invites/:code": previewInvite,
  "POST /v1/invites/:code/accept": acceptInvite,
  "POST /v1/invites/:code/decline": declineInvite,
  "DELETE /v1/invites/:code": revokeInvite,
  "POST /v1/automatch": autoMatch,
  "PUT /v1/push-tokens": registerPushToken,
  "DELETE /v1/push-tokens/:token": unregisterPushToken,
  "GET /.well-known/apple-app-site-association": appSiteAssociation,
  "GET /join/:code": joinFallback,
  "POST /v1/matches/:matchID/cancel": cancelChallenge,
  "GET /v1/people": listPeople,
  "PATCH /v1/people/:playerID": updatePerson,
  "DELETE /v1/people/:playerID": removePerson,
  "POST /v1/people/:playerID/block": blockPerson,
  "DELETE /v1/people/:playerID/block": unblockPerson,
  "GET /v1/players": searchPlayers,
  "GET /v1/handles/:handle": checkHandle,
  "GET /v1/presence/socket": presenceSocket,
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
  if (!route.handler) {
    throw new HttpError("not_implemented", `${route.method} ${route.path} arrives with ${route.ticket}.`, {
      ticket: route.ticket,
    });
  }
  if (route.auth === "required") {
    const auth = await authenticate(env, request, identityDeps.now());
    await enforceRateLimit(env, { kind: "account", accountID: auth.accountID });
    return route.handler({ ...rc, params, auth });
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
    ctx.waitUntil(
      pruneSessions(env, controller.scheduledTime)
        .then((pruned) => log.info("sessions.pruned", { pruned }))
        .catch((error) => log.error("sessions.prune_failed", { error })),
    );
    ctx.waitUntil(
      expireInvites(env, controller.scheduledTime, log).catch((error) => log.error("invites.expire_failed", { error })),
    );
    ctx.waitUntil(
      expireChallenges(env, ctx, controller.scheduledTime, log).catch((error) =>
        log.error("challenges.expire_failed", { error }),
      ),
    );
  },
} satisfies ExportedHandler<Env>;
