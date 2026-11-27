// The route table: every endpoint of the contract (REFERENCE.md "Endpoints"), with the
// ticket that implements it. Routes without a handler answer 501 `not_implemented`
// naming their ticket, so the app and tests can see the full surface from day one.
// A ticket that builds an endpoint adds its `handler` here (and keeps REFERENCE.md in sync).

export type Ticket = "#284" | "#285" | "#286" | "#287";
export type Auth = "none" | "required";

export interface RouteContext {
  request: Request;
  env: Env;
  ctx: ExecutionContext;
  params: Record<string, string>;
  url: URL;
  requestId: string;
  /** The verified caller, set by the entry point on `auth: "required"` routes (#285). */
  auth?: { accountID: string; sessionID: string; expiresAt?: number };
}

export interface Route {
  method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
  /** `:name` segments capture a path parameter. */
  path: string;
  ticket: Ticket;
  auth: Auth;
  summary: string;
  handler?: (rc: RouteContext) => Promise<Response> | Response;
}

const r = (
  method: Route["method"],
  path: string,
  ticket: Ticket,
  auth: Auth,
  summary: string,
): Route => ({ method, path, ticket, auth, summary });

/** The contract's endpoints. `/health` is bound in index.ts. */
export const CONTRACT_ROUTES: Route[] = [
  r("GET", "/health", "#284", "none", "Liveness + deployed version/commit (?deep=1 checks D1 + DO)"),

  // Accounts (#285)
  r("POST", "/v1/auth/apple", "#285", "none", "Sign in with Apple identity token → AuthSession"),
  r("POST", "/v1/auth/google", "#285", "none", "Sign in with Google id_token → AuthSession"),
  r("POST", "/v1/auth/refresh", "#285", "none", "Rotate refresh token → AuthSession"),
  r("POST", "/v1/auth/dev", "#285", "none", "Development only: sign in without a provider token → AuthSession"),
  r("POST", "/v1/auth/logout", "#285", "required", "Revoke the refresh token"),
  r("GET", "/v1/account", "#285", "required", "The caller's Account"),
  r("PATCH", "/v1/account", "#285", "required", "Change display name"),
  r("DELETE", "/v1/account", "#285", "required", "Delete account + personal data"),

  // Matches (#286) — OnlineMatchService
  r("GET", "/v1/matches", "#286", "required", "Caller's matches (lobby list) → MatchListResponse"),
  r("POST", "/v1/matches", "#286", "required", "Create a match (direct challenge) → MatchSnapshot"),
  r("GET", "/v1/matches/:matchID", "#286", "required", "load → MatchSnapshot"),
  r("POST", "/v1/matches/:matchID/accept", "#286", "required", "acceptInvite → MatchSnapshot"),
  r("POST", "/v1/matches/:matchID/decline", "#286", "required", "Decline a pending match"),
  r("POST", "/v1/matches/:matchID/end-turn", "#286", "required", "endTurn → MatchSnapshot"),
  r("POST", "/v1/matches/:matchID/save-turn", "#286", "required", "saveTurn (live turn) → MatchSnapshot"),
  r("POST", "/v1/matches/:matchID/end-match", "#286", "required", "endMatch → MatchSnapshot"),
  r("POST", "/v1/matches/:matchID/quit", "#286", "required", "quit (in or out of turn) → MatchSnapshot"),
  r("POST", "/v1/matches/:matchID/requests", "#286", "required", "sendRequest (out of turn, opaque)"),
  r("POST", "/v1/matches/:matchID/dice", "#286", "required", "Change the shared dice slider → DiceHandicap"),
  r("POST", "/v1/matches/:matchID/roll", "#286", "required", "Server draws the turn's dice → RollRecord"),
  r("GET", "/v1/matches/:matchID/socket", "#286", "required", "WebSocket upgrade: live match events"),
  r("DELETE", "/v1/matches/:matchID", "#287", "required", "Remove an ended match from the lobby"),

  // Invites, auto-match, push (#287)
  r("POST", "/v1/invites", "#287", "required", "New match + invite code/link → Invite"),
  r("GET", "/v1/invites/:code", "#287", "required", "Invite preview → InvitePreview"),
  r("POST", "/v1/invites/:code/accept", "#287", "required", "Join via code → MatchSnapshot"),
  r("POST", "/v1/invites/:code/decline", "#287", "required", "Decline an invite"),
  r("DELETE", "/v1/invites/:code", "#287", "required", "Creator cancels an open invite"),
  r("POST", "/v1/automatch", "#287", "required", "Random opponent → MatchSnapshot"),
  r("PUT", "/v1/push-tokens", "#287", "required", "Register/refresh an APNs device token"),
  r("DELETE", "/v1/push-tokens/:token", "#287", "required", "Unregister a device token"),
  r("GET", "/.well-known/apple-app-site-association", "#287", "none", "Universal links (AASA JSON)"),
  r("GET", "/join/:code", "#287", "none", "Invite link web fallback page"),
];

interface Compiled {
  route: Route;
  regex: RegExp;
  names: string[];
}

function compile(route: Route): Compiled {
  const names: string[] = [];
  const pattern = route.path
    .split("/")
    .map((seg) => {
      if (!seg.startsWith(":")) return seg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      names.push(seg.slice(1));
      return "([^/]+)";
    })
    .join("/");
  return { route, regex: new RegExp(`^${pattern}$`), names };
}

export type Match =
  | { kind: "found"; route: Route; params: Record<string, string> }
  | { kind: "wrong_method"; allow: string[] }
  | { kind: "none" };

export class Router {
  private readonly compiled: Compiled[];
  constructor(routes: Route[]) {
    this.compiled = routes.map(compile);
  }

  match(method: string, pathname: string): Match {
    const allow: string[] = [];
    for (const c of this.compiled) {
      const m = c.regex.exec(pathname);
      if (!m) continue;
      if (c.route.method !== method && !(method === "HEAD" && c.route.method === "GET")) {
        allow.push(c.route.method);
        continue;
      }
      const params: Record<string, string> = {};
      c.names.forEach((n, i) => (params[n] = decodeURIComponent(m[i + 1]!)));
      return { kind: "found", route: c.route, params };
    }
    return allow.length ? { kind: "wrong_method", allow } : { kind: "none" };
  }
}
