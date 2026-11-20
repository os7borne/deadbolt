---
name: Accounts + one-time codes UX (per platform)
status: Built (2026-11-19), builds clean on Mac + iOS, not yet installed or reviewed by owner
progress:
  - "[x] Decisions below confirmed by owner"
  - "[x] Core: code-only logins (password optional when a code is present; website optional only for code-only)"
  - "[x] iPhone: Codes tab (Authenticator-style list, ring, tap = copy)"
  - "[x] iPhone: calmer 'accounts on a site' screen (no row of four buttons)"
  - "[x] Chrome popup: one Fill button + ⋯ menu; separate Codes section"
  - "[x] Mac: group accounts under one site row; Codes filter as a code list"
  - "[x] Setup flow: issuer/account from the QR prefill title, username and a suggested site"
---

# Accounts + one-time codes: plan

Owner feedback 2026-11-19: the iPhone "2 accounts on <site>" screen and the Chrome popup rows are ugly (email wrapped letter by
letter, four icon buttons per row, "Password + code" wrapping). Codes should look like Microsoft Authenticator on iPhone
(a list of codes, ring timer, tap copies). Mac may combine a site's logins and codes; iPhone and Chrome should **not** combine
them, because mixing a password row and a code row for the same site is confusing there.

## Principle

One stored thing (a login item, possibly with a code) — but each surface shows only what it is *for*:

| Surface | Shows | Combined with codes? |
|---|---|---|
| Mac window | Sites with their accounts; each account has password, passkey and code in its detail | **Yes** (owner OK'd) |
| iPhone Vault tab | Logins and passkeys only (a small "code" badge on rows that have one) | No |
| iPhone Codes tab | Codes only, Authenticator style | No |
| Chrome in-page menu | Logins on a login field; **codes only on a code field** (already) | No |
| Chrome toolbar popup | Section "Logins" (Fill), section "Codes" (tap = copy) | No |
| iPhone AutoFill sheet | Logins; codes via the system's one-time-code suggestion (already) | No |

## 1. Data: code-only entries (Core)

Today a code lives on a login and the form insists on website + username + password. Authenticator-style use needs a code on
its own.
- `LoginFormModel.missing`: a password is **not** required when a code is present. Username is not required either when a code
  is present (title falls back to the issuer, account falls back to the code's account name).
- Website stays required **for anything that should fill in a browser**. For a pure code entry the website is optional (the
  Microsoft/Bitwarden rows in the owner's authenticator have none). Such items never appear in autofill; they show only in
  Codes lists. Needs `LoginItem.sites` to be allowed empty for code-only items: audit `matches(host:)`, merge, import, bridge.
- Chrome/popup label: no password → "Code only" (today it would say "Passkey only").
- Setup screen: issuer + account from the otpauth link prefill title and username; if the issuer contains a dot (a domain) it
  prefills the website, otherwise it offers a *suggestion* (`github.com` for "GitHub") that the owner confirms. Never silent.
- Tests: code-only item saves, syncs and merges; never offered for fill; Core stays at LWW per field.

## 2. iPhone

**Codes tab** (Authenticator-style):
- Row: site tile · title (bold) · account (secondary) · the code large in brass, grouped `486 582` · ring with seconds left
  (turns red at ≤ 5 s) · no chevron. **Tap the row = copy the code** + haptic + toast "Code copied · clears in 60 s".
  Long-press: copy username, open the login, Edit.
- Search at the top; sorted by title; pinned/recent later. A "+" scans a QR or enters a key (existing setup flow).
- Codes refresh together on the 30 s boundary; the ring is a `TimelineView`, no timers to leak.
- Tabs become Vault · **Codes** · Generator · Devices · Settings (5). If that is too tight on iPhone 11, Generator moves into
  the Vault toolbar (decision Q1).

**"Accounts on a site" screen** (replaces the row of four buttons):
- Row = avatar letter · email on **one line** (tail-truncated; full value in the detail) · secondary line: "Password · Passkey"
  (+ "Code" badge) · star for the preferred account. Nothing else on the row.
- Tap → the login detail (copy username / password, reveal, history, code, passkey all live there). Swipe: Copy password,
  Copy username. Long-press menu: Make preferred, Edit, Delete. "Add another account" stays at the bottom.
- Rows never wrap an email character by character.

## 3. Chrome toolbar popup

- Header unchanged ("deadbolt.osborne.vc · Unlocked via Mac").
- **Logins**: tile · email (one line, ellipsis) · secondary "Password" · one gold **Fill** button · a **⋯** menu with
  Copy password, Copy username. No "Code" or "Copy" buttons on the row.
- **Codes** (only if the site has some): tile · account · live code with a small ring · tap the row = copy.
- Footer: Generate password · Open Deadbolt. The "Nothing is stored in Chrome…" line stays but shrinks.
- In-page menu: unchanged (logins on login fields, codes on code fields).

## 4. Mac

- List grouped by site: one row per site ("Osborne · 3 accounts"), expands to its accounts; a site with one account is a
  plain row. Filter tabs stay All / Passkeys / Codes.
- Detail already shows password and code together — keep it. Multiple accounts on one site: a compact account switcher at the
  top of the detail rather than three separate list rows.
- **Codes** filter: the same list as the iPhone Codes tab (live code + ring, click = copy, ⌘C copies the selected code).
- Menu-bar panel: top accounts for the front browser site, with a copy-code button on rows that have one.

## 5. Build order

1. Core: code-only items + tests (and decide `sites` empty handling).
2. iPhone Codes tab + setup prefill (biggest win, replaces the owner's authenticator).
3. iPhone accounts screen cleanup.
4. Chrome popup rows + Codes section (bump extension version, re-sync Safari).
5. Mac grouping + Codes list.
6. Install Mac + iPhone, owner review.

## Open questions

- Q1 (answered: Codes tab + Generator in Vault toolbar, 4 tabs) Five tabs on iPhone, or fold Generator into the Vault toolbar? (recommend: Codes as the 2nd tab, Generator into Vault toolbar → 4 tabs)
- Q2 (answered: yes, website optional) Allow code entries with **no website** (authenticator replacement), or always require one? (recommend: allow, they never autofill)

## Revision 2026-11-19 (owner feedback after first install)

Grouping accounts under one row on Mac/iPhone and then tapping through (list → accounts → detail) took three taps to see what a
site has. Changed to: **All** = flat, one row per login with auth-type icons; new **Websites** filter = one row per site that opens
a single screen with every account's password / code / passkey inline. The "Mac combines, iPhone doesn't" rule is replaced by
"combining only happens in the Websites filter, on every platform". Built clean on Mac + iOS; not yet installed.
