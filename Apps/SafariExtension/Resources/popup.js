// Deadbolt popup: status, logins for the current tab's site, fill/copy, generate.
const $ = (id) => document.getElementById(id);
const send = (msg) => new Promise((r) => chrome.runtime.sendMessage(msg, (x) => r(chrome.runtime.lastError ? { ok: false } : x)));
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

let tab;
// Which list the popup shows: this page's logins, or cards / identities / notes (not tied to a site).
let mode = "site";
const TABS = [["site", "This site"], ["cards", "Cards"], ["identities", "Identities"], ["notes", "Notes"]];

function toast(text) {
  const t = $("toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 2000);
}

/** Copy, then clear the clipboard after 60 s if it still holds what we put there. The control that was used
 *  confirms in place (see `tick`), not with a toast. */
async function copySecret(text, label, control) {
  try { await navigator.clipboard.writeText(text); } catch { return toast(`Couldn’t copy ${label.toLowerCase()}`); }
  if (control) tick(control);
  setTimeout(async () => {
    try { if ((await navigator.clipboard.readText()) === text) await navigator.clipboard.writeText(""); } catch {}
  }, 60_000);
}

/** A button shows "✓ Copied" for a moment; a code row's ring turns into a check. */
function tick(el) {
  clearTimeout(el._t);
  if (el.classList.contains("codeRow")) {
    const ring = el.querySelector(".ring");
    el._done = true;
    ring.classList.add("done"); ring.textContent = "✓";
    el._t = setTimeout(() => { el._done = false; ring.classList.remove("done"); }, 1500);
    return;
  }
  if (el._orig === undefined) el._orig = el.textContent;
  el.textContent = "✓ Copied";
  el.classList.add("done");
  el._t = setTimeout(() => { el.textContent = el._orig; el.classList.remove("done"); el._orig = undefined; }, 1500);
}

function setStatus(text, color) {
  $("status").textContent = text;
  $("status").style.setProperty("--dot", color);
}

function drawTabs() {
  const nav = $("tabs");
  nav.hidden = false;
  nav.innerHTML = TABS.map(([k, label]) => `<button role="tab" aria-selected="${k === mode}" data-tab="${k}">${label}</button>`).join("");
  nav.querySelectorAll("[data-tab]").forEach((b) => b.onclick = () => { mode = b.dataset.tab; render(); });
}

const PRIMARY_LABEL = { number: "number", email: "email", name: "name", body: "text" };

/** Cards, identities, notes. The list has names and last four digits only. A copy button asks Deadbolt for Mac to put one
 *  field on the clipboard itself (Touch ID first for secrets), so the value never passes through Chrome or this popup. */
async function renderItems() {
  const main = $("main");
  main.innerHTML = `<p class="empty">Loading…</p>`;
  const r = await send({ type: "items" });
  if (!r.ok) {
    if (r.error === "locked") { mode = "site"; return render(); }
    main.innerHTML = `<p class="empty">${r.error === "unknown" ? "Update Deadbolt for Mac to see cards and identities here." : "Couldn’t load your items."}</p>`;
    return;
  }
  const list = r[mode] || [];
  const none = { cards: "No cards saved yet.", identities: "No identities saved yet.", notes: "No secure notes saved yet." }[mode];
  if (!list.length) { main.innerHTML = `<p class="empty">${none}</p>`; return; }

  const sub = (it) => mode === "cards" ? `${it.brand} •••• ${it.last4}${it.expiry ? " · " + it.expiry : ""}${it.expired ? " · Expired" : ""}`
                    : mode === "identities" ? (it.name || "Identity")
                    : (it.label || "Secure note");
  const btn = (it, f, cls, text) => `<button class="${cls}" data-id="${esc(it.id)}" data-field="${esc(f.key)}" data-secret="${f.secret ? 1 : 0}">${esc(text)}</button>`;

  const canFill = mode === "cards" || mode === "identities";
  main.innerHTML = list.map((it) => {
    // Cards and identities: Fill is the main button and every copy is in the ⋯ menu. Notes can only be copied.
    const primary = canFill ? null : it.fields.find((f) => f.key === it.primary);
    const rest = it.fields.filter((f) => f !== primary);
    return `
    <div class="item">
      <div class="row">
        <div class="tile">${esc((it.title || "?")[0].toUpperCase())}</div>
        <div class="t"><b title="${esc(it.title)}">${esc(it.title)}</b><span class="${it.expired ? "expired" : ""}">${esc(sub(it))}</span></div>
        ${canFill ? `<button class="fill" data-fillitem="${esc(it.id)}">Fill</button>` : ""}
        ${primary ? btn(it, primary, "fill", "Copy " + (PRIMARY_LABEL[primary.key] || primary.label.toLowerCase())) : ""}
        ${rest.length ? `<button class="more" data-more="${esc(it.id)}" aria-label="More for ${esc(it.title)}" aria-expanded="false">⋯</button>` : ""}
      </div>
      ${rest.length ? `<div class="menu wrap" data-menu="${esc(it.id)}" hidden>${rest.map((f) => btn(it, f, "ghost", canFill ? "Copy " + f.label.toLowerCase() : f.label)).join("")}</div>` : ""}
    </div>`;
  }).join("") + `<p class="hint">${canFill ? "Fill puts it into this page’s form after a Touch ID check on your Mac (a card number or code). " : ""}Copies are made by Deadbolt for Mac, not Chrome, and leave the clipboard after 30 seconds.</p>`;

  main.querySelectorAll("[data-fillitem]").forEach((b) => b.onclick = async () => {
    const kind = mode === "cards" ? "card" : "identity";
    const r = await new Promise((res) => chrome.tabs.sendMessage(tab.id, { type: "fillItemFromPopup", kind, id: b.dataset.fillitem },
      (x) => res(chrome.runtime.lastError ? { ok: false, error: "noPage" } : x)));
    if (r?.ok) return window.close();   // the page asks the Mac; Touch ID may take a moment
    toast(r?.error === "noFields" ? `No ${kind} fields found on this page` : "Can’t fill on this page");
  });

  main.querySelectorAll("[data-more]").forEach((b) => b.onclick = () => {
    const m = main.querySelector(`[data-menu="${CSS.escape(b.dataset.more)}"]`);
    m.hidden = !m.hidden;
    b.setAttribute("aria-expanded", String(!m.hidden));
  });
  main.querySelectorAll("[data-field]").forEach((b) => b.onclick = async () => {
    const orig = b.textContent;
    if (b.dataset.secret === "1") { b.disabled = true; b.textContent = "Touch ID…"; }   // Touch ID can close this popup; the Mac shows the result
    const c = await send({ type: "copyItem", id: b.dataset.id, field: b.dataset.field });
    b.disabled = false; b.textContent = orig;
    if (c.ok) tick(b);
    else if (c.error === "cancelled") toast("Cancelled");
    else if (c.error === "locked") render();
    else toast("Couldn’t copy");
  });
}

async function render() {
  clearInterval(render.timer);
  $("tabs").hidden = true;
  [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  let host = "";
  try { host = new URL(tab.url).hostname.replace(/^www\./, ""); } catch {}
  $("site").textContent = host || "Deadbolt";
  const main = $("main");

  const status = await send({ type: "status" });
  if (!status.ok) {
    setStatus("Not connected", "#FF8C7E");
    main.innerHTML = status.error === "notRunning"
      ? `<p class="empty">Deadbolt for Mac isn’t running. Open it from Applications, then try again.</p>`
      : `<p class="empty">This browser can’t reach Deadbolt for Mac. Open Deadbolt once (it registers itself with your browsers), then reopen this popup.</p>
         <p class="empty" style="font-size:11px;color:#8A8F99">Browser said: ${esc(status.detail || status.error || "unknown")}</p>`;
    return;
  }
  if (!status.hasVault) {
    setStatus("No vault", "#8A8F99");
    main.innerHTML = `<p class="empty">Set up Deadbolt for Mac first.</p>`;
    return;
  }
  if (status.locked) {
    setStatus("Locked", "#8A8F99");
    main.innerHTML = `<button class="big" id="unlock">Unlock with Touch ID</button>`;
    $("unlock").onclick = async () => { $("unlock").textContent = "Waiting for Touch ID…"; await send({ type: "unlock", tabId: tab.id, url: tab.url }); render(); };
    return;
  }
  setStatus("Unlocked via Mac", "#6FCF97");
  drawTabs();
  if (mode !== "site") return renderItems();

  const r = await send({ type: "accounts", url: tab.url, tabId: tab.id });
  if (!r.ok) {
    main.innerHTML = `<p class="empty">${r.error === "insecurePage" ? "Deadbolt only fills on secure (https) pages." : "Nothing to fill on this page."}</p>`;
    return;
  }
  if (!r.accounts.length) { main.innerHTML = `<p class="empty">No logins saved for ${esc(r.site)}.</p>`; return; }
  // Chrome's own stored favicon for this page: no network request, nothing leaves the browser.
  // Chrome only (Safari has no _favicon): letters otherwise.
  const chromeFav = /Chrome\/|Chromium\//.test(navigator.userAgent);
  const fav = chromeFav ? chrome.runtime.getURL(`/_favicon/?pageUrl=${encodeURIComponent(tab.url)}&size=32`) : null;
  const tile = (a) => fav ? `<div class="tile fav"><img src="${fav}" alt="" width="20" height="20"></div>`
                          : `<div class="tile">${esc((a.username || a.title || "?")[0].toUpperCase())}</div>`;

  // Logins and codes are separate lists: a row is either something to sign in with or a code to copy.
  const logins = r.accounts.filter((a) => a.hasPassword || a.hasPasskey);
  const codes = r.accounts.filter((a) => a.hasCode);
  main.innerHTML = [
    logins.length ? `<h2>Logins</h2>` + logins.map((a) => `
      <div class="item">
        <div class="row">
          ${tile(a)}
          <div class="t"><b title="${esc(a.username || a.title)}">${esc(a.username || a.title)}</b><span>${esc(a.label || (a.hasPassword ? "Password" : "Passkey"))}</span></div>
          ${a.hasPassword ? `<button class="fill" data-fill="${esc(a.id)}">Fill</button>` : ""}
          ${a.hasPassword ? `<button class="more" data-more="${esc(a.id)}" aria-label="More for ${esc(a.username || a.title)}" aria-expanded="false">⋯</button>` : ""}
        </div>
        <div class="menu" data-menu="${esc(a.id)}" hidden>
          <button class="ghost" data-copy="${esc(a.id)}">Copy password</button>
          ${a.username ? `<button class="ghost" data-user="${esc(a.username)}">Copy username</button>` : ""}
        </div>
      </div>`).join("") : "",
    codes.length ? `<h2>One-time codes</h2>` + codes.map((a) => `
      <button class="row codeRow" data-code="${esc(a.id)}" title="Copy code">
        ${tile(a)}
        <div class="t"><b>${esc(a.username || a.title)}</b><span class="code" data-live="${esc(a.id)}">······</span></div>
        <span class="ring" data-ring="${esc(a.id)}"></span>
      </button>`).join("") : "",
  ].join("");

  main.querySelectorAll("[data-fill]").forEach((b) => b.onclick = async () => {
    const c = await send({ type: "fill", id: b.dataset.fill, url: tab.url, tabId: tab.id });
    if (!c.ok) return toast("Couldn’t fill");
    chrome.tabs.sendMessage(tab.id, { type: "fillFromPopup", username: c.username, password: c.password }, () => void chrome.runtime.lastError);
    window.close();
  });
  main.querySelectorAll("[data-more]").forEach((b) => b.onclick = () => {
    const m = main.querySelector(`[data-menu="${CSS.escape(b.dataset.more)}"]`);
    m.hidden = !m.hidden;
    b.setAttribute("aria-expanded", String(!m.hidden));
  });
  main.querySelectorAll("[data-copy]").forEach((b) => b.onclick = async () => {
    const c = await send({ type: "fill", id: b.dataset.copy, url: tab.url, tabId: tab.id });
    if (c.ok) copySecret(c.password, "Password", b);
  });
  main.querySelectorAll("[data-user]").forEach((b) => b.onclick = () => copySecret(b.dataset.user, "Username", b));

  // Live codes: the Mac app returns the code and the seconds left; ask again when it runs out. Tap a row to copy.
  const live = new Map();
  async function refresh(id) {
    const c = await send({ type: "code", id, url: tab.url, tabId: tab.id });
    if (!c.ok) return;
    live.set(id, { code: c.code, until: Date.now() + c.remaining * 1000, period: c.period || 30 });
  }
  function paint() {
    for (const [id, v] of live) {
      const left = Math.max(0, Math.ceil((v.until - Date.now()) / 1000));
      const el = main.querySelector(`[data-live="${CSS.escape(id)}"]`);
      const ring = main.querySelector(`[data-ring="${CSS.escape(id)}"]`);
      if (ring?.closest(".codeRow")?._done) { if (left === 0) refresh(id); continue; }   // showing the copied check
      if (el) { el.textContent = `${v.code.slice(0, 3)} ${v.code.slice(3)}`; el.classList.toggle("low", left <= 5); }
      if (ring) { ring.textContent = left; ring.style.setProperty("--p", `${(left / v.period) * 100}%`); ring.classList.toggle("low", left <= 5); }
      if (left === 0) refresh(id);
    }
  }
  await Promise.all(codes.map((a) => refresh(a.id)));
  paint();
  clearInterval(render.timer);
  render.timer = setInterval(paint, 1000);
  main.querySelectorAll("[data-code]").forEach((b) => b.onclick = () => {
    const v = live.get(b.dataset.code);
    if (v) copySecret(v.code, "Code", b);
  });
}

$("generate").onclick = async () => { const g = await send({ type: "generate" }); if (g.ok) copySecret(g.password, "New password", $("generate")); };
$("open").onclick = () => send({ type: "open" });
render();
