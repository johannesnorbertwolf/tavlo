import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { ApiError } from "../src/api";
import { ROUTES } from "../src/index";
import { CONTRACT_ROUTES, Router } from "../src/routes";

const sample = (path: string) => path.replace(/:[A-Za-z]+/g, "x1");

describe("route table", () => {
  it("has no duplicate method + path", () => {
    const keys = CONTRACT_ROUTES.map((r) => `${r.method} ${r.path}`);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("matches path parameters", () => {
    const router = new Router(CONTRACT_ROUTES);
    expect(router.match("POST", "/v1/matches/m_123/end-turn")).toMatchObject({
      kind: "found",
      params: { matchID: "m_123" },
    });
    expect(router.match("GET", "/v1/matches/m_123/end-turn")).toEqual({ kind: "wrong_method", allow: ["POST"] });
    expect(router.match("GET", "/v1/matches/a/b/c")).toEqual({ kind: "none" });
    expect(router.match("HEAD", "/health")).toMatchObject({ kind: "found" });
  });

  // Every not-yet-built endpoint answers 501 naming its ticket (the contract is live).
  for (const route of ROUTES.filter((r) => !r.handler)) {
    it(`${route.method} ${route.path} → 501 (${route.ticket})`, async () => {
      const res = await exports.default.fetch(`https://server.test${sample(route.path)}`, {
        method: route.method,
      });
      expect(res.status).toBe(501);
      const body = ApiError.parse(await res.json());
      expect(body.error).toMatchObject({ code: "not_implemented", ticket: route.ticket });
    });
  }
});
