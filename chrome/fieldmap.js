// Deadbolt for Chrome — which form field is which, for card and address forms.
// Pure helpers: no UI, no messaging, nothing leaves the page. content.js decides when to use them.
// Loaded before content.js, in the same isolated world; the page can't see this object.
(() => {
  if (globalThis.__deadboltFieldMap) return;

  // HTML autocomplete tokens we understand. The page's own labels win over guesses.
  const CARD_TOKENS = ["cc-name", "cc-given-name", "cc-family-name", "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc"];
  const ID_TOKENS = ["name", "honorific-prefix", "given-name", "additional-name", "family-name", "organization", "email", "tel", "tel-national",
    "street-address", "address-line1", "address-line2", "address-line3", "address-level2", "address-level1", "postal-code", "country", "country-name"];
  const KNOWN = new Set([...CARD_TOKENS, ...ID_TOKENS]);
  const CARD = new Set(CARD_TOKENS);

  const TEXTY = new Set(["", "text", "tel", "number", "email", "search", "password"]);

  function tokens(el) { return (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/).filter(Boolean); }

  /** Everything a person could read to tell what the field is: names, placeholder, aria-label and its <label>s. */
  function hints(el) {
    const labels = el.labels ? [...el.labels].map((l) => l.textContent) : [];
    return [el.name, el.id, el.placeholder, el.getAttribute("aria-label"), ...labels].filter(Boolean).join(" ").toLowerCase().replace(/[_\-.[\]]+/g, " ");
  }

  /** The key for a field, or null when it isn't a card / address field (or can't be filled). */
  function classify(el) {
    if (!el || !el.tagName) return null;
    const tag = el.tagName;
    if (tag !== "INPUT" && tag !== "SELECT" && tag !== "TEXTAREA") return null;
    if (el.disabled || el.readOnly) return null;
    const type = tag === "INPUT" ? (el.type || "text").toLowerCase() : tag.toLowerCase();
    if (tag === "INPUT" && !TEXTY.has(type)) return null;     // hidden, checkbox, radio, button, file…
    if (type === "search" || el.getAttribute("role") === "searchbox") return null;

    const known = tokens(el).reverse().find((t) => KNOWN.has(t));
    let key = known || guess(el, hints(el), type);
    if (!key) return null;
    if (key === "tel-national") key = "tel";
    if (key === "country-name") key = "country";
    // A password-type box is only ever a card number or security code (many sites mask the CVV); anything else is a login field.
    if (type === "password" && key !== "cc-csc" && key !== "cc-number") return null;
    return key;
  }

  function guess(el, s, type) {
    if (!s && type !== "email") return null;
    // Card first: "card number" must not be read as a generic number.
    if (/\b(cvv2?|cvc2?|csc|cid)\b|security ?code|card ?(verification|code)|verification ?(code|number)/.test(s)) return "cc-csc";
    if (/name ?on ?(the )?card|card ?holder|cardholder|\bcc ?name\b/.test(s)) return "cc-name";
    if (/(exp|expiry|expiration|expires|valid|card).{0,12}month|\bexp ?mm\b|\bcc ?month\b/.test(s)) return "cc-exp-month";
    if (/(exp|expiry|expiration|expires|valid|card).{0,12}year|\bexp ?yy(yy)?\b|\bcc ?year\b/.test(s)) return "cc-exp-year";
    if (/\bexp(iry|iration|ires|date)?\b|valid ?(thru|till|until|through)|mm ?[\/\-] ?yy/.test(s) && !/expense|expert/.test(s)) return "cc-exp";
    if (/(card|cc|credit|debit) ?(num|no\b|number)|cardnumber|\bccnum\b|\bpan\b/.test(s)) return "cc-number";

    if (type === "password") return null;
    // Address forms. Deliberately conservative: a wrong guess puts a menu on a field that isn't one.
    if (type === "email" || /e ?mail/.test(s)) return "email";
    if (/first ?name|given ?name|\bfname\b|forename/.test(s)) return "given-name";
    if (/last ?name|family ?name|surname|\blname\b/.test(s)) return "family-name";
    if (/middle ?name|\bmname\b/.test(s)) return "additional-name";
    if (/full ?name|your ?name/.test(s)) return "name";
    if (/company|organi[sz]ation|employer|business ?name/.test(s)) return "organization";
    if (type === "tel" || /phone|mobile|\btel\b|contact ?(no|number)/.test(s)) return /phone|mobile|\btel\b|contact/.test(s) || type === "tel" ? "tel" : null;
    if (/\b(zip|postal|post ?code|pin ?code|pincode|postcode|zipcode)\b/.test(s)) return "postal-code";
    if (/address ?(line ?)?(2|two)|addr(ess)? ?2|\b(apt|suite|unit|flat|landmark)\b/.test(s)) return "address-line2";
    if (/address ?(line ?)?(3|three)|addr(ess)? ?3/.test(s)) return "address-line3";
    if (/address ?(line ?)?(1|one)|addr(ess)? ?1|street|\bstreet ?address\b|^address$/.test(s.trim())) return "address-line1";
    if (/\b(city|town|locality)\b/.test(s)) return "address-level2";
    if (/\b(state|province|region|prefecture)\b/.test(s)) return "address-level1";
    if (/\bcountry\b/.test(s)) return "country";
    return null;
  }

  const groupOf = (key) => (CARD.has(key) ? "card" : "identity");

  /** The fields in `scope` that belong to `group` and are really visible (the page's `visible` test is passed in). */
  function collect(scope, group, visible) {
    const out = [];
    for (const el of scope.querySelectorAll("input, select, textarea")) {
      const key = classify(el);
      if (key && groupOf(key) === group && visible(el)) out.push({ el, key });
    }
    return out;
  }

  /** Is this form worth offering a card or an identity for? Avoids a menu on every lone email or name box. */
  function worthOffering(group, fields, scope, visible) {
    if (group === "card") return fields.some((f) => ["cc-number", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc"].includes(f.key));
    // A form with a password box is a sign-in or sign-up form: the login menu handles that.
    if ([...scope.querySelectorAll('input[type="password"]')].some(visible)) return false;
    return new Set(fields.map((f) => f.key)).size >= 2;
  }

  // ----- what to ask the Mac for, and how to write it into the field -----

  const monthName = (m, style) => new Intl.DateTimeFormat("en", { month: style }).format(new Date(2000, m - 1, 1));

  /** How this single expiry box wants the date written: MM/YY, MM/YYYY or MMYY. */
  function expiryKey(el) {
    const s = `${el.placeholder || ""} ${el.getAttribute("aria-label") || ""}`.toLowerCase();
    if (/mm ?[\/\-. ] ?yyyy/.test(s) || el.maxLength === 7) return "expiryLong";
    if (el.maxLength === 4 || /\bmmyy\b/.test(s)) return "expiryCompact";
    return "expiry";
  }

  const yearIsTwoDigits = (el) => el.tagName === "INPUT" && el.maxLength === 2;

  /** The Mac fill keys this field might need (the union over all fields becomes the request). */
  function wanted(key, el) {
    switch (key) {
      case "cc-number": return ["number"];
      case "cc-csc": return ["code"];
      case "cc-name": return ["holder"];
      case "cc-given-name": return ["holderFirst"];
      case "cc-family-name": return ["holderLast"];
      case "cc-exp": return [expiryKey(el)];
      case "cc-exp-month": return ["expMonth"];
      case "cc-exp-year": return el.tagName === "SELECT" ? ["expYear", "expYear2"] : [yearIsTwoDigits(el) ? "expYear2" : "expYear"];
      case "given-name": return ["first"];
      case "additional-name": return ["middle"];
      case "family-name": return ["last"];
      case "name": return ["name"];
      case "honorific-prefix": return ["salutation"];
      case "organization": return ["company"];
      case "email": return ["email"];
      case "tel": return ["phone"];
      case "street-address": return ["address"];
      case "address-line1": return ["address1"];
      case "address-line2": return ["address2"];
      case "address-line3": return ["address3"];
      case "address-level2": return ["city"];
      case "address-level1": return ["state"];
      case "postal-code": return ["postal"];
      case "country": return ["country"];
      default: return [];
    }
  }

  const norm = (s) => String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").trim().toLowerCase();

  /** For a <select>: the option matching any candidate by value or visible text. Countries also match by ISO code. */
  function pickOption(select, candidates) {
    const want = candidates.filter(Boolean).map(norm);
    let region = null;
    try { region = new Intl.DisplayNames(["en"], { type: "region" }); } catch {}
    for (const opt of select.options) {
      const names = [opt.value, opt.textContent];
      if (region && /^[A-Za-z]{2}$/.test(opt.value)) { try { names.push(region.of(opt.value.toUpperCase())); } catch {} }
      if (names.filter(Boolean).map(norm).some((n) => want.includes(n))) return opt;
    }
    return null;
  }

  /** What to write into this field: { text } for an input, { option } for a <select>, or null if the Mac sent nothing for it. */
  function plan(key, el, values) {
    const k = wanted(key, el).find((x) => values[x] !== undefined && values[x] !== "");
    if (!k) return null;
    const v = values[k];
    if (el.tagName === "SELECT") {
      let candidates = [v];
      if (key === "cc-exp-month") { const m = Number(v); candidates = [String(m), v, monthName(m, "long"), monthName(m, "short")]; }
      if (key === "cc-exp-year") candidates = [values.expYear, values.expYear2];
      const option = pickOption(el, candidates);
      return option ? { option } : null;
    }
    if (el.maxLength > 0 && v.length > el.maxLength) {
      // Too long for the box (a 2-digit year box asked for 4 digits, say): use the shorter form if the Mac sent it.
      const alt = key === "cc-exp-year" ? values.expYear2 : null;
      return alt && alt.length <= el.maxLength ? { text: alt } : null;
    }
    return { text: v };
  }

  globalThis.__deadboltFieldMap = { classify, groupOf, collect, worthOffering, wanted, plan, expiryKey, pickOption };
})();
