# Deadbolt — security model and review

Last review: 2026-11-19 (full pass over every surface, before moving real passwords in).

## What Deadbolt protects against

| Attacker | Protection |
|---|---|
| Someone who steals a **locked** iPhone or Mac | Vault sealed with AES-256-GCM; opening needs Face ID/Touch ID (Keychain item `biometryCurrentSet`, ThisDeviceOnly) or the master password (Argon2id). The device passcode is not accepted. iOS: complete file protection. |
| Someone who steals an **unlocked** device | Auto-lock (iOS: on background after "Lock after"; Mac: sleep, screen lock, user switch, idle ≥ 60 s). Reveal/copy needs the vault unlocked; recovery words need a fresh Face ID/Touch ID or the master password. |
| A **lost/stolen linked device** | Remove it (needs master password): relay revokes it, every copy marks it revoked, the vault key is rotated (new epoch, new mailbox, key sealed only to remaining devices' Secure Enclave agreement keys), and it erases itself after verifying a signed removal if it reconnects. |
| The **relay** (or whoever controls Cloudflare / the domain) | Sees only sealed, signed messages. Can withhold, delay or replay (merge is idempotent; signatures + epochs stop forgery/tampering). Can't link a device (approval + 4-digit code + master password). Can't wipe a device (removal must be signed by a vault device). |
| A **web page** (phishing, malicious script) | Passwords are released only for logins saved for the page's own site (`Vault.login(_:for:)`, tested); filling a login saved for another site asks first and names both sites (iOS); browser site comes from the browser, never the page; https only; no fill into invisible/zero-opacity fields; clicks on Deadbolt's in-page UI must be trusted and actually land on it (clickjacking); UI in a closed shadow root. |
| **Another app on the Mac** | The Chrome bridge socket (0600, app-group container) answers only a peer whose code signature is `com.osborne.deadbolt.bridge` from team 4CMN2DUGUL (checked per connection from the kernel audit token). Browsers launch the bridge only for the Deadbolt extension id. |
| **Icon fetching** | Never a third-party service: our relay fetches from each site, https only, images ≤ 256 KB, PNG/JPEG/ICO/WebP/GIF only (no SVG), no cookies. Can be switched off (no requests, cache deleted). |

## Passkeys in Chrome-family browsers (Aside, Chrome…)

A script in the page's own world (`chrome/inject.js`) wraps `navigator.credentials` and only *relays* the site's
request. The Mac app decides everything: the **origin** comes from the browser's own tab URL (never the page), the
**rpId** must be the page's host or a parent that isn't a public suffix (`PublicSuffix`, full PSL incl. private
section, tested), `clientDataJSON` is built in the app from that origin and a validated base64url challenge (so it
can't be injected into), and every create/sign-in needs **Touch ID** (unlocking with Touch ID counts). Excluded
credentials are honoured. If Deadbolt has nothing for the site, or isn't running, the browser's own implementation
runs. Conditional ("autofill") passkey requests and iframes stay with the browser. Safari uses the Mac AutoFill
provider instead (no page script).

## Not protected (stated plainly)

- **Malware running as you on an unlocked Mac/iPhone**, or a debugger attached to the app. (Development-signed daily builds carry `get-task-allow`; TestFlight/App Store builds don't.)
- **Data already on a removed device**: rotation protects everything from the removal on. Change important passwords if a device is stolen.
- **A weak master password** if the vault file itself is stolen: Argon2id (64 MiB, 3 passes) slows guessing but can't save a short password. Minimum 10 characters; passphrases suggested.
- **XSS on the real site**: a script on github.com can read what Deadbolt fills into github.com — true of every password manager.
- **Metadata at the relay**: random mailbox id, message sizes/times, IP addresses, an iPhone's push token. Apple sees that a (content-free) push was sent.

## Review 2026-11-19 — findings

| # | Finding | Severity | Status |
|---|---|---|---|
| R1 | Mac app ran two vault sessions (SwiftUI may build `App` twice): Chrome's could be unlocked while the menu bar showed locked, and it never auto-locked | High | **Fixed**: one `MacRuntime` session |
| R2 | Lock-on-sleep/screen-lock never fired on Mac (observers on `NotificationCenter.default` instead of the workspace/distributed centres) | High | **Fixed**, plus idle lock (`LockPolicy`, tested) |
| R3 | Device id in restorable preferences: an iPhone restored from an iCloud backup would clone the old phone's sync identity | High | **Fixed**: id in Keychain (ThisDeviceOnly), safe migration |
| R4 | iOS AutoFill "Search all logins" could fill another site's login with no warning (phishing) | High | **Fixed**: confirmation naming both sites |
| R5 | Erase on a linked device didn't revoke it: lingered as an active device | Medium | **Fixed**: erase = retire (signed revocation) + erase |
| R6 | In-page fill menu: clickjacking by overlays; transparent fields counted as visible | Medium | **Fixed**: trusted, hit-tested clicks; UI re-appended on top; opacity/size check |
| R7 | Change-password forms: captured the old password for "Update" | Medium | **Fixed**: new-password / last field |
| R8 | Icon cache and pending sync queue included in iCloud device backups (reveal which sites you use) | Medium | **Fixed**: excluded from backup |
| R9 | No warning when several link requests arrive at once | Low–Med | **Fixed**: explicit warning (iPhone + Mac) |
| R10 | Recovery words needed biometrics, no fallback | Low | **Fixed**: master password fallback |
| R11 | Link secret used Swift's general RNG | Low | **Fixed**: `SecureRandom` (SecRandomCopyBytes) |
| R12 | "Last password unlock" in a future date (edited preferences) extended biometric-only unlock | Low | **Fixed**: future dates rejected (tested) |
| R13 | Bridge site check and idle-lock rule untested | Gap | **Fixed**: tests in `SecurityPolicyTests` |

Added with Mac AutoFill / Safari / browser passkeys (2026-11-19): the bridge socket accepts exactly two signed callers
(`com.osborne.deadbolt.bridge`, `com.osborne.deadbolt.safari`); passkey refusal paths verified through the real
bridge (other-site rpId, public-suffix rpId, http page, injection attempt in the challenge).

Added 2026-11-19 (two-step sign-in, forms, lab):
- **Two-step sign-in reads, never fills, hidden fields.** `typedUsernameFor` may read an off-screen `autocomplete="username"`
  field's value for the save prompt (it's what the person typed); filling still requires `visible()`. The step-one username is kept
  in `chrome.storage.session` as `user-<tab>` with the host, used only for a capture on the **same host within 10 minutes**, and
  removed when the tab closes. It is a username, not a secret.
- **Orphaned content scripts** (extension reloaded) now stand down instead of throwing; they can't reach the bridge anyway.
- **QR codes for one-time codes** are decoded on device (Core Image / VisionKit); images aren't stored or sent. On iOS the setup-key
  paste uses `PasteButton` (no clipboard read prompt); on the Mac, Paste Screenshot reads the pasteboard only when pressed.
- **Lab pages** are static, `noindex`, store test data only in the visiting browser, and load no third-party code (QR library vendored).

Added 2026-11-20 (generator, custom fields, codes, HUD, AutoFill):
- **Generator preferences** live inside the encrypted vault and sync like logins; the relay sees only sealed ops. The bridge's `generate` returns a password from them only while the vault is unlocked (defaults otherwise); it never returns preferences.
- **Custom fields** (including "hidden" ones) are stored and synced inside the encrypted vault like passwords. Hiding is display-only masking; revealed values and copies are plain text on screen / clipboard (cleared after 60 s like other copies).
- **Code-only entries** (no password, maybe no website) are never returned by `accounts`-for-fill in the in-page menu (`codeOnly` flag, filtered client-side) and, with no website, match no site at all. A code is only released via `code` for a login that belongs to the page's site (unchanged check).
- **Passkey HUD / in-page note** only describe a request the bridge has already validated (origin from the browser's tab URL, rpId checks unchanged); they add no new input path. The in-page note lives in the closed shadow root.
- **Mac AutoFill** now needs the AutoFill-provider entitlement on the host app as well as the extension (both signed by this team); no change to what the extension can read (same app-group vault, same biometric gate).
- **Device names** shown to the user are derived locally from the stored model string; nothing new is sent anywhere.

## Known limitations (tracked, not fixed)

- **Rotation is not transactional.** If the removing device crashes between announcing the new key and re-sealing its own copy, devices can split across epochs (fix: persist the pending rotation and retry on next sync).
- **Device offline > 7 days across a rotation** misses the announcement (relay TTL) and must be linked again. **Concurrent removals** could produce two next-epoch keys.
- **4-digit linking code**: 1-in-10,000 chance per attempt for a man-in-the-middle; link posts are rate-limited (20/min/IP).
- **Site icons** are decoded by Apple's ImageIO from untrusted sites (size/type limited; can be turned off).
- **Chrome**: logins inside iframes aren't filled; native-messaging manifests need a sandbox temporary exception (fine for direct/TestFlight-internal, not App Review).
- **Two-step sign-ins that change host** between steps (e.g. `accounts.x.com` → `login.x.com`) save without the username (step-one memory is per host).
- **Unverified on device**: Argon2id 64 MiB inside the iOS AutoFill extension's memory limit; passkey registration and one-time-code AutoFill on iOS.

## Cards, identities and secure notes (2026-11-20)

- They live in the same sealed vault and sync like logins. They are **not** site-bound, so they never go through `Vault.login(_:for:)` and are never given to a web page, the AutoFill system, the menu-bar panel or Spotlight.
- Secrets (card number, security code, PIN, SSN/national ID, passport, licence number, note text, hidden custom fields) are masked; showing, copying and opening an item for editing each need a fresh Touch ID / Face ID check, or the master password when biometrics aren't available (`VaultSession.confirmOwner`). Copies leave the clipboard after 30 s.
- Search matches names, brand, last four digits and similar, never the full number, code or ID numbers (`searchText`, tested).
- Older builds drop data they don't know: `Vault.schema` makes newer vaults unreadable to older builds instead, and the first card must be saved only after every device runs a build that knows them.
- **Chrome popup (extension 0.4.0):** Cards / Identities / Notes tabs. The bridge's `items` answer has names, brand, last four digits and expiry only. `copyItem` asks the Mac app to copy one field itself: the value never travels to Chrome, the popup or a page. Secret fields need a fresh Touch ID on the Mac (small floating note says what is being copied); other fields (cardholder name, email, address…) copy straight away; clipboard clears after 30 s (60 s for non-secret). The extension's background script answers these two requests **only to its own popup** (`!sender.tab`, own extension id, popup URL), so a page or its content script can't ask; the bridge also cannot return logins this way (`Vault.copyField` never finds one). A check started from the browser does not bring Deadbolt in front of Chrome. **Fill into pages (extension 0.5.0, 2026-11-20):** on card and address forms in the **top frame of an https page** the page script (closed shadow root, trusted-click check) lists names and last four digits, and a pick asks the Mac for **only the fields that form really has** (`Vault.fillValues`): no security-code box on the page → the code is never requested or released. A card number or security code needs a fresh Touch ID on the Mac, and its prompt (and the floating note) names the site it is going to, taken from Chrome's tab URL, never from the page. Names, addresses, email and phone fill on the pick alone; ID numbers, PINs and note text are copy-only. Only visible fields are filled (honeypot boxes are skipped); fields the person already typed in are left alone. A pick fills only the part of the page around the field the person is in: on a merchant's saved-cards list with a CVV box per card, only the box beside the chosen row gets the code (it never lands in the other cards' boxes), and the menu favours the card whose last four digits the row shows. Page sub-frames (iframes) are refused by the extension: no fill there. A masked CVV or card number is never treated as a login password (it used to be capturable by the save-on-submit logic). Not covered: pages whose fields live in a closed or open shadow DOM; cross-origin payment iframes (Stripe, Adyen, Razorpay…) don't fill yet.
- Known limit: a Mac with its lid closed has no Touch ID, so every check falls back to the master password.

## Rules for future changes

- Crypto only via CryptoKit / WebCrypto / libsodium; versioned formats with AAD; test vectors for every format.
- Never log, print or persist plaintext secrets. A secret that isn't a login password (card, ID number, note) is released only after `confirmOwner`. Anything releasing a password to a web page goes through `Vault.login(_:for:)`.
- Lock decisions go through `LockPolicy`. One session per process.
- Every new cache or file that reveals which sites you use is excluded from device backups.
