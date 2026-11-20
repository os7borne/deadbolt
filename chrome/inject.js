// Deadbolt passkeys — runs in the page's own JavaScript world (MAIN), top frame only.
// Wraps navigator.credentials.create/get for public-key requests and relays them to Deadbolt's content script,
// which asks Deadbolt for Mac. This file decides nothing: the origin, the rpId check, clientDataJSON and the
// Touch ID check all happen in the Mac app. If Deadbolt has no passkey for the site, or isn't running, the
// browser's own implementation runs as if Deadbolt weren't here.
(() => {
  if (!window.isSecureContext || !navigator.credentials || window.__deadboltPasskeys) return;
  Object.defineProperty(window, "__deadboltPasskeys", { value: true });

  const original = { create: navigator.credentials.create.bind(navigator.credentials), get: navigator.credentials.get.bind(navigator.credentials) };
  const pending = new Map();
  let seq = 0;

  const toB64 = (buf) => {
    const bytes = buf instanceof ArrayBuffer ? new Uint8Array(buf) : new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
    let s = ""; for (const b of bytes) s += String.fromCharCode(b);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const fromB64 = (s) => {
    const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
    const out = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
    return out.buffer;
  };

  const acked = new Set();
  window.addEventListener("message", (e) => {
    if (e.source !== window) return;
    if (e.data?.__deadbolt === "passkey-ack") { acked.add(e.data.id); return; }
    if (e.data?.__deadbolt !== "passkey-reply") return;
    const p = pending.get(e.data.id);
    if (p) { pending.delete(e.data.id); p(e.data.reply); }
  });

  const ask = (op, payload) => new Promise((resolve) => {
    const id = `${Date.now()}-${++seq}`;
    pending.set(id, resolve);
    window.postMessage({ __deadbolt: "passkey-request", id, op, payload }, window.location.origin);
    const giveUp = () => { if (pending.has(id)) { pending.delete(id); resolve({ ok: false, error: "timeout" }); } };
    setTimeout(() => { if (!acked.has(id)) giveUp(); }, 1500);   // Deadbolt's script isn't listening: browser takes over
    setTimeout(giveUp, 120_000);                                  // Touch ID left waiting
  });

  const domError = (name) => new DOMException(
    name === "InvalidStateError" ? "A passkey for this account already exists in Deadbolt." : "The operation either timed out or was not allowed.",
    ["InvalidStateError", "NotSupportedError", "SecurityError"].includes(name) ? name : "NotAllowedError");

  /** An object that looks and behaves like a real PublicKeyCredential to the site's JavaScript. */
  function credential(r, attestation) {
    const rawId = fromB64(r.id);
    const responseProto = attestation ? AuthenticatorAttestationResponse.prototype : AuthenticatorAssertionResponse.prototype;
    const response = Object.create(responseProto);
    const props = { clientDataJSON: fromB64(r.clientDataJSON) };
    if (attestation) {
      Object.assign(props, { attestationObject: fromB64(r.attestationObject) });
      Object.defineProperties(response, {
        getTransports: { value: () => ["internal", "hybrid"] },
        getAuthenticatorData: { value: () => fromB64(r.authenticatorData) },
        getPublicKey: { value: () => fromB64(r.publicKey) },
        getPublicKeyAlgorithm: { value: () => r.publicKeyAlgorithm },
      });
    } else {
      Object.assign(props, { authenticatorData: fromB64(r.authenticatorData), signature: fromB64(r.signature),
                             userHandle: r.userHandle ? fromB64(r.userHandle) : null });
    }
    for (const [k, v] of Object.entries(props)) Object.defineProperty(response, k, { value: v, enumerable: true });

    const cred = Object.create(PublicKeyCredential.prototype);
    Object.defineProperties(cred, {
      id: { value: r.id, enumerable: true },
      rawId: { value: rawId, enumerable: true },
      type: { value: "public-key", enumerable: true },
      authenticatorAttachment: { value: "platform", enumerable: true },
      response: { value: response, enumerable: true },
      getClientExtensionResults: { value: () => (attestation ? { credProps: { rk: true } } : {}) },
      toJSON: { value: () => {
        const json = { id: r.id, rawId: r.id, type: "public-key", authenticatorAttachment: "platform", clientExtensionResults: {},
                       response: { clientDataJSON: r.clientDataJSON } };
        if (attestation) Object.assign(json.response, { attestationObject: r.attestationObject, authenticatorData: r.authenticatorData,
                                                        publicKey: r.publicKey, publicKeyAlgorithm: r.publicKeyAlgorithm, transports: ["internal", "hybrid"] });
        else Object.assign(json.response, { authenticatorData: r.authenticatorData, signature: r.signature, userHandle: r.userHandle });
        return json;
      } },
    });
    return cred;
  }

  navigator.credentials.create = async function (options) {
    const pk = options?.publicKey;
    if (!pk) return original.create(options);
    const reply = await ask("create", {
      rpId: pk.rp?.id || "",
      challenge: toB64(pk.challenge),
      userId: toB64(pk.user.id),
      userName: pk.user.name || pk.user.displayName || "",
      algs: (pk.pubKeyCredParams || []).map((p) => p.alg),
      exclude: (pk.excludeCredentials || []).map((c) => toB64(c.id)),
    });
    if (reply?.ok) return credential(reply, true);
    if (["noHost", "notRunning", "timeout", "declined"].includes(reply?.error)) return original.create(options); // let the browser handle it
    throw domError(reply?.error);
  };

  navigator.credentials.get = async function (options) {
    const pk = options?.publicKey;
    // Conditional (autofill-style) requests stay with the browser for now.
    if (!pk || options.mediation === "conditional") return original.get(options);
    const reply = await ask("get", {
      rpId: pk.rpId || "",
      challenge: toB64(pk.challenge),
      allow: (pk.allowCredentials || []).map((c) => toB64(c.id)),
    });
    if (reply?.ok) return credential(reply, false);
    if (["none", "noHost", "notRunning", "timeout", "declined", "locked"].includes(reply?.error)) return original.get(options);
    throw domError(reply?.error);
  };
})();
