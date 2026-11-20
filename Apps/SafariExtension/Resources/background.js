// Deadbolt for Chrome — service worker.
// Talks to Deadbolt for Mac through the native-messaging host. Nothing secret is stored here: a captured
// sign-in waits in chrome.storage.session (memory, not readable by content scripts) for at most 5 minutes.
// The site is always taken from Chrome (sender.tab.url / the active tab), never from what a page says.

const HOST = "com.osborne.deadbolt";
const PENDING_TTL = 5 * 60 * 1000;

function native(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
      if (chrome.runtime.lastError || !reply) resolve({ ok: false, error: "noHost", detail: chrome.runtime.lastError?.message ?? "No reply" });
      else resolve(reply);
    });
  });
}

const httpsOrLocal = (url) => {
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.hostname === "localhost" || u.hostname === "127.0.0.1";
  } catch { return false; }
};

async function pendingFor(tabId) {
  const key = `pending-${tabId}`;
  const got = (await chrome.storage.session.get(key))[key];
  if (!got || Date.now() - got.at > PENDING_TTL) { await chrome.storage.session.remove(key); return null; }
  return got;
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    // Messages from pages (content script) carry the page's real URL from Chrome; popup messages say which tab.
    const fromPage = !!sender.tab;
    const url = fromPage ? sender.tab.url : msg.url;
    const tabId = fromPage ? sender.tab.id : msg.tabId;

    switch (msg.type) {
      case "status":
        return native({ type: "status" });
      case "badge":
        if (fromPage) await badgeFor(tabId, url);
        return { ok: true };
      case "unlock": {
        const r = await native({ type: "unlock" });
        if (r.ok && !r.locked && tabId && url) badgeFor(tabId, url); // the page's own tab, or the one the popup names
        return r;
      }
      case "open":
        return native({ type: "open" });
      case "generate":
        return native({ type: "generate" });

      case "items":
      case "copyItem": {
        // Cards, identities and notes. Only the extension's own popup may ask, never a page: a content script always has
        // sender.tab, so it is refused here. The answer to "items" has names and last four digits only; "copyItem" asks the
        // Mac app to put one field on the clipboard itself (after Touch ID for secrets), so no secret ever reaches Chrome.
        if (fromPage || sender.id !== chrome.runtime.id || (sender.url && !sender.url.startsWith(chrome.runtime.getURL("popup.html")))) {
          return { ok: false, error: "forbidden" };
        }
        return msg.type === "items"
          ? native({ type: "items" })
          : native({ type: "copyItem", id: String(msg.id || "").slice(0, 64), field: String(msg.field || "").slice(0, 32) });
      }

      case "fillCandidates": {
        // The page script asks which cards / identities to offer on a form. Top frame of an https page only. Names and the last four
        // digits come back, nothing else; "passive" so just looking at a form doesn't keep the vault unlocked.
        if (!fromPage || sender.frameId !== 0 || !httpsOrLocal(url)) return { ok: false, error: "forbidden" };
        const kind = msg.kind === "card" ? "cards" : msg.kind === "identity" ? "identities" : null;
        if (!kind) return { ok: false, error: "badRequest" };
        const r = await native({ type: "items", passive: true });
        if (!r.ok) return r;
        return { ok: true, items: (r[kind] || []).map((it) => kind === "cards"
          ? { id: it.id, title: it.title, brand: it.brand, last4: it.last4, expiry: it.expiry, expired: it.expired }
          : { id: it.id, title: it.title, name: it.name }) };
      }
      case "fillItem": {
        // A pick in the page menu (or the popup's Fill button). The address comes from Chrome (sender.tab.url), never from the page.
        // The Mac releases only the requested fields, and asks for Touch ID first when a card number or code is among them.
        if (!fromPage || sender.frameId !== 0 || !httpsOrLocal(url)) return { ok: false, error: "forbidden" };
        const want = Array.isArray(msg.want) ? msg.want.filter((k) => typeof k === "string" && k.length <= 16).slice(0, 24) : [];
        return native({ type: "fillItem", id: String(msg.id || "").slice(0, 64), want, url });
      }

      case "accounts":
        if (!httpsOrLocal(url)) return { ok: false, error: "insecurePage" };
        return native({ type: "accounts", url });

      case "fill":
      case "code":
        if (!httpsOrLocal(url)) return { ok: false, error: "insecurePage" };
        return native({ type: msg.type, url, id: msg.id });

      case "passkeyCreate":
      case "passkeyGet": {
        if (!fromPage || !httpsOrLocal(url)) return { ok: false, error: "SecurityError" };
        const p = msg.payload || {};
        // Only plain fields go on; the Mac app derives the origin from `url` (Chrome's tab URL), never from the page.
        const r = await native({ type: msg.type, url, rpId: String(p.rpId || ""), challenge: String(p.challenge || ""),
          userId: p.userId, userName: p.userName, algs: p.algs, exclude: p.exclude, allow: p.allow, choose: p.choose });
        if (msg.type === "passkeyCreate" && r.ok) badgeFor(tabId, url);
        return r;
      }

      case "stepUser": {
        // Step one of a two-step sign-in: the username, kept for 10 minutes for this tab and host only.
        if (!fromPage || !httpsOrLocal(url) || !msg.username) return { ok: false };
        await chrome.storage.session.set({ [`user-${tabId}`]: { host: new URL(url).hostname, username: String(msg.username).slice(0, 256), at: Date.now() } });
        return { ok: true };
      }

      case "capture": {
        // A sign-in form was submitted: keep it briefly so the next page can offer to save it.
        if (!fromPage || !httpsOrLocal(url) || !msg.password) return { ok: false };
        let username = msg.username || "";
        if (!username) {   // two-step sign-in: use the username from step one, if it was on this same host just now
          const k = `user-${tabId}`, step = (await chrome.storage.session.get(k))[k];
          if (step && step.host === new URL(url).hostname && Date.now() - step.at < 10 * 60 * 1000) username = step.username;
        }
        await chrome.storage.session.set({ [`pending-${tabId}`]: { url, username, password: msg.password, at: Date.now() } });
        return { ok: true };
      }

      case "pendingSave": {
        const p = await pendingFor(tabId);
        if (!p) return { ok: true, action: "none" };
        const site = new URL(p.url).hostname;
        // The Mac app decides "same site" (registrable domain, Public Suffix List): login.x.com → app.x.com is fine,
        // a different site keeps the sign-in waiting (until it expires) instead of prompting there.
        const r = await native({ type: "propose", url: p.url, pageUrl: url, username: p.username, password: p.password });
        if (r.error === "locked") return { ok: true, action: "unlock", username: p.username, site };   // keep it waiting
        if (r.ok && r.reason === "otherSite") return { ok: true, action: "none" };
        if (!r.ok || r.action === "none") { await chrome.storage.session.remove(`pending-${tabId}`); return { ok: true, action: "none" }; }
        return { ok: true, action: r.action, username: p.username, site };
      }

      case "save": {
        const p = await pendingFor(tabId);
        await chrome.storage.session.remove(`pending-${tabId}`);
        if (!p) return { ok: false, error: "expired" };
        const saved = await native({ type: "save", url: p.url, username: p.username, password: p.password, separate: !!msg.separate });
        if (saved.ok) badgeFor(tabId, url);
        return saved;
      }

      case "dismissSave":
        await chrome.storage.session.remove(`pending-${tabId}`);
        return { ok: true };
    }
    return { ok: false, error: "unknown" };
  })().then(sendResponse);
  return true; // async response
});

chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove([`pending-${tabId}`, `user-${tabId}`]));

// ---------- toolbar badge: how many logins Deadbolt has for this tab's site ----------
// The page script asks for a count when a page loads; Chrome supplies that page's real URL (sender.tab.url), so no
// "tabs" (browsing history) permission is needed. Counts come from the Mac app over native messaging, locally.
// Locked → no badge: a locked vault shouldn't reveal even a count. Badge requests are passive: they don't keep
// the vault unlocked.

chrome.action.setBadgeBackgroundColor({ color: "#D4AF6A" });
if (chrome.action.setBadgeTextColor) chrome.action.setBadgeTextColor({ color: "#1A1408" });

async function badgeFor(tabId, url) {
  let text = "";
  if (url && httpsOrLocal(url)) {
    const r = await native({ type: "accounts", url, passive: true });
    if (r.ok && r.accounts.length) text = r.accounts.length > 9 ? "9+" : String(r.accounts.length);
  }
  await chrome.action.setBadgeText({ tabId, text }).catch(() => {});
  const shown = (await chrome.storage.session.get("badged")).badged ?? {};
  if (text) shown[tabId] = true; else delete shown[tabId];
  await chrome.storage.session.set({ badged: shown });
}

async function clearAllBadges() {
  const shown = (await chrome.storage.session.get("badged")).badged ?? {};
  for (const id of Object.keys(shown)) await chrome.action.setBadgeText({ tabId: Number(id), text: "" }).catch(() => {});
  await chrome.storage.session.set({ badged: {} });
}

// Once a minute: if Deadbolt has locked itself, clear every badge.
chrome.alarms.create("badge", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(async (a) => {
  if (a.name !== "badge") return;
  const st = await native({ type: "status" });
  if (!st.ok || st.locked) clearAllBadges();
});
