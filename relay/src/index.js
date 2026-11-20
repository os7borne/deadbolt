// Deadbolt relay — a dead-drop for end-to-end encrypted sync messages.
//
// It never sees vault contents: messages are sealed and signed on the device. It stores them only until every
// device in the mailbox has acknowledged them, and never longer than 7 days. Link rooms (pairing a new device)
// live 15 minutes. No accounts, no logging of bodies, no analytics.
//
//   POST /v1/mailbox/:id/create      {device, key}          first device; signed with that key
//   POST /v1/mailbox/:id/members     {device, key}          signed by a member
//   POST /v1/mailbox/:id/revoke      Revocation             signed by a member; target is told with 410
//   POST /v1/mailbox/:id/messages    SyncMessage            signed by a member → {seq}
//   GET  /v1/mailbox/:id/messages?after=N                   signed by a member → {messages, latest, oldest}
//   POST /v1/mailbox/:id/ack         {seq}                  signed by a member
//   POST /v1/mailbox/:id/push        {token|null}           signed by a member: its APNs token (iPhone)
//
// After a new message, other members with a push token get a silent push ({"aps":{"content-available":1}}, nothing
// else) at most every 15 s, so the iPhone fetches without the app being opened. Secret APNS_KEY (.p8 PEM).
//   GET  /v1/icon/:domain                                   open: the site's own icon (see icons below)
//   POST /v1/link/:id                LinkMessage            open
//   GET  /v1/link/:id?after=N                               open
//
// Rate limits (Workers rate-limiting binding, per client IP, per minute): link posts 20, link reads 120,
// mailbox requests 600. Over the limit → 429.
//
// Signature (ECDSA P-256 / SHA-256, raw r||s, base64) over:
//   "deadbolt-relay/v1\n{METHOD}\n{path+query}\n{unix ms}\n{sha256(body) hex}"
// in headers X-Deadbolt-Device, X-Deadbolt-Time, X-Deadbolt-Signature.

const DAY = 24 * 3600 * 1000;
const MESSAGE_TTL = 7 * DAY;
const LINK_TTL = 15 * 60 * 1000;
const MAX_BODY = 1_500_000;
const MAX_MESSAGES = 5000;
const MAX_LINK_MESSAGES = 40;
const CLOCK_SKEW = 5 * 60 * 1000;

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
const fail = (status, error) => json({ error }, status);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json({ ok: true });

    const ip = request.headers.get("cf-connecting-ip") ?? "local";
    const limited = async (limiter) => limiter && !(await limiter.limit({ key: ip })).success;

    let m = url.pathname.match(/^\/v1\/mailbox\/([0-9a-f]{64})\/(create|members|revoke|messages|ack|push)$/);
    if (m) {
      if (await limited(env.MAILBOX_LIMIT)) return fail(429, "Too many requests");
      return env.MAILBOX.get(env.MAILBOX.idFromName(m[1])).fetch(request);
    }

    m = url.pathname.match(/^\/v1\/icon\/([a-z0-9.-]{3,253})$/);
    if (m && request.method === "GET") {
      if (await limited(env.ICON_LIMIT)) return fail(429, "Too many requests");
      return icon(m[1], ctx);
    }

    m = url.pathname.match(/^\/v1\/link\/([0-9a-f]{32})$/);
    if (m) {
      if (await limited(request.method === "POST" ? env.LINK_POST_LIMIT : env.LINK_READ_LIMIT)) return fail(429, "Too many requests");
      return env.LINK.get(env.LINK.idFromName(m[1])).fetch(request);
    }

    return fail(404, "Not found");
  },
};

// ---------- helpers ----------

const b64 = {
  decode: (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0)),
  encode: (bytes) => {
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(s);
  },
};

async function sha256Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return [...d].map((x) => x.toString(16).padStart(2, "0")).join("");
}

async function verifySignature(keyB64, sigB64, message) {
  try {
    const key = await crypto.subtle.importKey("raw", b64.decode(keyB64), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64.decode(sigB64), message);
  } catch {
    return false;
  }
}

/** Reads the body once and checks the request signature against `keyFor(device)`. */
async function authenticate(request, keyFor) {
  const url = new URL(request.url);
  const device = request.headers.get("x-deadbolt-device");
  const time = request.headers.get("x-deadbolt-time");
  const sig = request.headers.get("x-deadbolt-signature");
  const body = new Uint8Array(await request.arrayBuffer());
  if (body.length > MAX_BODY) return { error: fail(413, "Too large") };
  if (!device || !time || !sig || !/^\d+$/.test(time)) return { error: fail(401, "Unsigned request") };
  if (Math.abs(Date.now() - Number(time)) > CLOCK_SKEW) return { error: fail(401, "Clock out of range") };
  const key = await keyFor(device, body);
  if (key instanceof Response) return { error: key };
  if (!key) return { error: fail(403, "Not a member of this mailbox") };
  const canonical = `deadbolt-relay/v1\n${request.method}\n${url.pathname}${url.search}\n${time}\n${await sha256Hex(body)}`;
  if (!(await verifySignature(key, sig, new TextEncoder().encode(canonical)))) return { error: fail(401, "Bad signature") };
  return { device, body };
}

const parseJSON = (bytes) => {
  try { return JSON.parse(new TextDecoder().decode(bytes)); } catch { return null; }
};

// ---------- mailbox ----------

// ---------- website icons ----------
//
// Fetched from the site itself (never a third-party icon service), cached at Cloudflare's edge: 7 days for an
// icon, 1 day for "none found". No cookies or referrer are sent, nothing is logged. Only images ≤ 256 KB pass.

const ICON_TTL = 7 * 24 * 3600;
const ICON_MISS_TTL = 24 * 3600;
const ICON_MAX = 256 * 1024;
const HTML_MAX = 512 * 1024;
const UA = "Mozilla/5.0 (compatible; DeadboltIcons/1.0; +https://deadbolt.osborne.vc)";
const IMAGE_TYPES = ["image/png", "image/jpeg", "image/x-icon", "image/vnd.microsoft.icon", "image/webp", "image/gif"];

const validDomain = (d) =>
  d.length <= 253 && d.includes(".") && !/^[0-9.]+$/.test(d) &&
  d.split(".").every((l) => /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(l));

async function timedFetch(url, accept, ms = 5000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    const r = await fetch(url, { headers: { "user-agent": UA, accept }, redirect: "follow", signal: ctrl.signal, cf: { cacheTtl: 3600 } });
    return new URL(r.url).protocol === "https:" ? r : null; // never follow a redirect down to http
  } catch { return null; } finally { clearTimeout(t); }
}

async function readCapped(response, max) {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const chunks = []; let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > max) { reader.cancel(); return null; }
    chunks.push(value);
  }
  const out = new Uint8Array(size); let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}

/** Icon candidates declared in the page's <head>, best first. */
function declaredIcons(html, base) {
  const out = [];
  for (const tag of html.match(/<link\b[^>]*>/gi) ?? []) {
    const attr = (n) => tag.match(new RegExp(`\\b${n}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i"))?.slice(2).find((x) => x !== undefined) ?? "";
    const rel = attr("rel").toLowerCase();
    if (!/\b(apple-touch-icon(-precomposed)?|icon)\b/.test(rel)) continue;
    const href = attr("href");
    if (!href || href.startsWith("data:")) continue;
    let u;
    try { u = new URL(href, base); } catch { continue; }
    if (u.protocol !== "https:" || /\.svg(\?|$)/i.test(u.pathname) || /svg/i.test(attr("type"))) continue; // apps can't draw SVG favicons
    const size = Math.max(0, ...(attr("sizes").match(/\d+/g) ?? ["0"]).map(Number));
    const touch = rel.includes("apple-touch-icon");
    if (!touch && size && size < 64) continue;
    out.push({ url: u.toString(), score: (touch ? 10_000 : 0) + (size || (touch ? 180 : 32)) });
  }
  return out.sort((a, b) => b.score - a.score).map((c) => c.url);
}

async function findIcon(domain) {
  for (const host of [domain, `www.${domain}`]) {
    const page = await timedFetch(`https://${host}/`, "text/html");
    const candidates = [];
    if (page?.ok && (page.headers.get("content-type") ?? "").includes("html")) {
      const bytes = await readCapped(page, HTML_MAX);
      if (bytes) candidates.push(...declaredIcons(new TextDecoder().decode(bytes).slice(0, HTML_MAX), page.url));
    }
    candidates.push(`https://${host}/apple-touch-icon.png`, `https://${host}/favicon.ico`);
    for (const c of [...new Set(candidates)].slice(0, 6)) {
      const r = await timedFetch(c, "image/*");
      if (!r?.ok) continue;
      const type = (r.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
      if (!IMAGE_TYPES.includes(type)) continue;
      const bytes = await readCapped(r, ICON_MAX);
      if (bytes && bytes.length > 64) return { bytes, type };
    }
    if (page) break; // the bare domain answered: don't also try www
  }
  return null;
}

async function icon(domain, ctx) {
  if (!validDomain(domain)) return fail(400, "Bad domain");
  const cache = caches.default;
  const key = new Request(`https://deadbolt-icons.invalid/${domain}`);
  const hit = await cache.match(key);
  if (hit) return hit;
  const found = await findIcon(domain);
  const response = found
    ? new Response(found.bytes, { headers: { "content-type": found.type, "cache-control": `public, max-age=${ICON_TTL}`, "x-content-type-options": "nosniff" } })
    : new Response(null, { status: 404, headers: { "cache-control": `public, max-age=${ICON_MISS_TTL}` } });
  ctx.waitUntil(cache.put(key, response.clone()));
  return response;
}

// ---------- APNs (silent push) ----------

const APNS_PRODUCTION = "https://api.push.apple.com";
const APNS_SANDBOX = "https://api.sandbox.push.apple.com";
const PUSH_GAP = 15 * 1000;
let cachedJWT;

const b64url = (bytes) => b64.encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function providerToken(env, now) {
  if (cachedJWT && now - cachedJWT.at < 40 * 60 * 1000) return cachedJWT.value;
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const head = enc({ alg: "ES256", kid: env.APNS_KEY_ID });
  const body = enc({ iss: env.APNS_TEAM, iat: Math.floor(now / 1000) });
  const der = b64.decode(env.APNS_KEY.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, ""));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${body}`)));
  cachedJWT = { value: `${head}.${body}.${b64url(sig)}`, at: now };
  return cachedJWT.value;
}

/** "sent" | "gone" (drop the token) | "failed". Development builds use the sandbox: fall back on BadDeviceToken. */
async function silentPush(env, token) {
  if (!env.APNS_KEY) return "failed";
  const jwt = await providerToken(env, Date.now());
  const attempt = (host) => fetch(`${host}/3/device/${token}`, {
    method: "POST",
    headers: { authorization: `bearer ${jwt}`, "apns-topic": env.APNS_TOPIC, "apns-push-type": "background",
               "apns-priority": "5", "content-type": "application/json" },
    body: JSON.stringify({ aps: { "content-available": 1 } }),
  });
  const reasonOf = async (r) => (r.status === 200 ? "" : ((await r.json().catch(() => ({}))).reason ?? ""));
  let r = await attempt(APNS_PRODUCTION);
  let reason = await reasonOf(r);
  if (r.status === 400 && reason === "BadDeviceToken") { r = await attempt(APNS_SANDBOX); reason = await reasonOf(r); }
  if (r.status === 200) return "sent";
  if (r.status === 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "BadEnvironmentKeyInToken"].includes(reason)) return "gone";
  return "failed";
}

export class Mailbox {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS members (device TEXT PRIMARY KEY, key TEXT NOT NULL, cursor INTEGER NOT NULL DEFAULT 0, seen INTEGER NOT NULL DEFAULT 0)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS revoked (device TEXT PRIMARY KEY, record TEXT NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS messages (seq INTEGER PRIMARY KEY, sender TEXT NOT NULL, at INTEGER NOT NULL, body TEXT NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v INTEGER NOT NULL)`);
    for (const col of ["token TEXT", "pushed INTEGER NOT NULL DEFAULT 0"]) {
      try { this.sql.exec(`ALTER TABLE members ADD COLUMN ${col}`); } catch { /* already there */ }
    }
  }

  /** Wake the other members' iPhones (silent push), no more than every 15 s each. */
  async pushOthers(sender) {
    const now = Date.now();
    const rows = this.sql.exec(`SELECT device, token FROM members WHERE device != ? AND token IS NOT NULL AND pushed < ?`, sender, now - PUSH_GAP).toArray();
    for (const row of rows) {
      this.sql.exec(`UPDATE members SET pushed = ? WHERE device = ?`, now, row.device);
      const result = await silentPush(this.env, row.token).catch(() => "failed");
      if (result === "gone") this.sql.exec(`UPDATE members SET token = NULL WHERE device = ?`, row.device);
    }
  }

  member(device) { return this.sql.exec(`SELECT key FROM members WHERE device = ?`, device).toArray()[0]?.key ?? null; }
  revocation(device) { return this.sql.exec(`SELECT record FROM revoked WHERE device = ?`, device).toArray()[0]?.record ?? null; }
  memberCount() { return this.sql.exec(`SELECT COUNT(*) AS n FROM members`).one().n; }
  latest() { return this.sql.exec(`SELECT v FROM meta WHERE k = 'latest'`).toArray()[0]?.v ?? 0; }

  /** Members sign with their stored key; a removed device gets its signed revocation back (410). */
  keyFor(device) {
    const r = this.revocation(device);
    if (r) return new Response(r, { status: 410, headers: { "content-type": "application/json" } });
    return this.member(device);
  }

  async fetch(request) {
    const url = new URL(request.url);
    const action = url.pathname.split("/").pop();
    const route = `${request.method} ${action}`;

    if (route === "POST create") {
      const auth = await authenticate(request, (_, body) => {
        const b = parseJSON(body);
        return b && typeof b.key === "string" ? b.key : null; // self-signed: proves possession of the key
      });
      if (auth.error) return auth.error;
      const b = parseJSON(auth.body);
      if (b.device !== auth.device) return fail(400, "Device mismatch");
      if (this.memberCount() > 0) return fail(409, "Mailbox already exists");
      this.sql.exec(`INSERT INTO members (device, key, seen) VALUES (?, ?, ?)`, b.device, b.key, Date.now());
      return json({ ok: true });
    }

    const auth = await authenticate(request, (d) => this.keyFor(d));
    if (auth.error) return auth.error;
    this.sql.exec(`UPDATE members SET seen = ? WHERE device = ?`, Date.now(), auth.device);

    switch (route) {
      case "POST members": {
        const b = parseJSON(auth.body);
        if (!b || typeof b.device !== "string" || typeof b.key !== "string") return fail(400, "Bad request");
        if (this.revocation(b.device)) return fail(409, "That device was removed");
        this.sql.exec(`INSERT OR IGNORE INTO members (device, key, cursor, seen) VALUES (?, ?, ?, ?)`, b.device, b.key, this.latest(), Date.now());
        return json({ ok: true });
      }

      case "POST revoke": {
        const r = parseJSON(auth.body);
        if (!r || typeof r.device !== "string" || r.by !== auth.device) return fail(400, "Bad revocation");
        this.sql.exec(`DELETE FROM members WHERE device = ?`, r.device);
        this.sql.exec(`INSERT OR REPLACE INTO revoked (device, record) VALUES (?, ?)`, r.device, new TextDecoder().decode(auth.body));
        this.prune();
        return json({ ok: true });
      }

      case "POST messages": {
        if (this.sql.exec(`SELECT COUNT(*) AS n FROM messages`).one().n >= MAX_MESSAGES) return fail(429, "Mailbox full");
        const seq = this.latest() + 1;
        this.sql.exec(`INSERT INTO messages (seq, sender, at, body) VALUES (?, ?, ?, ?)`, seq, auth.device, Date.now(), b64.encode(auth.body));
        this.sql.exec(`INSERT OR REPLACE INTO meta (k, v) VALUES ('latest', ?)`, seq);
        this.sql.exec(`UPDATE members SET cursor = MAX(cursor, ?) WHERE device = ?`, seq, auth.device);
        await this.ensureAlarm();
        this.ctx.waitUntil(this.pushOthers(auth.device));
        return json({ seq });
      }

      case "GET messages": {
        const after = Math.max(0, Number(url.searchParams.get("after") ?? 0) || 0);
        const rows = this.sql.exec(`SELECT seq, sender, at, body FROM messages WHERE seq > ? ORDER BY seq LIMIT 200`, after).toArray();
        const latest = this.latest();
        const oldest = this.sql.exec(`SELECT MIN(seq) AS s FROM messages`).one().s ?? latest + 1;
        return json({ messages: rows.map((r) => ({ seq: r.seq, from: r.sender, at: r.at, body: r.body })), latest, oldest });
      }

      case "POST push": {
        const b = parseJSON(auth.body);
        const token = b?.token;
        if (token !== null && (typeof token !== "string" || !/^[0-9a-f]{64,200}$/.test(token))) return fail(400, "Bad token");
        this.sql.exec(`UPDATE members SET token = ? WHERE device = ?`, token, auth.device);
        return json({ ok: true });
      }

      case "POST ack": {
        const b = parseJSON(auth.body);
        if (!b || !Number.isInteger(b.seq)) return fail(400, "Bad ack");
        this.sql.exec(`UPDATE members SET cursor = MAX(cursor, ?) WHERE device = ?`, Math.min(b.seq, this.latest()), auth.device);
        this.prune();
        return json({ ok: true });
      }
    }
    return fail(404, "Not found");
  }

  /** Delete what every member already has, and anything past the 7-day limit. */
  prune() {
    const min = this.sql.exec(`SELECT MIN(cursor) AS c FROM members`).one().c;
    if (min !== null) this.sql.exec(`DELETE FROM messages WHERE seq <= ?`, min);
    this.sql.exec(`DELETE FROM messages WHERE at < ?`, Date.now() - MESSAGE_TTL);
  }

  async ensureAlarm() {
    if ((await this.ctx.storage.getAlarm()) == null) await this.ctx.storage.setAlarm(Date.now() + DAY);
  }

  async alarm() {
    this.prune();
    if (this.sql.exec(`SELECT COUNT(*) AS n FROM messages`).one().n > 0) await this.ctx.storage.setAlarm(Date.now() + DAY);
  }
}

// ---------- link rooms ----------

export class LinkRoom {
  constructor(ctx) {
    this.ctx = ctx;
    this.sql = ctx.storage.sql;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS messages (seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, body TEXT NOT NULL)`);
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.method === "POST") {
      const body = new Uint8Array(await request.arrayBuffer());
      if (body.length > MAX_BODY) return fail(413, "Too large");
      const m = parseJSON(body);
      if (!m || !["hello", "accept", "details", "vault", "deny"].includes(m.kind)) return fail(400, "Bad link message");
      if (this.sql.exec(`SELECT COUNT(*) AS n FROM messages`).one().n >= MAX_LINK_MESSAGES) return fail(429, "Link room full");
      this.sql.exec(`INSERT INTO messages (at, body) VALUES (?, ?)`, Date.now(), b64.encode(body));
      if ((await this.ctx.storage.getAlarm()) == null) await this.ctx.storage.setAlarm(Date.now() + LINK_TTL);
      return json({ ok: true });
    }
    if (request.method === "GET") {
      const after = Math.max(0, Number(url.searchParams.get("after") ?? 0) || 0);
      const rows = this.sql.exec(`SELECT seq, at, body FROM messages WHERE seq > ? ORDER BY seq LIMIT 50`, after).toArray();
      const latest = rows.length ? rows[rows.length - 1].seq : after;
      return json({ messages: rows.map((r) => ({ seq: r.seq, from: "", at: r.at, body: r.body })), latest, oldest: rows[0]?.seq ?? latest + 1 });
    }
    return fail(405, "Method not allowed");
  }

  async alarm() {
    await this.ctx.storage.deleteAll(); // the whole room disappears 15 minutes after first use
  }
}
