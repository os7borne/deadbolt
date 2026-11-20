// Shared helpers for the Deadbolt test lab. Nothing leaves this browser: test data lives in localStorage.
const Lab = {
  b64url(buf) {
    const b = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer || buf);
    let s = ""; for (const x of b) s += String.fromCharCode(x);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  unb64url(s) {
    const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
    return Uint8Array.from(b, (c) => c.charCodeAt(0));
  },
  random(n) { return crypto.getRandomValues(new Uint8Array(n)); },
  async sha256(data) { return new Uint8Array(await crypto.subtle.digest("SHA-256", data)); },
  equal(a, b) { if (a.length !== b.length) return false; for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false; return true; },
  /** Renders a list of [ok, label, detail] checks. */
  checks(el, rows) {
    el.innerHTML = rows.map(([ok, label, detail]) => `<div class="check"><span class="${ok === true ? "ok" : ok === false ? "bad" : "muted"}">${ok === true ? "✓" : ok === false ? "✗" : "•"}</span>
      <div><div>${label}</div>${detail ? `<div class="muted mono">${detail}</div>` : ""}</div></div>`).join("");
  },
};
