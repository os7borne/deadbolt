#if os(macOS)
import AppKit
import DeadboltCore
import SwiftUI

/// Mac vault window v3 (2026-11-20): sidebar (filters with counts; Devices, Settings, Lock at the foot), then toolbar over list + detail,
/// and the status bar. The traffic lights sit over the sidebar, so there is no empty title-bar strip above the toolbar.
/// Same visual language as the menu-bar panel: 13 pt text, 44 px rows, quiet icon buttons, brass used sparingly.
struct MacMainView: View {
    enum Filter: Int, CaseIterable { case all, websites, passkeys, codes, cards, identities, notes }

    @Environment(VaultSession.self) private var session
    @State private var filter = Filter.all
    @State private var selection: UUID?
    @State private var query = ""
    @State private var adding = false
    @State private var deleting: LoginItem?
    @State private var hovered: UUID?
    @State private var showGenerator = false
    @State private var siteSelection: String?
    @State private var copiedID: UUID?
    @State private var addingCode = false
    @State private var sheet: ItemSheet?
    @State private var deletingItem: PendingDelete?
    @FocusState private var searchFocused: Bool
    /// Column widths the owner dragged them to; kept between launches. Double-click a divider to reset it.
    @AppStorage("macSidebarWidth", store: AppConfig.defaults) private var sidebarWidth = 204.0
    @AppStorage("macListWidth", store: AppConfig.defaults) private var listWidth = 320.0
    private static let minDetail = 340.0

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                // Keep every column usable: the detail pane never gets narrower than `minDetail`, even in a small window.
                let total = geo.size.width
                let sideMax = max(170, min(300, total - listWidth - 2 - Self.minDetail))
                let side = min(max(sidebarWidth, 170), sideMax)
                let listMax = max(250, min(520, total - side - 2 - Self.minDetail))
                let listW = min(max(listWidth, 250), listMax)
                HStack(spacing: 0) {
                    sidebar.frame(width: side)
                    ColumnDivider(width: $sidebarWidth, current: side, range: 170...sideMax, reset: 204)
                    VStack(spacing: 0) {
                        toolbar
                        Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1)
                        if session.settingsOpen {
                            MacSettingsView()
                        } else {
                            HStack(spacing: 0) {
                                list.frame(width: listW)
                                ColumnDivider(width: $listWidth, current: listW, range: 250...listMax, reset: 320)
                                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
            Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1)
            MacStatusBar()
        }
        .ignoresSafeArea(.container, edges: .top)   // content starts at the very top; the sidebar holds the traffic lights
        .background(WindowChrome())
        .font(.db(13))
        .background(DB.ground)
        .foregroundStyle(DB.text)
        .sheet(isPresented: $adding) { MacEditSheet(original: nil) }
        .sheet(isPresented: $addingCode) { AddCodeFlow() }   // set it up, then name it, in one sheet
        .sheet(item: $sheet) { sheetView($0) }
        .ownerCheckSheet(session)
        .alert(deletingItem.map { "Delete \($0.title)?" } ?? "", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
            Button("Delete", role: .destructive) { if let d = deletingItem { deleteItem(d) }; deletingItem = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It is removed from all your devices.") }
        .confirmationDialog(deleting.map { "Delete \($0.username) on \($0.title)?" } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { try? session.mutate { $0.delete(d.id) }; session.show("Login deleted") }
                if selection == deleting?.id { selection = nil }
                deleting = nil
            }
        } message: { Text("Its password, history and any passkey links are removed from all your devices.") }
        .onAppear { if selection == nil { selection = rows.first?.id }; takePendingSheet() }
        .onChange(of: session.pendingItemSheet) { _, _ in takePendingSheet() }
        .onDisappear { session.settingsOpen = false }   // locking or leaving brings the vault back next time
        .onChange(of: filter) { _, f in
            if f == .websites { if siteSelection == nil { siteSelection = groups.first?.id } }
            else if let sel = selection, !rows.contains(where: { $0.id == sel }) { selection = rows.first?.id }
        }
    }

    // MARK: toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(DB.text3)
                TextField("Search \(session.vault.itemCount) items", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                Text("⌘F").font(.db(11)).foregroundStyle(DB.text3)
            }
            .padding(.horizontal, 10).frame(maxWidth: 420).frame(height: 30)
            .background(Color(hex: 0x1A1C22), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(searchFocused ? DB.brass : DB.lineStrong))
            .background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden() }
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                addMenu
                toolButton("wand.and.stars", "Password generator") { showGenerator.toggle() }
                    .popover(isPresented: $showGenerator, arrowEdge: .bottom) { MacGeneratorPopover() }
            }
        }
        .padding(.horizontal, 14).frame(height: 52)
        .background(Color(hex: 0x111216).gesture(WindowDragGesture()))
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38).contentShape(Rectangle()).gesture(WindowDragGesture())   // the traffic lights sit here
            HStack(spacing: 8) {
                DeadboltGlyph(height: 17)
                Text("Deadbolt").font(.db(14, .bold))
            }
            .padding(.leading, 18).padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 2) {
                sidebarTitle("Library")
                ForEach([Filter.all, .websites, .passkeys, .codes], id: \.self) { sidebarRow($0) }
                sidebarTitle("Item types").padding(.top, 14)
                ForEach([Filter.cards, .identities, .notes], id: \.self) { sidebarRow($0) }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 12)
            Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 2) {
                footerRow("laptopcomputer.and.iphone", "Devices", active: false) { openSettingsTab("devices") }
                footerRow("gearshape", "Settings", active: session.settingsOpen) {
                    if session.settingsOpen { session.settingsOpen = false } else { openSettingsTab(nil) }
                }
                .help("Settings (⌘,)")
                footerRow("lock", "Lock", active: false) { session.lock() }
                    .keyboardShortcut("l", modifiers: .command).help("Lock now (⌘L)")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x0E0F12))
    }

    private func sidebarTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.db(10.5, .semibold)).tracking(0.7).foregroundStyle(DB.text3)
            .padding(.leading, 10).padding(.bottom, 3)
    }

    private func sidebarRow(_ f: Filter) -> some View {
        let on = filter == f && !session.settingsOpen
        return Button { filter = f; session.settingsOpen = false } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(f)).font(.system(size: 12, weight: .medium)).foregroundStyle(on ? DB.brass : DB.text2).frame(width: 18)
                Text(title(f)).font(.db(13, on ? .semibold : .regular)).foregroundStyle(on ? DB.text : Color(hex: 0xC9CCD2)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count(f))").font(.dbMono(11)).foregroundStyle(DB.text3)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(on ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(f.rawValue + 1)")), modifiers: .command)   // ⌘1 … ⌘7
        .accessibilityLabel("\(title(f)), \(count(f))")
    }

    private func footerRow(_ symbol: String, _ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(active ? DB.brass : DB.text2).frame(width: 18)
                Text(title).font(.db(13, active ? .semibold : .regular)).foregroundStyle(active ? DB.text : Color(hex: 0xC9CCD2))
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(active ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(_ f: Filter) -> String {
        switch f {
        case .all: "All Items"
        case .websites: "Websites"
        case .passkeys: "Passkeys"
        case .codes: "One-Time Codes"
        case .cards: "Cards"
        case .identities: "Identities"
        case .notes: "Secure Notes"
        }
    }

    private func icon(_ f: Filter) -> String {
        switch f {
        case .all: "square.grid.2x2"
        case .websites: "globe"
        case .passkeys: "person.badge.key"
        case .codes: "clock"
        case .cards: ItemKind.card.symbol
        case .identities: ItemKind.identity.symbol
        case .notes: ItemKind.note.symbol
        }
    }

    private func count(_ f: Filter) -> Int {
        let v = session.vault
        switch f {
        case .all: return v.itemCount
        case .websites: return Set(v.logins.compactMap { $0.sites.first }).count
        case .passkeys: return v.logins.filter { !$0.passkeyIDs.isEmpty }.count
        case .codes: return v.logins.filter { $0.totpSecret != nil }.count
        case .cards: return v.cards.count
        case .identities: return v.identities.count
        case .notes: return v.notes.count
        }
    }

    /// New login / card / identity / secure note / one-time code. ⌘N makes the kind the current filter shows (a login otherwise).
    private var addMenu: some View {
        Menu {
            Button { adding = true } label: { Label("Login", systemImage: "key.horizontal") }
            Button { sheet = .card(nil) } label: { Label("Card", systemImage: ItemKind.card.symbol) }
            Button { sheet = .identity(nil) } label: { Label("Identity", systemImage: ItemKind.identity.symbol) }
            Button { sheet = .note(nil) } label: { Label("Secure Note", systemImage: ItemKind.note.symbol) }
            Divider()
            Button { addingCode = true } label: { Label("One-Time Code…", systemImage: "clock") }
        } label: {
            Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(DB.onBrass)
                .frame(width: 30, height: 30).background(DB.brass, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("New item (⌘N)").accessibilityLabel("New item")
        .background { Button("") { newForCurrentFilter() }.keyboardShortcut("n", modifiers: .command).hidden() }
    }

    private func newForCurrentFilter() {
        switch filter {
        case .cards: sheet = .card(nil)
        case .identities: sheet = .identity(nil)
        case .notes: sheet = .note(nil)
        default: adding = true
        }
    }

    private func toolButton(_ icon: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(active ? DB.brass : DB.text2)
                .frame(width: 30, height: 30).background(active ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    /// Settings opens inside this window, on the given tab (or the last one used).
    private func openSettingsTab(_ tab: String?) {
        if let tab { AppConfig.defaults.set(tab, forKey: "macSettingsTab") }
        session.settingsOpen = true
    }

    // MARK: list

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title(filter)).font(.db(13, .semibold))
                Text("\(filter == .websites ? groups.count : rows.count)").font(.dbMono(11.5)).foregroundStyle(DB.text3)
                Spacer()
                if filter == .codes {
                    Button { addingCode = true } label: { Label("Add Code", systemImage: "plus") }
                        .buttonStyle(MacButtonStyle()).help("Add a one-time code")
                } else if filter == .cards || filter == .identities || filter == .notes {
                    Button { newForCurrentFilter() } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(MacButtonStyle()).help("New \(title(filter).lowercased().dropLast())")
                }
            }
            .padding(.horizontal, 14).frame(height: 40)

            ScrollView {
                if filter == .codes {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        LazyVStack(spacing: 1) { ForEach(items) { l in codeRow(l, ctx.date) } }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 8)
                } else if filter == .websites {
                    LazyVStack(spacing: 1) { ForEach(groups) { g in siteRow(g) } }
                        .padding(.horizontal, 6).padding(.bottom, 8)
                } else {
                    // All / Passkeys / Cards / Identities / Notes: every item on its own row; the icons say what is saved.
                    LazyVStack(spacing: 1) { ForEach(rows) { r in rowView(r) } }
                        .padding(.horizontal, 6).padding(.bottom, 8)
                }
            }
            .overlay {
                if filter == .websites ? groups.isEmpty : rows.isEmpty {
                    Text(query.isEmpty ? "Nothing here yet" : "Nothing matches “\(query)”").font(.db(12)).foregroundStyle(DB.text3)
                }
            }
        }
        .background(DB.ground)
    }

    /// Websites filter: one row per site with everything saved there; the detail pane lists it all.
    private func siteRow(_ g: MacSiteGroup) -> some View {
        let on = siteSelection == g.id
        return HStack(spacing: 10) {
            SiteTile(title: g.title, site: g.site, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.title).font(.db(13, .semibold)).lineLimit(1)
                Text(g.logins.count == 1 ? (g.site ?? g.logins[0].username) : "\(g.logins.count) accounts · \(g.site ?? "")")
                    .font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if g.logins.contains(where: { !$0.password.isEmpty }) { Image(systemName: "ellipsis.rectangle").foregroundStyle(DB.text2) }
                if g.logins.contains(where: { !$0.passkeyIDs.isEmpty }) { Image(systemName: "person.badge.key").foregroundStyle(DB.brass) }
                if g.logins.contains(where: { $0.totpSecret != nil }) { Image(systemName: "clock").foregroundStyle(DB.text2) }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(on ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color(hex: 0x3A3220) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { siteSelection = g.id }
        .accessibilityElement(children: .combine)
    }

    /// Codes filter: a list of codes with a timing ring; click to copy.
    private func codeRow(_ l: LoginItem, _ date: Date) -> some View {
        let on = selection == l.id
        return HStack(spacing: 10) {
            SiteTile(title: l.title, site: l.sites.first, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.title).font(.db(13, .semibold)).lineLimit(1)
                Text(l.username).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let s = l.totpSecret, let t = try? TOTP(s) {
                let left = t.secondsRemaining(at: date)
                Text(TOTP.grouped(t.code(at: date))).font(.dbMono(14)).tracking(0.8)
                    .foregroundStyle(left <= 5 ? DB.danger : DB.brass)
                if copiedID == l.id {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(DB.good)
                        .transition(.scale.combined(with: .opacity)).accessibilityLabel("Copied")
                } else {
                    CodeRing(left: left, period: t.period, size: 24)
                }
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(on ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color(hex: 0x3A3220) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = l.id
            if let s = l.totpSecret, let t = try? TOTP(s) {
                Clipboard.copySecret(t.code())
                withAnimation(.snappy(duration: 0.2)) { copiedID = l.id }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if copiedID == l.id { withAnimation(.snappy(duration: 0.2)) { copiedID = nil } }
                }
            }
        }
        .help("Click to copy the code")
        .contextMenu { LoginContextMenu(login: l, edit: { session.editTarget = .init(id: l.id) }, delete: { deleting = l }) }
    }

    private func row(_ l: LoginItem) -> some View {
        let on = selection == l.id
        return HStack(spacing: 10) {
            SiteTile(title: l.title, site: l.sites.first, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.title).font(.db(13, .semibold)).lineLimit(1)
                Text(l.username.isEmpty ? "Code only" : l.username).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovered == l.id {
                CopyButtons(login: l, size: 22)
            } else {
                AuthBadges(login: l)
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(on ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color(hex: 0x3A3220) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = l.id }
        .onHover { hovered = $0 ? l.id : (hovered == l.id ? nil : hovered) }
        .contextMenu { LoginContextMenu(login: l, edit: { session.editTarget = .init(id: l.id) }, delete: { deleting = l }) }
    }

    // MARK: cards, identities, notes

    private enum Row: Identifiable {
        case login(LoginItem), card(CardItem), identity(IdentityItem), note(NoteItem)
        var id: UUID {
            switch self { case .login(let x): x.id; case .card(let x): x.id; case .identity(let x): x.id; case .note(let x): x.id }
        }
        var title: String {
            switch self { case .login(let x): x.title; case .card(let x): x.title; case .identity(let x): x.title; case .note(let x): x.title }
        }
    }

    /// Everything the list shows for the current filter. Logins keep their own filters; the new kinds show in All and their own tab.
    private var rows: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func ok(_ text: String) -> Bool { q.isEmpty || text.contains(q) }
        let loginFilters: [Filter] = [.all, .websites, .passkeys, .codes]
        let logins: [Row] = loginFilters.contains(filter) ? items.map(Row.login) : []
        let cards: [Row] = filter == .all || filter == .cards ? session.vault.cards.filter { ok($0.searchText) }.map(Row.card) : []
        let identities: [Row] = filter == .all || filter == .identities ? session.vault.identities.filter { ok($0.searchText) }.map(Row.identity) : []
        let notes: [Row] = filter == .all || filter == .notes ? session.vault.notes.filter { ok($0.searchText) }.map(Row.note) : []
        return (logins + cards + identities + notes).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @ViewBuilder private func rowView(_ r: Row) -> some View {
        switch r {
        case .login(let l): row(l)
        case .card(let c):
            typedRow(id: c.id, symbol: ItemKind.card.symbol, title: c.title,
                     subtitle: [c.maskedSummary, c.expiry].compactMap { $0 }.joined(separator: " · "), expired: c.isExpired()) {
                CardMenu(card: c, edit: { edit(.card, c.id) }, delete: { deletingItem = .init(kind: .card, id: c.id, title: c.title) })
            }
        case .identity(let i):
            typedRow(id: i.id, symbol: ItemKind.identity.symbol, title: i.title.isEmpty ? i.fullName : i.title,
                     subtitle: [i.fullName, i.email].first { !$0.isEmpty && $0 != i.title } ?? "Identity") {
                IdentityMenu(identity: i, edit: { edit(.identity, i.id) }, delete: { deletingItem = .init(kind: .identity, id: i.id, title: i.title.isEmpty ? i.fullName : i.title) })
            }
        case .note(let n):
            typedRow(id: n.id, symbol: ItemKind.note.symbol, title: n.title, subtitle: n.label.flatMap { $0.isEmpty ? nil : $0 } ?? "Secure note") {
                NoteMenu(note: n, edit: { edit(.note, n.id) }, delete: { deletingItem = .init(kind: .note, id: n.id, title: n.title) })
            }
        }
    }

    private func typedRow<M: View>(id: UUID, symbol: String, title: String, subtitle: String, expired: Bool = false,
                                   @ViewBuilder menu: () -> M) -> some View {
        let on = selection == id
        return HStack(spacing: 10) {
            TypeTile(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.db(13, .semibold)).lineLimit(1)
                Text(subtitle).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if expired { Text("Expired").font(.db(11, .medium)).foregroundStyle(DB.danger) }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(on ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color(hex: 0x3A3220) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { selection = id }
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
    }

    /// The menu-bar panel asked for an editor to be opened here.
    private func takePendingSheet() {
        guard let s = session.pendingItemSheet else { return }
        session.pendingItemSheet = nil
        sheet = s
    }

    /// Opening an existing card, identity or note to edit shows its secrets, so it asks for Touch ID first.
    private func edit(_ kind: ItemKind, _ id: UUID) {
        Task {
            guard await session.confirmOwner("Edit this \(kind.noun)") else { return }
            switch kind {
            case .card: sheet = .card(id)
            case .identity: sheet = .identity(id)
            case .note: sheet = .note(id)
            }
        }
    }

    @ViewBuilder private func sheetView(_ s: ItemSheet) -> some View {
        switch s {
        case .card(let id): MacCardSheet(original: id.flatMap { session.vault.card($0) })
        case .identity(let id): MacIdentitySheet(original: id.flatMap { session.vault.identity($0) })
        case .note(let id): MacNoteSheet(original: id.flatMap { session.vault.note($0) })
        }
    }

    private func deleteItem(_ d: PendingDelete) {
        try? session.mutate { v in
            switch d.kind {
            case .card: v.deleteCard(d.id)
            case .identity: v.deleteIdentity(d.id)
            case .note: v.deleteNote(d.id)
            }
        }
        session.show("\(d.kind.noun.prefix(1).uppercased() + d.kind.noun.dropFirst()) deleted")
        if selection == d.id { selection = nil }
    }

    private var groups: [MacSiteGroup] {
        let bySite = Dictionary(grouping: items.filter { !$0.sites.isEmpty }) { $0.sites[0] }
        return bySite.map { site, logins in
            MacSiteGroup(id: site, site: logins[0].sites.first, title: logins[0].title,
                         logins: logins.sorted { a, b in a.preferred != b.preferred ? a.preferred : a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var items: [LoginItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return session.vault.logins
            .filter { l in
                switch filter {
                case .all, .websites, .cards, .identities, .notes: true
                case .passkeys: !l.passkeyIDs.isEmpty
                case .codes: l.totpSecret != nil
                }
            }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q) || $0.sites.contains { $0.contains(q) } }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if filter == .websites {
            if let sid = siteSelection, let g = groups.first(where: { $0.id == sid }) {
                MacSiteDetail(group: g, delete: { deleting = $0 }).id(sid)
            } else {
                VStack(spacing: 10) {
                    DeadboltGlyph(height: 36).opacity(0.3)
                    Text("Select a website").font(.db(13)).foregroundStyle(DB.text3)
                }
            }
        } else if let id = selection, let login = session.vault.login(id) {
            MacLoginDetail(login: login, delete: { deleting = login }).id(id)
        } else if let id = selection, let c = session.vault.card(id) {
            MacCardDetail(card: c, edit: { edit(.card, c.id) }, delete: { deletingItem = .init(kind: .card, id: c.id, title: c.title) },
                          openIdentity: { filter = .all; selection = $0 }).id(id)
        } else if let id = selection, let i = session.vault.identity(id) {
            MacIdentityDetail(identity: i, edit: { edit(.identity, i.id) },
                              delete: { deletingItem = .init(kind: .identity, id: i.id, title: i.title.isEmpty ? i.fullName : i.title) }).id(id)
        } else if let id = selection, let n = session.vault.note(id) {
            MacNoteDetail(note: n, edit: { edit(.note, n.id) }, delete: { deletingItem = .init(kind: .note, id: n.id, title: n.title) }).id(id)
        } else {
            VStack(spacing: 10) {
                DeadboltGlyph(height: 36).opacity(0.3)
                Text("Select an item").font(.db(13)).foregroundStyle(DB.text3)
            }
        }
    }
}

// MARK: - detail

struct MacLoginDetail: View {
    @Environment(VaultSession.self) private var session
    let login: LoginItem
    let delete: () -> Void
    @State private var revealed = false
    @State private var showHistory = false
    @State private var addingCode = false
    @State private var shownFields: Set<UUID> = []
    /// Inside the website detail: no header, websites or history (the site view shows those once).
    var compact = false

    private var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                if !compact { HStack(spacing: 14) {
                    SiteTile(title: login.title, site: login.sites.first, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(login.title).font(.db(18, .semibold))
                        Text("\(login.sites.first ?? "No website") · edited \(login.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.db(12)).foregroundStyle(DB.text2)
                    }
                    Spacer()
                    Button("Edit") { session.editTarget = .init(id: login.id) }
                        .buttonStyle(MacButtonStyle()).keyboardShortcut("e", modifiers: .command)
                    Menu {
                        LoginContextMenu(login: login, edit: { session.editTarget = .init(id: login.id) }, delete: delete)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DB.lineStrong))
                        .accessibilityLabel("More actions")
                } }

                group {
                    if !login.username.isEmpty {
                        field("Username") {
                            Text(login.username).textSelection(.enabled)
                            Spacer()
                            icon("doc.on.doc", "Copy username") { copy(login.username, "Username copied") }
                        }
                    }
                    if !login.password.isEmpty {
                        divider
                        field("Password") {
                            Text(revealed ? login.password : String(repeating: "•", count: 16))
                                .font(.dbMono(13)).textSelection(.enabled).lineLimit(1)
                            Spacer()
                            icon(revealed ? "eye.slash" : "eye", revealed ? "Hide password" : "Show password") { revealed.toggle() }
                            icon("key.horizontal", "Copy password", prominent: true) {
                                copy(login.password, "Password copied")
                                try? session.mutate { $0.markUsed(login.id) }
                            }
                        }
                    }
                    if let secret = login.totpSecret, let totp = try? TOTP(secret) {
                        divider
                        field("One-time code") {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let left = totp.secondsRemaining(at: ctx.date)
                                HStack(spacing: 8) {
                                    ZStack {
                                        Circle().stroke(DB.line, lineWidth: 2.5)
                                        Circle().trim(from: 0, to: CGFloat(left) / CGFloat(totp.period))
                                            .stroke(left <= 5 ? DB.danger : DB.brass, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                    }
                                    .frame(width: 15, height: 15)
                                    Text(TOTP.grouped(totp.code(at: ctx.date))).font(.dbMono(14)).tracking(0.8)
                                    Text("\(left) s").font(.db(12)).foregroundStyle(DB.text3)
                                }
                            }
                            Spacer()
                            icon("doc.on.doc", "Copy one-time code") { copy(totp.code(), "Code copied") }
                        }
                    }
                    if login.totpSecret == nil {
                        divider
                        field("One-time code") {
                            Button { addingCode = true } label: { Label("Set Up…", systemImage: "qrcode.viewfinder") }.buttonStyle(MacButtonStyle())
                            Text("For sites that ask for a 6-digit code").font(.db(12)).foregroundStyle(DB.text3)
                            Spacer()
                        }
                    }
                    if !login.passkeyIDs.isEmpty {
                        divider
                        field("Passkey") {
                            Text("Saved in Deadbolt")
                            Spacer()
                            Text("Synced to your devices").font(.db(12)).foregroundStyle(DB.good)
                        }
                    }
                }

                if let fields = login.customFields, !fields.isEmpty {
                    group {
                        ForEach(Array(fields.enumerated()), id: \.element.id) { i, f in
                            if i > 0 { divider }
                            let masked = f.hidden && !shownFields.contains(f.id)
                            field(f.name) {
                                Text(masked ? String(repeating: "•", count: max(6, min(f.value.count, 14))) : f.value)
                                    .font(f.hidden ? .dbMono(13) : .db(13)).textSelection(.enabled).lineLimit(2)
                                Spacer()
                                if f.hidden {
                                    icon(masked ? "eye" : "eye.slash", masked ? "Show \(f.name)" : "Hide \(f.name)") {
                                        if masked { shownFields.insert(f.id) } else { shownFields.remove(f.id) }
                                    }
                                }
                                icon("doc.on.doc", "Copy \(f.name)") { copy(f.value, "") }
                            }
                        }
                    }
                }

                if !compact { group {
                    field("Websites") {
                        Text(login.sites.isEmpty ? "None — kept only in your code list" : login.sites.joined(separator: ", ")).lineLimit(3)
                            .foregroundStyle(login.sites.isEmpty ? DB.text2 : DB.text)
                        Spacer()
                    }
                    if let label = login.label, !label.isEmpty { divider; field("Label") { Text(label); Spacer() } }
                    if !login.isCodeOnly { divider }
                    if !login.isCodeOnly { field("History") {
                        Text(login.history.isEmpty ? "No older passwords" : "\(login.history.count) older password\(login.history.count == 1 ? "" : "s")")
                            .foregroundStyle(DB.text2)
                        Spacer()
                        if !login.history.isEmpty {
                            Button(showHistory ? "Hide" : "Show") { showHistory.toggle() }.buttonStyle(.plain).foregroundStyle(DB.brass).font(.db(12))
                        }
                    } }
                    if showHistory && !login.isCodeOnly {
                        ForEach(Array(login.history.enumerated()), id: \.offset) { _, entry in
                            divider
                            field("") {
                                Text(entry.password).font(.dbMono(12.5)).textSelection(.enabled).lineLimit(1)
                                Spacer()
                                Text(entry.replacedAt.formatted(date: .abbreviated, time: .omitted)).font(.db(12)).foregroundStyle(DB.text3)
                                Button("Restore") {
                                    try? session.mutate { v in
                                        guard var item = v.login(login.id) else { return }
                                        item.restore(entry); v.upsert(item)
                                    }
                                    session.show("Password restored")
                                }
                                .buttonStyle(.plain).foregroundStyle(DB.brass).font(.db(12))
                            }
                        }
                    }
                } }

                if let notes = login.notes, !notes.isEmpty {
                    group {
                        Text(notes).foregroundStyle(DB.text2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }
            }
            .padding(.horizontal, compact ? 0 : 28).padding(.vertical, compact ? 0 : 22)
            .frame(maxWidth: compact ? .infinity : 720, alignment: .leading)
    }

    var body: some View {
        Group { if compact { content } else { ScrollView { content } } }
        .sheet(isPresented: $addingCode) {
            OneTimeCodeSetupView(site: login.sites.first) { raw, _ in
                try? session.mutate { v in
                    guard var item = v.login(login.id) else { return }
                    item.totpSecret = raw; v.upsert(item)
                }
                session.show("One-time code added")
            }
        }
    }

    private var divider: some View { Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1) }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DB.line))
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.db(12)).foregroundStyle(DB.text3).frame(width: 110, alignment: .leading)
            content()
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(minHeight: 40)
    }

    /// Copy icons ("doc.on.doc", "key.horizontal") turn into a checkmark when used; others (show/hide) are plain buttons.
    private func icon(_ name: String, _ label: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let copies = label.hasPrefix("Copy")
        func face(_ done: Bool) -> some View {
            Image.tick(name, done: done).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(done ? DB.good : (prominent ? DB.brass : DB.text2))
                .frame(width: 26, height: 26)
                .background(done ? DB.goodWash : (prominent ? DB.brassWash : .clear), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        return Group {
            if copies { TickButton(action: action) { face($0) } } else { Button(action: action) { face(false) } }
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func copy(_ text: String, _ title: String) {
        Clipboard.copySecret(text)   // the icon shows a checkmark
    }
}

// MARK: - status bar

struct MacStatusBar: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(syncText(ctx.date))
                }
                Text("\(activeDevices) device\(activeDevices == 1 ? "" : "s")")
                Spacer()
                Text(lockText(ctx.date))
            }
            .font(.db(11.5)).foregroundStyle(DB.text3)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Color(hex: 0x0F1014))
        }
    }

    private var activeDevices: Int { max(1, (session.vault.devices ?? []).filter { $0.revoked == nil }.count) }

    private var dot: Color {
        switch session.sync.status {
        case .upToDate: DB.good
        case .syncing: DB.brass
        case .offline: DB.danger
        case .off: DB.text3
        }
    }

    private func syncText(_ now: Date) -> String {
        switch session.sync.status {
        case .upToDate(let at): "Synced \(at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
        case .syncing: "Syncing…"
        case .offline(let why): why
        case .off: "Sync off"
        }
    }

    private func lockText(_ now: Date) -> String {
        let left = max(Prefs.lockAfter, LockPolicy.macMinimum) - now.timeIntervalSince(session.lastActivity)
        return left > 60 ? "Locks in \(Int(left / 60)) min" : "Locks in under a minute"
    }
}

// MARK: - edit sheet

struct MacEditSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: LoginFormModel
    @State private var revealed: Bool
    @State private var showMore: Bool
    @State private var addingCode = false
    @State private var confirmDelete = false
    @FocusState private var focus: Field?
    private enum Field { case site, user, password }

    init(original: LoginItem?, site: String = "") {
        let m = LoginFormModel(original: original, site: site)
        _form = State(initialValue: m)
        _revealed = State(initialValue: original == nil)
        _showMore = State(initialValue: m.hasMore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SiteTile(title: form.original?.title ?? (form.primarySite ?? "?"), site: form.primarySite, size: 28)
                Text(form.original.map { "Edit \($0.title)" } ?? "New Login").font(.db(15, .semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                row("Website") {
                    TextField("github.com", text: $form.site).macField().focused($focus, equals: .site)
                    if let h = form.siteHint { note(h.text, color: h.ok ? DB.text3 : DB.danger) }
                }
                row("Username") { TextField("Email or username", text: $form.username).macField().focused($focus, equals: .user) }
                row("Password") {
                    HStack(spacing: 6) {
                        Group {
                            if revealed { TextField("Password", text: $form.password) } else { SecureField("Password", text: $form.password) }
                        }
                        .font(.dbMono(12.5)).macField().focused($focus, equals: .password)
                        Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye").frame(width: 14) }
                            .buttonStyle(MacButtonStyle()).help(revealed ? "Hide password" : "Show password")
                        Button { form.password = session.newPassword(); revealed = true } label: { Label("Generate", systemImage: "wand.and.stars") }
                            .buttonStyle(MacButtonStyle())
                    }
                    if let s = PasswordStrength.describe(form.password) {
                        HStack(spacing: 8) {
                            HStack(spacing: 3) {
                                ForEach(0..<3) { i in Capsule().fill(i <= s.level ? PasswordStrength.color(s.level) : DB.line).frame(width: 20, height: 3) }
                            }
                            note(form.passwordChanged ? "\(s.text) · the current password moves to history when you save" : s.text)
                        }
                    }
                }
                row("One-time code") {
                    if let code = form.code {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(DB.good)
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text("\(TOTP.grouped(code.code(at: ctx.date)))  ·  \(code.secondsRemaining(at: ctx.date)) s").font(.dbMono(12.5))
                            }
                            Spacer()
                            Button("Replace…") { addingCode = true }.buttonStyle(MacButtonStyle())
                            Button("Remove") { form.totp = "" }.buttonStyle(MacButtonStyle())
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button { addingCode = true } label: { Label("Set Up…", systemImage: "qrcode.viewfinder") }.buttonStyle(MacButtonStyle())
                            note("For sites that ask for a 6-digit code")
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Button { withAnimation(.snappy) { showMore.toggle() } } label: {
                        Label("More options", systemImage: showMore ? "chevron.down" : "chevron.right").font(.db(12))
                    }
                    .buttonStyle(.plain).foregroundStyle(DB.text3)
                }
                if showMore {
                    row("Other websites") { MacExtraWebsites(form: form) }
                    row("Custom fields") { MacCustomFields(form: form) }
                    row("Label") { TextField("Personal, Work…", text: $form.label).macField() }
                    row("Notes") { TextField("", text: $form.notes, axis: .vertical).lineLimit(3...5).macField() }
                }
            }
            if let error = form.error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
            HStack(spacing: 8) {
                if form.original != nil {
                    Button("Delete Login…") { confirmDelete = true }.buttonStyle(.plain).foregroundStyle(DB.danger).font(.db(12.5))
                }
                Spacer()
                if let m = form.missing { Text(m).font(.db(12)).foregroundStyle(DB.text3) }
                Button("Cancel") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(form.missing != nil).opacity(form.missing != nil ? 0.5 : 1)
            }
        }
        .padding(20)
        .frame(width: 500)
        .font(.db(13))
        .background(DB.surface)
        .foregroundStyle(DB.text)
        .preferredColorScheme(.dark)
        .onAppear { if form.isNew && form.site.isEmpty { focus = .site } }
        .sheet(isPresented: $addingCode) {
            OneTimeCodeSetupView(site: form.primarySite) { raw, t in form.useCode(raw, t) }
        }
        .confirmationDialog("Delete \(form.original?.username ?? "") on \(form.original?.title ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let o = form.original { try? session.mutate { $0.delete(o.id) }; session.show("Login deleted") }
                dismiss()
            }
        } message: { Text("Its password, history and any passkey links are removed from all your devices.") }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).font(.db(12)).foregroundStyle(DB.text3).frame(width: 100, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
    }

    private func note(_ text: String, color: Color = DB.text3) -> some View {
        Text(text).font(.db(11.5)).foregroundStyle(color)
    }

    private func save() {
        do {
            let (title, detail) = try form.save(in: session)
            session.show(title, detail)
            dismiss()
        } catch { form.error = error.friendly }
    }
}

// MARK: - generator popover

struct MacGeneratorPopover: View {
    @Environment(VaultSession.self) private var session
    @State private var model = GeneratorModel()

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $m.settings.passphrase) { Text("Password").tag(false); Text("Passphrase").tag(true) }
                .pickerStyle(.segmented).labelsHidden()
            Text(m.value).font(.dbMono(14)).textSelection(.enabled).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 10).background(Color(hex: 0x0F1014), in: RoundedRectangle(cornerRadius: 8))
            if m.settings.passphrase {
                HStack {
                    Text("\(m.settings.words) words").font(.db(12)).foregroundStyle(DB.text2).frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { Double(m.settings.words) }, set: { m.settings.words = Int($0) }), in: 4...8, step: 1).tint(DB.brass)
                }
            } else {
                HStack {
                    Text("Length \(m.settings.options.length)").font(.db(12)).foregroundStyle(DB.text2).frame(width: 70, alignment: .leading)
                    Slider(value: Binding(get: { Double(m.settings.options.length) }, set: { m.settings.options.length = Int($0) }), in: 8...64, step: 1).tint(DB.brass)
                }
                HStack(spacing: 14) {
                    kind("A–Z", $m.settings.options.upper)
                    kind("a–z", $m.settings.options.lower)
                    kind("0–9", $m.settings.options.digits)
                    kind("!@#$", $m.settings.options.symbols)
                }
                HStack {
                    Stepper("Min. numbers  \(m.settings.options.minDigits)", value: $m.settings.options.minDigits, in: 1...10)
                        .disabled(!m.settings.options.digits)
                    Stepper("Min. symbols  \(m.settings.options.minSymbols)", value: $m.settings.options.minSymbols, in: 1...10)
                        .disabled(!m.settings.options.symbols)
                }
                .font(.db(12)).foregroundStyle(DB.text2)
                Toggle("Avoid look-alike characters (0 O 1 l I)", isOn: $m.settings.options.avoidAmbiguous).toggleStyle(.checkbox).font(.db(12))
            }
            HStack {
                Button { m.regenerate() } label: { Label("New", systemImage: "arrow.clockwise") }.buttonStyle(MacButtonStyle())
                Spacer()
                TickButton(action: { Clipboard.copySecret(m.value) }) { done in
                    Label(done ? "Copied" : "Copy", systemImage: done ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(MacButtonStyle(prominent: true))
            }
            Text("Synced to your other devices and used by every Generate button.").font(.db(11)).foregroundStyle(DB.text3)
        }
        .padding(14).frame(width: 360)
        .font(.db(13))
        .onAppear { model.load(session) }
        .onChange(of: model.settings) { model.changed(session) }
    }

    private func kind(_ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(title, isOn: on).toggleStyle(.checkbox).font(.db(12)).disabled(model.isLastKind(on.wrappedValue))
    }
}

// MARK: - shared Mac controls

struct MacButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.db(12.5, prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? DB.onBrass : DB.text)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? DB.brass.opacity(configuration.isPressed ? 0.8 : 1) : Color(hex: 0x1A1C22).opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(prominent ? .clear : DB.lineStrong))
    }
}

extension View {
    /// Compact Mac text field: 28 px, hairline border, dark well.
    func macField() -> some View {
        self.textFieldStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 5).frame(minHeight: 28)
            .background(Color(hex: 0x0F1014), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DB.lineStrong))
    }
}

/// Websites filter, detail pane: every account on the site with its password, code and passkey on one screen.
struct MacSiteDetail: View {
    @Environment(VaultSession.self) private var session
    let group: MacSiteGroup
    let delete: (LoginItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    SiteTile(title: group.title, site: group.site, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title).font(.db(18, .semibold))
                        Text("\(group.site ?? "") · \(group.logins.count) account\(group.logins.count == 1 ? "" : "s")")
                            .font(.db(12)).foregroundStyle(DB.text2)
                    }
                    Spacer()
                }
                ForEach(session.vault.accounts(for: group.site ?? "").filter { a in group.logins.contains { $0.id == a.id } }) { a in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(a.username.isEmpty ? a.title : a.username).font(.db(13, .semibold))
                            if let l = a.label, !l.isEmpty {
                                Text(l).font(.db(11)).foregroundStyle(DB.text2).padding(.horizontal, 7).frame(height: 18)
                                    .background(DB.control, in: Capsule())
                            }
                            if a.preferred { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(DB.brass).help("Suggested first") }
                            Spacer()
                            Button("Edit") { session.editTarget = .init(id: a.id) }.buttonStyle(MacButtonStyle())
                            Menu {
                                LoginContextMenu(login: a, edit: { session.editTarget = .init(id: a.id) }, delete: { delete(a) })
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 26)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DB.lineStrong))
                        }
                        MacLoginDetail(login: a, delete: { delete(a) }, compact: true)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// Several accounts on one site, for the Websites filter.
struct MacSiteGroup: Identifiable {
    let id: String
    let site: String?
    let title: String
    let logins: [LoginItem]
}

/// Lets the window's content run under the title bar (hidden, transparent) so the sidebar can carry the traffic lights.
private struct WindowChrome: NSViewRepresentable {
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
        }
    }
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ view: ChromeView, context: Context) {}
}

/// A column edge you can drag. One hairline, a wider invisible grab area, the resize cursor, double-click to reset.
private struct ColumnDivider: View {
    @Binding var width: Double
    /// The width actually shown (the stored one, held inside what the window leaves room for).
    let current: Double
    let range: ClosedRange<Double>
    let reset: Double
    @State private var start: Double?

    var body: some View {
        // The grab area is the view's own frame (9 pt), pulled back to 1 pt of layout by negative padding, and drawn above both columns.
        ZStack {
            Color.clear.contentShape(Rectangle())
            Rectangle().fill(Color(hex: 0x1C1F26)).frame(width: 1)
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .padding(.horizontal, -4)
        .pointerStyle(.columnResize)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    if start == nil { start = current }
                    width = min(max((start ?? current) + drag.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { width = reset }
        .zIndex(1)
        .accessibilityHidden(true)
    }
}
#endif
