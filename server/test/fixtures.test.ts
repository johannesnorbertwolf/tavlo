// Shared contract fixtures (server/fixtures/*.json): each must decode with its schema
// here and with its Codable mirror in Swift (ServerAPITests). Every fixture file must
// be listed below, so a new one cannot slip in untested.
import { describe, expect, it } from "vitest";
import * as api from "../src/api";
import { array, type Schema } from "../src/schema";

const files = import.meta.glob<unknown>("../fixtures/*.json", { eager: true, import: "default" });
const fixture = (name: string): unknown => {
  const value = files[`../fixtures/${name}`];
  if (value === undefined) throw new Error(`missing fixture ${name}`);
  return value;
};

const SCHEMAS: Record<string, Schema<unknown>> = {
  "health.json": api.HealthResponse,
  "error-stale-revision.json": api.ApiError,
  "error-rate-limited.json": api.ApiError,
  "apple-sign-in-request.json": api.AppleSignInRequest,
  "google-sign-in-request.json": api.GoogleSignInRequest,
  "refresh-request.json": api.RefreshRequest,
  "auth-session.json": api.AuthSession,
  "update-account-request.json": api.UpdateAccountRequest,
  "match-snapshot.json": api.MatchSnapshot,
  "match-snapshot-new.json": api.MatchSnapshot,
  "match-list.json": api.MatchListResponse,
  "create-match-request.json": api.CreateMatchRequest,
  "write-turn-request.json": api.WriteTurnRequest,
  "end-match-request.json": api.EndMatchRequest,
  "quit-request.json": api.QuitRequest,
  "send-request-request.json": api.SendRequestRequest,
  "dice-change-request.json": api.DiceChangeRequest,
  "roll-request.json": api.RollRequest,
  "roll-record.json": api.RollRecord,
  "create-invite-request.json": api.CreateInviteRequest,
  "invite.json": api.Invite,
  "invite-preview.json": api.InvitePreview,
  "auto-match-request.json": api.AutoMatchRequest,
  "push-token-request.json": api.PushTokenRequest,
  "ws-messages.json": array(api.ServerMessage),
};

const decodeBase64Json = (b64: string): unknown =>
  JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));

describe("shared fixtures", () => {
  it("every fixture file has a schema", () => {
    const names = Object.keys(files).map((p) => p.replace("../fixtures/", "")).sort();
    expect(names).toEqual(Object.keys(SCHEMAS).sort());
  });

  for (const [name, schema] of Object.entries(SCHEMAS)) {
    it(`${name} decodes`, () => {
      expect(() => schema.parse(fixture(name))).not.toThrow();
    });
  }

  it("the snapshot's data is an OnlineMatchPayload the app can read", () => {
    const snap = api.MatchSnapshot.parse(fixture("match-snapshot.json"));
    const payload = decodeBase64Json(snap.data!) as Record<string, unknown>;
    expect(payload.schemaVersion).toBe(2);
    expect(payload.variant).toBe(snap.variant);
    expect(payload.startingPlayer).toBe(snap.startingPlayer);
    expect(Object.keys(payload.colorByPlayerID as object).sort()).toEqual(
      snap.participants.map((p) => p.playerID).sort(),
    );
  });

  it("drops unknown keys and keeps absent optionals absent", () => {
    const snap = api.MatchSnapshot.parse(fixture("match-snapshot-new.json"));
    expect(snap).not.toHaveProperty("futureField");
    expect(snap.diceHandicap).toEqual({ whiteLevel: 0, rev: 0 });
    expect(snap.participants[1]!.playerID).toBeNull();
  });

  it("tags WebSocket messages by type", () => {
    const msgs = array(api.ServerMessage).parse(fixture("ws-messages.json"));
    expect(msgs.map((m) => m.type)).toEqual(["hello", "match", "roll", "request", "error"]);
  });
});

describe("request validation", () => {
  const roll = fixture("roll-request.json") as { rollValues: number[] };

  it("needs exactly 21 roll values in [0, 1]", () => {
    expect(api.RollRequest.parse(roll).rollValues).toHaveLength(api.ROLL_COUNT);
    expect(() => api.RollRequest.parse({ ...roll, rollValues: roll.rollValues.slice(1) })).toThrow(/fewer than 21/);
    expect(() => api.RollRequest.parse({ ...roll, rollValues: [...roll.rollValues, 0.5] })).toThrow(/more than 21/);
    expect(() => api.RollRequest.parse({ ...roll, rollValues: [1.5, ...roll.rollValues.slice(1)] })).toThrow(
      /rollValues\[0\]: above 1/,
    );
    expect(() => api.RollRequest.parse({ gameIndex: 0, plyIndex: 0 })).not.toThrow();
  });

  it("clamps the dice slider to ±4 and rejects unknown variants", () => {
    expect(() => api.DiceChangeRequest.parse({ whiteLevel: 5, baseRev: 0 })).toThrow(/whiteLevel/);
    expect(() => api.CreateMatchRequest.parse({ variant: "chess", targetWins: 1 })).toThrow(/variant/);
    expect(() => api.CreateMatchRequest.parse({ variant: "fevga", targetWins: 3 })).toThrow(/targetWins/);
  });

  it("rejects non-base64 payloads and oversized ones", () => {
    expect(() => api.WriteTurnRequest.parse({ baseRevision: 1, data: "not base64!" })).toThrow(/data/);
    const big = "A".repeat(Math.ceil(api.MAX_PAYLOAD_BYTES / 3) * 4 + 4);
    expect(() => api.WriteTurnRequest.parse({ baseRevision: 1, data: big })).toThrow(/longer than/);
  });

  it("knows every variant's points", () => {
    expect(api.VARIANT_MAX_POINTS).toEqual({ plakoto: 1, plakoto_standard: 2, fevga: 2, portes: 2 });
  });
});
