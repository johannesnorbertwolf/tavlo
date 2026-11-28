// MatchQueue (#287, REFERENCE.md "Auto-match"): one small Durable Object per auto-match
// queue, addressed by `<variant>:<targetWins>` (`MATCH_QUEUE.getByName(...)`). It keeps the
// matches waiting for a random opponent, oldest first. `enter` runs inside
// `blockConcurrencyWhile`, so two players entering at the same moment are served one after
// the other: the second finds the first one's match instead of both creating one (the race
// a D1 "find, else create" would have). The MatchRoom stays the source of truth: an entry
// whose match ended (its creator cancelled = quit) or whose seat is taken is dropped.

import { DurableObject } from "cloudflare:workers";
import type { MatchSnapshot, VariantID } from "./api";
import type { PlayerRef, RoomResult } from "./match-room";
import { randomToken } from "./sessions";

/** A waiting match older than this is dropped (its creator has long stopped waiting). */
export const QUEUE_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export interface EnterInput {
  player: PlayerRef;
  variant: VariantID;
  targetWins: number;
}

export interface EnterResult {
  match: MatchSnapshot;
  /** true: joined someone's waiting match; false: created one (or still waiting in it). */
  joined: boolean;
}

export function queueName(variant: string, targetWins: number): string {
  return `${variant}:${targetWins}`;
}

export class MatchQueue extends DurableObject<Env> {
  /** Test seam. */
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(
        "CREATE TABLE IF NOT EXISTS waiting (match_id TEXT PRIMARY KEY, creator_id TEXT NOT NULL, created_at INTEGER NOT NULL)",
      );
    });
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  /** Waiting entries, oldest first (tests). */
  async entries(): Promise<{ match_id: string; creator_id: string; created_at: number }[]> {
    return this.sql
      .exec<{ match_id: string; creator_id: string; created_at: number }>("SELECT * FROM waiting ORDER BY created_at, match_id")
      .toArray();
  }

  /**
   * Find a random opponent for `player`: join the oldest waiting match of someone else,
   * else keep waiting in the player's own (a second tap answers the same match), else
   * create a match with an open `matching` seat and wait in it.
   */
  async enter(input: EnterInput): Promise<RoomResult<EnterResult>> {
    // A throw inside blockConcurrencyWhile resets the object: answer an error instead.
    return this.ctx.blockConcurrencyWhile(() =>
      this.serve(input).catch((e): RoomResult<EnterResult> => {
        console.error(JSON.stringify({ level: "error", event: "queue.unhandled", error: String(e) }));
        return { ok: false, error: { code: "internal", message: "Something went wrong." } };
      }),
    );
  }

  private async serve(input: EnterInput): Promise<RoomResult<EnterResult>> {
    {
      const now = this.now();
      this.sql.exec("DELETE FROM waiting WHERE created_at < ?", now - QUEUE_MAX_AGE_MS);

      // 1. Someone else's waiting match, oldest first.
      for (;;) {
        const next = this.sql
          .exec<{ match_id: string }>(
            "SELECT match_id FROM waiting WHERE creator_id != ? ORDER BY created_at, match_id LIMIT 1",
            input.player.id,
          )
          .toArray()[0];
        if (!next) break;
        this.sql.exec("DELETE FROM waiting WHERE match_id = ?", next.match_id);
        const joined = await this.env.MATCH_ROOM.getByName(next.match_id).join(input.player);
        if (joined.ok) return { ok: true, value: { match: joined.value, joined: true } };
        // Ended (creator cancelled or deleted) or taken: drop it and look further.
      }

      // 2. The player's own waiting match (a double tap, or coming back to the queue).
      const own = this.sql
        .exec<{ match_id: string }>("SELECT match_id FROM waiting WHERE creator_id = ? ORDER BY created_at LIMIT 1", input.player.id)
        .toArray()[0];
      if (own) {
        const loaded = await this.env.MATCH_ROOM.getByName(own.match_id).load(input.player.id);
        const waiting =
          loaded.ok && !loaded.value.isEnded && loaded.value.participants[1]?.playerID === null;
        if (loaded.ok && waiting) return { ok: true, value: { match: loaded.value, joined: false } };
        this.sql.exec("DELETE FROM waiting WHERE match_id = ?", own.match_id);
      }

      // 3. A new match, waiting here.
      const matchID = randomToken("m_", 9);
      const created = await this.env.MATCH_ROOM.getByName(matchID).create({
        matchID,
        variant: input.variant,
        targetWins: input.targetWins,
        creator: input.player,
        openSeat: "matching",
      });
      if (!created.ok) return created;
      this.sql.exec("INSERT INTO waiting (match_id, creator_id, created_at) VALUES (?, ?, ?)", matchID, input.player.id, now);
      return { ok: true, value: { match: created.value, joined: false } };
    }
  }
}
