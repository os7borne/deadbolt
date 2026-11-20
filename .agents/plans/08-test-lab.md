---
name: Test lab (deadbolt.osborne.vc/lab)
status: Live
progress:
  - "[x] Static pages in website/public/lab (lab.css, lab.js helpers), noindex, no network calls, test data in localStorage"
  - "[x] 1 classic form · 2 script sign-in · 3 icon-only button · 4 two-step · 5 other-subdomain redirect · 6 change password · 7 hidden-field trap (table of what was filled) · 8 iframe"
  - "[x] 5 served from lab-login.osborne.vc (second custom domain on Worker deadbolt-site) → lands on deadbolt.osborne.vc/lab/welcome.html"
  - "[x] 9 one-time codes: 20-byte secret, QR (vendored qrcode-generator 1.4.4, MIT) + setup key + otpauth link, autocomplete=one-time-code field, in-page RFC 6238 verify (±1 step); verified against RFC vectors 5/5; QR round-trip via Core Image verified"
  - "[x] 10 passkeys: register (ES256, resident, UV required, optional excludeCredentials → InvalidStateError) and sign in (allow-list or discoverable chooser); checks clientData type/challenge/origin, rpIdHash, UP/UV/AT, BE/BS shown, signature verified with the saved SPKI (DER→raw tested on 200 signatures), userHandle"
  - "[x] Deployed: cd website && npx wrangler@4 deploy"
  - "[ ] lab-login.osborne.vc DNS: authoritative answers correct; some resolvers still had negative cache on 2026-11-19 — recheck"
  - "[ ] Owner runs all 10 in Aside, Safari (Mac) and iPhone; record results here"
---

# Test lab

Each page states "Expected:" behaviour. Pages use `Lab.checks(el, [[ok, label, detail]])` to show ✓/✗ (ok null = info).
Keep it static and first-party: no CDNs, analytics or fonts from elsewhere (same rule as the main site).
