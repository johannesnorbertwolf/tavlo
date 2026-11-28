// MatchRoom: one Durable Object (SQLite storage backend) per online match, addressed by
// its match id (`MATCH_ROOM.getByName(matchID)`). The single writer for the match (#286,
// REFERENCE.md "Match operations", "Server dice", "WebSocket"): seats, turn holder, the
// opaque payload + its revision, the shared dice slider, the roll log, out-of-turn
// requests and the hibernatable sockets. Every state change is made synchronously
// (one SQLite transaction, so no other event interleaves), then the lobby index in D1
// is updated and the sockets are told.
//
// RPC methods return a `RoomResult` instead of throwing: exceptions lose their fields
// crossing the RPC boundary, so the Worker turns `{ok: false, error}` into the error
// response (`unwrapRoom` in matches.ts).

import { DurableObject } from "cloudflare:workers";
import {
  type Color,
  type DiceHandicap,
  type ErrorCode,
  type MatchSnapshot,
  type OutOfTurnRequest,
  type QuitRequest,
  type RollRecord,
  type RollRequest,
  VARIANT_MAX_POINTS,
  type VariantID,
  WS_PING,
  WS_PONG,
} from "./api";
import { cryptoRandom, type DiceRandom, drawRoll } from "./dice";
import { Logger } from "./log";
import { checkPayloadSize, PayloadError, type PlyDice, readPlyDice } from "./payload";
import { SERVICE_NAME } from "./version";

/**
 * Storage migrations, applied in order inside `blockConcurrencyWhile` on first use.
 * Append only: never edit a shipped step (objects in production already ran it).
 */
export const ROOM_MIGRATIONS: readonly string[][] = [
  // 1 (#284): bookkeeping only.
  ["CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"],
  // 2 (#286): the match. One `match` row; `revision` versions `data` (the payload) only.
  [
    `CREATE TABLE match (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      match_id TEXT NOT NULL,
      variant TEXT NOT NULL,
      target_wins INTEGER NOT NULL,
      starting_player TEXT NOT NULL,
      data TEXT,
      revision INTEGER NOT NULL DEFAULT 0,
      current_seat INTEGER,
      is_ended INTEGER NOT NULL DEFAULT 0,
      dice_level INTEGER NOT NULL DEFAULT 0,
      dice_rev INTEGER NOT NULL DEFAULT 0,
      dice_by TEXT,
      last_write_seat INTEGER,
      last_write_op TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )`,
    `CREATE TABLE seats (
      seat INTEGER PRIMARY KEY,
      player_id TEXT,
      display_name TEXT,
      color TEXT NOT NULL,
      status TEXT NOT NULL,
      outcome TEXT NOT NULL DEFAULT 'none',
      deleted INTEGER NOT NULL DEFAULT 0
    )`,
    `CREATE TABLE rolls (
      game_index INTEGER NOT NULL,
      ply_index INTEGER NOT NULL,
      player TEXT NOT NULL,
      die1 INTEGER NOT NULL,
      die2 INTEGER NOT NULL,
      weighted INTEGER,
      beta REAL,
      roll_values TEXT,
      rolled_at INTEGER NOT NULL,
      seq INTEGER NOT NULL,
      PRIMARY KEY (game_index, ply_index)
    )`,
    `CREATE TABLE requests (
      id TEXT PRIMARY KEY,
      from_seat INTEGER NOT NULL,
      data TEXT NOT NULL,
      sent_at INTEGER NOT NULL,
      seq INTEGER NOT NULL
    )`,
  ],
];

export interface RoomInfo {
  storage: "sqlite";
  schemaVersion: number;
}

export type RoomResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: { code: ErrorCode; message: string; path?: string } };

class RoomError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly path?: string,
  ) {
    super(message);
  }
}

export interface PlayerRef {
  id: string;
  displayName: string;
}

export interface CreateInput {
  matchID: string;
  variant: VariantID;
  targetWins: number;
  creator: PlayerRef;
  /** Direct challenge: seat 1 is this player, `invited`. Absent: seat 1 is open. */
  opponent?: PlayerRef;
  /**
   * The open seat's status without `opponent` (#287): `matching` (auto-match, the default)
   * or `invited` (an invite code; whoever accepts it joins).
   */
  openSeat?: "matching" | "invited";
}

export type WriteOp = "endTurn" | "saveTurn" | "endMatch";

export interface WriteInput {
  baseRevision: number;
  data: string;
  /** endMatch: the caller's outcome. */
  outcome?: "won" | "lost" | "tied";
}

/** Max pending out-of-turn requests per match. */
export const MAX_REQUESTS = 50;

interface MatchRow extends Record<string, SqlStorageValue> {
  match_id: string;
  variant: string;
  target_wins: number;
  starting_player: string;
  data: string | null;
  revision: number;
  current_seat: number | null;
  is_ended: number;
  dice_level: number;
  dice_rev: number;
  dice_by: string | null;
  last_write_seat: number | null;
  last_write_op: string | null;
  created_at: number;
  updated_at: number;
}

interface SeatRow extends Record<string, SqlStorageValue> {
  seat: number;
  player_id: string | null;
  display_name: string | null;
  color: string;
  status: string;
  outcome: string;
  deleted: number;
}

interface RollRow extends Record<string, SqlStorageValue> {
  game_index: number;
  ply_index: number;
  player: string;
  die1: number;
  die2: number;
  weighted: number | null;
  beta: number | null;
  rolled_at: number;
}

interface SocketTag {
  accountID: string;
  /** Access-token expiry (ms); a socket past it is closed with 4401 on the next send. */
  exp: number;
}

/** Match event → WebSocket `match.event` (REFERENCE.md "WebSocket"). */
export type MatchEventName =
  | "created"
  | "joined"
  | "accepted"
  | "declined"
  | "turnEnded"
  | "turnSaved"
  | "matchEnded"
  | "quit"
  | "diceChanged";

const OPPOSITE: Record<string, string> = { won: "lost", lost: "won", tied: "tied" };

/** Random id `<prefix><n base64url chars>`. */
function randomID(prefix: string, bytes: number): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return prefix + btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export class MatchRoom extends DurableObject<Env> {
  /** Test seams (set inside `runInDurableObject`). */
  random: DiceRandom = cryptoRandom;
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Answered by the runtime while the object hibernates: keepalives cost no wake-up.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(WS_PING, WS_PONG));
    ctx.blockConcurrencyWhile(async () => this.migrate());
  }

  private get sql() {
    return this.ctx.storage.sql;
  }

  private schemaVersion(): number {
    const hasMeta = this.sql
      .exec<{ n: number }>("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table' AND name = 'meta'")
      .one().n;
    if (!hasMeta) return 0;
    const row = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'schema_version'").toArray()[0];
    return row ? Number(row.value) : 0;
  }

  private migrate(): void {
    for (let v = this.schemaVersion(); v < ROOM_MIGRATIONS.length; v++) {
      this.ctx.storage.transactionSync(() => {
        for (const stmt of ROOM_MIGRATIONS[v]!) this.sql.exec(stmt);
        this.sql.exec(
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

  private log(fields: Record<string, unknown> = {}): Logger {
    return new Logger({ service: SERVICE_NAME, env: this.env.ENVIRONMENT, room: true, ...fields });
  }

  // ── State access ──────────────────────────────────────────────────────────────

  private matchRow(): MatchRow | undefined {
    return this.sql.exec<MatchRow>("SELECT * FROM match WHERE id = 1").toArray()[0];
  }

  private requireMatch(): MatchRow {
    const m = this.matchRow();
    if (!m) throw new RoomError("not_found", "No such match.");
    return m;
  }

  private seats(): SeatRow[] {
    return this.sql.exec<SeatRow>("SELECT * FROM seats ORDER BY seat").toArray();
  }

  /** The caller's seat; refused when not a participant or the account was deleted. */
  private seatOf(accountID: string): SeatRow {
    const seat = this.seats().find((s) => s.player_id === accountID);
    if (!seat) throw new RoomError("forbidden", "Not a participant of this match.");
    if (seat.deleted) throw new RoomError("unauthorized", "Account no longer exists.");
    return seat;
  }

  private dice(m: MatchRow): DiceHandicap {
    const d: DiceHandicap = { whiteLevel: m.dice_level, rev: m.dice_rev };
    if (m.dice_by === "W" || m.dice_by === "B") d.by = m.dice_by;
    return d;
  }

  private rollRecord(r: RollRow): RollRecord {
    const out: RollRecord = {
      gameIndex: r.game_index,
      plyIndex: r.ply_index,
      player: r.player as Color,
      die1: r.die1,
      die2: r.die2,
      rolledAt: r.rolled_at,
    };
    if (r.weighted !== null) out.weighted = r.weighted;
    if (r.beta !== null) out.beta = r.beta;
    return out;
  }

  /** The snapshot as `viewer` sees it (requests addressed to the viewer only). */
  private snapshot(viewer: string | null): MatchSnapshot {
    const m = this.requireMatch();
    const seats = this.seats();
    const viewerSeat = seats.find((s) => s.player_id === viewer)?.seat;
    const last = this.sql
      .exec<RollRow>("SELECT * FROM rolls ORDER BY seq DESC LIMIT 1")
      .toArray()[0];
    const requests =
      viewerSeat === undefined
        ? []
        : this.sql
            .exec<{ id: string; from_seat: number; data: string; sent_at: number }>(
              "SELECT id, from_seat, data, sent_at FROM requests WHERE from_seat != ? ORDER BY seq",
              viewerSeat,
            )
            .toArray()
            .map(
              (r): OutOfTurnRequest => ({
                id: r.id,
                from: seats.find((s) => s.seat === r.from_seat)?.player_id ?? "unknown",
                data: r.data,
                sentAt: r.sent_at,
              }),
            );
    const current = m.current_seat === null ? null : (seats.find((s) => s.seat === m.current_seat)?.player_id ?? null);
    return {
      matchID: m.match_id,
      revision: m.revision,
      variant: m.variant as VariantID,
      targetWins: m.target_wins,
      startingPlayer: m.starting_player as Color,
      data: m.data,
      participants: seats.map((s) => ({
        playerID: s.player_id,
        displayName: s.display_name,
        color: s.color as Color,
        status: s.status as MatchSnapshot["participants"][number]["status"],
        outcome: s.outcome as MatchSnapshot["participants"][number]["outcome"],
      })),
      currentPlayerID: m.is_ended ? null : current,
      isEnded: m.is_ended === 1,
      diceHandicap: this.dice(m),
      lastRoll: last ? this.rollRecord(last) : null,
      requests,
      createdAt: m.created_at,
      updatedAt: m.updated_at,
    };
  }

  private async run<T>(op: string, fn: () => T): Promise<RoomResult<T>> {
    try {
      return { ok: true, value: fn() };
    } catch (e) {
      if (e instanceof RoomError) {
        return { ok: false, error: { code: e.code, message: e.message, ...(e.path ? { path: e.path } : {}) } };
      }
      this.log().error("room.unhandled", { op, error: e });
      return { ok: false, error: { code: "internal", message: "Something went wrong." } };
    }
  }

  /** After a committed change: lobby index + sockets. Never fails the operation. */
  private async changed(event: MatchEventName): Promise<void> {
    this.broadcast(event);
    await this.writeIndex();
  }

  // ── Operations (RPC) ──────────────────────────────────────────────────────────

  /** A new match: caller in seat 0 (White) holding the turn, `data` null, revision 0. */
  async create(input: CreateInput): Promise<RoomResult<MatchSnapshot>> {
    const result = await this.run("create", () => {
      if (this.matchRow()) throw new RoomError("bad_request", "Match exists.");
      const now = this.now();
      // House Plakoto: White always starts; the other variants draw (GameVariant.randomStartingPlayer).
      const starter: Color = input.variant === "plakoto" ? "W" : this.random.die() <= 3 ? "W" : "B";
      this.ctx.storage.transactionSync(() => {
        this.sql.exec(
          "INSERT INTO match (id, match_id, variant, target_wins, starting_player, current_seat, created_at, updated_at) " +
            "VALUES (1, ?, ?, ?, ?, 0, ?, ?)",
          input.matchID,
          input.variant,
          input.targetWins,
          starter,
          now,
          now,
        );
        this.sql.exec(
          "INSERT INTO seats (seat, player_id, display_name, color, status) VALUES (0, ?, ?, 'W', 'active')",
          input.creator.id,
          input.creator.displayName,
        );
        this.sql.exec(
          "INSERT INTO seats (seat, player_id, display_name, color, status) VALUES (1, ?, ?, 'B', ?)",
          input.opponent?.id ?? null,
          input.opponent?.displayName ?? null,
          input.opponent ? "invited" : (input.openSeat ?? "matching"),
        );
      });
      return this.snapshot(input.creator.id);
    });
    if (result.ok) {
      this.log({ match: input.matchID }).info("match.created", { variant: input.variant, targetWins: input.targetWins });
      await this.changed("created");
    }
    return result;
  }

  /** load. */
  async load(accountID: string): Promise<RoomResult<MatchSnapshot>> {
    return this.run("load", () => {
      this.requireMatch();
      this.seatOf(accountID);
      return this.snapshot(accountID);
    });
  }

  /** The invited seat joins (idempotent for an already active seat). */
  async accept(accountID: string): Promise<RoomResult<MatchSnapshot>> {
    const fx = { changed: false };
    const result = await this.run("accept", () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      if (seat.status === "active") return this.snapshot(accountID);
      if (m.is_ended || seat.status !== "invited") throw new RoomError("match_ended", "The invitation is closed.");
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("UPDATE seats SET status = 'active' WHERE seat = ?", seat.seat);
        this.touch();
      });
      fx.changed = true;
      return this.snapshot(accountID);
    });
    if (fx.changed) await this.changed("accepted");
    return result;
  }

  /**
   * #287: `player` takes the open seat 1 (auto-match or an accepted invite code) and is
   * `active` at once. Refused when the match is over, the seat is taken or `player`
   * created the match. If the creator already ended its turn, the joiner now holds it.
   */
  async join(player: PlayerRef): Promise<RoomResult<MatchSnapshot>> {
    const fx = { changed: false };
    const result = await this.run("join", () => {
      const m = this.requireMatch();
      const seats = this.seats();
      if (seats[0]?.player_id === player.id) throw new RoomError("forbidden", "You created this match.");
      const open = seats.find((s) => s.seat === 1);
      if (open?.player_id === player.id && open.status === "active") return this.snapshot(player.id);
      if (m.is_ended) throw new RoomError("match_ended", "The match is over.");
      if (!open || open.player_id !== null || (open.status !== "matching" && open.status !== "invited")) {
        throw new RoomError("forbidden", "The seat is taken.");
      }
      this.ctx.storage.transactionSync(() => {
        this.sql.exec(
          "UPDATE seats SET player_id = ?, display_name = ?, status = 'active' WHERE seat = 1",
          player.id,
          player.displayName,
        );
        this.touch();
      });
      fx.changed = true;
      return this.snapshot(player.id);
    });
    if (fx.changed) await this.changed("joined");
    return result;
  }

  /**
   * #287: the open seat's invite was declined, cancelled or expired: a match still waiting
   * for that seat ends (seat 1 `declined`, outcomes stay `none`, event `declined`).
   * A filled seat or an ended match: nothing to do (`false`).
   */
  async closeOpenSeat(): Promise<RoomResult<boolean>> {
    const fx = { changed: false };
    const result = await this.run("closeOpenSeat", () => {
      const m = this.matchRow();
      if (!m || m.is_ended) return false;
      const open = this.seats().find((s) => s.seat === 1);
      if (!open || open.player_id !== null) return false;
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("UPDATE seats SET status = 'declined' WHERE seat = 1");
        this.sql.exec("UPDATE seats SET status = 'done' WHERE seat = 0");
        this.endMatchRow();
      });
      fx.changed = true;
      return true;
    });
    if (fx.changed) await this.changed("declined");
    return result;
  }

  /** The invited seat declines: the match ends. */
  async decline(accountID: string): Promise<RoomResult<null>> {
    const fx = { changed: false };
    const result = await this.run("decline", () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      if (seat.status === "declined") return null;
      if (m.is_ended || seat.status !== "invited") throw new RoomError("match_ended", "The invitation is closed.");
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("UPDATE seats SET status = 'declined' WHERE seat = ?", seat.seat);
        this.sql.exec("UPDATE seats SET status = 'done' WHERE seat != ?", seat.seat);
        this.endMatchRow();
      });
      fx.changed = true;
      return null;
    });
    if (fx.changed) await this.changed("declined");
    return result;
  }

  /** end-turn / save-turn / end-match (REFERENCE.md "Match operations"). */
  async write(accountID: string, op: WriteOp, input: WriteInput): Promise<RoomResult<MatchSnapshot>> {
    const fx: { event?: MatchEventName } = {};
    const result = await this.run(op, () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      if (this.isRepeat(m, seat, op, input)) return this.snapshot(accountID);
      this.checkInTurnWrite(m, seat, input);
      const other = 1 - seat.seat;
      this.ctx.storage.transactionSync(() => {
        this.storeData(m, seat, op, input.data);
        if (op === "endTurn") {
          this.sql.exec("UPDATE match SET current_seat = ? WHERE id = 1", other);
          // Requests addressed to the caller are dropped once its turn ends.
          this.sql.exec("DELETE FROM requests WHERE from_seat = ?", other);
        } else if (op === "endMatch") {
          const outcome = input.outcome ?? "won";
          this.sql.exec("UPDATE seats SET outcome = ?, status = 'done' WHERE seat = ?", outcome, seat.seat);
          this.sql.exec(
            "UPDATE seats SET outcome = CASE WHEN outcome = 'quit' THEN 'quit' ELSE ? END, " +
              "status = CASE WHEN player_id IS NULL THEN status ELSE 'done' END WHERE seat = ?",
            OPPOSITE[outcome]!,
            other,
          );
          this.endMatchRow();
        }
      });
      fx.event = op === "endTurn" ? "turnEnded" : op === "saveTurn" ? "turnSaved" : "matchEnded";
      return this.snapshot(accountID);
    });
    if (fx.event) await this.changed(fx.event);
    return result;
  }

  /** quit in turn (final data) or out of turn; the opponent wins and the match ends. */
  async quit(accountID: string, input: QuitRequest): Promise<RoomResult<MatchSnapshot>> {
    const fx = { changed: false };
    const result = await this.run("quit", () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      if (input.inTurn) {
        if (input.baseRevision === undefined) throw new RoomError("bad_request", "baseRevision is required in turn.", "baseRevision");
        if (input.data === undefined) throw new RoomError("bad_request", "data is required in turn.", "data");
        const write = { baseRevision: input.baseRevision, data: input.data };
        if (this.isRepeat(m, seat, "quit", write)) return this.snapshot(accountID);
        this.checkInTurnWrite(m, seat, write);
        this.ctx.storage.transactionSync(() => {
          this.storeData(m, seat, "quit", write.data);
          this.quitSeat(seat.seat);
        });
      } else {
        if (m.is_ended) throw new RoomError("match_ended", "The match is over.");
        // #287: while the other seat is still open (auto-match, invite) the creator may
        // cancel without the final data even when holding the turn: nobody plays on.
        const otherOpen = this.seats().some((s) => s.seat !== seat.seat && s.player_id === null);
        if (m.current_seat === seat.seat && !otherOpen) {
          throw new RoomError("bad_request", "You hold the turn: quit in turn.", "inTurn");
        }
        this.ctx.storage.transactionSync(() => this.quitSeat(seat.seat));
      }
      fx.changed = true;
      return this.snapshot(accountID);
    });
    if (fx.changed) await this.changed("quit");
    return result;
  }

  /** An opaque message to the other participant, kept until the recipient's turn ends. */
  async sendRequest(accountID: string, data: string): Promise<RoomResult<{ id: string }>> {
    const fx: { sent?: OutOfTurnRequest; recipient?: string | null } = {};
    const result = await this.run("sendRequest", () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      if (m.is_ended) throw new RoomError("match_ended", "The match is over.");
      try {
        checkPayloadSize(data);
      } catch (e) {
        throw new RoomError("payload_too_large", (e as Error).message, "data");
      }
      const pending = this.sql.exec<{ n: number }>("SELECT count(*) AS n FROM requests").one().n;
      if (pending >= MAX_REQUESTS) throw new RoomError("rate_limited", "Too many pending requests.");
      const id = randomID("rq_", 9);
      const now = this.now();
      this.sql.exec(
        "INSERT INTO requests (id, from_seat, data, sent_at, seq) VALUES (?, ?, ?, ?, " +
          "(SELECT coalesce(max(seq), 0) + 1 FROM requests))",
        id,
        seat.seat,
        data,
        now,
      );
      fx.sent = { id, from: accountID, data, sentAt: now };
      fx.recipient = this.seats().find((s) => s.seat !== seat.seat)?.player_id ?? null;
      return { id };
    });
    if (fx.sent && fx.recipient) this.sendTo(fx.recipient, { type: "request", matchID: this.matchRow()!.match_id, request: fx.sent });
    return result;
  }

  /** The shared slider (#272): either player, any time; `OnlineDiceRequest.isAccepted`. */
  async changeDice(accountID: string, whiteLevel: number, baseRev: number): Promise<RoomResult<DiceHandicap>> {
    const fx = { changed: false };
    const result = await this.run("changeDice", () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      if (m.is_ended) throw new RoomError("match_ended", "The match is over.");
      const current = this.dice(m);
      if (current.whiteLevel === whiteLevel && (baseRev >= current.rev || current.by === seat.color)) return current;
      if (!(baseRev >= current.rev || current.by === seat.color)) {
        throw new RoomError("stale_revision", "The dice were changed meanwhile: reload.");
      }
      this.sql.exec(
        "UPDATE match SET dice_level = ?, dice_rev = dice_rev + 1, dice_by = ?, updated_at = ? WHERE id = 1",
        whiteLevel,
        seat.color,
        this.now(),
      );
      fx.changed = true;
      return this.dice(this.requireMatch());
    });
    if (fx.changed) await this.changed("diceChanged");
    return result;
  }

  /** The turn holder's dice for (gameIndex, plyIndex): drawn once, then the same answer. */
  async roll(accountID: string, input: RollRequest): Promise<RoomResult<RollRecord>> {
    const fx: { fresh?: RollRecord } = {};
    const result = await this.run("roll", () => {
      const m = this.requireMatch();
      const seat = this.seatOf(accountID);
      const existing = this.sql
        .exec<RollRow>("SELECT * FROM rolls WHERE game_index = ? AND ply_index = ?", input.gameIndex, input.plyIndex)
        .toArray()[0];
      if (existing) {
        if (existing.player !== seat.color) throw new RoomError("bad_request", "That ply is not yours.", "plyIndex");
        return this.rollRecord(existing);
      }
      if (m.is_ended) throw new RoomError("match_ended", "The match is over.");
      if (m.current_seat !== seat.seat) throw new RoomError("not_your_turn", "Not your turn.");
      if (seat.status !== "active") throw new RoomError("forbidden", "Accept the match first.");
      // Only the ply the game waits for: the next ply of the stored current game, or the
      // first ply of a game the caller is starting (its write may still be on the way).
      const stored = readPlyDice(m.data);
      const g = stored.length;
      const isNext =
        (input.gameIndex === g - 1 && input.plyIndex === stored[g - 1]!.length) ||
        (input.gameIndex === g && input.plyIndex === 0);
      if (!isNext) throw new RoomError("bad_request", "Not the ply the game is waiting for.", "plyIndex");
      const dice = this.dice(m);
      if (dice.whiteLevel !== 0 && !input.rollValues) {
        throw new RoomError("bad_request", "Weighted dice need the 21 roll values.", "rollValues");
      }
      const drawn = drawRoll(
        dice.whiteLevel,
        seat.color as Color,
        dice.whiteLevel === 0 ? undefined : input.rollValues,
        VARIANT_MAX_POINTS[m.variant as VariantID] ?? 1,
        this.random,
      );
      const now = this.now();
      this.sql.exec(
        "INSERT INTO rolls (game_index, ply_index, player, die1, die2, weighted, beta, roll_values, rolled_at, seq) " +
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT coalesce(max(seq), 0) + 1 FROM rolls))",
        input.gameIndex,
        input.plyIndex,
        seat.color,
        drawn.die1,
        drawn.die2,
        drawn.weighted ?? null,
        drawn.beta ?? null,
        dice.whiteLevel === 0 ? null : JSON.stringify(input.rollValues),
        now,
      );
      fx.fresh = this.rollRecord(
        this.sql
          .exec<RollRow>("SELECT * FROM rolls WHERE game_index = ? AND ply_index = ?", input.gameIndex, input.plyIndex)
          .one(),
      );
      return fx.fresh;
    });
    if (fx.fresh) {
      const roll = fx.fresh;
      this.log({ match: this.matchRow()!.match_id }).info("match.roll", {
        gameIndex: roll.gameIndex,
        plyIndex: roll.plyIndex,
        weighted: roll.weighted ?? 0,
        beta: roll.beta ?? 0,
        rollValues: roll.weighted ? input.rollValues : undefined,
      });
      this.broadcastRaw({ type: "roll", matchID: this.matchRow()!.match_id, roll });
    }
    return result;
  }

  /**
   * Account deletion hook (#285 → #286): a running match ends as the deleted player's
   * quit (the opponent wins); in every match the player is anonymised (display name
   * null) and refused from now on, and their sockets are closed. Returns the opponent's
   * account id when a running match with an accepted opponent ended (#287: "opponent left"
   * push), else null.
   */
  async accountDeleted(accountID: string): Promise<string | null> {
    const m = this.matchRow();
    if (!m) return null;
    const seats = this.seats();
    const seat = seats.find((s) => s.player_id === accountID);
    if (!seat || seat.deleted) return null;
    const wasRunning = !m.is_ended;
    const other = seats.find((s) => s.seat !== seat.seat);
    const notify = wasRunning && other?.player_id && other.status === "active" && !other.deleted ? other.player_id : null;
    this.ctx.storage.transactionSync(() => {
      if (wasRunning) this.quitSeat(seat.seat);
      this.sql.exec("UPDATE seats SET display_name = NULL, deleted = 1 WHERE seat = ?", seat.seat);
      this.touch();
    });
    for (const ws of this.ctx.getWebSockets(accountID)) {
      this.closeWith(ws, 4403, "forbidden", "Account deleted.");
    }
    await this.changed("quit");
    return notify;
  }

  // ── Write helpers ─────────────────────────────────────────────────────────────

  /**
   * Idempotent retry: the caller resends the identical write that produced the current
   * revision (same op, same bytes, built on the revision before) → answer, no change.
   */
  private isRepeat(m: MatchRow, seat: SeatRow, op: string, input: WriteInput): boolean {
    return (
      input.baseRevision === m.revision - 1 &&
      m.last_write_seat === seat.seat &&
      m.last_write_op === op &&
      m.data === input.data
    );
  }

  private checkInTurnWrite(m: MatchRow, seat: SeatRow, input: WriteInput): void {
    if (m.is_ended) throw new RoomError("match_ended", "The match is over.");
    if (m.current_seat !== seat.seat) throw new RoomError("not_your_turn", "Not your turn.");
    if (seat.status !== "active") throw new RoomError("forbidden", "Accept the match first.");
    if (input.baseRevision !== m.revision) {
      throw new RoomError("stale_revision", `baseRevision ${input.baseRevision} is not the current ${m.revision}.`);
    }
    let next: PlyDice;
    try {
      checkPayloadSize(input.data);
      next = readPlyDice(input.data);
    } catch (e) {
      if (e instanceof PayloadError && e.tooLarge) throw new RoomError("payload_too_large", e.message, "data");
      throw new RoomError("bad_request", (e as Error).message, "data");
    }
    this.verifyDice(readPlyDice(m.data), next, seat.color);
  }

  /**
   * Every ply must carry the server's roll for its (game, ply); a ply new since the last
   * write must also be the caller's own roll. Forced passes are plies too.
   */
  private verifyDice(previous: PlyDice, next: PlyDice, color: string): void {
    const rolls = new Map<string, RollRow>();
    for (const r of this.sql.exec<RollRow>("SELECT * FROM rolls").toArray()) rolls.set(`${r.game_index}/${r.ply_index}`, r);
    next.forEach((plies, g) => {
      const known = previous[g]?.length ?? 0;
      plies.forEach(([d1, d2], p) => {
        const roll = rolls.get(`${g}/${p}`);
        const where = `games[${g}].plies[${p}]`;
        if (!roll) throw new RoomError("bad_request", `${where} has no server roll.`, "data");
        const same = (roll.die1 === d1 && roll.die2 === d2) || (roll.die1 === d2 && roll.die2 === d1);
        if (!same) throw new RoomError("bad_request", `${where} dice differ from the server roll.`, "data");
        if (p >= known && roll.player !== color) {
          throw new RoomError("bad_request", `${where} was not rolled by you.`, "data");
        }
      });
    });
  }

  private storeData(m: MatchRow, seat: SeatRow, op: string, data: string): void {
    this.sql.exec(
      "UPDATE match SET data = ?, revision = ?, last_write_seat = ?, last_write_op = ?, updated_at = ? WHERE id = 1",
      data,
      m.revision + 1,
      seat.seat,
      op,
      this.now(),
    );
  }

  private touch(): void {
    this.sql.exec("UPDATE match SET updated_at = ? WHERE id = 1", this.now());
  }

  private endMatchRow(): void {
    this.sql.exec("UPDATE match SET is_ended = 1, current_seat = NULL, updated_at = ? WHERE id = 1", this.now());
    this.sql.exec("DELETE FROM requests");
  }

  /** `seat` quits: outcome quit; a filled opponent seat wins; the match ends. */
  private quitSeat(seat: number): void {
    this.sql.exec("UPDATE seats SET outcome = 'quit', status = 'done' WHERE seat = ?", seat);
    this.sql.exec(
      "UPDATE seats SET outcome = CASE WHEN player_id IS NULL OR status IN ('invited', 'declined') THEN outcome " +
        "WHEN outcome = 'quit' THEN 'quit' ELSE 'won' END, " +
        "status = CASE WHEN player_id IS NULL THEN status ELSE 'done' END WHERE seat != ?",
      seat,
    );
    this.endMatchRow();
  }

  // ── Lobby index (D1 match_index) ──────────────────────────────────────────────

  /** One row per filled, not deleted seat, from that player's point of view. */
  private async writeIndex(): Promise<void> {
    const m = this.matchRow();
    if (!m) return;
    const seats = this.seats();
    const statements = seats
      .filter((s) => s.player_id !== null && !s.deleted)
      .map((s) => {
        const other = seats.find((o) => o.seat !== s.seat)!;
        let state: string;
        if (m.is_ended || s.status === "declined" || s.status === "done") state = "ended";
        else if (s.status === "invited") state = "invited";
        else if (m.current_seat === s.seat) state = "yourTurn";
        else if (other.player_id === null || other.status === "invited" || other.status === "matching")
          state = "waitingForOpponent";
        else state = "theirTurn";
        return this.env.DB.prepare(
          "INSERT INTO match_index (match_id, account_id, opponent_id, variant, target_wins, state, outcome, created_at, updated_at) " +
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT (match_id, account_id) DO UPDATE SET opponent_id = excluded.opponent_id, " +
            "state = excluded.state, outcome = excluded.outcome, updated_at = excluded.updated_at " +
            "WHERE excluded.updated_at >= match_index.updated_at",
        ).bind(m.match_id, s.player_id, other.player_id, m.variant, m.target_wins, state, s.outcome, m.created_at, m.updated_at);
      });
    if (!statements.length) return;
    try {
      await this.env.DB.batch(statements);
    } catch (error) {
      // The room stays the source of truth; the lobby catches up with the next change.
      this.log({ match: m.match_id }).warn("match.index_failed", { error });
    }
  }

  // ── WebSocket (hibernatable) ──────────────────────────────────────────────────

  /**
   * Upgrade from the Worker, which already verified the bearer token and passes the
   * account id + token expiry in `x-tavtav-account` / `x-tavtav-token-exp`.
   */
  override async fetch(request: Request): Promise<Response> {
    const accountID = request.headers.get("x-tavtav-account") ?? "";
    const exp = Number(request.headers.get("x-tavtav-token-exp") ?? 0);
    const m = this.matchRow();
    if (!m) {
      return Response.json({ error: { code: "not_found", message: "No such match." } }, { status: 404 });
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    const seat = this.seats().find((s) => s.player_id === accountID);
    if (!seat || seat.deleted) {
      this.ctx.acceptWebSocket(server, ["refused"]);
      this.closeWith(server, 4403, "forbidden", "Not a participant.");
      return new Response(null, { status: 101, webSocket: client });
    }
    this.ctx.acceptWebSocket(server, [accountID]);
    server.serializeAttachment({ accountID, exp } satisfies SocketTag);
    server.send(JSON.stringify({ type: "hello", matchID: m.match_id, revision: m.revision, serverTime: this.now() }));
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
  }

  override async webSocketError(): Promise<void> {}

  private closeWith(ws: WebSocket, code: number, errorCode: string, message: string): void {
    try {
      ws.send(JSON.stringify({ type: "error", error: { code: errorCode, message } }));
      ws.close(code, message);
    } catch {
      // the socket is gone already
    }
  }

  /** Live sockets of `accountID` (closing any whose token expired: 4401). */
  private liveSockets(tag?: string): { ws: WebSocket; accountID: string }[] {
    const now = this.now();
    const out: { ws: WebSocket; accountID: string }[] = [];
    for (const ws of this.ctx.getWebSockets(tag)) {
      const t = ws.deserializeAttachment() as SocketTag | null;
      if (!t) continue;
      if (t.exp && t.exp <= now) {
        this.closeWith(ws, 4401, "token_expired", "Access token expired; reconnect.");
        continue;
      }
      out.push({ ws, accountID: t.accountID });
    }
    return out;
  }

  /** `match` message to every socket, each with its own viewer's snapshot. */
  private broadcast(event: MatchEventName): void {
    if (!this.matchRow()) return;
    const byAccount = new Map<string, string>();
    for (const { ws, accountID } of this.liveSockets()) {
      let text = byAccount.get(accountID);
      if (text === undefined) {
        text = JSON.stringify({ type: "match", event, match: this.snapshot(accountID) });
        byAccount.set(accountID, text);
      }
      try {
        ws.send(text);
      } catch {
        // closed meanwhile
      }
    }
  }

  private broadcastRaw(message: unknown): void {
    const text = JSON.stringify(message);
    for (const { ws } of this.liveSockets()) {
      try {
        ws.send(text);
      } catch {
        // closed meanwhile
      }
    }
  }

  private sendTo(accountID: string, message: unknown): void {
    const text = JSON.stringify(message);
    for (const { ws } of this.liveSockets(accountID)) {
      try {
        ws.send(text);
      } catch {
        // closed meanwhile
      }
    }
  }
}
