// PresenceHub (#301, REFERENCE.md "People, presence, challenges"): one Durable Object
// (SQLite storage) for the whole service, `PRESENCE.getByName("global")`. Every app in
// the foreground keeps one hibernatable WebSocket to it; that is what "online" means.
//
// Cheap on the Free plan: the app's `{"type":"ping"}` every 30 s is answered by the runtime
// without waking the object (`setWebSocketAutoResponse`), and the runtime remembers when it
// last did (`getWebSocketAutoResponseTimestamp`), so "online" = a socket whose last
// keepalive (or connect) is younger than `PRESENCE_ONLINE_MS` — no timers, no storage
// writes per ping. The object wakes only for a connect, a close, a people lookup and a
// challenge event.
//
// Privacy: presence goes only to watchers, and the watch list of an account is exactly
// the people the Worker looked up for it (`lookup`: people you've played with who don't
// hide their status). A hidden account is never broadcast.
//
// It also carries the live challenge events (`send`): an incoming challenge reaches an
// open app at once (the push goes out anyway; the app shows a card instead of the banner).

import { DurableObject } from "cloudflare:workers";
import { PRESENCE_ONLINE_MS, type Presence, WS_PING, WS_PONG } from "./api";

interface SocketTag {
  accountID: string;
  /** Access-token expiry (ms): the first message after it closes the socket with 4401. */
  exp: number;
  /** Connected at (ms). */
  at: number;
}

export class PresenceHub extends DurableObject<Env> {
  /** Test seam. */
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(WS_PING, WS_PONG));
    ctx.blockConcurrencyWhile(async () => {
      this.sql.exec(
        "CREATE TABLE IF NOT EXISTS seen (account_id TEXT PRIMARY KEY, last_seen_at INTEGER NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)",
      );
      this.sql.exec("CREATE TABLE IF NOT EXISTS watch (target TEXT NOT NULL, watcher TEXT NOT NULL, PRIMARY KEY (target, watcher))");
      this.sql.exec("CREATE INDEX IF NOT EXISTS watch_by_watcher ON watch (watcher)");
    });
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  // ── Sockets ───────────────────────────────────────────────────────────────────

  /**
   * Upgrade from the Worker, which verified the token and passes `x-tavtav-account`,
   * `x-tavtav-token-exp` and `x-tavtav-hidden` (the account's "hide my status").
   */
  override async fetch(request: Request): Promise<Response> {
    const accountID = request.headers.get("x-tavtav-account") ?? "";
    const exp = Number(request.headers.get("x-tavtav-token-exp") ?? 0);
    const hidden = request.headers.get("x-tavtav-hidden") === "1";
    if (!accountID) return Response.json({ error: { code: "unauthorized", message: "No account." } }, { status: 401 });
    const now = this.now();
    const wasOnline = this.isOnline(accountID, now);
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server, [accountID]);
    server.serializeAttachment({ accountID, exp, at: now } satisfies SocketTag);
    this.sql.exec(
      "INSERT INTO seen (account_id, last_seen_at, hidden) VALUES (?, ?, ?) " +
        "ON CONFLICT (account_id) DO UPDATE SET last_seen_at = excluded.last_seen_at, hidden = excluded.hidden",
      accountID,
      now,
      hidden ? 1 : 0,
    );
    server.send(JSON.stringify({ type: "hello", serverTime: now }));
    if (!wasOnline && !hidden) this.broadcastPresence(accountID, { online: true, lastSeenAt: now });
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Clients send only pings (answered by the runtime); anything else is ignored. */
  override async webSocketMessage(): Promise<void> {}

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, reason);
    } catch {
      // already closed
    }
    this.socketGone(ws);
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    this.socketGone(ws);
  }

  /** The account's last socket went away: last seen now, watchers told. */
  private socketGone(ws: WebSocket): void {
    const tag = ws.deserializeAttachment() as SocketTag | null;
    if (!tag) return;
    const now = this.now();
    const others = this.ctx.getWebSockets(tag.accountID).filter((s) => s !== ws && this.fresh(s, now) !== null);
    if (others.length) return;
    this.sql.exec("UPDATE seen SET last_seen_at = ? WHERE account_id = ?", now, tag.accountID);
    if (!this.isHidden(tag.accountID)) this.broadcastPresence(tag.accountID, { online: false, lastSeenAt: now });
  }

  /** The socket's last sign of life (keepalive or connect) if within the online window. */
  private fresh(ws: WebSocket, now: number): number | null {
    const last = this.lastAlive(ws);
    return last !== null && now - last < PRESENCE_ONLINE_MS ? last : null;
  }

  private lastAlive(ws: WebSocket): number | null {
    const tag = ws.deserializeAttachment() as SocketTag | null;
    if (!tag) return null;
    if (ws.readyState !== WebSocket.READY_STATE_OPEN) return null;
    const ping = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
    return Math.max(ping, tag.at);
  }

  private isOnline(accountID: string, now: number): boolean {
    return this.ctx.getWebSockets(accountID).some((ws) => this.fresh(ws, now) !== null);
  }

  private isHidden(accountID: string): boolean {
    return (this.sql.exec<{ hidden: number }>("SELECT hidden FROM seen WHERE account_id = ?", accountID).toArray()[0]?.hidden ?? 0) === 1;
  }

  /** Sends `message` to the live sockets of `accountID`; returns how many got it. */
  private sendTo(accountID: string, message: unknown, now = this.now()): number {
    const text = JSON.stringify(message);
    let sent = 0;
    for (const ws of this.ctx.getWebSockets(accountID)) {
      const tag = ws.deserializeAttachment() as SocketTag | null;
      if (!tag) continue;
      try {
        if (tag.exp && tag.exp <= now) {
          ws.send(JSON.stringify({ type: "error", error: { code: "token_expired", message: "Access token expired; reconnect." } }));
          ws.close(4401, "Access token expired");
          continue;
        }
        ws.send(text);
        sent++;
      } catch {
        // closed meanwhile
      }
    }
    return sent;
  }

  private broadcastPresence(accountID: string, presence: Presence): void {
    const watchers = this.sql
      .exec<{ watcher: string }>("SELECT watcher FROM watch WHERE target = ?", accountID)
      .toArray()
      .map((r) => r.watcher);
    const message = { type: "presence", playerID: accountID, ...presence };
    for (const w of watchers) this.sendTo(w, message);
  }

  // ── RPC ───────────────────────────────────────────────────────────────────────

  /**
   * The presence of `ids` (the watcher's people who don't hide it, chosen by the Worker),
   * and from now on `watcher` gets their changes live (its watch list is replaced).
   */
  async lookup(watcher: string, ids: string[]): Promise<Record<string, Presence>> {
    const now = this.now();
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM watch WHERE watcher = ?", watcher);
      for (const id of new Set(ids)) {
        if (id !== watcher) this.sql.exec("INSERT OR IGNORE INTO watch (target, watcher) VALUES (?, ?)", id, watcher);
      }
    });
    const out: Record<string, Presence> = {};
    for (const id of ids) {
      const row = this.sql
        .exec<{ last_seen_at: number; hidden: number }>("SELECT last_seen_at, hidden FROM seen WHERE account_id = ?", id)
        .toArray()[0];
      if (row?.hidden) continue;
      let newest = row?.last_seen_at ?? null;
      let online = false;
      for (const ws of this.ctx.getWebSockets(id)) {
        const alive = this.lastAlive(ws);
        if (alive === null) continue;
        if (now - alive < PRESENCE_ONLINE_MS) online = true;
        newest = Math.max(newest ?? 0, alive);
      }
      out[id] = { online, lastSeenAt: online ? now : newest };
    }
    return out;
  }

  /** "Hide my status" changed: remembered, and the watchers see the account go / come. */
  async setHidden(accountID: string, hidden: boolean): Promise<void> {
    const now = this.now();
    const before = this.isHidden(accountID);
    this.sql.exec(
      "INSERT INTO seen (account_id, last_seen_at, hidden) VALUES (?, ?, ?) " +
        "ON CONFLICT (account_id) DO UPDATE SET hidden = excluded.hidden",
      accountID,
      now,
      hidden ? 1 : 0,
    );
    if (before === hidden) return;
    const online = this.isOnline(accountID, now);
    if (hidden) {
      if (online) this.broadcastPresence(accountID, { online: false, lastSeenAt: null });
    } else if (online) {
      this.broadcastPresence(accountID, { online: true, lastSeenAt: now });
    }
  }

  /** A block (#301): neither gets the other's presence any more. */
  async unwatch(a: string, b: string): Promise<void> {
    this.sql.exec("DELETE FROM watch WHERE (target = ? AND watcher = ?) OR (target = ? AND watcher = ?)", a, b, b, a);
  }

  /** A live message (a challenge event) to the account's open apps; how many got it. */
  async send(accountID: string, message: unknown): Promise<number> {
    return this.sendTo(accountID, message);
  }

  /** Account deletion (#301 hook): sockets closed (4403), last-seen + watch rows gone. */
  async forget(accountID: string): Promise<void> {
    for (const ws of this.ctx.getWebSockets(accountID)) {
      try {
        ws.send(JSON.stringify({ type: "error", error: { code: "forbidden", message: "Account deleted." } }));
        ws.close(4403, "Account deleted");
      } catch {
        // gone
      }
    }
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM seen WHERE account_id = ?", accountID);
      this.sql.exec("DELETE FROM watch WHERE watcher = ? OR target = ?", accountID, accountID);
    });
  }

  /** Tests: the stored rows. */
  async rows(): Promise<{ seen: { account_id: string; hidden: number }[]; watch: { target: string; watcher: string }[] }> {
    return {
      seen: this.sql
        .exec<{ account_id: string; hidden: number }>("SELECT account_id, hidden FROM seen ORDER BY account_id")
        .toArray()
        .map((r) => ({ account_id: r.account_id, hidden: r.hidden })),
      watch: this.sql
        .exec<{ target: string; watcher: string }>("SELECT target, watcher FROM watch ORDER BY target, watcher")
        .toArray()
        .map((r) => ({ target: r.target, watcher: r.watcher })),
    };
  }
}
