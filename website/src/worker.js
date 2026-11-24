// deadbolt.osborne.vc Worker: invite requests (public form) and a small admin API. Everything else is static (./public).
//
//   POST /api/request                 public: {email, platforms[], note, company(honeypot), ts}. Always answers {ok:true}
//                                     (no hint whether an address was already there, or filtered as a bot).
//   POST /api/admin/login             {key} -> sets a signed, HttpOnly session cookie (12 h)
//   POST /api/admin/logout
//   GET  /api/admin/requests          list + counts + the saved reply template
//   POST /api/admin/requests/:id      {action: approve | reject | pending | delete}
//   PUT  /api/admin/template          {text}
//   POST /api/admin/links             {label, days, max}  a standalone download link (e.g. for store reviewers)
//   POST /api/admin/links/:id         {action: revoke | delete}
//   GET  /d/<token>                   a page with a Download button (a mail scanner opening the link uses nothing up)
//   POST /d/<token>                   streams the DMG from KV and counts one download; links expire and have a download limit
//
// Download links: only a SHA-256 of the token is stored. Approving a request makes a link (7 days, 5 downloads); the full
// URL is shown to the admin once, at creation ("New link" makes another and revokes the old one).
//
// Stored per request: email, devices, optional note, status, timestamps. No IP address, user agent or cookie is stored.
// Daily cron: rejected requests are deleted after 30 days, never-handled ones after 90, download links 30 days after they expire.

const DAY = 24 * 3600 * 1000;
const SESSION_MS = 12 * 3600 * 1000;
const PLATFORMS = ["iphone", "mac", "chrome"];
const EMAIL = /^[^\s@<>"',;:()[\]\\]{1,64}@[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?\.[a-z]{2,}$/i;
const COOKIE = "__Host-dbadmin";
const DMG_KEY = "Deadbolt.dmg";
const HOSTS = new Set(["deadbolt.osborne.vc", "localhost", "127.0.0.1"]);

const json = (obj, status = 200, headers = {}) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store", ...headers } });

const enc = new TextEncoder();
const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
async function hmac(secret, text) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(text)));
}
/** Compares two strings in constant time by comparing their HMACs under a throwaway key. */
async function same(a, b) {
  const k = hex(crypto.getRandomValues(new Uint8Array(16)));
  return (await hmac(k, a)) === (await hmac(k, b));
}

async function readJson(request, limit = 8192) {
  if (!(request.headers.get("content-type") || "").toLowerCase().startsWith("application/json")) return null;
  const text = await request.text();
  if (text.length > limit) return null;
  try { const v = JSON.parse(text); return v && typeof v === "object" ? v : null; } catch { return null; }
}

/** A browser form on our own origin, not another site posting to us. */
function sameOrigin(request, url) {
  const o = request.headers.get("origin");
  return !o || o === url.origin;
}

async function session(request, env) {
  if (!env.ADMIN_KEY) return false;
  const m = (request.headers.get("cookie") || "").match(new RegExp(`(?:^|; )${COOKIE}=([0-9]+)\\.([0-9a-f]{64})`));
  if (!m || Number(m[1]) < Date.now()) return false;
  return same(m[2], await hmac(env.ADMIN_KEY, `deadbolt-admin:${m[1]}`));
}

const b64url = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const sha256hex = async (text) => hex(await crypto.subtle.digest("SHA-256", enc.encode(text)));
const clamp = (n, lo, hi, dflt) => { n = Math.floor(Number(n)); return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt; };

/** A new personal download link. Returns the full URL (the only time the token exists in readable form). */
async function makeLink(env, origin, { requestId = null, label = null, days = 7, max = 5 } = {}) {
  const token = b64url(crypto.getRandomValues(new Uint8Array(24)));
  const now = Date.now();
  await env.DB.prepare("INSERT INTO links (request_id, label, token_hash, created_at, expires_at, max_downloads) VALUES (?, ?, ?, ?, ?, ?)")
    .bind(requestId, label, await sha256hex(token), now, now + clamp(days, 1, 60, 7) * DAY, clamp(max, 1, 100, 5)).run();
  return `${origin}/d/${token}`;
}

const page = (title, body, status = 200) => new Response(
  `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow"><meta name="color-scheme" content="dark"><title>${title}</title><link rel="icon" type="image/png" href="/favicon.png"><link rel="stylesheet" href="/legal.css"></head><body><main style="padding-top:90px;text-align:center"><img src="/logo.png" alt="" width="64" height="64" style="border-radius:16px"><h1 style="font-size:32px;margin-top:18px">${title}</h1>${body}</main></body></html>`,
  { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-robots-tag": "noindex, nofollow", "referrer-policy": "no-referrer" } });

/** Looks a token up by its hash. Returns the row only while the link can still be used. */
async function liveLink(env, token) {
  const row = await env.DB.prepare("SELECT id, expires_at, max_downloads, downloads, revoked FROM links WHERE token_hash = ?").bind(await sha256hex(token)).first();
  return row && !row.revoked && row.expires_at > Date.now() && row.downloads < row.max_downloads ? row : null;
}

async function download(request, env, url, token, limited) {
  if (await limited(env.DOWNLOAD_LIMIT)) return page("Slow down", "<p>Too many tries. Wait a minute.</p>", 429);
  const gone = () => page("This link has ended", "<p>It has expired or been used up. Ask for a new one.</p>", 410);
  if (request.method === "GET") {
    const l = await liveLink(env, token);
    if (!l) return gone();
    const left = l.max_downloads - l.downloads, days = Math.max(1, Math.ceil((l.expires_at - Date.now()) / DAY));
    return page("Deadbolt for Mac", `<p>macOS 15 or later · notarized by Apple</p><form method="post"><button class="go" style="background:#D4AF6A;color:#1A1408;border:0;border-radius:12px;font:inherit;font-weight:700;padding:14px 28px;cursor:pointer" type="submit">Download</button></form><p class="meta" style="margin-top:22px">This personal link works ${left} more time${left === 1 ? "" : "s"} and expires in ${days} day${days === 1 ? "" : "s"}. Please don’t share it.</p>`);
  }
  if (request.method !== "POST") return page("Not found", "", 405);
  // One atomic step: count the download only if the link is still good, so two clicks can't both get the last one.
  const r = await env.DB.prepare("UPDATE links SET downloads = downloads + 1 WHERE token_hash = ? AND revoked = 0 AND expires_at > ? AND downloads < max_downloads")
    .bind(await sha256hex(token), Date.now()).run();
  if (r.meta.changes !== 1) return gone();
  const { value, metadata } = await env.DMG.getWithMetadata(DMG_KEY, { type: "stream" });
  if (!value) {
    await env.DB.prepare("UPDATE links SET downloads = downloads - 1 WHERE token_hash = ?").bind(await sha256hex(token)).run();
    return page("Not available yet", "<p>The download isn’t ready. Please try again later.</p>", 503);
  }
  const name = String(metadata?.filename || "Deadbolt.dmg").replace(/[^A-Za-z0-9._-]/g, "_");
  const headers = { "content-type": "application/x-apple-diskimage", "content-disposition": `attachment; filename="${name}"`, "cache-control": "no-store", "x-content-type-options": "nosniff" };
  if (Number(metadata?.size) > 0) headers["content-length"] = String(metadata.size);
  return new Response(value, { headers });
}

const clean = (s, max) => String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, max);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (!HOSTS.has(url.hostname)) return json({ error: "Not found" }, 404);
    const ip = request.headers.get("cf-connecting-ip") ?? "local";
    const limited = async (limiter) => limiter && !(await limiter.limit({ key: ip })).success;
    const dl = url.pathname.match(/^\/d\/([A-Za-z0-9_-]{20,64})$/);
    if (dl) return download(request, env, url, dl[1], limited);
    if (!url.pathname.startsWith("/api/")) return env.ASSETS.fetch(request);

    // ---- public: request an invite ----
    if (url.pathname === "/api/request") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      if (!sameOrigin(request, url)) return json({ error: "Forbidden" }, 403);
      if (await limited(env.REQUEST_LIMIT)) return json({ error: "Too many requests. Try again in a minute." }, 429);
      const body = await readJson(request);
      if (!body) return json({ error: "Bad request" }, 400);

      const email = clean(body.email, 254).toLowerCase();
      if (!EMAIL.test(email)) return json({ error: "Enter a valid email address." }, 400);
      const platforms = [...new Set((Array.isArray(body.platforms) ? body.platforms : []).map((p) => String(p).toLowerCase()).filter((p) => PLATFORMS.includes(p)))];
      if (!platforms.length) return json({ error: "Choose at least one device." }, 400);
      const note = clean(body.note, 500);

      // Bots: a hidden field people never see, and a form submitted faster than anyone can type. Both answer "ok" and store nothing.
      const tooFast = !Number.isFinite(Number(body.ts)) || Date.now() - Number(body.ts) < 2000;
      if (clean(body.company, 50) || tooFast) return json({ ok: true });

      // Flood guard: never more than 200 new requests an hour, whoever sends them.
      const recent = await env.DB.prepare("SELECT COUNT(*) AS n FROM requests WHERE created_at > ?").bind(Date.now() - 3600 * 1000).first();
      if ((recent?.n ?? 0) >= 200) return json({ ok: true });

      await env.DB.prepare("INSERT OR IGNORE INTO requests (email, platforms, note, status, created_at) VALUES (?, ?, ?, 'pending', ?)")
        .bind(email, platforms.join(","), note || null, Date.now()).run();
      return json({ ok: true });
    }

    // ---- admin ----
    if (!url.pathname.startsWith("/api/admin/")) return json({ error: "Not found" }, 404);
    if (!env.ADMIN_KEY) return json({ error: "Admin is not set up" }, 503);

    if (url.pathname === "/api/admin/login") {
      if (request.method !== "POST" || !sameOrigin(request, url)) return json({ error: "Forbidden" }, 403);
      if (await limited(env.LOGIN_LIMIT)) return json({ error: "Too many attempts. Wait a minute." }, 429);
      const body = await readJson(request, 512);
      if (!body || typeof body.key !== "string" || !(await same(body.key, env.ADMIN_KEY))) {
        await new Promise((r) => setTimeout(r, 400));
        return json({ error: "That key isn't right." }, 401);
      }
      const exp = Date.now() + SESSION_MS;
      const token = `${exp}.${await hmac(env.ADMIN_KEY, `deadbolt-admin:${exp}`)}`;
      return json({ ok: true }, 200, { "set-cookie": `${COOKIE}=${token}; Path=/; Max-Age=${SESSION_MS / 1000}; HttpOnly; Secure; SameSite=Strict` });
    }

    if (!(await session(request, env))) return json({ error: "Sign in first" }, 401);
    // Everything below changes or reads private data: only from our own admin page (custom header + same origin + JSON).
    if (request.method !== "GET" && (request.headers.get("x-requested-with") !== "deadbolt-admin" || !sameOrigin(request, url))) {
      return json({ error: "Forbidden" }, 403);
    }

    if (url.pathname === "/api/admin/logout" && request.method === "POST") {
      return json({ ok: true }, 200, { "set-cookie": `${COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict` });
    }

    if (url.pathname === "/api/admin/requests" && request.method === "GET") {
      const rows = (await env.DB.prepare("SELECT id, email, platforms, note, status, created_at, handled_at FROM requests ORDER BY created_at DESC LIMIT 500").all()).results;
      const links = (await env.DB.prepare("SELECT id, request_id, label, created_at, expires_at, max_downloads, downloads, revoked FROM links ORDER BY created_at DESC LIMIT 1000").all()).results;
      const t = await env.DB.prepare("SELECT value FROM settings WHERE key = 'template'").first();
      const dmg = await env.DMG.getWithMetadata(DMG_KEY, { type: "stream" }).catch(() => null);
      if (dmg?.value) dmg.value.cancel?.();
      return json({ requests: rows, links, template: t?.value ?? null, dmg: dmg?.value ? { filename: dmg.metadata?.filename ?? null, size: dmg.metadata?.size ?? null } : null });
    }

    let m = url.pathname.match(/^\/api\/admin\/requests\/(\d{1,12})$/);
    if (m && request.method === "POST") {
      const body = await readJson(request, 512);
      const id = Number(m[1]);
      const action = body?.action;
      const exists = await env.DB.prepare("SELECT id FROM requests WHERE id = ?").bind(id).first();
      if (!exists) return json({ error: "Not found" }, 404);
      if (action === "delete") {
        await env.DB.prepare("DELETE FROM links WHERE request_id = ?").bind(id).run();
        await env.DB.prepare("DELETE FROM requests WHERE id = ?").bind(id).run();
      } else if (["approve", "reject", "pending"].includes(action)) {
        const status = action === "approve" ? "approved" : action === "reject" ? "rejected" : "pending";
        await env.DB.prepare("UPDATE requests SET status = ?, handled_at = ? WHERE id = ?").bind(status, status === "pending" ? null : Date.now(), id).run();
        // Not approved (any more) means no working download link.
        if (status !== "approved") await env.DB.prepare("UPDATE links SET revoked = 1 WHERE request_id = ?").bind(id).run();
        if (status === "approved") {
          const live = await env.DB.prepare("SELECT id FROM links WHERE request_id = ? AND revoked = 0 AND expires_at > ? AND downloads < max_downloads LIMIT 1").bind(id, Date.now()).first();
          if (!live) return json({ ok: true, url: await makeLink(env, url.origin, { requestId: id }) });
        }
      } else if (action === "newlink") {
        await env.DB.prepare("UPDATE links SET revoked = 1 WHERE request_id = ?").bind(id).run();
        return json({ ok: true, url: await makeLink(env, url.origin, { requestId: id }) });
      } else if (action === "revokelink") {
        await env.DB.prepare("UPDATE links SET revoked = 1 WHERE request_id = ?").bind(id).run();
      } else return json({ error: "Bad request" }, 400);
      return json({ ok: true });
    }

    if (url.pathname === "/api/admin/links" && request.method === "POST") {
      const body = await readJson(request, 1024);
      if (!body) return json({ error: "Bad request" }, 400);
      const label = clean(body.label, 80) || "Link";
      return json({ ok: true, url: await makeLink(env, url.origin, { label, days: body.days, max: body.max }) });
    }
    m = url.pathname.match(/^\/api\/admin\/links\/(\d{1,12})$/);
    if (m && request.method === "POST") {
      const body = await readJson(request, 512);
      if (body?.action === "revoke") await env.DB.prepare("UPDATE links SET revoked = 1 WHERE id = ?").bind(Number(m[1])).run();
      else if (body?.action === "delete") await env.DB.prepare("DELETE FROM links WHERE id = ?").bind(Number(m[1])).run();
      else return json({ error: "Bad request" }, 400);
      return json({ ok: true });
    }

    if (url.pathname === "/api/admin/template" && request.method === "PUT") {
      const body = await readJson(request, 8192);
      if (!body || typeof body.text !== "string" || body.text.length > 4000) return json({ error: "Bad request" }, 400);
      await env.DB.prepare("INSERT INTO settings (key, value) VALUES ('template', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").bind(body.text).run();
      return json({ ok: true });
    }

    return json({ error: "Not found" }, 404);
  },

  // Daily: rejected requests are removed after 30 days, requests nobody handled after 90.
  async scheduled(event, env) {
    const now = Date.now();
    await env.DB.prepare("DELETE FROM requests WHERE status = 'rejected' AND handled_at < ?").bind(now - 30 * DAY).run();
    await env.DB.prepare("DELETE FROM requests WHERE status = 'pending' AND created_at < ?").bind(now - 90 * DAY).run();
    await env.DB.prepare("DELETE FROM links WHERE expires_at < ?").bind(now - 30 * DAY).run();
  },
};
