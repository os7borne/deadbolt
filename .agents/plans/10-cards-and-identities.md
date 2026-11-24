---
name: Cards and identities (Bitwarden-style item types)
status: In progress (2026-11-20). Decisions confirmed; Core built and tested; UI, import and Chrome not started
progress:
  - "[x] Owner answers the open decisions (section 6)"
  - "[x] Core: CardItem + IdentityItem + NoteItem, Vault arrays, stamp/delta/merge/tombstones, schema guard, tests (115 passing)"
  - "[x] Backup item count covers the new types (restore needs no change: the whole Vault is sealed)"
  - "[x] Import: Bitwarden JSON (logins, cards, identities, notes) in Core + both import screens; encrypted export = the existing backup file, already covers everything"
  - "[x] Mac UI: filters, rows, detail panes, edit sheets, New menu, Touch ID on reveal/copy/edit (built, compiles; NOT yet seen or exercised by the owner)"
  - "[x] iPhone UI: list, detail, edit forms (built, compiles; NOT yet seen or exercised on the iPhone)"
  - "[x] Mac menu-bar panel lists cards, identities, notes (built 2026-11-20, not run)"
  - "[x] Both apps installed 2026-11-20 (Mac 14:17 build, iPhone 11 Debug build)"
  - "[ ] Owner runs the checklist in section 11; fixes from that"
  - "[x] Chrome popup (copy): extension 0.4.0 + bridge `items`/`copyItem` (built, tested with a throwaway jsdom harness, not yet used in Chrome)"
  - "[x] Chrome in-page fill, top frame only: extension 0.5.0 + bridge `fillItem` + lab pages 12/13 (built, tested with 70 harness checks, not yet used in Chrome)"
  - "[ ] Fill inside payment iframes (decision needed, section 14)"
  - "[ ] SECURITY.md updated; reveal/copy rules tested"
---

# Cards and identities: plan

Goal: store payment cards and identities (name, address, ID numbers) in the vault, the way Bitwarden does, with the same
guarantees as logins: end-to-end encrypted, synced through the existing dead-drop relay, no server ever sees readable data.

## 1. What the code looks like today (review)

- `Vault` (`Core/.../Vault/Vault.swift`) is one Codable struct holding `logins: [LoginItem]` and `passkeys: [Passkey]` plus
  vault-level fields (`generator`, `devices`, `tombstones`, `metaClocks`). It is sealed as **one blob** in `VaultFile` (format 1).
- **Sync is not a generic item store.** `Merge.swift` hard-codes logins and passkeys: `LoginItem.mergedFields`, `changedFields`,
  `merged`, and `Vault.stamp / delta / merge / isEmptyDelta / newestClock`. Deletes are `tombstones["login:<uuid>"]`.
  A new item type has to be added to **each** of those, or it will not sync, will not delete across devices and will not merge.
- `SyncMessage` carries a whole `Vault` as the delta payload, so new arrays travel automatically once `delta`/`merge` know them.
- Old data is handled by making new fields optional (`customFields?`, `generator?`, `clocks?`). Follow the same rule.
- `.logins` is used in 28 places in `Apps/`: lists, filters, search, AutoFill, bridge. New types must not leak into the
  AutoFill extension, the Chrome "accounts"/"fill" paths or the site-matching code.
- `BackupFile.items` counts `vault.logins.count` only.
- `CSVImport` already detects Bitwarden CSV (`login_uri` column) but reads only login rows.
- UI: Mac `MacMainView.Filter` = all / websites / passkeys / codes; iPhone `VaultFilter` = All / Websites / Passkeys + Codes tab.
  Forms are driven by `LoginFormModel` (shared by iPhone `EditLoginView` and Mac `MacEditSheet`).

## 2. Platform limits (checked, not assumed)

- **iOS and macOS AutoFill cannot fill cards or identities from a third-party manager.** In the iOS 27.2 SDK headers,
  `AuthenticationServices` credential types are password, passkey and one-time code only. So on iPhone and in Mac apps a card
  is something you open in Deadbolt and **copy from** (number, expiry, code, one field at a time). No system "fill my card".
- **Chrome** (our extension) and the **Safari Web Extension** can fill, because they are our own content scripts.
  Checkout forms often put the card in a cross-origin iframe (Stripe, Adyen). Chrome iframes are already a known gap
  (`SECURITY.md`), so in-page card fill will work on plain forms only at first.
- Apple Wallet / Safari's own saved cards are not reachable by us. Import has to come from a Bitwarden export or typing.

## 3. Data model

New types in `Core/.../Vault/`, same style as `LoginItem` (id, title, fields, `notes`, `customFields`, `createdAt`,
`updatedAt`, `clocks`). All new `Vault` properties are **optional arrays** so old vaults decode unchanged.

**CardItem**: `title`, `cardholderName`, `brand` (Visa, Mastercard, Amex… auto-detected from the number, overridable),
`number`, `expMonth`, `expYear`, `securityCode`, `pin` (hidden), `billingIdentityID` (optional link to an identity), `label`, `notes`,
`customFields`. Derived: `last4`, `isExpired`, Luhn check (a warning, never a blocker: some cards fail it).

**IdentityItem**: `title`, `salutation`, `firstName`, `middleName`, `lastName`, `username`, `company`, `email`, `phone`,
`address1-3`, `city`, `state`, `postalCode`, `country`, `ssn`, `passportNumber`, `licenseNumber`, `label`, `notes`,
`customFields`. Sensitive (`ssn`, `passportNumber`, `licenseNumber`) are **hidden by default**.

Merge: same per-field last-writer-wins with HLC clocks as logins, no history needed. To avoid copying the 60 lines of
merge code three times, first extract a small generic helper (`mergedFields` + `changedFields` + `pick` driven by a field
list) and use it for the new types only. Do not refactor `LoginItem` merging in this change: it is tested and in daily use.

Deletes: tombstone keys `card:<uuid>`, `identity:<uuid>`, merged exactly like logins ("an edit after a delete brings it back").

**Schema guard (important):** a build that does not know about cards will decode a vault, ignore `cards`, and then re-save it,
which **silently deletes every card** on that device and syncs the loss. Mitigations:
1. Add `Vault.schema: Int?` (2 = has cards). New builds refuse to open a higher schema than they know.
2. The owner updates iPhone, Mac app and Mac AutoFill extension **before** saving the first card. The plan's release step says so.
3. A test: vault with cards -> encode -> decode as the current model -> cards survive; and old vault JSON still decodes.

Not in v1, kept out on purpose: `login` and `card` sharing one generic `Item` enum (big refactor of 28 call sites).

## 4. Security rules for the new types

These follow `SECURITY.md` "Rules for future changes" and the existing threat table.

- Secrets (card number, code, PIN, SSN, passport, licence) are **masked by default**; reveal and copy go through the same
  re-authentication used for passwords. Row subtitle shows `Visa •••• 4242`, never the full number.
- **Never** put cards/identities in `ASCredentialIdentityStore`, the AutoFill extension's lists or Spotlight/search indexes.
  Search matches title, brand, last 4, cardholder, label only, never the full number or code.
- **Chrome bridge**: `accounts`/`fill`/`code` stay login-only. New actions (`cards`, `identities`, `fillCard`, `fillIdentity`)
  return **names and last 4 only** until the owner picks one **in the Deadbolt popup/menu with a trusted click**; the Mac app
  then asks for Touch ID before releasing a card number or code. Cards are not site-bound, so a page must never be able to
  request a card by itself. Top frame only, https only, never hidden or cross-origin frames (existing rules).
- Clipboard: copied card numbers/codes expire from the clipboard (use the Phase 7 clipboard-clearing work; if it is not built
  yet, build it first for these fields, 30 s).
- Backups and sync: nothing special, they ride the existing sealed formats. Backup `items` count includes all types.
- Add to `SECURITY.md`: cards/identities are in the vault but not released to web pages without a user pick + Touch ID.
- Honest note for Privacy screen: a stolen unlocked Mac exposes cards like it exposes passwords (already out of scope).

## 5. Build order

1. **Core (no UI).** `CardItem`, `IdentityItem`, `Vault.cards/identities/schema`, `stamp`, `delta`, `merge`, `isEmptyDelta`,
   `newestClock`, tombstones, `BackupFile.items`. Tests: round trip, merge conflicts (two devices edit different fields of one
   card), delete vs edit, old-vault decode, schema guard, Luhn/brand/expiry helpers, search never matching full number.
2. **Import/export.** Extend `CSVImport` for Bitwarden `type` = card / identity rows (`card_number`, `card_exp_month`… are not
   in the CSV format: Bitwarden's **JSON** export is the one that carries cards and identities, so add JSON import). Encrypted export
   includes the new types.
3. **Mac UI.** Filters add Cards and Identities; `New ⌘N` becomes a small type menu (Login, Card, Identity, plus Secure Note if
   chosen below); `CardFormModel` / `IdentityFormModel` + sheets modelled on `LoginFormModel`/`MacEditSheet`; detail pages as
   field lists with hide/reveal + `TickButton` copy. Status bar counts unchanged.
4. **iPhone UI.** Same list rows (brand icon for cards), detail with tap-to-copy, edit forms. iPhone has no AutoFill for these (section 2),
   so tap-to-copy must be fast: number, expiry, code each one tap away from the card row.
5. **Chrome popup**: Cards and Identities lists with copy (v1). **In-page fill** next: detect `autocomplete` tokens (`cc-number`,
   `cc-exp`, `cc-csc`, `cc-name`, `given-name`, `address-line1`, `postal-code`…), menu on those fields, trusted click, Touch ID.
   Bump `chrome/manifest.json`, rerun `scripts/sync-safari-extension.sh`, add lab scenarios 12 (card checkout) and 13 (address form).
6. **Release.** Update every device before the first card is saved (section 3). Update `AGENTS.md` decisions table and `SECURITY.md`.

Rough size: Core + tests about 1 day, import 0.5 day, Mac UI 1 day, iPhone UI 1 day, Chrome copy 0.5 day, Chrome fill 1-2 days.

## 6. Decisions (owner confirmed 2026-11-20)

Secure Note: yes. All shows every type with a type icon. Touch ID on every copy/reveal of number, code, PIN, ID numbers. Chrome: popup copy first, in-page fill later. Billing-identity link and Bitwarden-JSON-only import: taken as recommended (not objected to).

Original table:

| # | Question | Recommendation |
|---|---|---|
| 1 | Include **Secure Note** as a third type (Bitwarden has it)? Logins already have a notes field, so it is optional. | Yes, small once the generic merge helper exists |
| 2 | Should **All** show cards and identities too, or keep All = logins and give them their own filters? | Own filters **and** a type icon in All, like Bitwarden; but you set "one row per login" for All on 2026-11-19, so confirm |
| 3 | Touch ID **every time** a card is revealed/copied, or only when Deadbolt was unlocked longer than N minutes ago? | Every copy of number/code/SSN; names and last 4 free |
| 4 | Chrome in-page fill in v1, or popup copy only first? | Copy first; fill after the form detection is proven in the lab |
| 5 | Link a card to an identity as billing address? | Yes, optional, cheap |
| 6 | Import source: Bitwarden JSON only (nothing else exports cards)? | Yes |

## 7. Built so far (Core, 2026-11-20)

- `Vault/SyncedItem.swift`: `SyncedItem` protocol + `ItemField` (keypath-driven field list) and generic `stampItems` / `mergeItems` / `upsertItem` on `Vault`.
  New types declare their fields once; clocks, deltas, tombstones and merge come for free. `LoginItem` merging is untouched.
- `CardItem` (brand detection, Luhn, expiry, masked summary, grouped number, `searchText` without secrets), `IdentityItem`, `NoteItem`.
- `Vault`: `cards`, `identities`, `notes` (non-optional, decode as empty from old vaults), `schema` (2) and `currentSchema`.
  **A vault with a newer schema fails to decode** (`unsupportedVersion`), so a downgraded build refuses instead of dropping data.
  `upsert(_:)` overloads, `deleteCard/deleteIdentity/deleteNote` (deleting an identity unlinks cards that pointed at it), `itemCount`.
- Tombstone keys `card:<uuid>`, `identity:<uuid>`, `note:<uuid>`.
- Tests: `Tests/DeadboltCoreTests/ItemTypesTests.swift` (18 tests). Mac app target compiles unsigned.

**Release warning:** builds made before this change do not know these types and would drop them on their next save. Install the new build on
the iPhone, the Mac app and the Mac AutoFill extension **before** saving the first card, identity or note.

## 8. Import (built 2026-11-20)

- `Import/BitwardenJSON.swift`; `PasswordImporter.parse` routes text starting with `{` there, CSV unchanged. Reads Bitwarden item types 1 login,
  2 note, 3 card, 4 identity; custom fields (hidden/text; linked fields dropped), extra login URIs become extra sites. Folders, favourites,
  attachments and SSH keys are not imported (SSH keys are listed as skipped). Encrypted exports are refused with a message telling the owner what to pick.
- Cards, identities and notes are **only added**, never overwritten; a repeat is skipped (card = same number, or same title + cardholder when
  there is no number; identity = same title, name, email, address line 1, postcode; note = same title + text). Re-importing a file adds nothing.
- `ImportPlan` counts new/already-saved for each type; iPhone and Mac screens show them and the button says "Import N items".
- Tests: `BitwardenImportTests.swift` (6). Core now 121 tests. Mac and iOS targets compile unsigned.
- Note for the owner: the Bitwarden JSON export is **plain text**: delete it afterwards (the import screen already offers to).

## 9. Mac UI (built 2026-11-20, compiles unsigned, not run by the agent)

- `Views/OwnerCheck.swift` (shared): `VaultSession.confirmOwner(reason)` = fresh Touch ID/Face ID every time; if biometrics are off, unavailable (lid
  closed) or cancelled, the **master password** sheet appears (`OwnerPasswordSheet`, shown by `.ownerCheckSheet(session)`). Device passcode is never accepted.
  `copyProtected(_:what:)` = check, copy with the **30 s** clipboard timeout (`Clipboard.sensitiveClearAfter`; logins keep 60 s), toast.
- `Views/ItemForms.swift` (shared, will serve iPhone): `CardFormModel` (digits-only number, Luhn warning that never blocks, month + year both or neither,
  default title "Visa 4242"), `IdentityFormModel`, `NoteFormModel`.
- `Views/MacItemViews.swift`: `TypeTile`, detail panes (`MacCardDetail`, `MacIdentityDetail`, `MacNoteDetail`), context/⋯ menus (`CardMenu`, `IdentityMenu`, `NoteMenu`),
  edit sheets (`MacCardSheet`, `MacIdentitySheet`, `MacNoteSheet`), `CustomFieldsEditor`. Secret rows are masked, eye + copy each ask for the check, a revealed
  value hides again after 20 s. Opening an existing card/identity/note **to edit** also asks (otherwise Edit would bypass the reveal check).
- `MacMainView`: filters All, Websites, Passkeys, Codes, **Cards, Identities, Notes** (tab row scrolls); All = every kind sorted by title with type icons; `+` is now a menu
  (Login, Card, Identity, Secure Note, One-Time Code…) and ⌘N creates the kind of the current filter (login otherwise); search placeholder counts all items; the
  "Add Code" button on the Codes tab is unchanged. Card rows show brand, last 4, expiry and a red **Expired** tag. A card's billing identity has a "Show" link.
- Not touched on purpose: menu-bar panel, Mac AutoFill, Chrome bridge and iPhone are still logins-only, so none of these can see or fill cards yet.
- Free to copy without a check: cardholder name, expiry, brand, name/address/email/phone. Everything secret is gated (see `FieldSpec.secret`).

## 10. iPhone UI (built 2026-11-20, compiles unsigned, not run)

- Shared with the Mac (`Views/ItemCommon.swift`): `ItemKind`, `ItemSheet`, `PendingDelete`, `ItemRef`, `TypeTile`, `TypedItemRow`, `FieldSpec` + the field lists
  (`CardItem.fieldSpecs`, `IdentityItem.specGroups`, `NoteItem.fieldSpecs`) and the copy menus (`CardMenu`, `IdentityMenu`, `NoteMenu`). The Mac views were changed to use them.
- `Views/ItemViews.swift` (iOS only; empty stand-ins on Mac because `VaultViews.swift` compiles on both): `ItemFields`/`ItemFieldRow` (masked secret rows, Face ID on every show/copy,
  hides after 20 s, haptic on copy), `ItemScaffold`, `CardDetailView`, `IdentityDetailView`, `NoteDetailView`, `EditCardView`, `EditIdentityView`, `EditNoteView`, `ItemCustomFields`.
- `VaultListView`: filter chips scroll (All, Websites, Passkeys, **Cards, Identities, Notes**); All lists every kind by title; `+` is a menu (Login, Card, Identity, Secure note);
  swipe "Copy number" on cards; long-press menus; Edit on a detail screen and from a menu asks for Face ID first; delete asks to confirm.
- `MainView` hosts `.ownerCheckSheet`, so the master-password fallback appears as a small bottom sheet.
- Not done: AutoFill extension and Codes tab are unchanged (logins only). The menu-bar panel on the Mac is still logins-only (offered to the owner, not decided).

Next: step 5, Chrome popup copy (bridge actions `cards`/`identities`: names + last 4 only, secret released after a pick and Touch ID).

## 11. Owner decisions (2026-11-20, questionnaire) and device test

Decided: menu-bar panel lists cards/identities/notes (done); **pause here so the owner installs and tests before more is built**; Bitwarden folders stay ignored;
cancelling Touch ID/Face ID falls through to the master-password sheet (current behaviour, kept).

Menu-bar panel: ↵ or click = login password / card number (Touch ID) / identity email (else name) / note text (Touch ID); ⋯ and right-click = the full copy menu;
Edit asks Touch ID, then opens the editor in the main window (`session.pendingItemSheet`). The password sheet is hosted in the panel too, and any pending
check gives up after 2 minutes, so a closed window can't wedge later checks (found while building the panel).

**Install** (AGENTS.md section 8): Mac = signed Release build, quit the running app, back it up to `build/backup/Deadbolt-previous.app`, `ditto` to /Applications,
then `pluginkit -a` and `pluginkit -e use -i com.osborne.deadbolt.autofill`. iPhone = `xcodebuild … -scheme Deadbolt … build` then `xcrun devicectl device install app`.
Install **both** before saving a card (older builds drop cards).

**Checklist**
1. Mac: New › Card with a real-looking test number (4111 1111 1111 1111, any expiry/code). Row shows `Visa •••• 1111`; a typo'd number shows the warning but saves.
2. Mac: click the eye on Number: Touch ID asks; number shows in groups and hides after ~20 s. Copy: Touch ID asks, paste elsewhere = digits only, gone from the clipboard after 30 s.
3. Mac: Edit on the card asks Touch ID before the sheet opens. Cancel Touch ID once: the master-password sheet should appear; Cancel that: nothing is released.
4. Mac lid closed (external display): copy a secret: master-password sheet instead of Touch ID.
5. Mac: New › Identity (with address and a passport number) and Secure Note. Cards filter, Identities, Notes tabs; search for the last 4 digits finds the card; searching the full number does not.
6. Mac menu-bar panel: cards/identities/notes appear; ↵ on a card asks Touch ID and copies; Edit… opens the editor in the main window; with the main window closed, copy still works.
7. Sync: within a minute the same items appear on the iPhone (Vault tab, chips scroll sideways). Edit the card's title on the iPhone: it changes on the Mac.
8. iPhone: eye and copy ask Face ID every time; swipe a card row = Copy number; Edit asks Face ID; delete from the iPhone removes it on the Mac.
9. Import: Bitwarden **JSON** export (not encrypted) of a few cards/identities/notes: preview counts look right; importing the same file again adds nothing.
10. Old data: logins, passkeys, codes, Chrome fill and AutoFill still work as before (nothing about them was meant to change).

Report anything odd: the layout of the scrolling tab row (Mac) and chips (iPhone) were not seen by the agent.

After testing: step 5 (Chrome popup copy, then in-page fill).

## 12. Mac window v3: sidebar (2026-11-20)

Owner feedback: the Add button only offered Login (the installed app was the pre-feature build, from Nov 20 01:29: it had none of the new code) and the header was clumsy
(a title-bar strip above a toolbar, "Deadbolt" floating off to one side). Done: sidebar with filters + counts, Devices/Settings/Lock moved to its foot, traffic lights over the sidebar,
toolbar reduced to search + New menu + generator, list header with filter name/count and a contextual "New"/"Add Code" button, ⌘1-⌘7 for the filters, window min width 940.
Compiles; **not seen by the agent**: first things to check are the traffic lights over the sidebar, that the window drags by the toolbar/sidebar top, and the settings view in the new layout.

Installed 2026-11-20 by the agent: Mac = signed Release build in /Applications (previous copy in `build/backup/Deadbolt-previous.app`, AutoFill extension re-registered); iPhone 11 = signed Debug build via devicectl. The checklist in section 11 can start.

Reinstalled the Mac app 2026-11-20 14:57 (grouped identity form, idle-lock activity + focus-after-Touch-ID fixes, resizable columns). Previous copy in `build/backup/Deadbolt-previous.app`.

## 13. Chrome popup copy (built 2026-11-20)

- **Core:** `Vault/CopyFields.swift`: `CopyField` (key, label, secret, value) for cards (number, code, pin = secret; holder, expiry MM/YY, MM/YYYY, month, year), identities
  (name, email, phone, address, company, username; ssn, passport, license = secret) and notes (body = secret); `Vault.copyField(item:key:)` never finds a login. 4 tests (Core now 125).
- **Mac bridge (`BridgeServer.swift`):** `items` (names, brand, last 4, expiry, which fields exist and whether secret) and `copyItem` (Touch ID for secrets, then the Mac copies; HUD note while waiting).
  The password-sheet fallback brings Deadbolt's window forward if Touch ID can't be used. `confirmOwner` no longer activates Deadbolt unless Deadbolt was already the active app.
- **Extension 0.4.0:** popup tabs This site / Cards / Identities / Notes; `background.js` only accepts `items`/`copyItem` from its own popup. Safari copy regenerated with `scripts/sync-safari-extension.sh`.
- **Tests:** throwaway jsdom harness (scratchpad, not committed): 18 checks: page/other-extension/web-URL senders refused and nothing forwarded; popup lists cards without any number in the DOM;
  hostile titles escaped; copy sends only id+field; cancel handled; older Mac app gives a clear message.
- **To use it:** install the new Mac app (bridge), reload the extension at chrome://extensions (or Aside's equivalent), open the popup, Cards tab. Both are needed: a new extension with an old Mac app says "Update Deadbolt for Mac".
- **Not built (decision needed):** in-page fill of cards/addresses. Needs: field detection by `autocomplete` tokens, a menu on those fields, a trusted click, top frame + https only, Touch ID, and a way for the value to reach the page
  (today nothing secret goes through Chrome; fill must). Iframe checkouts (Stripe/Adyen) won't work without frame support, which logins don't have either.

## 14. In-page fill (built 2026-11-20, extension 0.5.0)

**Owner decision (2026-11-20): copying is not enough, so fill.** Defaults chosen by the agent (tell me to change any): Touch ID only for a card number / security code; identity fields (name, address, email, phone) fill on the pick alone;
ID numbers stay copy-only; top frame only for now.

- **Core:** `Vault/FillValues.swift`: `fillValues(item:want:)` returns only requested keys (card: number*, code*, holder, holderFirst/Last, expMonth, expYear, expYear2, expiry MM/YY, expiryLong, expiryCompact; identity: salutation, first, middle, last, name, company, username, email, phone, address (joined), address1-3, city, state, postal, country; *secret). `hasSecret` tells the Mac whether Touch ID is needed. PIN / ID numbers / note text not fillable. 6 tests (Core now 131).
- **Mac:** bridge `fillItem` (https or localhost only; Touch ID + floating note naming the host when a secret is requested).
- **Extension:** `chrome/fieldmap.js` (autocomplete tokens, then conservative name/label guesses; month/year/country/state `<select>` matching; expiry format by placeholder/maxlength), `content.js` (menu on focus in a card/address field, pick = trusted click, fills visible fields only, skips fields the person typed, never treats a masked CVV as a password), `background.js` (`fillCandidates`, `fillItem`: page script only, frame 0, https, Chrome's tab URL, sanitised key list), popup **Fill** button on cards and identities (copies are in the ⋯ menu), Safari resources regenerated (`fieldmap.js` added to the sync script).
- **Lab:** `website/public/lab/card-checkout.html` and `address-form.html` (+ index entries 12, 13). **Not deployed** (the site is public; deploying is `cd website && npx wrangler@4 deploy`, owner to say). Local use without deploying: `cd website/public && python3 -m http.server 8123 --bind 127.0.0.1`, open http://127.0.0.1:8123/lab/card-checkout.html (the extension matches 127.0.0.1).
- **Tests (scratchpad jsdom harness, not committed):** 70 checks: classification on realistic markup (tokens, guesses, negatives), worth-offering rules, expiry/select/country matching, the full page flow (menu shows names and last 4 only; an untrusted click does nothing; a genuine click asks for exactly the fields the form has; honeypot skipped; typed text kept; second pick replaces what Deadbolt filled; cancel/locked/empty), CVV not captured as a password on submit, popup and background permission rules (sub-frame, http, popup sender refused; Chrome's URL used).
  The trusted-click test swaps the browser's `isTrusted` for a flag because jsdom can't produce trusted events; a check asserts the real gate line in content.js is unchanged.
- **Not verified:** any real Chrome run; real checkouts; Safari (shares the code, untested).
- **Open decision, iframes:** many checkouts (Stripe Elements, Adyen, Razorpay…) put the card fields in cross-origin iframes. Supporting them means running the content script in sub-frames, relaying the menu to the top frame (the frame is too small to show it) and allow-listing processor origins, so a random ad iframe can never receive a card. Larger and riskier than everything above; needs the owner's go-ahead and a list of which processors matter (India: Razorpay, PayU, Cashfree, Stripe?).

**First real-Chrome result (owner, 2026-11-20, live lab test 12):** form A (autocomplete hints) and form B (names only, split month/year drop-downs) both filled every visible field, and the hidden trap stayed empty. Lab pages 12 and 13 deployed to https://deadbolt.osborne.vc/lab/ (owner ran the deploy; the agent's attempt was blocked by the permission check).
Still unconfirmed: that pressing Pay does not offer to save a password, that the Touch ID prompt/floating note named the site, the address page (13), the popup Fill button, and a real checkout.

## 15. Suggestions: three rows + scroll, most recent first (2026-11-20)

Owner asks: the in-page autofill list should show at most 3 suggestions with scroll for more; sort most recently used first. Answers: **most recent first, ★ only breaks ties among never-used**; **suggestions only** (app lists stay A–Z).

- **Core:** `lastUsedAt` on `CardItem` / `IdentityItem` (synced per field, doesn't touch `updatedAt`); `Vault.markItemUsed`, `cardsByRecency`, `identitiesByRecency`; `accounts(for:)` now orders used-newest-first, then never-used with ★ first, then A–Z. 4 new tests, one old test updated (Core 135).
- **Where use is recorded:** bridge `fillItem` / `copyItem`, `copyProtected`, the card/identity copy menus, the menu-bar panel's primary action. Logins already did (`markUsed`). The edit forms keep a newer `lastUsedAt` instead of overwriting it with the copy they opened with.
- **Where the order shows:** Chrome/Safari in-page menus and popup lists (the Mac sends them in this order; the extension never re-sorts), the Mac menu-bar panel (cards/identities), iPhone and Mac AutoFill suggestions for logins (they use `accounts(for:)`).
- **Extension 0.5.1:** `.list.scroll { max-height: 184px }` + `min-height: 52px` rows (3 rows + a peek of the 4th), header shows "N accounts · scroll" / "N · scroll" only when there are more than 3. Applies to login, card and identity menus. 8 more harness checks (78 in total across the three scratch files).
- Not changed: the popup's own lists (they live in a scrolling popup), the passkey chooser, the Mac main window and iPhone vault lists.

Installed 2026-11-20 17:31 (agent, owner-approved): Mac signed Release (previous copy in `build/backup/Deadbolt-previous.app`) and iPhone 11 Debug build. Extension 0.5.1 needs a reload at chrome://extensions.

## 16. Stale "Unlock Deadbolt" menu after Touch ID (fixed 2026-11-20, extension 0.5.2)

Owner report: in the in-page suggestion menu, Unlock asked for Touch ID, Touch ID succeeded, and the menu still said "Unlock Deadbolt".
Cause: a race in `content.js`. When the Touch ID dialog closes Chrome refocuses the field; that focus opened a *second* menu request which reached the Mac before the unlock had finished, got "locked", and drew a stale Unlock menu.
The unlock's own refresh then returned at once because "a menu is already open for this field". It affected the **login** menu as well as the card/identity menu.
Fix: every menu request carries a sequence number (`menuSeq`, bumped by new requests and by `hideMenu`); an answer is used only if it is still the latest; the post-unlock refresh is `force`d. Regression test (scratch harness `test4.js`, 4 checks, fails on the old code, passes on the new): refocus during unlock, delayed "locked" reply, then the fresh list must win, for cards and logins.
Chrome only needs the extension reloaded (no Mac reinstall). The Safari copy inside the Mac app is regenerated but only ships with the next Mac build.

## 17. Fill went into every CVV box on a saved-cards list (fixed 2026-11-20, extension 0.5.3)

Owner report with screenshot: a merchant checkout listing the shopper's saved cards (****6847, ****4165, …), each with its own CVV box. Picking a card from Deadbolt's menu in one CVV box filled **all** of them.
Cause: a pick filled every field of the card group found in the whole form/page, so a page with several boxes for the same thing got all of them. Same flaw for billing + shipping name/address blocks.
Fix (`content.js`): `pickScope` grows outward from the focused field and stops before it would include a second field of the same kind; `onePerKey` keeps the nearest box if duplicates remain; the Mac is asked only for the keys that scope needs (a CVV-only row asks for `code` only);
`last4Hint` reads "****4165" from the nearest part of the page and the menu then offers just the matching card (all cards if none matches or the page shows several); the popup's Fill on a page with several identical boxes and nothing focused says "click the one you want first".
Tests: scratch harness `test5.js` (10 checks, 6 fail on the old code). Total across the five scratch suites: 92.
Reload the extension (0.5.3); no Mac reinstall needed. Safari's copy is regenerated and ships with the next Mac build.

## 18. "Open Deadbolt" in the Chrome popup did nothing (fixed 2026-11-20, installed 23:14)

Owner report. Reproduced against the installed app: Deadbolt running with **no window on screen**, bridge `{"type":"open"}` replies `ok`, still no window (checked with a CoreGraphics window list, scratch `winlist.swift`).
Cause: `BridgeServer.open()` only brought *existing* windows forward. Deadbolt is a menu-bar app (LSUIElement); once the main window is closed a SwiftUI `Window` can only be reopened from inside SwiftUI (`openWindow`), which the bridge doesn't have. A plain `NSApp.activate()` from a background request is also often ignored on recent macOS. The same `open()` is used when Touch ID can't unlock ("show the window for the master password") and for the password fallback on a card/identity copy, so those had the same gap.
Fix: `MenuBarLabel` (alive from launch) and `SettingsCommand` register `MacRuntime.openMainWindow` (= `openWindow(id: "main")`); `open()` calls it, then `NSApp.activate()`, orders existing windows front, and asks LaunchServices to open/activate the app (`NSWorkspace.openApplication`, `activates = true`).
To verify after installing: close Deadbolt's window, run the bridge `open` request (or press the popup button) and count windows again.

Verified after installing (agent, scripted): with Deadbolt running, no window on screen and Zed frontmost, the bridge `open` request (the one the popup button sends) leaves **Deadbolt frontmost with its 1045x700 window on screen** (`lsappinfo front` + a CoreGraphics window list). Before the fix the same request replied ok and nothing appeared.
Caveats: not clicked from a real Chrome popup; the window was "not on screen" rather than closed by hand (a scripted close isn't supported); `System Events`' "frontmost" is unreliable for this menu-bar app, use `lsappinfo front`.

## 19. Toolbar account count never came back after unlocking (fixed 2026-11-20, extension 0.5.4)

Owner report: the extension icon no longer shows the account count. Checked: the Mac side was fine (unlocked, a passive `accounts` request returned the right accounts).
Cause: by design the badge is cleared while Deadbolt is locked (a locked vault shouldn't show even a count), but nothing ever **restored** it: the count only returned on the next page load. Each Mac reinstall restarted Deadbolt locked, the minute check cleared every badge, and after unlocking they stayed empty until each tab was reloaded.
Fix (`background.js`): remember which tabs reported which https page and whether their count is *waiting* (Deadbolt locked / not running / unreachable when asked, or the badge was cleared on lock). Waiting tabs are refreshed on the minute check once Deadbolt is available, when the tab is activated (`tabs.onActivated`, optional), and when the popup opens (`badgeNow`, popup-only). With nothing waiting the minute check makes no extra requests. Storage updates are serialised so two tabs loading at once can't overwrite each other.
Still true: a tab opened before an extension reload has an orphaned page script and reports nothing until it is reloaded once.
Tests: scratch `test6.js` (15 checks; the restore checks fail on the old code), all six suites 107 checks. Reload the extension (0.5.4); no Mac reinstall needed.
