// #287 universal links: the AASA file and the /join/{code} fallback page (languages,
// invite states, escaping, headers).
import { exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Invite } from "../src/api";
import { AASA, APP_STORE_URL, escapeHtml, joinPage, pageLanguage } from "../src/web";
import { call, ok, player } from "./lobby-helpers";

beforeEach(() => {
  vi.spyOn(console, "log").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());

const get = (path: string, headers: Record<string, string> = {}) =>
  exports.default.fetch(`https://tavtav-server-staging.tavtav.workers.dev${path}`, {
    headers: { "cf-connecting-ip": `10.9.${Math.floor(Math.random() * 250)}.1`, ...headers },
  });

describe("apple-app-site-association", () => {
  it("serves the app's /join/* paths as JSON, without a redirect", async () => {
    const res = await get("/.well-known/apple-app-site-association");
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");
    expect(res.headers.get("cache-control")).toBe("public, max-age=3600");
    const body = await res.json();
    expect(body).toEqual({
      applinks: {
        details: [{ appIDs: ["8XRKL83C4V.com.plakoto.TavliApp"], components: [{ "/": "/join/*", comment: "Invite links (#287)" }] }],
      },
    });
    expect(body).toEqual(JSON.parse(JSON.stringify(AASA)));
  });
});

describe("join page", () => {
  it("picks en / de / nl / el from Accept-Language (q-values), else English", () => {
    expect(pageLanguage(null)).toBe("en");
    expect(pageLanguage("de-DE,de;q=0.9,en;q=0.8")).toBe("de");
    expect(pageLanguage("fr-FR, nl;q=0.5, en;q=0.4")).toBe("nl");
    expect(pageLanguage("en;q=0.2, el-GR;q=0.9")).toBe("el");
    expect(pageLanguage("fa-IR")).toBe("en");
    expect(pageLanguage("de;q=0, nl")).toBe("nl");
  });

  it("shows who invites, the code and the App Store link, in the reader's language", async () => {
    const a = await player("Alex");
    const inv = await ok(await call("POST", "/v1/invites", { variant: "fevga", targetWins: 2 }, a.token), Invite, 201);
    const en = await get(`/join/${inv.code}`);
    expect(en.status).toBe(200);
    expect(en.headers.get("content-type")).toBe("text/html; charset=utf-8");
    expect(en.headers.get("content-security-policy")).toContain("default-src 'none'");
    const html = await en.text();
    expect(html).toContain("Alex invites you to a game of Fevga.");
    expect(html).toContain("Best of 3");
    expect(html).toContain(`>${inv.code}<`);
    expect(html).toContain(`href="${APP_STORE_URL}"`);
    expect(html).toContain('content="app-id=6838396758, app-argument=');
    expect(html).not.toContain("<script");

    const el = await (await get(`/join/${inv.code.toLowerCase()}`, { "accept-language": "el-GR" })).text();
    expect(el).toContain('lang="el"');
    expect(el).toContain("Πρόσκληση από Alex για μια παρτίδα Φεύγα.");
    const de = await (await get(`/join/${inv.code}`, { "accept-language": "de" })).text();
    expect(de).toContain("Alex lädt dich zu einer Partie Fevga ein.");
    const nl = await (await get(`/join/${inv.code}`, { "accept-language": "nl-BE" })).text();
    expect(nl).toContain("Alex nodigt je uit voor een potje Fevga.");
  });

  it("says so for an unknown code (404) or a closed invite (no code shown)", async () => {
    const unknown = await get("/join/ZZZZZZ");
    expect(unknown.status).toBe(404);
    expect(await unknown.text()).toContain("This invite link isn’t valid.");
    expect((await get("/join/%3Cscript%3E")).status).toBe(404);

    const a = await player("Alex");
    const inv = await ok(await call("POST", "/v1/invites", { variant: "portes", targetWins: 1 }, a.token), Invite, 201);
    expect((await call("DELETE", `/v1/invites/${inv.code}`, undefined, a.token)).status).toBe(204);
    const closed = await (await get(`/join/${inv.code}`)).text();
    expect(closed).toContain("This invite isn’t open any more.");
    expect(closed).not.toContain(`>${inv.code}<`);
  });

  it("escapes names", () => {
    expect(escapeHtml(`<b>"Sam" & 'Bob'</b>`)).toBe("&lt;b&gt;&quot;Sam&quot; &amp; &#39;Bob&#39;&lt;/b&gt;");
    const html = joinPage({
      lang: "en",
      code: "K7Q4MZ",
      url: "https://x/join/K7Q4MZ",
      invite: { creatorName: "<img src=x>", variant: "plakoto", targetWins: 1, status: "open" },
    });
    expect(html).toContain("&lt;img src=x&gt; invites you to a game of Plakoto (house rules).");
    expect(html).toContain("Single game");
    expect(html).not.toContain("<img");
  });
});
