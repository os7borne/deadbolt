---
name: Mac app v2 + streamlined forms
status: Built and installed, owner review pending
progress:
  - "[x] Design canvas row 'Mac app v2 (proposed)': vault window (interactive), edit sheet, Settings window; approved by owner 2026-11-19"
  - "[x] MacMainView v2: no sidebar, one toolbar (search ⌘F, New ⌘N, generator popover, Devices, Settings, Lock ⌘L), filter tabs All/Passkeys/Codes with counts, 44 px rows with hover copy buttons + passkey mark, context menu"
  - "[x] Detail as field list: username, password (reveal, copy), one-time code with ring, passkey, websites, label, history (expand + Restore), notes"
  - "[x] Status bar: sync state, device count, time to lock"
  - "[x] MacSettingsView: Settings scene (⌘,), tabs General / Security / AutoFill / Devices / Backups / About; toolbar Devices opens the Devices tab; locked → Unlock button"
  - "[x] Compact bottom-right toasts on Mac (ToastOverlay.compact)"
  - "[x] LoginFormModel shared by iPhone EditLoginView and Mac MacEditSheet (website first with preview, password strength, Save names what's missing, More options collapsed)"
  - "[x] OneTimeCodeSetupView: iPhone camera scan + Photos screenshot; Mac paste screenshot / choose image / drop; setup-key fallback; live code preview; friendly errors (HOTP, not an authenticator QR, bad key)"
  - "[x] 'Add one-time code' on login detail (iPhone card, Mac 'Set Up…' row)"
  - "[x] Camera usage text covers one-time codes"
  - "[x] Builds clean (Mac Release, iOS Debug); installed on Mac + iPhone 11"
  - "[ ] Owner: review window, Settings, forms; try lab test 9 with camera (iPhone) and Paste Screenshot (Mac)"
  - "[x] Mac restyle (2026-11-19): Devices, Backups, Recovery Kit, Import, link-approval and remove-device in Views/MacSettingsPanes.swift (builds clean; not yet installed or eyeballed)"
  - "[x] Generator preferences (2026-11-19): length, A-Z, a-z, 0-9, symbols, min numbers/symbols, avoid look-alikes, passphrase words. Stored in the vault (Vault.generator, metaClocks[\"generator\"], synced LWW); used by iPhone Generator, Mac popover, both login-form Generate buttons and the Chrome bridge. Core tests 94. Built clean on Mac + iOS; not installed/eyeballed"
  - "[x] Other websites list + custom fields (2026-11-20): LoginItem.customFields (merged per field), editors in Views/LoginFormExtras.swift, shown in iPhone + Mac detail with hide/reveal + copy. Core tests 97. Built clean; not installed. Not yet filled by Chrome/AutoFill"
  - "[x] Mac v2 for the AutoFill extension sheets (2026-11-20): AutoFillViews.swift scales by an `AF` metrics enum (iPhone sizes unchanged; Mac = 13 pt text, 44 px rows, MacButtonStyle/macField, compact cards, Touch ID icon); window 380x440. Built clean; not installed; owner still has to enable Mac AutoFill to see it"
---

# Mac app v2 + streamlined forms

Design source: canvas https://claude.ai/artifact/XaS4NKFZCvWkKNTgoifMDJ, boards MacVault2 / MacEdit2 / MacSettings2 and the
"Mac app v2 — design rules" note. Visual language = the menu-bar panel: 13 pt text, 12 pt secondary, 44 px rows, 26 px quiet icon
buttons, brass only for the primary action and selection.

Menu bar: Delete deliberately isn't a hover button; it's in the right-click menu and the edit sheet (⌘E), always confirmed.
