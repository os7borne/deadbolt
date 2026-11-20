---
name: Phase 5 — Chrome extension
status: In progress
progress:
  - "[x] deadbolt-bridge: sandboxed native-messaging host inside the Mac app (stdin/stdout ↔ Unix socket in the 4CMN2DUGUL.com.osborne.deadbolt group container)"
  - "[x] Mac app BridgeServer: per-connection code-signature check of the peer (identifier + team via audit token); impostor connections closed (verified)"
  - "[x] Host manifest written to ~/Library/Application Support/Google/Chrome/NativeMessagingHosts on launch (temporary-exception entitlement), allowed_origins = fixed extension id lhalfpljkecpmpgcfibbaeldddnekdfa (manifest key; private key discarded)"
  - "[x] Requests: status, unlock (Touch ID), open, generate, accounts(site), fill/code (login must match the page's site), propose/save (save-or-update rules)"
  - "[x] Extension (chrome/, no build): inline fill menu (closed shadow DOM), save/update prompt after sign-in, popup (status, unlock, fill/copy/code, generate). Site always from Chrome, https only"
  - "[x] Bridge round trip verified from the shell (status/accounts/fill)"
  - "[x] Owner test in Aside: fill menu works; fixed menu closing on click, hidden save card showing, missing logo (now inline SVG, no web_accessible_resources)"
  - "[x] Toolbar badge: login count per tab, requested by the page script (no 'tabs' permission), passive (doesn't extend the idle lock), cleared within a minute of the vault locking (alarms)"
  - "[x] 0.2.4 (2026-11-19): after a fill the menu no longer reopens on the password field (own focus changes ignored; tabbing into a field that already has a value doesn't open it, clicking still does). Owner confirmed"
  - "[x] 0.2.5 (2026-11-19): autocomplete=new-password boxes offer 'Use a strong password' (fills new + confirm, then a 4 s note); save flow unchanged. Owner confirmed in lab test 6. Lab test 6 text updated locally, website not yet redeployed"
  - "[x] 0.3.1 (2026-11-19): passkey requests show an in-page note \"Confirm with Touch ID on your Mac\" (appears after 350 ms so quick browser fallbacks never flash it; pulses while waiting; then \"Passkey used/saved\" or \"Cancelled\"). Owner test pending"
  - "[x] Mac HUD (2026-11-20): Apps/macOS/PasskeyHUD.swift, a non-activating floating panel (top centre, current screen) while the bridge waits for Touch ID: \"Sign in with a passkey · Confirm with Touch ID · rpId\", pulsing; then Passkey used/saved or Cancelled for 2 s. Built clean, not installed yet"
  - "[x] 0.3.2 (2026-11-20): popup copy confirms in place (✓ Copied / ring → check), no toast; single-page sign-ins: save prompt now polled every 1.5 s for 40 s (was one look at 1.8 s, which missed slow SPAs); lab test 11 added and deployed; owner confirmed the save prompt appears (2026-11-20)"
  - "[ ] Owner test of the badge"
  - "[x] Passkeys in Chrome/Aside: MAIN-world relay (inject.js), content relay + account chooser, Mac app validates origin/rpId (PSL) and builds clientDataJSON, Touch ID per operation; falls back to the browser when Deadbolt has nothing; conditional mediation + iframes left to the browser"
  - "[ ] Owner test: create + sign in with a passkey on webauthn.io in Aside"
  - "[x] Host manifest written for every installed Chromium browser: Chrome (+Beta/Canary), Chromium, Brave, Edge, Vivaldi, Arc, Yab, Aside (owner uses **Aside**: ~/Library/Application Support/Aside, also com.ardia.browser/Chromium)"
  - "[x] 0.2.1 save fixes: locked vault → unlock-to-save card; redirect to another subdomain of the same site saves (PSL registrable domain, checked in the Mac app); capture on any button in a form with a filled password + pagehide"
  - "[x] 0.2.2: 'Extension context invalidated' after reloading the extension handled (alive() guard)"
  - "[x] 0.2.3: two-step sign-in — menu on a lone username/email field (fills username only), step-one username remembered (stepUser, per tab+host, 10 min), off-screen autocomplete=username read for the save; verified in jsdom on lab test 4"
  - "[ ] Owner retest in Aside: lab tests 1–8 (test 5 waits for lab-login.osborne.vc DNS to settle)"
  - "[ ] Logins inside iframes (lab test 8)"
---

The App Store would reject the temporary-exception entitlement; fine for direct/TestFlight-internal use. Revisit before any public release.
