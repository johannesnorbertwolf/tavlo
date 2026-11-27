// MatchRoom: one Durable Object (SQLite storage backend) per online match. #284 ships
// the class, its storage-schema migrator and the WebSocket keepalive; #286 adds the
// match state, the OnlineMatchService operations, server dice and live events
// (REFERENCE.md "Match room").

import { DurableObject } from "cloudflare:workers";
import { WS_PING, WS_PONG } from "./api";

/**
 * Storage migrations, applied in order inside `blockConcurrencyWhile` on first use.
 * Append only: never edit a shipped step (objects in production already ran it).
 */
export const ROOM_MIGRATIONS: readonly string[][] = [
  // 1 (#284): bookkeeping only.
  ["CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"],
];

export interface RoomInfo {
  storage: "sqlite";
  schemaVersion: number;
}

export class MatchRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Answered by the runtime while the object hibernates: keepalives cost no wake-up.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(WS_PING, WS_PONG));
    ctx.blockConcurrencyWhile(async () => this.migrate());
  }

  private schemaVersion(): number {
    const sql = this.ctx.storage.sql;
    const hasMeta = sql
      .exec<{ n: number }>("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'meta'")
      .one().n;
    if (!hasMeta) return 0;
    const row = sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'schema_version'").toArray()[0];
    return row ? Number(row.value) : 0;
  }

  private migrate(): void {
    const sql = this.ctx.storage.sql;
    for (let v = this.schemaVersion(); v < ROOM_MIGRATIONS.length; v++) {
      this.ctx.storage.transactionSync(() => {
        for (const stmt of ROOM_MIGRATIONS[v]!) sql.exec(stmt);
        sql.exec(
          "INSERT INTO meta (key, value) VALUES ('schema_version', ?) " +
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          String(v + 1),
        );
      });
    }
  }

  /** RPC: storage health (the deep /health check). */
  async info(): Promise<RoomInfo> {
    return { storage: "sqlite", schemaVersion: this.schemaVersion() };
  }
}
