---
name: Logins without a password + Chrome Add login
status: Built, not yet exercised by the owner
progress:
  - "[x] Core: LoginItem.passwordless (merged per field), isPasswordless, empty password never overwrites (proposeSave), no empty history entry; 8 tests (PasswordlessTests)"
  - "[x] iPhone + Mac login form: password optional, hint text, detail rows, envelope badge, menu-bar click copies the username"
  - "[x] Bridge: propose/save accept an empty password with a username; accounts reports passwordless; new ops add and site"
  - "[x] Chrome 0.6.0: popup Add login (prefilled from the tab), passwordless rows (Copy username), email-only sign-in save prompt"
  - "[x] jsdom harness over the real content.js + background.js: OTP, link, two-step, newsletter/contact/search ignored, password regression"
  - "[ ] Owner: install Mac + iPhone builds, reload the extension, try a real email-code site (workfromacafe.com)"
  - "[ ] Phase 3: fill the email into the site's field (Chrome in-page menu; iOS AutoFill identity for passwordless logins)"
---

# Logins without a password

Why: the owner signs up with a throwaway email on sites that only send a code or a link, and the extension never offered to save those (no password box = nothing captured).

## How the email-only prompt decides (chrome/content.js)
- Capture: a submitted form (or a sign-in-looking button) with **exactly one visible email box that holds an address**, **no visible password box**, **no textarea**, and sign-in wording (button/heading text, `autocomplete=username`, or a /login-ish path). Newsletter/search/contact words veto it.
- Prompt: held by the service worker (`pendingSave` answers `wait`) while the page shows a password box (two-step sign-in), a one-time-code box (single, or a row of one-digit boxes) or the email form itself. Pending sign-ins expire after 5 min as before.
- A later password capture replaces an email-only one; an email-only capture never replaces a waiting password one.

## Known limits
- Not seen on the real workfromacafe.com sign-in form (the agent's browser was already signed in there). If its markup differs from the heuristics, adjust `emailOnlyCapture` / `otpBoxes`.
- An SPA that keeps the email box on screen after sending the code, with no code box recognised, keeps waiting until the 5-minute expiry and never prompts. Use Add login in the popup then.
- Bridge ops `add` and `site` were compile-checked only (no signed Mac app run).
