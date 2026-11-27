// JSON responses and the one error format (REFERENCE.md "Errors").

import { API_VERSION, type ApiError, type ErrorCode } from "./api";

export const ERROR_STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  token_expired: 401,
  forbidden: 403,
  not_found: 404,
  method_not_allowed: 405,
  stale_revision: 409,
  not_your_turn: 409,
  match_ended: 409,
  invite_unavailable: 410,
  payload_too_large: 413,
  upgrade_required: 426,
  rate_limited: 429,
  internal: 500,
  not_implemented: 501,
  unavailable: 503,
};

type ErrorExtras = Omit<ApiError["error"], "code" | "message">;

/** Thrown by handlers; turned into the error response by the entry point. */
export class HttpError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly extras: ErrorExtras = {},
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

export function errorResponse(err: HttpError, requestId?: string): Response {
  const body: ApiError = {
    error: { code: err.code, message: err.message, ...err.extras, ...(requestId ? { requestId } : {}) },
  };
  const headers = { ...err.headers };
  if (err.extras.retryAfter !== undefined) headers["retry-after"] = String(err.extras.retryAfter);
  return json(body, ERROR_STATUS[err.code], headers);
}

/** Headers every response carries. */
export function withStandardHeaders(res: Response, requestId: string): Response {
  if (res.webSocket) return res; // a 101 upgrade must be returned untouched
  const out = new Response(res.body, res);
  out.headers.set("x-request-id", requestId);
  out.headers.set("x-tavtav-api", String(API_VERSION));
  if (!out.headers.has("cache-control")) out.headers.set("cache-control", "no-store");
  return out;
}

/** Parse a JSON request body against a schema; any problem is a 400 with the path. */
export async function readJson<T>(req: Request, schema: { parse: (v: unknown) => T }): Promise<T> {
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    throw new HttpError("bad_request", "Body is not valid JSON.");
  }
  try {
    return schema.parse(raw);
  } catch (e) {
    const path = (e as { path?: string }).path;
    throw new HttpError("bad_request", (e as Error).message, path ? { path } : {});
  }
}
