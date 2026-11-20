---
name: Phase 4 — Accounts, linking, sync
status: In progress
progress:
  - "[x] HLC + per-field clocks on logins, tombstones, passkey/device/meta clocks; stamping on every local change (VaultStore.mutate)"
  - "[x] Merge: field-level last-writer-wins, losing password kept in history, delete-vs-later-edit, revocations never undone; commutative/idempotent (tests)"
  - "[x] Device keys: P-256 signing + agreement, Secure Enclave when available; Keychain storage"
  - "[x] SyncMessage: sealed under VK sync subkey, signed by device; rejects unknown/revoked senders, forgeries, tampering, wrong epoch"
  - "[x] Link protocol: QR (room+ephemeral+secret) or account-number room; ECDH + HKDF bound to the hello; 4-digit code; vault sent still master-password locked"
  - "[x] Relay Worker (relay/): SQLite Durable Objects, signed requests, members, revocations (410 + signed record), ack-based deletion, 7-day TTL, 15-min link rooms"
  - "[x] Integration tests Swift ↔ local relay (DEADBOLT_RELAY_URL), incl. CryptoKit raw signatures verifying in WebCrypto"
  - "[x] Apps: SyncEngine (push delta / pull / ack / snapshot on gap, 20 s while unlocked + after changes), Devices tab, Join (QR/account number), approve (scan on iPhone, requests in Devices + Mac menu), remove/retire with master password, verified-removal wipe"
  - "[x] Relay deployed to deadbolt-relay.osborne.vc (2026-11-18); live integration tests pass 3/3"
  - "[ ] On-device test: iPhone ↔ Mac link, edit both ways, remove/retire"
  - "[x] Vault-key rotation on removal: next epoch wrapped by master password + recovery key, KeyGrant per remaining device (ECDH to its agreement key), new mailbox with remaining members, signed .rotate in old mailbox, local re-seal + Face ID key refresh (tests)"
  - "[x] Link privacy: hello carries only public keys; names/models travel sealed (details, per-role context)"
  - "[x] Relay rate limits (Workers ratelimit binding, per IP/min): link POST 20, link GET 120, mailbox 600"
  - "[x] Fix: link requests no longer tied to view lifetime ('cancelled' error); approve sheet opens after scanner dismisses; Try again"
  - "[x] Silent push: relay sends content-free APNs pushes (≤1/15 s per device, token per member, prod→sandbox fallback, gone tokens dropped); iPhone unlocked → full sync, locked → prefetch sealed messages to a pending queue merged at next unlock (app or AutoFill sheet; rotations wait for the app)"
---

# Phase 4 — Sync

Spec: AGENTS.md §4b. Relay protocol: header comment in `relay/src/index.js`.

## Known gaps (stated, not hidden)
- **Retire doesn't rotate.** A retiring device erases itself after revoking, so the key isn't rotated (it would have to generate the new key itself). Removal of another device always rotates.
- **Device offline > 7 days across a rotation** misses the `.rotate` message (relay TTL) and must be linked again.
- **Two devices removing at the same moment** could produce two epoch+1 keys; not handled yet (rare, single owner).
- iPhone syncs when the app is open (every 20 s) and right after changes; no background push yet.
