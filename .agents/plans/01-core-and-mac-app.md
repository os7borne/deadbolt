---
name: Phase 1 — Core + Mac app
status: In progress
progress:
  - "[x] Envelope v1 (AES-256-GCM, version+epoch header and context bound as AAD) + tests"
  - "[x] VaultKey with per-purpose HKDF subkeys and epochs + tests"
  - "[x] Argon2id KDF (libsodium via swift-sodium 0.11.0, NFKC-normalized password) + tests"
  - "[x] Key wrapping under master password and recovery key + tests"
  - "[x] Recovery key ↔ 24 words (BIP39 English, SHA-256 checksum, official vectors) + tests"
  - "[x] Account number: 15 random digits + Luhn check digit + tests"
  - "[x] WebAuthn: passkey model, none-attestation registration, ES256 assertions, minimal CBOR + tests"
  - "[x] Vault model: LoginItem (multi-account per site), save-or-update proposals, preferred account, password history (cap 20, restorable), passkey linking + tests"
  - "[x] VaultFile v1: whole vault sealed under VK; VK wrapped by master password + recovery key; atomic write, complete file protection, excluded from backups + tests"
  - "[ ] Per-record sealing / op log (needed for sync, phase 4) + snapshots"
  - "[ ] Keychain: biometric-wrapped VK (biometryCurrentSet, no passcode fallback) + test proving it's really in the Keychain"
  - "[x] Password generator (random + passphrase)"
  - "[x] TOTP (RFC 6238 vectors, SHA1/256/512) + otpauth:// parsing + base32; codes in detail/list/Mac menu; iOS AutoFill one-time codes"
  - "[x] Importers by header: Apple Passwords, Chrome, 1Password, Bitwarden, generic CSV; preview (new/updated/unchanged/skipped); never duplicates; offers to delete the export"
  - "[x] Encrypted backup file (recovery-key encrypted), weekly + after import, to a chosen folder (security-scoped bookmark), keeps newest 10; restore on first run keeps the same Recovery Kit"
  - "[x] Recovery Kit PDF (print/share on iOS, open in Preview on Mac; temp file deleted on leave)"
  - "[x] project.yml + iOS app + AutoFill extension + macOS menu-bar app"
---

# Phase 1 — Core + Mac app

`Core/` is a Swift package (`swift test` from `Core/`). Crypto lives in `Core/Sources/DeadboltCore/Crypto/`, account identity in `Account/`.

## Notes
- KDF defaults (3 passes, 64 MiB) are provisional until the phase 0 Argon2 spike on the iPhone 11.
- `bip39-english.txt` is the official list (SHA-256 `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`).
