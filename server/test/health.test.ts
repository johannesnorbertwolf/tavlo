import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { API_VERSION, ApiError, HealthResponse } from "../src/api";
import { SERVER_VERSION } from "../src/version";
import pkg from "../package.json";

const call = (path: string, init?: RequestInit) => exports.default.fetch(`https://server.test${path}`, init);

describe("GET /health", () => {
  it("answers with version, commit and environment", async () => {
    const res = await call("/health");
    expect(res.status).toBe(200);
    const body = HealthResponse.parse(await res.json());
    expect(body).toMatchObject({
      status: "ok",
      service: "tavtav-server",
      version: SERVER_VERSION,
      commit: "dev",
      environment: "development",
      apiVersion: API_VERSION,
    });
    expect(body.checks).toBeUndefined();
    expect(Math.abs(body.time - Date.now())).toBeLessThan(60_000);
  });

  it("carries the standard headers", async () => {
    const res = await call("/health", { headers: { "cf-ray": "abc123-FRA" } });
    expect(res.headers.get("x-request-id")).toBe("abc123-FRA");
    expect(res.headers.get("x-tavtav-api")).toBe(String(API_VERSION));
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("content-type")).toMatch(/^application\/json/);
  });

  it("checks D1 and the Durable Object namespace with ?deep=1", async () => {
    const res = await call("/health?deep=1");
    expect(res.status).toBe(200);
    const body = HealthResponse.parse(await res.json());
    expect(body.checks).toEqual({ d1: "ok", durableObjects: "ok" });
  });

  it("keeps SERVER_VERSION in step with package.json", () => {
    expect(SERVER_VERSION).toBe(pkg.version);
  });
});

describe("errors", () => {
  it("unknown path → 404 in the error format", async () => {
    const res = await call("/nope");
    expect(res.status).toBe(404);
    const body = ApiError.parse(await res.json());
    expect(body.error.code).toBe("not_found");
    expect(body.error.requestId).toBe(res.headers.get("x-request-id"));
  });

  it("wrong method → 405 with Allow", async () => {
    const res = await call("/health", { method: "POST" });
    expect(res.status).toBe(405);
    expect(res.headers.get("allow")).toBe("GET");
    expect(ApiError.parse(await res.json()).error.code).toBe("method_not_allowed");
  });
});
