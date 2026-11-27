import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MatchRoom, ROOM_MIGRATIONS } from "../src/match-room";

describe("D1 schema (migrations/)", () => {
  it("creates the initial tables", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_%' ESCAPE '\\' ORDER BY name",
    ).all<{ name: string }>();
    expect(results.map((r) => r.name)).toEqual(
      expect.arrayContaining(["account_identities", "accounts", "match_index", "ops_alerts", "sessions"]),
    );
  });

  it("links identities to accounts and enforces one account per subject", async () => {
    const now = Date.now();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO accounts (id, display_name, created_at, last_seen_at) VALUES (?, ?, ?, ?)").bind(
        "acc_t1",
        "Test",
        now,
        now,
      ),
      env.DB.prepare(
        "INSERT INTO account_identities (provider, subject, account_id, created_at) VALUES ('apple', 's1', 'acc_t1', ?)",
      ).bind(now),
    ]);
    await expect(
      env.DB.prepare(
        "INSERT INTO account_identities (provider, subject, account_id, created_at) VALUES ('apple', 's1', 'acc_t1', ?)",
      )
        .bind(now)
        .run(),
    ).rejects.toThrow(/UNIQUE|PRIMARY KEY/);
    await expect(
      env.DB.prepare(
        "INSERT INTO account_identities (provider, subject, account_id, created_at) VALUES ('facebook', 's2', 'acc_t1', ?)",
      )
        .bind(now)
        .run(),
    ).rejects.toThrow(/CHECK/);
  });

  it("deleting an account removes its identities and lobby rows", async () => {
    const now = Date.now();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO accounts VALUES ('acc_t2', 'Gone', ?, ?)").bind(now, now),
      env.DB.prepare(
        "INSERT INTO account_identities (provider, subject, account_id, created_at) VALUES ('google', 'g2', 'acc_t2', ?)",
      ).bind(now),
      env.DB.prepare(
        "INSERT INTO match_index (match_id, account_id, variant, target_wins, state, created_at, updated_at) " +
          "VALUES ('m1', 'acc_t2', 'plakoto', 2, 'yourTurn', ?, ?)",
      ).bind(now, now),
    ]);
    await env.DB.prepare("DELETE FROM accounts WHERE id = 'acc_t2'").run();
    const left = await env.DB.prepare(
      "SELECT (SELECT count(*) FROM account_identities WHERE account_id = 'acc_t2') + " +
        "(SELECT count(*) FROM match_index WHERE account_id = 'acc_t2') AS n",
    ).first<{ n: number }>();
    expect(left?.n).toBe(0);
  });
});

describe("MatchRoom Durable Object", () => {
  it("uses SQLite storage and runs its storage migrations once", async () => {
    const stub = env.MATCH_ROOM.getByName("room-test");
    expect(await stub.info()).toEqual({ storage: "sqlite", schemaVersion: ROOM_MIGRATIONS.length });
    await runInDurableObject(stub, async (instance: MatchRoom, state) => {
      expect(instance).toBeInstanceOf(MatchRoom);
      const rows = state.storage.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'schema_version'");
      expect(rows.one().value).toBe(String(ROOM_MIGRATIONS.length));
    });
  });
});
