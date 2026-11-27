// The one thing the server reads from the opaque match payload (#286, REFERENCE.md
// "Server dice"): each ply's dice, `games[g].plies[p].die1 / die2`, to check them against
// the roll log. Nothing else in the `OnlineMatchPayload` is interpreted.

import { MAX_PAYLOAD_BYTES } from "./api";

/** Per game, each ply's `[die1, die2]`. */
export type PlyDice = [number, number][][];

export class PayloadError extends Error {
  constructor(
    message: string,
    readonly tooLarge = false,
  ) {
    super(message);
    this.name = "PayloadError";
  }
}

function decodeBase64(b64: string): Uint8Array {
  let bin: string;
  try {
    bin = atob(b64);
  } catch {
    throw new PayloadError("data is not base64.");
  }
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

/** Decoded size check (the schema bounds only the base64 length). */
export function checkPayloadSize(b64: string): void {
  if (decodeBase64(b64).length > MAX_PAYLOAD_BYTES) throw new PayloadError("data is over 64 KiB.", true);
}

const isDie = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v) && v >= 1 && v <= 6;

/** The plies' dice of a base64 `OnlineMatchPayload` (null data = no games). */
export function readPlyDice(b64: string | null): PlyDice {
  if (b64 === null) return [];
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(decodeBase64(b64)));
  } catch (e) {
    if (e instanceof PayloadError) throw e;
    throw new PayloadError("data is not a JSON match payload.");
  }
  const games = (payload as { games?: unknown } | null)?.games;
  if (games === undefined) {
    // A v1 payload (flat `plies`) is one game; the server never sees one, but read it.
    const plies = (payload as { plies?: unknown } | null)?.plies;
    return plies === undefined ? [] : [readPlies(plies, 0)];
  }
  if (!Array.isArray(games)) throw new PayloadError("data.games is not a list.");
  return games.map((g, i) => readPlies((g as { plies?: unknown } | null)?.plies ?? [], i));
}

function readPlies(plies: unknown, game: number): [number, number][] {
  if (!Array.isArray(plies)) throw new PayloadError(`data.games[${game}].plies is not a list.`);
  return plies.map((ply, p) => {
    const d1 = (ply as { die1?: unknown } | null)?.die1;
    const d2 = (ply as { die2?: unknown } | null)?.die2;
    if (!isDie(d1) || !isDie(d2)) throw new PayloadError(`data.games[${game}].plies[${p}] has no valid dice.`);
    return [d1, d2];
  });
}
