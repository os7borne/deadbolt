---
name: Phase 6 — Mac AutoFill + Safari saving
status: Built, needs owner enabling + testing
progress:
  - "[x] Mac vault + preferences moved to the shared app group 4CMN2DUGUL.com.osborne.deadbolt (one-time migration, old copy kept)"
  - "[x] DeadboltMacAutoFill: passwords, passkeys, one-time codes in Safari and all Mac apps; same SwiftUI screens as iOS (AutoFillViews.swift)"
  - "[x] System identities (QuickType-style suggestions) on Mac too"
  - "[x] DeadboltSafari: Safari Web Extension built from chrome/ via scripts/sync-safari-extension.sh (flat resources, no key/favicon, no MAIN passkey script); native handler forwards to the app socket (signature-checked)"
  - "[x] In Safari the inline fill menu is off (system AutoFill does it); save prompt, popup, badge stay"
  - "[x] Deadbolt now listed and switched on in System Settings › AutoFill & Passwords (2026-11-20; needed the entitlement on the host app too)"
  - "[ ] Owner: Safari › Settings › Extensions › Deadbolt on; try AutoFill in Safari (lab) and a native app"
---
