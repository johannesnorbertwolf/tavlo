// Handles (#301, REFERENCE.md "Handles and search"): every account has a unique handle,
// separate from its display name, so players can find each other (like Lichess).
// 3–20 of [A-Za-z0-9_], shown as typed, unique ignoring case (`accounts.handle_key` =
// lower case, UNIQUE index — so two players taking the same handle at once: exactly one
// UPDATE succeeds, the other gets 409 `handle_taken`). Reserved words are refused.
// Mirrored by Swift `HandleRule`.

import { HANDLE_PATTERN, type HandleAvailability, RESERVED_HANDLES } from "./api";
import { HttpError, json } from "./http";
import type { RouteContext } from "./routes";

const RESERVED = new Set<string>(RESERVED_HANDLES);

export type HandleProblem = "invalid" | "reserved";

/** Why `handle` can't be anyone's (null = fine as far as the rule goes). */
export function handleProblem(handle: string): HandleProblem | null {
  if (!HANDLE_PATTERN.test(handle)) return "invalid";
  const key = handle.toLowerCase();
  if (RESERVED.has(key) || key.startsWith("tavtav")) return "reserved";
  return null;
}

/**
 * A handle from a display name: accents dropped, spaces and dashes → `_`, anything else
 * outside [A-Za-z0-9_] dropped, 20 at most; "player" when too little is left (a Greek or
 * Persian name — the app transliterates before it suggests, the server can't).
 */
export function suggestHandle(displayName: string): string {
  let base = displayName
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/[\s.\-]+/gu, "_")
    .replace(/[^A-Za-z0-9_]/g, "")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 20);
  if (base.length < 3 || handleProblem(base)) base = "player";
  return base;
}

const randomDigits = (n: number) =>
  Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => String(b % 10)).join("");

/** `base` if free, else `base` + digits (trimmed to fit), until one is free. */
export async function freeHandle(env: Env, base: string): Promise<string> {
  for (let attempt = 0; attempt < 8; attempt++) {
    const digits = attempt === 0 && base !== "player" ? "" : randomDigits(Math.min(2 + attempt, 6));
    const candidate = base.slice(0, 20 - digits.length) + digits;
    const taken = await env.DB.prepare("SELECT 1 AS ok FROM accounts WHERE handle_key = ?").bind(candidate.toLowerCase()).first();
    if (!taken && !handleProblem(candidate)) return candidate;
  }
  return `player${randomDigits(10)}`;
}

/** Gives the account a generated handle if it has none (new accounts; never overwrites). */
export async function ensureHandle(env: Env, accountID: string, displayName: string): Promise<void> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const handle = await freeHandle(env, suggestHandle(displayName));
    try {
      await env.DB.prepare("UPDATE accounts SET handle = ?, handle_key = ? WHERE id = ? AND handle IS NULL")
        .bind(handle, handle.toLowerCase(), accountID)
        .run();
      return;
    } catch (e) {
      if (!String(e).includes("UNIQUE")) throw e; // someone took it meanwhile: try another
    }
  }
}

/**
 * The account takes `handle` (its one change). 403 when it was changed before, 400 for
 * the rule, 409 `handle_taken` when someone else has it (also when two race for it).
 */
export async function chooseHandle(env: Env, accountID: string, handle: string): Promise<void> {
  const problem = handleProblem(handle);
  if (problem) {
    throw new HttpError("bad_request", problem === "reserved" ? "That handle is reserved." : "Handles are 3–20 letters, digits or _.", {
      path: "handle",
    });
  }
  const row = await env.DB.prepare("SELECT handle, handle_chosen FROM accounts WHERE id = ?")
    .bind(accountID)
    .first<{ handle: string | null; handle_chosen: number }>();
  if (!row) throw new HttpError("unauthorized", "Account no longer exists.");
  if (row.handle === handle) return;
  if (row.handle_chosen) throw new HttpError("forbidden", "Your handle can be changed only once.");
  try {
    const res = await env.DB.prepare(
      "UPDATE accounts SET handle = ?, handle_key = ?, handle_chosen = 1 WHERE id = ? AND handle_chosen = 0",
    )
      .bind(handle, handle.toLowerCase(), accountID)
      .run();
    if (res.meta.changes !== 1) throw new HttpError("forbidden", "Your handle can be changed only once.");
  } catch (e) {
    if (e instanceof HttpError) throw e;
    if (String(e).includes("UNIQUE")) throw new HttpError("handle_taken", "Someone else has that handle.", { path: "handle" });
    throw e;
  }
}

/** GET /v1/handles/{handle} — whether the caller could take it (for the name prompt). */
export async function checkHandle(rc: RouteContext): Promise<Response> {
  if (!rc.auth) throw new HttpError("unauthorized", "Sign in first.");
  const handle = rc.params.handle ?? "";
  const body: HandleAvailability = { handle, available: false };
  const problem = handleProblem(handle);
  if (problem) {
    body.reason = problem;
    return json(body);
  }
  const owner = await rc.env.DB.prepare("SELECT id FROM accounts WHERE handle_key = ?")
    .bind(handle.toLowerCase())
    .first<{ id: string }>();
  if (owner && owner.id === rc.auth.accountID) {
    body.available = true; // already yours (another spelling of it may still be chosen)
    body.reason = "yours";
  } else if (owner) body.reason = "taken";
  else body.available = true;
  return json(body);
}
