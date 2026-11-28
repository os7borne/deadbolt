// Deadbolt for Chrome — page script (top frame only).
// Finds sign-in fields, offers the logins saved for this site, fills the one you pick, and after you sign in
// offers to save or update the password. Also offers saved cards and identities on checkout and address forms
// (field detection is in fieldmap.js). All UI lives in a closed shadow root so the page can't style or read it.
(() => {
  if (window.__deadbolt) return;
  window.__deadbolt = true;

  // After the extension is reloaded or updated, scripts already running in open tabs are cut off from it and
  // Chrome throws "Extension context invalidated". Stand down quietly; the next page load runs the new script.
  const alive = () => { try { return !!chrome.runtime?.id; } catch { return false; } };
  const send = (msg) => new Promise((r) => {
    if (!alive()) return r({ ok: false, error: "reloaded" });
    try { chrome.runtime.sendMessage(msg, (reply) => r(chrome.runtime.lastError ? { ok: false } : reply)); }
    catch { r({ ok: false, error: "reloaded" }); }
  });

  const FM = globalThis.__deadboltFieldMap;   // fieldmap.js: which field is which

  // ---------- fields ----------

  /** Really visible to a person: no zero-size, invisible or transparent fields (a trick to harvest autofill). */
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
      const s = getComputedStyle(n);
      if (s.display === "none" || s.visibility === "hidden" || Number(s.opacity) < 0.1) return false;
    }
    return true;
  };

  /** A masked card number or CVV is a password-type box but not a password: never offered logins, never saved as one. */
  const isCardBox = (el) => { const k = FM?.classify(el); return k === "cc-csc" || k === "cc-number"; };

  const passwordFields = () => [...document.querySelectorAll('input[type="password"]')].filter((el) => visible(el) && !el.disabled && !el.readOnly && !isCardBox(el));

  /** The username field for a password field: the closest text/email input before it in the same form. */
  function usernameFor(pw) {
    const scope = pw.form || pw.closest("form, [role=form], section, main, div") || document;
    const inputs = [...scope.querySelectorAll('input:not([type]), input[type="text"], input[type="email"], input[type="tel"]')]
      .filter((el) => visible(el) && !el.disabled);
    const before = inputs.filter((el) => el.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
    const pick = (list) => list.find((el) => /user|email|login|account|name|phone/i.test(`${el.name} ${el.id} ${el.autocomplete} ${el.placeholder}`)) || list[list.length - 1];
    return pick(before) || null;
  }

  /** For READING only (never filling): two-step pages keep the step-one username in an off-screen field marked
   *  autocomplete="username". Its value is what the person typed earlier, so it's safe to save with. */
  function typedUsernameFor(pw) {
    const shown = usernameFor(pw);
    if (shown && shown.value.trim()) return shown.value.trim();
    const scope = pw.form || document;
    const kept = [...scope.querySelectorAll('input[autocomplete~="username"]')].find((el) => el.value.trim());
    return kept ? kept.value.trim() : "";
  }

  /** Step one of a two-step sign-in: a username/email field with no password field next to it yet. */
  const userWords = /user|email|login|account|identifier/i;
  function loneUsernameField(el) {
    if (!(el instanceof HTMLInputElement) || !["text", "email", "tel", ""].includes(el.type) || !visible(el) || el.disabled) return false;
    const scope = el.form || document;
    if ([...scope.querySelectorAll('input[type="password"]')].some(visible)) return false;
    return /\busername\b/.test(el.autocomplete) || el.type === "email" || userWords.test(`${el.name} ${el.id}`);
  }

  // ---------- email-only sign-in (emailed link or code): no password box, so the email is what gets saved ----------

  /** Visible email boxes that hold an address. Used to spot an email-only sign-in and to see when its form has gone. */
  const emailBoxes = (scope) => [...(scope || document).querySelectorAll("input")].filter((el) =>
    visible(el) && !el.disabled && ["email", "text"].includes(el.type) && el.value.includes("@")
    && (el.type === "email" || /\b(username|email)\b/.test(el.autocomplete) || /e-?mail/i.test(`${el.name} ${el.id} ${el.placeholder} ${el.ariaLabel || ""}`)));

  /** Visible boxes that look like a one-time-code entry (a single box, or a row of one-digit boxes). */
  const otpWords = /\b(otp|one.?time|verification|verify|passcode|security.?code|login.?code|sign.?in.?code|confirm(ation)?.?code)\b|\bcode\b/i;
  const notOtp = /zip|postal|promo|coupon|discount|gift|voucher|country|area|referral|invite|captcha|search|card/i;
  function otpBoxes() {
    const skip = ["password", "hidden", "checkbox", "radio", "submit", "button", "file", "email", "image"];
    const boxes = [...document.querySelectorAll("input")].filter((el) => visible(el) && !el.disabled && !el.readOnly && !skip.includes(el.type) && !isCardBox(el));
    const digits = boxes.filter((el) => el.maxLength === 1 && ["text", "tel", "number"].includes(el.type));
    return boxes.filter((el) => {
      if (/\bone-time-code\b/.test(el.autocomplete)) return true;
      const words = `${el.name} ${el.id} ${el.placeholder} ${el.ariaLabel || ""}`;
      if (notOtp.test(words)) return false;
      if (otpWords.test(words)) return true;
      if (digits.length >= 4 && digits.includes(el)) return true;
      return (el.inputMode === "numeric" || /\\d|0-9/.test(el.pattern || "")) && el.maxLength > 0 && el.maxLength <= 8;
    });
  }

  const signInWords = /log[ -]?in|sign[ -]?in|sign[ -]?up|continue|next|\b(send|email|text|get)\b.{0,25}\b(code|link|otp)\b|magic|passwordless|verify|register|create (an )?account|join|get started|access/i;
  const notSignIn = /subscribe|newsletter|updates|offers|waitlist|notify|notified|search|coupon|promo|discount|contact|message|feedback|invite|download|demo|quote|unsubscribe/i;

  /** A submitted form with one email address, no password box and a sign-in feel: keep the email so the next screens can offer to save it. */
  function emailOnlyCapture(form, button) {
    const scope = form || document;
    if (scope.querySelector("textarea")) return false;                                        // a contact form
    if ([...scope.querySelectorAll('input[type="password"]')].some(visible)) return false;   // password forms have their own path
    const boxes = emailBoxes(scope);
    if (boxes.length !== 1) return false;
    const el = boxes[0];
    const label = `${button?.textContent || ""} ${button?.value || ""} ${button?.ariaLabel || ""}`.slice(0, 120);
    const heading = (scope.querySelector?.("h1, h2, h3, legend")?.textContent || "").slice(0, 120);
    const attrs = `${form?.id || ""} ${typeof form?.className === "string" ? form.className : ""} ${form?.getAttribute?.("aria-label") || ""} ${el.placeholder || ""}`;
    if (notSignIn.test(`${label} ${heading} ${attrs}`)) return false;                        // newsletter, search, contact…
    const reads = /\busername\b/.test(el.autocomplete) || signInWords.test(label) || signInWords.test(heading)
               || /log-?in|sign-?in|sign-?up|signup|auth|register|session/i.test(location.pathname);
    if (!reads) return false;
    send({ type: "capture", username: el.value.trim(), password: "", passwordless: true });
    pollPending(60_000);   // the code or link step can take a while; checkPending extends this while it's still waiting
    return true;
  }

  /** Sets a value the way a person typing would, so React/Vue/Angular forms notice. */
  function setValue(el, value) {
    if (!el) return;
    el.focus();
    const proto = Object.getPrototypeOf(el);
    const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    setter ? setter.call(el, value) : (el.value = value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    flashFilled(el);   // a short visual cue only; the value above is already in
  }

  // ---------- UI (closed shadow root) ----------

  const host = document.createElement("deadbolt-ui");
  host.style.cssText = "all: initial; position: fixed; z-index: 2147483647; top: 0; left: 0;";
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `
    <style>
      :host { all: initial; }
      [hidden] { display: none !important; }   /* our display rules must never override "hidden" */
      * { box-sizing: border-box; font-family: -apple-system, system-ui, sans-serif; }
      .menu { position: fixed; min-width: 280px; max-width: 360px; background: #111216; color: #F2F0EA; border: 1px solid #2B2E36;
              border-radius: 12px; box-shadow: 0 14px 40px rgba(0,0,0,.35); overflow: hidden; font-size: 14px; }
      .head { display: flex; align-items: center; gap: 8px; padding: 9px 12px; border-bottom: 1px solid #22252D; color: #A3A7B0; font-size: 12px; }
      .head svg { width: 16px; height: 16px; flex: none; }
      button.row { all: unset; display: flex; align-items: center; gap: 10px; width: 100%; min-height: 52px; padding: 10px 12px; cursor: pointer; box-sizing: border-box; }
      /* Long lists scroll inside the menu: three rows and a peek of the fourth, so it is clear there is more. */
      .list { overflow-y: auto; overscroll-behavior: contain; scrollbar-width: thin; scrollbar-color: #3A3E48 transparent; }
      .list.scroll { max-height: 184px; }
      .count { margin-left: auto; color: #8A8F99; font-size: 11px; white-space: nowrap; }
      button.row:hover, button.row:focus-visible { background: #1F2229; outline: none; }
      .t { display: flex; flex-direction: column; gap: 1px; min-width: 0; }
      .t b { font-weight: 600; font-size: 14px; color: #F2F0EA; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .t span { font-size: 12px; color: #A3A7B0; }
      .tile { width: 26px; height: 26px; border-radius: 7px; background: #2A2F3A; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 12px; flex: none; }
      .star { margin-left: auto; color: #D4AF6A; font-size: 12px; }
      .card { position: fixed; top: 16px; right: 16px; width: 340px; background: #111216; color: #F2F0EA; border: 1px solid #2B2E36;
              border-radius: 16px; box-shadow: 0 20px 60px rgba(0,0,0,.4); padding: 16px; display: flex; flex-direction: column; gap: 12px; font-size: 14px; }
      .card h2 { margin: 0; font-size: 16px; font-weight: 700; }
      .card p { margin: 0; color: #A3A7B0; font-size: 13px; }
      .btns { display: flex; gap: 8px; }
      .primary, .secondary { all: unset; flex: 1; text-align: center; height: 36px; line-height: 36px; border-radius: 9px; font-weight: 600; cursor: pointer; font-size: 14px; }
      .primary { background: #D4AF6A; color: #1A1408; }
      .secondary { border: 1px solid #2B2E36; color: #F2F0EA; font-weight: 500; }
      .link { all: unset; color: #D4AF6A; font-size: 13px; cursor: pointer; }
      .ok { color: #6FCF97; font-weight: 600; }
      .wait { position: fixed; top: 16px; right: 16px; width: 320px; background: #111216; color: #F2F0EA; border: 1px solid #2B2E36;
              border-radius: 14px; box-shadow: 0 20px 60px rgba(0,0,0,.4); padding: 14px 16px; display: flex; gap: 12px; align-items: center; font-size: 14px; }
      .wait .ico { position: relative; width: 38px; height: 38px; flex: none; }
      .wait .ico svg { width: 38px; height: 38px; }
      .wait.busy .ico::after { content: ""; position: absolute; inset: -4px; border-radius: 12px; border: 2px solid #D4AF6A; opacity: 0; animation: ping 1.4s ease-out infinite; }
      @keyframes ping { 0% { transform: scale(.8); opacity: .8; } 100% { transform: scale(1.25); opacity: 0; } }
      .wait b { display: block; font-size: 14px; font-weight: 600; }
      .wait span { display: block; margin-top: 2px; font-size: 12px; color: #A3A7B0; }
      @media (prefers-reduced-motion: reduce) { .wait.busy .ico::after { animation: none; opacity: .6; } }
      /* Fill cue: a brass sweep and a small lock over each field Deadbolt fills. Drawn here, never on the page itself. */
      .fx { position: fixed; top: 0; left: 0; width: 0; height: 0; pointer-events: none; }
      .glow { position: fixed; pointer-events: none; overflow: hidden; animation: glow 950ms ease-out forwards; }
      .glow::before { content: ""; position: absolute; inset: 0; transform: translateX(-100%); animation: sweep 650ms cubic-bezier(.3,.1,.2,1) forwards;
                      background: linear-gradient(100deg, transparent 0%, rgba(212,175,106,.35) 40%, rgba(255,236,190,.75) 50%, rgba(212,175,106,.35) 60%, transparent 100%); }
      @keyframes glow { 0% { box-shadow: 0 0 0 2px rgba(212,175,106,.95), 0 0 16px 2px rgba(212,175,106,.55); opacity: 1; }
                        65% { opacity: 1; } 100% { box-shadow: 0 0 0 2px rgba(212,175,106,0), 0 0 16px 2px rgba(212,175,106,0); opacity: 0; } }
      @keyframes sweep { to { transform: translateX(100%); } }
      .badge { position: fixed; pointer-events: none; display: grid; place-items: center; border-radius: 50%; background: #D4AF6A; color: #1A1408;
               box-shadow: 0 2px 8px rgba(0,0,0,.35); animation: pop 1150ms cubic-bezier(.2,1.5,.4,1) forwards; }
      .badge svg { width: 62%; height: 62%; }
      @keyframes pop { 0% { transform: scale(0); opacity: 0; } 22% { transform: scale(1); opacity: 1; } 78% { transform: scale(1); opacity: 1; } 100% { transform: scale(.85); opacity: 0; } }
      @media (prefers-reduced-motion: reduce) {
        .glow::before { display: none; }
        .glow { animation: glowStill 900ms linear forwards; }
        @keyframes glowStill { 0% { box-shadow: 0 0 0 2px rgba(212,175,106,.9); opacity: 1; } 100% { box-shadow: 0 0 0 2px rgba(212,175,106,.9); opacity: 0; } }
        .badge { animation: badgeStill 900ms linear forwards; }
        @keyframes badgeStill { 0% { opacity: 1; } 100% { opacity: 0; } }
      }
    </style>
    <div class="menu" hidden role="listbox" aria-label="Deadbolt"></div>
    <div class="card" hidden role="dialog" aria-label="Deadbolt"></div>
    <div class="wait" hidden role="status" aria-live="polite"></div>
    <div class="fx" aria-hidden="true"></div>`;
  const fx = root.querySelector(".fx");
  const menu = root.querySelector(".menu");
  const card = root.querySelector(".card");
  const wait = root.querySelector(".wait");
  // ---------- fill cue ----------

  const lockSvg = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 11V8a4 4 0 0 1 8 0v3" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/><rect x="5" y="11" width="14" height="10" rx="2.4" fill="currentColor"/></svg>`;
  let fxNext = 0;
  /** Fields filled together (username, then password) get their cue a moment apart, so it reads as a sequence. */
  function flashFilled(el) {
    try {
      const now = performance.now(), delay = Math.max(0, fxNext - now);
      fxNext = now + delay + 140;
      setTimeout(() => drawFill(el), delay);
    } catch { /* a cue must never get in the way of filling */ }
  }
  function drawFill(el) {
    try {
      if (!el.isConnected) return;
      const r = el.getBoundingClientRect();
      if (r.width < 8 || r.height < 8 || r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) return;
      const radius = getComputedStyle(el).borderRadius;
      const glow = document.createElement("div");
      glow.className = "glow";
      glow.style.cssText = `left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;border-radius:${/^[\d.]+(px|%|em|rem)?( [\d.]+(px|%|em|rem)?){0,3}$/.test(radius) ? radius : "6px"};`;
      const size = Math.max(12, Math.min(18, r.height - 8));
      const badge = document.createElement("div");
      badge.className = "badge";
      badge.style.cssText = `left:${r.right - size - 8}px;top:${r.top + (r.height - size) / 2}px;width:${size}px;height:${size}px;`;
      badge.innerHTML = lockSvg;
      attach();   // the overlay is only added to the page when something needs it
      fx.append(glow, badge);
      setTimeout(() => { glow.remove(); badge.remove(); }, 1400);
    } catch { /* ignore */ }
  }

  // The logo is drawn inline: loading the extension's own icon file would need it exposed to every page,
  // which would also let pages detect that Deadbolt is installed.
  const logo = `<svg viewBox="0 0 32 32" aria-hidden="true"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#FFD84A"/><stop offset="1" stop-color="#B97A08"/></linearGradient></defs>
    <rect width="32" height="32" rx="7.5" fill="url(#g)"/>
    <path d="M11.5 14v-2.5a4.5 4.5 0 0 1 9 0V14" fill="none" stroke="#FDF7E7" stroke-width="2.6"/>
    <rect x="8.5" y="14" width="15" height="11.5" rx="2.8" fill="#FDF7E7"/>
    <path d="M16 16.6c1.3.9 2.4 1.2 3.4 1.3v2.3c0 2-1.5 3.3-3.4 4-1.9-.7-3.4-2-3.4-4v-2.3c1-.1 2.1-.4 3.4-1.3z" fill="#D49A1C"/></svg>`;
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  /** Rows in a scrolling list (more than three scroll) plus how many there are. */
  const listOf = (rows) => {
    const n = (rows.match(/<button class="row"/g) || []).length;
    return { n, html: `<div class="list${n > 3 ? " scroll" : ""}">${rows}</div>` };
  };
  // Always (re)append so our UI is the last, topmost element: a page can't slip an overlay above it.
  const attach = () => document.documentElement.appendChild(host);

  /** True only if the click really landed on our UI (not on something the page layered over it). */
  const genuine = (e) => e.isTrusted && document.elementFromPoint(e.clientX, e.clientY) === host;

  let anchor = null;

  function place() {
    if (!anchor || menu.hidden) return;
    const r = anchor.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(r.left, innerWidth - 368))}px`;
    menu.style.top = `${Math.min(r.bottom + 6, innerHeight - 60)}px`;
  }
  addEventListener("scroll", place, true);
  addEventListener("resize", place);

  // Every menu request gets a number. An answer is used only if no newer request (or dismissal) happened meanwhile, so a slow
  // "locked" reply can never overwrite the fresh list drawn after unlocking.
  let menuSeq = 0;
  function hideMenu() { menuSeq++; menu.hidden = true; anchor = null; }

  let loading = null;
  let filling = false;   // true while Deadbolt itself is filling fields

  async function showMenu(field, force = false) {
    // `force` is for the refresh right after unlocking: it must run even though a (stale, locked) menu is already open.
    if (!force && anchor === field && !menu.hidden) return;   // already open for this field: leave it alone
    if (!force && loading === field) return;                  // a request for this field is in flight
    const pw = field.type === "password" ? field : passwordFields().find((p) => usernameFor(p) === field);
    const lone = !pw && loneUsernameField(field);   // two-step step one: fill the username only
    if (!pw && !lone) return;
    const fresh = isNewPasswordField(field);         // a "new password" box: offer a strong one instead of saved logins
    loading = field;
    const seq = ++menuSeq;
    const reply = await send({ type: fresh ? "status" : "accounts" }).finally(() => { loading = null; });
    if (!field.isConnected || seq !== menuSeq) return; // the page replaced the field, or a newer request / dismissal took over
    let rows = "";
    if (reply.error === "noHost") return; // Deadbolt isn't installed on this Mac: stay out of the way
    if (fresh) {
      rows = `<button class="row" data-act="generate"><div class="tile">✦</div><div class="t"><b>Use a strong password</b><span>Fills the new password and its confirmation</span></div></button>`;
    } else if (reply.error === "locked") {
      rows = `<button class="row" data-act="unlock"><div class="tile">🔒</div><div class="t"><b>Unlock Deadbolt</b><span>Touch ID on your Mac</span></div></button>`;
    } else if (reply.ok && reply.accounts.some((a) => !a.codeOnly)) {
      rows = reply.accounts.filter((a) => !a.codeOnly).map((a) => `
        <button class="row" data-id="${esc(a.id)}" role="option">
          <div class="tile">${esc((a.name || a.username || a.title || "?")[0].toUpperCase())}</div>
          <div class="t"><b>${esc(a.name || a.username || a.title)}</b><span>${esc(a.name ? [a.username, a.label].filter(Boolean).join(" · ") : (a.label || (a.hasPassword ? "Password" : a.hasPasskey ? "Passkey only" : "Code only")))}</span></div>
          ${a.preferred ? '<span class="star">★</span>' : ""}
        </button>`).join("");
    } else {
      return; // nothing saved for this site
    }
    attach();
    const L = listOf(rows);
    menu.innerHTML = `<div class="head">${logo}Deadbolt · ${esc(location.hostname)}${L.n > 3 ? `<span class="count">${L.n} accounts · scroll</span>` : ""}</div>${L.html}`;
    menu.hidden = false;
    anchor = field;
    place();
    menu.querySelectorAll("button.row").forEach((b) => b.addEventListener("mousedown", (e) => e.preventDefault()));
    menu.querySelectorAll("button.row").forEach((b) => b.addEventListener("click", async (e) => {
      if (!genuine(e)) return;
      if (b.dataset.act === "generate") {
        const g = await send({ type: "generate" });
        hideMenu();
        if (g.ok && g.password) fillNewPassword(field, g.password);
        return;
      }
      if (b.dataset.act === "unlock") {
        hideMenu();
        const r = await send({ type: "unlock" });
        if (r.ok && !r.locked) { field.focus(); showMenu(field, true); }
        return;
      }
      const r = await send({ type: "fill", id: b.dataset.id });
      hideMenu();
      if (!r.ok) return;
      // Filling moves focus around (setValue focuses each field). Those are our own focus changes, not the
      // person arriving in a field, so they must not pop the menu open again on the password field.
      filling = true;
      try {
        if (lone) { if (r.username) setValue(field, r.username); field.focus(); return; }
        const user = usernameFor(pw);
        if (user && r.username) setValue(user, r.username);
        if (r.password) setValue(pw, r.password);
        pw.focus();
      } finally { filling = false; hideMenu(); }
    }));
  }

  const isNewPasswordField = (el) => el instanceof HTMLInputElement && el.type === "password" && /\bnew-password\b/.test(el.autocomplete);

  /** Fills a generated password into every "new password" box of the form (new + confirm), then says what happened. */
  function fillNewPassword(field, password) {
    const scope = field.form || field.closest("form, [role=form], section, main") || document;
    const targets = [...scope.querySelectorAll('input[type="password"]')]
      .filter((el) => isNewPasswordField(el) && visible(el) && !el.disabled && !el.readOnly);
    if (!targets.includes(field)) targets.push(field);
    filling = true;
    try { for (const el of targets) setValue(el, password); field.focus(); }
    finally { filling = false; hideMenu(); }
    attach();
    menu.innerHTML = `<div class="head">${logo}<span class="ok">Strong password filled</span> · Deadbolt will offer to save it when you submit</div>`;
    menu.hidden = false;
    anchor = field;
    place();
    setTimeout(() => { if (anchor === field && !menu.querySelector(".row")) hideMenu(); }, 4000);
  }

  // ---------- cards and identities ----------
  // The menu lists names and the last four digits only. A pick asks the Mac for just the fields this form has; the Mac asks for
  // Touch ID before a card number or security code leaves it, and its prompt names this site. Top frame only, https only.

  const hasValue = (el) => (el.tagName === "SELECT" ? el.selectedIndex > 0 && el.value !== "" : el.value !== "");
  const filledByUs = new WeakSet();   // fields Deadbolt filled: those may be overwritten by a second pick

  const scopeFor = (field) => field.form || document;   // wide: only for deciding whether to offer a menu at all

  /** The part of the page a pick should fill: grown outward from the field, stopping before it would take in a second field of the
   *  same kind. A merchant's saved-cards list has a CVV box per card; picking a card there must fill only the box beside it. */
  function pickScope(field, group) {
    const key = FM.classify(field);
    const limit = field.form || document.documentElement;
    const all = FM.collect(limit, group, visible);
    let best = field.parentElement || limit;
    for (let el = field.parentElement; el; el = el.parentElement) {
      if (all.filter((f) => f.key === key && el.contains(f.el)).length > 1) break;
      best = el;
      if (el === limit) break;
    }
    return best;
  }

  /** Still more than one box for the same thing (two address blocks, say): keep the one nearest the field the person is in. */
  function onePerKey(targets, field) {
    const at = targets.findIndex((t) => t.el === field);
    const nearest = new Map();
    targets.forEach((t, i) => {
      const d = at < 0 ? i : Math.abs(i - at);
      if (!nearest.has(t.key) || d < nearest.get(t.key).d) nearest.set(t.key, { t, d });
    });
    return targets.filter((t) => nearest.get(t.key).t === t);
  }

  /** The last four digits a saved-cards row shows next to the field ("****6847"), if the nearest part of the page that shows any
   *  shows exactly one set. Several different ones means the box can't be matched to a card, so we don't guess. */
  function last4Hint(field) {
    for (let el = field.parentElement, i = 0; el && i < 8; el = el.parentElement, i++) {
      const found = new Set([...(el.textContent || "").slice(0, 2000).matchAll(/(?:[*•x]{2,}|ending(?: in)?|last 4(?: digits)?:?)\s*(\d{4})(?!\d)/gi)].map((m) => m[1]));
      if (found.size === 1) return [...found][0];
      if (found.size > 1) return null;
    }
    return null;
  }

  /** "card" or "identity" when this field sits in a form worth offering one for; otherwise null. */
  function fillGroupFor(field) {
    if (!FM) return null;
    const key = FM.classify(field);
    if (!key || !visible(field)) return null;
    const group = FM.groupOf(key);
    const scope = scopeFor(field);
    return FM.worthOffering(group, FM.collect(scope, group, visible), scope, visible) ? group : null;
  }

  function setSelect(el, option) {
    el.focus();
    const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")?.set;
    setter ? setter.call(el, option.value) : (el.value = option.value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    flashFilled(el);
  }

  async function showFillMenu(field, group, force = false) {
    if (!force && anchor === field && !menu.hidden) return;
    if (!force && loading === field) return;
    loading = field;
    const seq = ++menuSeq;
    const reply = await send({ type: "fillCandidates", kind: group }).finally(() => { loading = null; });
    if (!field.isConnected || seq !== menuSeq) return;
    if (reply.error === "noHost" || reply.error === "reloaded") return;
    let rows = "";
    if (reply.error === "locked") {
      rows = `<button class="row" data-act="unlock"><div class="tile">🔒</div><div class="t"><b>Unlock Deadbolt</b><span>Touch ID on your Mac</span></div></button>`;
    } else if (reply.ok && reply.items.length) {
      // On a list of the merchant's own saved cards the row shows the last four digits: offer the card that matches.
      let shown = reply.items;
      const hint = group === "card" ? last4Hint(field) : null;
      const same = hint ? shown.filter((it) => it.last4 === hint) : [];
      if (same.length) shown = same;
      rows = shown.map((it) => `
        <button class="row" data-pick="${esc(it.id)}" role="option">
          <div class="tile">${group === "card" ? "💳" : "👤"}</div>
          <div class="t"><b>${esc(it.title)}</b><span>${group === "card"
            ? esc(`${it.brand} •••• ${it.last4}${it.expiry ? " · " + it.expiry : ""}${it.expired ? " · Expired" : ""}`) : esc(it.name || "")}</span></div>
        </button>`).join("");
    } else {
      return;   // nothing saved of this kind
    }
    attach();
    const L = listOf(rows);
    menu.innerHTML = `<div class="head">${logo}Deadbolt · ${group === "card" ? "Cards" : "Identities"} · ${esc(location.hostname)}${L.n > 3 ? `<span class="count">${L.n} · scroll</span>` : ""}</div>${L.html}`;
    menu.hidden = false;
    anchor = field;
    place();
    menu.querySelectorAll("button.row").forEach((b) => b.addEventListener("mousedown", (e) => e.preventDefault()));
    menu.querySelectorAll("button.row").forEach((b) => b.addEventListener("click", async (e) => {
      if (!genuine(e)) return;   // only a real click on our menu, never one the page made or layered over it
      hideMenu();
      if (b.dataset.act === "unlock") {
        const r = await send({ type: "unlock" });
        if (r.ok && !r.locked) { field.focus(); showFillMenu(field, group, true); }
        return;
      }
      await fillWithItem(group, b.dataset.pick, field);
    }));
  }

  /** Asks the Mac for what this form needs and writes it in. Skips fields the person already filled in. */
  async function fillWithItem(group, id, field) {
    const targets = onePerKey(FM.collect(pickScope(field, group), group, visible), field);
    if (!targets.length) return flashWait("Nothing to fill here", location.hostname);
    const want = [...new Set(targets.flatMap((t) => FM.wanted(t.key, t.el)))];
    const timer = setTimeout(() => showWait(true, group === "card" ? "Fill card" : "Fill details", `Confirm on your Mac · ${location.hostname}`), 350);
    let r;
    try { r = await send({ type: "fillItem", id, want }); } finally { clearTimeout(timer); hideWait(); }
    if (!r?.ok) {
      if (r?.error === "cancelled") flashWait("Cancelled", "Nothing was filled");
      else if (r?.error === "locked") flashWait("Deadbolt is locked", "Unlock it, then try again");
      else flashWait("Couldn’t fill", "Open Deadbolt and try again");
      return;
    }
    let n = 0;
    filling = true;
    try {
      for (const { key, el } of targets) {
        if (!el.isConnected || !visible(el)) continue;
        if (hasValue(el) && !filledByUs.has(el) && el !== field) continue;   // keep what the person typed
        const p = FM.plan(key, el, r.values || {});
        if (!p) continue;
        if (p.option) setSelect(el, p.option); else setValue(el, p.text);
        filledByUs.add(el);
        n++;
      }
      field.focus();
    } finally { filling = false; hideMenu(); }
    flashWait(n ? (group === "card" ? "Card filled" : "Details filled") : "Nothing matched", location.hostname);
  }

  const isLoginField = (el) =>
    el instanceof HTMLInputElement && (el.type === "password" || passwordFields().some((p) => usernameFor(p) === el) || loneUsernameField(el));

  // Open on focus and on any click in a login field (pages often re-focus fields, so clicks must re-open).
  // Safari: system AutoFill (Deadbolt's provider) already offers logins in the field; don't show a second menu.
  const inlineMenu = !(/Safari\//.test(navigator.userAgent) && !/Chrome\/|Chromium\//.test(navigator.userAgent));

  document.addEventListener("focusin", (e) => {
    if (filling) return;
    // A card or address field gets the cards / identities menu in every browser (there is no system AutoFill for these).
    const group = fillGroupFor(e.target);
    if (group) { if (!hasValue(e.target)) showFillMenu(e.target, group); else hideMenu(); return; }
    if (!inlineMenu) return;
    // Tabbing into a field that already has a value (filled, or typed) doesn't need suggestions; a click still opens them.
    if (isLoginField(e.target)) { if (!e.target.value) showMenu(e.target); else hideMenu(); }
    else if (e.target !== host) hideMenu();         // moved to some other field
  }, true);
  document.addEventListener("pointerdown", (e) => {
    const path = e.composedPath();
    if (path.includes(host)) return;                 // a click inside our menu
    if (anchor && path.includes(anchor)) return;     // a click in the field it belongs to: keep it open
    const group = fillGroupFor(e.target);
    if (group) { showFillMenu(e.target, group); return; }
    if (inlineMenu && isLoginField(e.target)) { showMenu(e.target); return; }
    hideMenu();                                      // anywhere else closes it
  }, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") hideMenu(); }, true);

  // ---------- save after sign-in ----------

  function capture(form, button) {
    const filled = (form ? [...form.querySelectorAll('input[type="password"]')] : passwordFields()).filter((p) => p.value && !isCardBox(p));
    if (!filled.length) { emailOnlyCapture(form, button); return; }
    // Change-password forms have old + new (+ confirm): save the NEW one, never the old.
    const pw = filled.find((p) => p.autocomplete === "new-password") || (filled.length > 1 ? filled[filled.length - 1] : filled[0]);
    send({ type: "capture", username: typedUsernameFor(pw), password: pw.value });
    pollPending();   // pages that don't navigate (single-page apps): look again until the form is gone
  }

  /** Step one done (Next pressed): remember the username so step two — maybe on another page — saves with it. */
  function rememberStepUser(form) {
    const f = [...(form || document).querySelectorAll("input")].find((el) => loneUsernameField(el) && el.value.trim());
    if (f) send({ type: "stepUser", username: f.value.trim() });
  }

  const filledPassword = (scope) => [...(scope || document).querySelectorAll('input[type="password"]')].some((p) => p.value && visible(p) && !isCardBox(p));

  document.addEventListener("submit", (e) => { capture(e.target, e.submitter); rememberStepUser(e.target); }, true);
  document.addEventListener("click", (e) => {
    const b = e.target.closest?.('button, input[type="submit"], input[type="image"], [role="button"], a');
    if (!b || host.contains(b)) return;
    const form = b.form || b.closest("form");
    // Any button pressed in a form with a filled password ("Get started", "Join", an arrow…); outside a form, only
    // buttons that read like signing in.
    if (form ? filledPassword(form)
             : filledPassword() && /log ?in|sign ?in|sign ?up|continue|next|submit|register|create|join|start|go/i.test(`${b.textContent} ${b.value || ""} ${b.ariaLabel || ""}`)) {
      capture(form, b);
    } else if (!filledPassword(form || undefined)) { rememberStepUser(form); emailOnlyCapture(form, b); }
  }, true);
  // Leaving the page with a typed password still filled in (sites that sign in from script and navigate away).
  addEventListener("pagehide", () => { if (filledPassword()) capture(null); }, true);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && e.target instanceof HTMLInputElement && (e.target.type === "password" || e.target.form)) capture(e.target.form, null);
  }, true);

  /** Single-page apps sign in without leaving the page, and can take a few seconds. Look every 1.5 s for up to 40 s
   *  (stopping as soon as the question is settled) instead of once. */
  let pollTimer = null, pollUntil = 0, waiting = false;
  function pollPending(ms = 40_000) {
    pollUntil = Math.max(pollUntil, Date.now() + ms);
    if (pollTimer) return;
    pollTimer = setInterval(async () => {
      waiting = false;
      const settled = await checkPending();
      if (waiting) pollUntil = Math.max(pollUntil, Date.now() + 10_000);   // an email-only sign-in is still going: keep looking
      if (settled || Date.now() > pollUntil) { clearInterval(pollTimer); pollTimer = null; }
    }, 1500);
  }

  /** True when settled (a prompt was shown, or there is nothing to ask); false to keep waiting. */
  async function checkPending() {
    if (!card.hidden) return false;
    if (passwordFields().some((p) => p.value)) return false; // still on the form (maybe a wrong password): wait
    // For an email-only sign-in the Mac side holds the question until the sign-in has finished: no password box (two-step),
    // no code box and no email form left on the page.
    const formUp = passwordFields().length > 0 || otpBoxes().length > 0 || emailBoxes(document).length > 0;
    const r = await send({ type: "pendingSave", formUp });
    if (!r.ok) return false;
    if (r.action === "wait") { waiting = true; pollPending(0); return false; }
    if (r.action === "none") return r.reason !== "otherSite";
    attach();
    if (r.action === "unlock") {
      // Deadbolt is locked: keep the sign-in waiting and offer to unlock, instead of losing it.
      card.innerHTML = `
        <div class="head" style="padding:0;border:0">${logo}Deadbolt</div>
        <h2>Save to Deadbolt?</h2>
        <p>${esc(r.username || "No username")} · ${esc(r.site)}${r.passwordless ? " · no password" : ""}</p>
        <p>Deadbolt is locked. Unlock to save this login.</p>
        <div class="btns"><button class="primary" data-a="unlock">Unlock with Touch ID</button><button class="secondary" data-a="no">Not now</button></div>`;
      card.hidden = false;
      card.querySelector('[data-a="unlock"]').addEventListener("click", async (e) => {
        if (!genuine(e)) return;
        const u = await send({ type: "unlock" });
        card.hidden = true;
        if (u.ok && !u.locked) checkPending();
      });
      card.querySelector('[data-a="no"]').addEventListener("click", async (e) => {
        if (!genuine(e)) return;
        await send({ type: "dismissSave" }); card.hidden = true;
      });
      return true;
    }
    const update = r.action === "update";
    const adds = update && r.addsPassword;   // the saved login had no password yet
    card.innerHTML = `
      <div class="head" style="padding:0;border:0">${logo}Deadbolt</div>
      <h2>${adds ? "Add the password to your saved login?" : update ? "Update saved password?" : "Save to Deadbolt?"}</h2>
      <p>${esc(r.username || "No username")} · ${esc(r.site)}${r.passwordless ? " · no password" : ""}</p>
      ${r.passwordless ? "<p>This site signs you in with an emailed link or code. Deadbolt keeps the email so you can copy it next time.</p>" : ""}
      ${update && !adds ? "<p>The old password moves to history, so you can undo this.</p>" : ""}
      <div class="btns"><button class="primary" data-a="save">${adds ? "Add password" : update ? "Update" : "Save"}</button><button class="secondary" data-a="no">Not now</button></div>
      ${update ? '<button class="link" data-a="separate">Save as a separate login</button>' : ""}`;
    card.hidden = false;
    card.querySelectorAll("[data-a]").forEach((b) => b.addEventListener("click", async (e) => {
      if (!genuine(e)) return;
      if (b.dataset.a === "no") { await send({ type: "dismissSave" }); card.hidden = true; return; }
      const res = await send({ type: "save", separate: b.dataset.a === "separate" });
      card.innerHTML = res.ok ? `<p class="ok">✓ ${update && b.dataset.a !== "separate" ? (adds ? "Password added" : "Password updated") : "Saved to Deadbolt"}</p>`
                              : `<p>Couldn’t save — open Deadbolt and try again.</p>`;
      setTimeout(() => (card.hidden = true), 2200);
    }));
    return true;
  }

  // Runs at document_start (to catch early passkey requests): wait for the page before looking for forms.
  const whenReady = (fn) => (document.readyState === "loading" ? document.addEventListener("DOMContentLoaded", fn, { once: true }) : fn());
  whenReady(() => setTimeout(checkPending, 800)); // after a navigation that followed a sign-in
  send({ type: "badge" });       // toolbar badge: logins saved for this site

  // ---------- passkeys (requests relayed from inject.js in the page world) ----------

  window.addEventListener("message", async (e) => {
    if (e.source !== window || e.data?.__deadbolt !== "passkey-request") return;
    const { id, op, payload } = e.data;
    window.postMessage({ __deadbolt: "passkey-ack", id }, window.location.origin);
    const answer = (reply) => window.postMessage({ __deadbolt: "passkey-reply", id, reply }, window.location.origin);
    if (op !== "create" && op !== "get") return answer({ ok: false, error: "declined" });
    // The Mac shows Touch ID; this note says why and where to look. It appears only if the Mac hasn't answered within
    // a moment, so a quick "no passkey here" (the browser then handles it) never flashes anything.
    const ask = async (msg) => {
      const hostName = location.hostname;
      const timer = setTimeout(() => showWait(true, op === "create" ? "Create a passkey" : "Sign in with a passkey",
        `Confirm with Touch ID on your Mac · ${hostName}`), 350);
      try { return await send(msg); } finally { clearTimeout(timer); hideWait(); }
    };
    let reply = await ask({ type: op === "create" ? "passkeyCreate" : "passkeyGet", payload });
    if (reply?.ok && reply.choices) {
      const chosen = await choosePasskey(reply.choices);
      if (!chosen) return answer({ ok: false, error: "NotAllowedError" });
      reply = await ask({ type: "passkeyGet", payload: { ...payload, choose: chosen } });
    }
    if (reply?.ok) flashWait(op === "create" ? "Passkey saved" : "Passkey used", location.hostname);
    else if (reply?.error === "NotAllowedError") flashWait("Cancelled", "No passkey was used");
    answer(reply || { ok: false, error: "noHost" });
  });

  let waitTimer = null;
  function hideWait() { clearTimeout(waitTimer); wait.hidden = true; wait.classList.remove("busy"); }
  /** busy = waiting for Touch ID on the Mac (pulsing); otherwise a short result note. */
  function showWait(busy, title, detail) {
    clearTimeout(waitTimer);
    attach();
    wait.innerHTML = `<div class="ico">${logo}</div><div><b>${esc(title)}</b><span>${esc(detail)}</span></div>`;
    wait.classList.toggle("busy", busy);
    wait.hidden = false;
  }
  function flashWait(title, detail) {
    showWait(false, title, detail);
    waitTimer = setTimeout(hideWait, 2200);
  }

  /** Several passkeys for this site: let the person pick (our UI, so the page can't see or fake it). */
  function choosePasskey(choices) {
    return new Promise((resolve) => {
      attach();
      card.innerHTML = `
        <div class="head" style="padding:0;border:0">${logo}Deadbolt</div>
        <h2>Sign in with a passkey</h2>
        <p>Choose an account for ${esc(location.hostname)}</p>
        ${choices.map((c) => `<button class="row" data-id="${esc(c.id)}"><div class="tile">${esc((c.name || "?")[0].toUpperCase())}</div>
          <div class="t"><b>${esc(c.name || "Account")}</b><span>Passkey</span></div></button>`).join("")}
        <div class="btns"><button class="secondary" data-a="cancel">Cancel</button></div>`;
      card.hidden = false;
      const done = (v) => { card.hidden = true; resolve(v); };
      card.querySelectorAll("button.row").forEach((b) => b.addEventListener("click", (e) => { if (genuine(e)) done(b.dataset.id); }));
      card.querySelector('[data-a="cancel"]').addEventListener("click", (e) => { if (genuine(e)) done(null); });
    });
  }

  // ---------- popup asks this page to fill ----------

  chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.type === "fillItemFromPopup") {
      // From the extension's own popup only (never a tab): fill the card or identity fields of this page.
      if (sender.id !== chrome.runtime.id || sender.tab || !FM) return;
      const group = msg.kind === "card" ? "card" : msg.kind === "identity" ? "identity" : null;
      const active = document.activeElement;
      const here = group && active && FM.classify(active) && FM.groupOf(FM.classify(active)) === group && visible(active) ? active : null;
      const all = group ? FM.collect(document, group, visible) : [];
      const field = here || all[0]?.el || null;
      if (!field) { sendResponse({ ok: false, error: "noFields" }); return; }
      // Several boxes for the same thing (a CVV per saved card, two address blocks) and none focused: don't guess which.
      if (!here && new Set(all.map((f) => f.key)).size !== all.length) { sendResponse({ ok: false, error: "ambiguous" }); return; }
      sendResponse({ ok: true });
      fillWithItem(group, String(msg.id || ""), field);
      return;
    }
    if (msg.type !== "fillFromPopup") return;
    const pw = passwordFields()[0];
    if (pw) { const u = usernameFor(pw); if (u && msg.username) setValue(u, msg.username); setValue(pw, msg.password); }
    else if (document.activeElement instanceof HTMLInputElement) setValue(document.activeElement, msg.username);
    sendResponse({ ok: !!pw });
  });
})();
