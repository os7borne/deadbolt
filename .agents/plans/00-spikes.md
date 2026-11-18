---
name: Phase 0 — Spikes
status: In progress
progress:
  - "[ ] Passkey registration + assertion through our iOS credential provider (iOS 18 sim + iPhone 11 on iOS 26)"
  - "[ ] Same on macOS (Safari)"
  - "[x] Saving new passwords on iOS — works on device via ASSavePasswordRequest (iOS 26.2+)"
  - "[ ] AutoFill extension reads a biometric Keychain item from the shared access group"
  - "[ ] Argon2id (64 MiB, 3 passes) inside the iOS AutoFill extension on iPhone 11: time + peak memory"
  - "[ ] Chrome native messaging → host bundled in a signed, sandboxed Mac app"
---

# Phase 0 — Spikes

Throwaway code lives in `spikes/`. Each spike ends with a short **Result** section here: works / doesn't / caveats, with the OS version tested. Results that change a decision go into AGENTS.md §1–2.

Needs the owner's devices: iPhone 11 (passkeys, AutoFill, Face ID, Argon2 timing), the Mac (Touch ID, Safari).

## How to run (spikes/ios)

1. `cd spikes/ios && xcodegen generate && open DeadboltSpike.xcodeproj`
2. Xcode › Settings › Accounts: signed in with the team account. Select the iPhone 11, run **DeadboltSpike**.
3. In the app: *Ask iOS to turn it on* (or Settings › General › AutoFill & Passwords › Deadbolt Spike).
4. Work through the app's sections; then test on the web:
   - **Passkeys:** Safari → https://webauthn.io → Register (pick Deadbolt Spike) → Authenticate.
   - **Password fill:** save a login for a site in the app, then tap a login field there → QuickType bar.
   - **Save (iOS 26.2+):** sign up / log in on any site in Safari → iOS should offer to save to Deadbolt Spike.
   - **Extension Argon2 + Face ID:** Settings › AutoFill & Passwords › Deadbolt Spike opens the configuration screen.
5. Copy the app's results log (Share log) back into this file.

## Results

- 2026-11-18 — **Save password**: SDK has `ASSavePasswordRequest` + `ASGeneratePasswordsRequest`, iOS 26.2+, not macOS.
- 2026-11-18 — Spike builds for the iOS Simulator (Xcode 27.2). CLI device signing failed: Xcode has no account signed in, and `-authenticationKey*` with the Admin key returned "Authentication failed" from xcodebuild even though the same key returns 200 from the API directly. Run from Xcode with the account instead.
- 2026-11-18 — WebAuthn encoding (none attestation, COSE ES256, BE/BS flags, DER assertions) unit-tested in Core.
- 2026-11-18 — **Run 1 on iPhone 11 (iOS 27.2, build 24B120)**, app side only:
  - Provider enable via `ASSettingsHelper.requestToTurnOnCredentialProviderExtension` → true.
  - Biometric Keychain item (`biometryCurrentSet`, shared access group): store + Face ID read in the app OK.
  - Argon2id ×3 passes in the **app**: 32 MiB ≈ 55–95 ms, **64 MiB ≈ 117 ms**, 128 MiB ≈ 250 ms. Fast enough; peak memory not yet measured (run 1 logged post-run footprint only; fixed).
  - `ASCredentialIdentityStore.replaceCredentialIdentities` OK.
  - **No `[ext]` lines at all**: extension entry points never logged. Entitlements verified correct in the signed build; no crash logs. Added a launch log line in `viewDidLoad` for run 2.
- 2026-11-18 — **Owner report, run 1 (iPhone 11, iOS 27.2):**
  - ✅ **System save-password prompt → our provider works, smoothly** (ASSavePasswordRequest). Confirms phase 6 Safari extension is only needed on macOS.
  - ✅ Password fill from saved logins works.
  - ⚠️ Saving an existing site+user created a **duplicate** instead of updating. Real app: match on (site, user) → update + push old value to history; for `formDidDisappear` with a changed password, ask before overwriting.
  - ❓ webauthn.io Register did nothing visible — passkey registration through our provider **unconfirmed**. Needs a log with `[ext]` lines.
  - ❓ Argon2 inside the extension (configuration UI) — unconfirmed.
  - UX: buttons gave no feedback (store key, Argon2) so they got tapped repeatedly. Real app: every action shows progress + result.
