---
name: Sort options for the item lists
status: Built, not released (compiles on Mac + iPhone; Core tests pass; owner hasn't tried it)
progress:
  - "[x] Core: ListSort + Listable (title, createdAt, updatedAt, lastUsedAt) for logins, cards, identities, notes; unit tests"
  - "[x] Storage: per device (owner chose), one choice for all lists, `@AppStorage(\"listSort\", store: AppConfig.defaults)`"
  - "[x] Mac: sort menu in the list header (MacMainView `rows`, Websites `groups`)"
  - "[x] iPhone: Sort menu in the Vault toolbar (VaultViews `entries`, Websites `groups`)"
  - "[-] Date line on rows: owner said no"
  - "[x] Docs: AGENTS.md row"
---

# Sort options for the item lists

Today every list is A–Z by title (Mac `MacMainView.rows`, iPhone `VaultViews.entries`; Websites groups by title). Suggestions in Chrome and AutoFill are already most-recently-used first and are not part of this.

## Options
| Option | Rule |
|---|---|
| Name A–Z (default) | `localizedCaseInsensitiveCompare` on the shown name (the friendly name if set); ties: username, then type |
| Name Z–A | reverse of the above |
| Last modified | `updatedAt`, newest first (editing and saving bumps it; using/filling does not) |
| Last used | `lastUsedAt`, newest first; never-used items after the used ones, A–Z among themselves; notes (no `lastUsedAt`) use `updatedAt` |
| Date added | `createdAt`, newest first |

Ties and identical import timestamps fall back to name, then type, so the order is stable.

Applies to every flat list (All, Passkeys, Cards, Identities, Notes). Websites offers all five, using the oldest created / newest edited / newest used item in each site group. The Codes tab keeps its own order for now.

## Where it goes
- **Core** (`DeadboltCore`): `enum ListSort: String, CaseIterable` and a small `Listable` protocol implemented by `LoginItem`, `CardItem`, `IdentityItem`, `NoteItem`, with one function that sorts any mixed list. Pure, so it is unit-tested (ordering, never-used last, stable ties, localized compare).
- **Mac**: a menu button in the list header next to the filter name and count, checkmark on the current option.
- **iPhone**: a Sort menu in the Vault toolbar next to the generator.
- Selection is by UUID, so re-sorting keeps the selected item.

## Storing the choice
Two ways, both already used elsewhere in the apps:

1. **Per device (recommended default).** `@AppStorage("listSort", store: AppConfig.defaults)`, the same place as `macSidebarWidth` / `macListWidth`. Survives restarts and updates, never leaves the device, nothing to sync. The phone and the Mac can differ.
2. **Synced in the vault.** Like the generator settings (`Vault.generator`, `metaClocks["generator"]`, last writer wins): a `Vault.listSort` field merged by the sync engine, so changing it on one device changes it on all. Costs a Core field, a merge rule, a sync test and a schema-compatible default (old vaults decode as "Name A–Z").

Either can remember **one choice for all lists** (simplest) or **one per filter** (All = Last used, Cards = Name). Recommended: one global choice.

Open questions for the owner: per device or synced; one choice or one per filter; "Edited 3 days ago" line on rows; section headers (Today, This week, Earlier) now or later.
