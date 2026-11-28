// Universal links (#287, REFERENCE.md "Universal links"): the Apple App Site Association
// file that lets the app open `https://<worker host>/join/<code>`, and the small web page
// that link shows when the app is not installed (or the link is opened in a browser):
// who invites, the code to type in the app, and the App Store link. Light + dark Caramel
// colours, English / German / Dutch / Greek by Accept-Language. No scripts, no cookies.

import type { VariantID } from "./api";
import { inviteDeps, loadInvite, normalizeInviteCode } from "./invites";
import type { RouteContext } from "./routes";

/** Team id + bundle id of the app (`TavliApp.entitlements` Associated Domains). */
export const APP_ID = "8XRKL83C4V.com.plakoto.TavliApp";
export const APP_STORE_ID = "6838396758";
export const APP_STORE_URL = `https://apps.apple.com/app/id${APP_STORE_ID}`;

export const AASA = {
  applinks: {
    details: [{ appIDs: [APP_ID], components: [{ "/": "/join/*", comment: "Invite links (#287)" }] }],
  },
} as const;

/** GET /.well-known/apple-app-site-association — JSON, no redirect, cacheable. */
export function appSiteAssociation(): Response {
  return new Response(JSON.stringify(AASA), {
    headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" },
  });
}

export type PageLanguage = "en" | "de" | "nl" | "el";

/** The best of our page languages for an Accept-Language header (q-values honoured). */
export function pageLanguage(header: string | null): PageLanguage {
  const supported: PageLanguage[] = ["en", "de", "nl", "el"];
  const ranked = (header ?? "")
    .split(",")
    .map((part, i) => {
      const [tag, ...params] = part.trim().split(";");
      const q = params.map((p) => p.trim()).find((p) => p.startsWith("q="));
      return { lang: (tag ?? "").trim().toLowerCase().split("-")[0] ?? "", q: q ? Number(q.slice(2)) : 1, i };
    })
    .filter((x) => x.lang && Number.isFinite(x.q) && x.q > 0)
    .sort((a, b) => b.q - a.q || a.i - b.i);
  for (const { lang } of ranked) {
    if ((supported as string[]).includes(lang)) return lang as PageLanguage;
  }
  return "en";
}

interface Copy {
  title: string;
  invites: (name: string, game: string) => string;
  invitesNoName: string;
  bestOfThree: string;
  singleGame: string;
  haveApp: string;
  codeLabel: string;
  steps: string;
  getApp: string;
  closed: string;
  unknown: string;
}

const VARIANT_NAMES: Record<PageLanguage, Record<VariantID, string>> = {
  en: { plakoto: "Plakoto (house rules)", plakoto_standard: "Plakoto", fevga: "Fevga", portes: "Portes" },
  de: { plakoto: "Plakoto (Hausregeln)", plakoto_standard: "Plakoto", fevga: "Fevga", portes: "Portes" },
  nl: { plakoto: "Plakoto (huisregels)", plakoto_standard: "Plakoto", fevga: "Fevga", portes: "Portes" },
  el: { plakoto: "Πλακωτό (κανόνες του σπιτιού)", plakoto_standard: "Πλακωτό", fevga: "Φεύγα", portes: "Πόρτες" },
};

const COPY: Record<PageLanguage, Copy> = {
  en: {
    title: "You’re invited to Tavtav",
    invites: (n, g) => `${n} invites you to a game of ${g}.`,
    invitesNoName: "You’re invited to a game of tavli.",
    bestOfThree: "Best of 3",
    singleGame: "Single game",
    haveApp: "Already have Tavtav? Open this link on your iPhone or iPad, or type the code in the app:",
    codeLabel: "Invite code",
    steps: "Play Online → Join with a code",
    getApp: "Get Tavtav on the App Store",
    closed: "This invite isn’t open any more. Ask your friend for a new one.",
    unknown: "This invite link isn’t valid. Check the link or ask your friend for a new one.",
  },
  de: {
    title: "Einladung zu Tavtav",
    invites: (n, g) => `${n} lädt dich zu einer Partie ${g} ein.`,
    invitesNoName: "Du bist zu einer Partie Tavli eingeladen.",
    bestOfThree: "Best of 3",
    singleGame: "Einzelspiel",
    haveApp: "Du hast Tavtav schon? Öffne diesen Link auf deinem iPhone oder iPad oder gib den Code in der App ein:",
    codeLabel: "Einladungscode",
    steps: "Online spielen → Mit Code beitreten",
    getApp: "Tavtav im App Store laden",
    closed: "Diese Einladung ist nicht mehr offen. Bitte um eine neue.",
    unknown: "Dieser Einladungslink ist ungültig. Prüfe den Link oder bitte um einen neuen.",
  },
  nl: {
    title: "Uitnodiging voor Tavtav",
    invites: (n, g) => `${n} nodigt je uit voor een potje ${g}.`,
    invitesNoName: "Je bent uitgenodigd voor een potje tavli.",
    bestOfThree: "Best of 3",
    singleGame: "Eén spel",
    haveApp: "Heb je Tavtav al? Open deze link op je iPhone of iPad, of typ de code in de app:",
    codeLabel: "Uitnodigingscode",
    steps: "Online spelen → Meedoen met code",
    getApp: "Download Tavtav in de App Store",
    closed: "Deze uitnodiging is niet meer open. Vraag om een nieuwe.",
    unknown: "Deze uitnodigingslink is ongeldig. Controleer de link of vraag om een nieuwe.",
  },
  el: {
    title: "Πρόσκληση στο Tavtav",
    invites: (n, g) => `Πρόσκληση από ${n} για μια παρτίδα ${g}.`,
    invitesNoName: "Έχεις πρόσκληση για μια παρτίδα τάβλι.",
    bestOfThree: "Στις 2 νίκες",
    singleGame: "Μία παρτίδα",
    haveApp: "Έχεις ήδη το Tavtav; Άνοιξε αυτόν τον σύνδεσμο στο iPhone ή στο iPad σου ή γράψε τον κωδικό στην εφαρμογή:",
    codeLabel: "Κωδικός πρόσκλησης",
    steps: "Παιχνίδι online → Συμμετοχή με κωδικό",
    getApp: "Κατέβασε το Tavtav από το App Store",
    closed: "Αυτή η πρόσκληση δεν είναι πια ανοιχτή. Ζήτα μια καινούρια.",
    unknown: "Αυτός ο σύνδεσμος πρόσκλησης δεν ισχύει. Έλεγξε τον σύνδεσμο ή ζήτα έναν καινούριο.",
  },
};

export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export interface JoinPageInput {
  lang: PageLanguage;
  /** The normalized code, or null for a malformed one. */
  code: string | null;
  /** The invite as stored; absent = unknown code. */
  invite?: { creatorName: string | null; variant: string; targetWins: number; status: string };
  url: string;
}

/** The fallback page's HTML (pure, for tests). */
export function joinPage(input: JoinPageInput): string {
  const t = COPY[input.lang];
  const inv = input.invite;
  const open = inv?.status === "open";
  const variant = inv ? (VARIANT_NAMES[input.lang][inv.variant as VariantID] ?? inv.variant) : "";
  const lead = !inv
    ? t.unknown
    : !open
      ? t.closed
      : inv.creatorName
        ? t.invites(inv.creatorName, variant)
        : t.invitesNoName;
  const length = inv && open ? (inv.targetWins === 2 ? t.bestOfThree : t.singleGame) : "";
  const code = input.code && open ? input.code : null;
  const banner = code
    ? `<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}, app-argument=${escapeHtml(input.url)}">`
    : `<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}">`;
  return `<!doctype html>
<html lang="${input.lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
${banner}
<title>${escapeHtml(t.title)}</title>
<style>
:root{--page:#ece6dc;--card:#f6f0e3;--ink:#3a2510;--ink2:rgba(58,37,16,.72);--accent:#a87a3e;--on-accent:#fff;--frame-top:#e8c089;--frame-bot:#a87a3e;--play:#8a4a22;--code-bg:#fbeed1;--shadow:rgba(0,0,0,.10);--edge:transparent}
@media (prefers-color-scheme:dark){:root{--page:#0e0805;--card:#1d130b;--ink:#f4d7a4;--ink2:#cf9f62;--accent:#e09a42;--on-accent:#140a02;--frame-top:#6e4526;--frame-bot:#341c0c;--play:#1f110a;--code-bg:#2b1c10;--shadow:rgba(0,0,0,.35);--edge:rgba(255,190,110,.08)}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;background:var(--page);color:var(--ink);font:17px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;display:flex;align-items:center;justify-content:center;padding:24px 16px}
main{width:100%;max-width:440px;text-align:center}
.mark{width:72px;height:72px;margin:0 auto 18px;display:block;filter:drop-shadow(0 6px 12px var(--shadow))}
h1{font-family:"Cormorant Garamond",Georgia,"Times New Roman",serif;font-weight:600;font-size:40px;line-height:1.1;margin:0 0 20px;letter-spacing:.01em}
.card{background:var(--card);border-radius:16px;padding:24px 20px;box-shadow:0 4px 14px var(--shadow);border:1px solid var(--edge)}
.lead{font-size:20px;font-weight:600;margin:0}
.meta{color:var(--ink2);margin:6px 0 0}
.how{color:var(--ink2);margin:22px 0 10px;font-size:15px}
.code{font:600 32px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.22em;padding:14px 12px 14px 18px;border-radius:12px;background:var(--code-bg);display:inline-block;user-select:all;-webkit-user-select:all}
.label{display:block;font-size:13px;color:var(--ink2);margin-top:8px}
.steps{font-size:15px;margin:10px 0 0}
.store{display:block;margin-top:22px;padding:14px 18px;min-height:44px;border-radius:12px;background:var(--accent);color:var(--on-accent);font-weight:600;text-decoration:none}
.store:focus-visible{outline:3px solid var(--ink);outline-offset:2px}
</style>
</head>
<body>
<main>
<svg class="mark" viewBox="0 0 72 72" aria-hidden="true"><defs><linearGradient id="f" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="var(--frame-top)"/><stop offset="1" stop-color="var(--frame-bot)"/></linearGradient></defs><rect width="72" height="72" rx="18" fill="url(#f)"/><rect x="10" y="10" width="52" height="52" rx="8" fill="var(--play)"/><path d="M14 58 L21 22 L28 58 Z M29 58 L36 18 L43 58 Z M44 58 L51 22 L58 58 Z" fill="var(--code-bg)"/></svg>
<h1>Tavtav</h1>
<div class="card">
<p class="lead">${escapeHtml(lead)}</p>
${length ? `<p class="meta">${escapeHtml(length)}</p>` : ""}
${
  code
    ? `<p class="how">${escapeHtml(t.haveApp)}</p>
<div class="code" aria-label="${escapeHtml(t.codeLabel)}">${escapeHtml(code)}</div>
<span class="label">${escapeHtml(t.codeLabel)}</span>
<p class="steps">${escapeHtml(t.steps)}</p>`
    : ""
}
<a class="store" href="${APP_STORE_URL}">${escapeHtml(t.getApp)}</a>
</div>
</main>
</body>
</html>
`;
}

/** GET /join/{code} — the invite link's page when the app does not open it. */
export async function joinFallback(rc: RouteContext): Promise<Response> {
  const lang = pageLanguage(rc.request.headers.get("accept-language"));
  const code = normalizeInviteCode(rc.params.code ?? "");
  const row = code ? await loadInvite(rc.env, code, inviteDeps.now()) : null;
  const html = joinPage({
    lang,
    code,
    url: rc.url.toString(),
    ...(row
      ? { invite: { creatorName: row.creator_name, variant: row.variant, targetWins: row.target_wins, status: row.status } }
      : {}),
  });
  return new Response(html, {
    status: row ? 200 : 404,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-language": lang,
      vary: "Accept-Language",
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      "referrer-policy": "no-referrer",
      "x-content-type-options": "nosniff",
    },
  });
}
