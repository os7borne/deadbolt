import DeadboltCore
import SwiftUI

/// One row in the vault list: a single login, or a site with several accounts.
struct SiteGroup: Identifiable, Hashable, Listable {
    let site: String
    let title: String
    let logins: [LoginItem]
    var id: String { site }
    var sortName: String { title }
    var sortTiebreak: String { "" }
    var sortTypeRank: Int { 0 }
    var sortID: String { site }
    var createdAt: Date { logins.map(\.createdAt).min() ?? .distantPast }
    var updatedAt: Date { logins.map(\.updatedAt).max() ?? .distantPast }
    var lastUsedAt: Date? { logins.compactMap(\.lastUsedAt).max() }
    var hasPasskey: Bool { logins.contains { !$0.passkeyIDs.isEmpty } }

    static func == (a: SiteGroup, b: SiteGroup) -> Bool { a.site == b.site && a.logins.map(\.id) == b.logins.map(\.id) }
    func hash(into h: inout Hasher) { h.combine(site); h.combine(logins.map(\.id)) }
}

enum VaultFilter: String, CaseIterable { case all = "All", websites = "Websites", passkeys = "Passkeys", cards = "Cards", identities = "Identities", notes = "Notes" }

struct VaultListView: View {
    @Environment(VaultSession.self) private var session
    /// How the lists are ordered. Per device: it lives in this iPhone's settings and is not synced.
    @AppStorage("listSort", store: AppConfig.defaults) private var sortRaw = ListSort.default.rawValue
    private var sort: ListSort { ListSort(stored: sortRaw) }
    @State private var query = ""
    @State private var filter = VaultFilter.all
    @State private var editing: LoginItem?
    @State private var deleting: LoginItem?
    @State private var adding = false
    @State private var itemSheet: ItemSheet?
    @State private var deletingItem: PendingDelete?

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(VaultFilter.allCases, id: \.self) { f in
                            Button { filter = f } label: {
                                Text(f == .all ? f.rawValue : "\(f.rawValue) \(count(f))")
                                    .font(.db(13, filter == f ? .semibold : .regular)).lineLimit(1).fixedSize()
                                    .foregroundStyle(filter == f ? DB.ground : Color(hex: 0xC9CCD2))
                                    .padding(.horizontal, 12).frame(height: 30)
                                    .background(filter == f ? DB.text : .clear, in: Capsule())
                                    .overlay(Capsule().stroke(filter == f ? .clear : DB.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }

            if vaultItemCount == 0 {
                EmptyVault(add: { adding = true })
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if (filter == .websites ? groups.isEmpty : entries.isEmpty) {
                Text(query.isEmpty ? "Nothing here yet" : "Nothing matches “\(query)”").font(.db(15)).foregroundStyle(DB.text2)
                    .listRowBackground(Color.clear)
            }

            if filter == .websites {
                // One row per website, with everything saved there combined (opens one screen listing it all).
                ForEach(groups) { g in
                    NavigationLink(value: g) { GroupRow(group: g) }
                        .listRowBackground(DB.ground)
                        .listRowSeparatorTint(DB.line)
                }
            } else {
                // One row per item, never combined; the icons say what is saved.
                ForEach(entries) { e in entryRow(e) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DB.ground)
        .searchable(text: $query, prompt: "Search \(vaultItemCount) items")
        .navigationTitle("Vault")
        .navigationDestination(for: SiteGroup.self) { g in
            WebsiteView(group: g)
        }
        .navigationDestination(for: UUID.self) { LoginDetailView(id: $0) }
        .navigationDestination(for: ItemRef.self) { ItemDestination(ref: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 16) {
                    Menu {
                        Picker("Sort by", selection: $sortRaw) {
                            ForEach(ListSort.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("Sort by")
                    NavigationLink { GeneratorView() } label: { Image(systemName: "wand.and.stars") }.accessibilityLabel("Password generator")
                    Menu {
                        Button { adding = true } label: { Label("Login", systemImage: "key.horizontal") }
                        Button { itemSheet = .card(nil) } label: { Label("Card", systemImage: ItemKind.card.symbol) }
                        Button { itemSheet = .identity(nil) } label: { Label("Identity", systemImage: ItemKind.identity.symbol) }
                        Button { itemSheet = .note(nil) } label: { Label("Secure note", systemImage: ItemKind.note.symbol) }
                    } label: { Image(systemName: "plus") }.accessibilityLabel("Add item")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button { session.lock() } label: { Image(systemName: "lock") }.accessibilityLabel("Lock now")
            }
        }
        .sheet(isPresented: $adding) { EditLoginView(original: nil) }
        .sheet(item: $editing) { EditLoginView(original: $0) }
        .sheet(item: $itemSheet) { ItemEditor(sheet: $0) }
        .alert(deletingItem.map { "Delete \($0.title)?" } ?? "", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
            Button("Delete", role: .destructive) { if let d = deletingItem { deleteItem(d) }; deletingItem = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It is removed from all your devices.") }
        .confirmationDialog(deleting.map { "Delete \($0.username) on \($0.title)?" } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { try? session.mutate { $0.delete(d.id) }; session.show("Login deleted") }
                deleting = nil
            }
        } message: { Text("Its password, history and any passkey links are removed from all your devices.") }
    }

    private func matches(_ l: LoginItem) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || l.title.lowercased().contains(q) || l.username.lowercased().contains(q) || l.sites.contains { $0.contains(q) }
    }

    /// All / Passkeys: every login on its own row.
    private var flat: [LoginItem] {
        guard filter == .all || filter == .passkeys else { return [] }
        return vaultLogins.filter { (filter != .passkeys || !$0.passkeyIDs.isEmpty) && matches($0) }
            .sorted { a, b in
                let c = a.title.localizedCaseInsensitiveCompare(b.title)
                return c == .orderedSame ? a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending : c == .orderedAscending
            }
    }

    /// Websites: one group per site, including standalone codes saved for that site.
    private var groups: [SiteGroup] {
        let logins = session.vault.logins.filter { !($0.sites.isEmpty) && matches($0) }
        let bySite = Dictionary(grouping: logins) { $0.sites[0] }
        return bySite.map { site, items in
            SiteGroup(site: site, title: items[0].title, logins: session.vault.accounts(for: site).filter { a in items.contains { $0.id == a.id } })
        }
        .sorted(by: sort.areInIncreasingOrder)
    }

    /// Logins and passkeys only: standalone one-time codes live in the Codes tab.
    private var vaultLogins: [LoginItem] { session.vault.logins.filter { !$0.isCodeOnly } }

    // MARK: cards, identities, notes

    private enum Entry: Identifiable, Listable {
        case login(LoginItem), card(CardItem), identity(IdentityItem), note(NoteItem)
        var id: UUID {
            switch self { case .login(let x): x.id; case .card(let x): x.id; case .identity(let x): x.id; case .note(let x): x.id }
        }
        private var item: any Listable {
            switch self { case .login(let x): x; case .card(let x): x; case .identity(let x): x; case .note(let x): x }
        }
        var sortName: String { item.sortName }
        var sortTiebreak: String { item.sortTiebreak }
        var sortTypeRank: Int { item.sortTypeRank }
        var sortID: String { item.sortID }
        var createdAt: Date { item.createdAt }
        var updatedAt: Date { item.updatedAt }
        var lastUsedAt: Date? { item.lastUsedAt }
        var title: String {
            switch self { case .login(let x): x.title; case .card(let x): x.title; case .identity(let x): x.shownTitle; case .note(let x): x.title }
        }
        var rank: Int { switch self { case .login: 0; case .card: 1; case .identity: 2; case .note: 3 } }
    }

    /// What the list shows: logins (All, Passkeys) plus cards, identities and notes (All and their own filters), by title.
    private var entries: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func ok(_ text: String) -> Bool { q.isEmpty || text.contains(q) }
        var out = flat.map(Entry.login)
        if filter == .all || filter == .cards { out += session.vault.cards.filter { ok($0.searchText) }.map(Entry.card) }
        if filter == .all || filter == .identities { out += session.vault.identities.filter { ok($0.searchText) }.map(Entry.identity) }
        if filter == .all || filter == .notes { out += session.vault.notes.filter { ok($0.searchText) }.map(Entry.note) }
        return sort.sorted(out)
    }

    private var vaultItemCount: Int { vaultLogins.count + session.vault.cards.count + session.vault.identities.count + session.vault.notes.count }

    @ViewBuilder private func entryRow(_ e: Entry) -> some View {
        switch e {
        case .login(let l):
            NavigationLink(value: l.id) { LoginRow(login: l) }
                .listRowBackground(DB.ground)
                .listRowSeparatorTint(DB.line)
                .swipeActions {
                    if !l.password.isEmpty { Button("Copy password") { copyPassword(l) }.tint(DB.brass) }
                }
                .contextMenu { LoginContextMenu(login: l, edit: { editing = l }, delete: { deleting = l }) }
        case .card(let c):
            NavigationLink(value: ItemRef(kind: .card, id: c.id)) {
                TypedItemRow(symbol: ItemKind.card.symbol, title: c.title, subtitle: c.rowSubtitle, expired: c.isExpired())
            }
            .listRowBackground(DB.ground).listRowSeparatorTint(DB.line)
            .swipeActions {
                if !c.number.isEmpty { Button("Copy number") { session.copyProtected(c.number, what: "card number") }.tint(DB.brass) }
            }
            .contextMenu { CardMenu(card: c, edit: { edit(.card(c.id), .card) }, delete: { deletingItem = .init(kind: .card, id: c.id, title: c.title) }) }
        case .identity(let i):
            NavigationLink(value: ItemRef(kind: .identity, id: i.id)) {
                TypedItemRow(symbol: ItemKind.identity.symbol, title: i.shownTitle, subtitle: i.rowSubtitle)
            }
            .listRowBackground(DB.ground).listRowSeparatorTint(DB.line)
            .contextMenu { IdentityMenu(identity: i, edit: { edit(.identity(i.id), .identity) }, delete: { deletingItem = .init(kind: .identity, id: i.id, title: i.shownTitle) }) }
        case .note(let n):
            NavigationLink(value: ItemRef(kind: .note, id: n.id)) {
                TypedItemRow(symbol: ItemKind.note.symbol, title: n.title, subtitle: n.rowSubtitle)
            }
            .listRowBackground(DB.ground).listRowSeparatorTint(DB.line)
            .contextMenu { NoteMenu(note: n, edit: { edit(.note(n.id), .note) }, delete: { deletingItem = .init(kind: .note, id: n.id, title: n.title) }) }
        }
    }

    /// Opening an existing card, identity or note to edit shows its secrets, so it asks for Face ID first.
    private func edit(_ sheet: ItemSheet, _ kind: ItemKind) {
        Task { if await session.confirmOwner("Edit this \(kind.noun)") { itemSheet = sheet } }
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
    }

    private func count(_ f: VaultFilter) -> Int {
        switch f {
        case .cards: session.vault.cards.count
        case .identities: session.vault.identities.count
        case .notes: session.vault.notes.count
        case .all: vaultLogins.count
        case .websites: Set(session.vault.logins.compactMap { $0.sites.first }).count
        case .passkeys: vaultLogins.filter { !$0.passkeyIDs.isEmpty }.count
        }
    }

    private func copyPassword(_ l: LoginItem) {
        Clipboard.copySecret(l.password)
        session.show("Password copied", "Clipboard clears in 60 seconds")
    }
}

private struct LoginRow: View {
    let login: LoginItem
    var body: some View {
        HStack(spacing: 14) {
            SiteTile(title: login.title, site: login.sites.first, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(login.title).font(.db(14.5, .semibold)).foregroundStyle(DB.text)
                Text(login.username).font(.db(12.5)).foregroundStyle(DB.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            AuthBadges(login: login)
        }
        .padding(.vertical, 3)
    }
}

private struct GroupRow: View {
    let group: SiteGroup
    var body: some View {
        HStack(spacing: 14) {
            SiteTile(title: group.title, site: group.site, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).font(.db(14.5, .semibold)).foregroundStyle(DB.text)
                Text(group.logins.count == 1 ? "1 account · \(group.site)" : "\(group.logins.count) accounts · \(group.site)")
                    .font(.db(12.5)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if group.logins.contains(where: { !$0.password.isEmpty }) { Image(systemName: "ellipsis.rectangle").foregroundStyle(DB.text2) }
                if group.hasPasskey { Image(systemName: "person.badge.key").foregroundStyle(DB.brass) }
                if group.logins.contains(where: { $0.totpSecret != nil }) { Image(systemName: "clock").foregroundStyle(DB.text2) }
            }
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.vertical, 3)
    }
}

private struct EmptyVault: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.horizontal").font(.system(size: 34, weight: .light)).foregroundStyle(DB.brass)
            Text("Your vault is empty").font(.db(18, .semibold)).foregroundStyle(DB.text)
            Text("Sign in to a site in Safari and Deadbolt will offer to save it, or add one yourself.")
                .font(.db(12.5)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
            Button("Add a login", action: add).buttonStyle(PrimaryButtonStyle(height: 48)).frame(maxWidth: 220).padding(.top, 6)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: several accounts on one site

/// Everything saved for one website on one screen: each account with its password, code and passkey, ready to copy.
struct WebsiteView: View {
    @Environment(VaultSession.self) private var session
    let group: SiteGroup
    @State private var adding = false
    @State private var revealed: Set<UUID> = []

    var body: some View {
        let accounts = session.vault.accounts(for: group.site)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    SiteTile(title: accounts.first?.title ?? group.title, site: group.site, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(accounts.first?.title ?? group.title).font(.db(20, .bold))
                        Text("\(accounts.count) account\(accounts.count == 1 ? "" : "s") · \(group.site)").font(.db(12.5)).foregroundStyle(DB.text2).lineLimit(1)
                    }
                }
                ForEach(accounts) { a in account(a) }
                Button { adding = true } label: {
                    Label("Add another account", systemImage: "plus").font(.db(14.5, .semibold)).foregroundStyle(DB.brass)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 52)
                        .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .sheet(isPresented: $adding) { EditLoginView(original: nil, site: group.site) }
    }

    private func account(_ a: LoginItem) -> some View {
        Card {
            NavigationLink(value: a.id) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.username.isEmpty ? a.title : a.username).font(.db(14.5, .semibold)).lineLimit(1).truncationMode(.middle)
                        if let l = a.label, !l.isEmpty { Text(l).font(.db(12)).foregroundStyle(DB.text3) }
                    }
                    Spacer(minLength: 0)
                    if a.preferred { Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(DB.brass).accessibilityLabel("Suggested first") }
                    Text("Details").font(.db(12)).foregroundStyle(DB.text3)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(DB.text3)
                }
                .padding(.horizontal, 16).frame(minHeight: 46).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !a.username.isEmpty {
                CardDivider()
                line("person", "Username", a.username, copyLabel: "Copy username") { copy(a.username, "Username copied") }
            }
            if !a.password.isEmpty {
                CardDivider()
                HStack(spacing: 12) {
                    kind("ellipsis.rectangle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Password").font(.db(12)).foregroundStyle(DB.text3)
                        Text(revealed.contains(a.id) ? a.password : String(repeating: "•", count: 14)).font(.dbMono(14)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    IconButton(systemName: revealed.contains(a.id) ? "eye.slash" : "eye", label: "Show or hide password") {
                        if revealed.contains(a.id) { revealed.remove(a.id) } else { revealed.insert(a.id) }
                    }
                    IconButton(systemName: "doc.on.doc", label: "Copy password", prominent: true) {
                        copy(a.password, "Password copied"); try? session.mutate { $0.markUsed(a.id) }
                    }
                }
                .padding(.horizontal, 16).frame(minHeight: 50)
            }
            if let s = a.totpSecret, let t = try? TOTP(s) {
                CardDivider()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = t.secondsRemaining(at: ctx.date)
                    HStack(spacing: 12) {
                        kind("clock")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("One-time code").font(.db(12)).foregroundStyle(DB.text3)
                            Text(TOTP.grouped(t.code(at: ctx.date))).font(.dbMono(18)).tracking(1).foregroundStyle(left <= 5 ? DB.danger : DB.brass)
                        }
                        Spacer(minLength: 0)
                        CodeRing(left: left, period: t.period)
                        IconButton(systemName: "doc.on.doc", label: "Copy one-time code") { copy(t.code(), "Code copied") }
                    }
                    .padding(.horizontal, 16).frame(minHeight: 54)
                }
            }
            if !a.passkeyIDs.isEmpty {
                CardDivider()
                HStack(spacing: 12) {
                    kind("person.badge.key", DB.brass)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Passkey").font(.db(12)).foregroundStyle(DB.text3)
                        Text("Sign in with \(KeychainKey.biometryName)").font(.db(13.5))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).frame(minHeight: 50)
            }
        }
    }

    private func kind(_ icon: String, _ color: Color = DB.text2) -> some View {
        Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
            .frame(width: 30, height: 30).background(DB.control, in: RoundedRectangle(cornerRadius: 9))
    }

    private func line(_ icon: String, _ title: String, _ value: String, copyLabel: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            kind(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.db(12)).foregroundStyle(DB.text3)
                Text(value).font(.db(13.5)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            IconButton(systemName: "doc.on.doc", label: copyLabel, action: action)
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
    }

    private func copy(_ text: String, _ title: String) {
        Clipboard.copySecret(text)   // the button itself shows a checkmark
    }
}

// MARK: login detail

struct LoginDetailView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var revealed = false
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var addingCode = false
    @State private var shownFields: Set<UUID> = []

    var body: some View {
        if let login = session.vault.login(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        SiteTile(title: login.title, site: login.sites.first, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(login.title).font(.db(22, .bold))
                            Text("\(login.sites.first ?? "") · edited \(login.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.db(12.5)).foregroundStyle(DB.text2)
                        }
                    }
                    .padding(.bottom, 8)

                    Card {
                        field("Username", login.username) {
                            IconButton(systemName: "doc.on.doc", label: "Copy username") {
                                Clipboard.copySecret(login.username)
                            }
                        }
                        if login.isPasswordless {
                            CardDivider()
                            field("Password", "None. Signs in with an emailed link or code") { EmptyView() }
                        }
                        if !login.password.isEmpty {
                        CardDivider()
                        field("Password", revealed ? login.password : String(repeating: "•", count: 16), mono: true) {
                            HStack(spacing: 8) {
                                IconButton(systemName: revealed ? "eye.slash" : "eye", label: revealed ? "Hide password" : "Show password") {
                                    revealed.toggle()
                                }
                                IconButton(systemName: "doc.on.doc", label: "Copy password", prominent: true) {
                                    Clipboard.copySecret(login.password)
                                    try? session.mutate { $0.markUsed(login.id) }
                                }
                            }
                        }
                        }
                    }

                    if let secret = login.totpSecret { CodeCard(secret: secret) } else {
                        Button { addingCode = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "qrcode.viewfinder").foregroundStyle(DB.brass)
                                    .frame(width: 36, height: 36).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add one-time code").font(.db(14.5, .semibold))
                                    Text("For sites that ask for a 6-digit code").font(.db(12)).foregroundStyle(DB.text2)
                                }
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(DB.text3)
                            }
                            .padding(14).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DB.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }

                    if !login.passkeyIDs.isEmpty {
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: "key.horizontal.fill").foregroundStyle(DB.brass)
                                    .frame(width: 36, height: 36).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Passkey").font(.db(14.5, .semibold))
                                    Text("Sign in with \(KeychainKey.biometryName) on \(login.sites.first ?? "this site")").font(.db(12)).foregroundStyle(DB.text2)
                                }
                                Spacer()
                            }
                            .padding(16)
                        }
                    }

                    if let fields = login.customFields, !fields.isEmpty {
                        Card {
                            ForEach(Array(fields.enumerated()), id: \.element.id) { i, f in
                                if i > 0 { CardDivider() }
                                let masked = f.hidden && !shownFields.contains(f.id)
                                field(f.name, masked ? String(repeating: "•", count: max(6, min(f.value.count, 14))) : f.value, mono: f.hidden) {
                                    HStack(spacing: 8) {
                                        if f.hidden {
                                            IconButton(systemName: masked ? "eye" : "eye.slash", label: masked ? "Show \(f.name)" : "Hide \(f.name)") {
                                                if masked { shownFields.insert(f.id) } else { shownFields.remove(f.id) }
                                            }
                                        }
                                        IconButton(systemName: "doc.on.doc", label: "Copy \(f.name)") { Clipboard.copySecret(f.value) }
                                    }
                                }
                            }
                        }
                    }

                    Card {
                        row("Websites", login.sites.joined(separator: "\n"))
                        if let label = login.label, !label.isEmpty { CardDivider(); row("Label", label) }
                        CardDivider()
                        NavigationLink { HistoryView(id: login.id) } label: {
                            HStack {
                                Text("Password history").font(.db(14.5))
                                Spacer()
                                Text(login.history.isEmpty ? "None" : "\(login.history.count) older").font(.db(13.5)).foregroundStyle(DB.text2)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 46)
                        }
                        .buttonStyle(.plain)
                    }

                    if let notes = login.notes, !notes.isEmpty {
                        Card { Text(notes).font(.db(13.5)).foregroundStyle(DB.text2).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    }

                    Button("Delete login", role: .destructive) { confirmDelete = true }
                        .font(.db(14.5)).foregroundStyle(DB.danger).frame(maxWidth: .infinity).padding(.top, 10)
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
            .sheet(isPresented: $editing) { EditLoginView(original: login) }
            .sheet(isPresented: $addingCode) {
                OneTimeCodeSetupView(site: login.sites.first) { raw, _ in
                    try? session.mutate { v in
                        guard var item = v.login(login.id) else { return }
                        item.totpSecret = raw; v.upsert(item)
                    }
                    session.show("One-time code added")
                }
            }
            .confirmationDialog("Delete \(login.username) on \(login.title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete from this device", role: .destructive) {
                    try? session.mutate { $0.delete(login.id) }
                    session.show("Login deleted")
                    dismiss()
                }
            } message: { Text("Its password, history and any passkey links are removed.") }
        } else {
            Text("This login was deleted.").foregroundStyle(DB.text2).frame(maxWidth: .infinity, maxHeight: .infinity).background(DB.ground)
        }
    }

    private func field<Trailing: View>(_ label: String, _ value: String, mono: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.db(12)).foregroundStyle(DB.text3)
                Text(value).font(mono ? .dbMono(15) : .db(15)).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.db(14.5))
            Spacer()
            Text(value).font(.db(13.5)).foregroundStyle(DB.text2).lineLimit(4).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).frame(minHeight: 46)
    }
}

struct HistoryView: View {
    @Environment(VaultSession.self) private var session
    let id: UUID
    @State private var revealed: Set<Int> = []

    var body: some View {
        let history = session.vault.login(id)?.history ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if history.isEmpty {
                    Text("No older passwords yet. When a password changes, the old one is kept here.").font(.db(13.5)).foregroundStyle(DB.text2)
                } else {
                    Card {
                        ForEach(Array(history.enumerated()), id: \.offset) { i, entry in
                            if i > 0 { CardDivider() }
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(revealed.contains(i) ? entry.password : String(repeating: "•", count: 12)).font(.dbMono(14)).lineLimit(1)
                                    Text("Replaced \(entry.replacedAt.formatted(date: .abbreviated, time: .shortened))").font(.db(12)).foregroundStyle(DB.text3)
                                }
                                Spacer()
                                IconButton(systemName: revealed.contains(i) ? "eye.slash" : "eye", label: "Show old password") {
                                    if revealed.contains(i) { revealed.remove(i) } else { revealed.insert(i) }
                                }
                                Button("Restore") {
                                    try? session.mutate { v in
                                        guard var item = v.login(id) else { return }
                                        item.restore(entry)
                                        v.upsert(item)
                                    }
                                    revealed = []
                                    session.show("Password restored", "The one it replaced is now in history")
                                }
                                .buttonStyle(.plain).font(.db(12.5, .semibold)).foregroundStyle(DB.brass)
                                .frame(minWidth: 44, minHeight: 44)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Password history")
    }
}

// MARK: add / edit

#if os(macOS)
/// On the Mac the same entry points open the compact Mac sheet.
struct EditLoginView: View {
    let original: LoginItem?
    var site: String = ""
    var body: some View { MacEditSheet(original: original, site: site) }
}
#else
/// New / edit login (iPhone). Website first, then username and password; one-time code is its own guided step;
/// label, notes and extra websites wait under "More options". Save says what's missing instead of just greying out.
struct EditLoginView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: LoginFormModel
    @State private var revealed: Bool
    @State private var showMore: Bool
    @State private var addingCode = false
    @FocusState private var focus: Field?
    private enum Field { case name, site, user, password }

    init(original: LoginItem?, site: String = "") {
        let m = LoginFormModel(original: original, site: site)
        _form = State(initialValue: m)
        _revealed = State(initialValue: original == nil)
        _showMore = State(initialValue: m.hasMore)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Card {
                            if !form.allowsCodeOnly {
                                row("Name") { TextField(form.namePlaceholder, text: $form.name).focused($focus, equals: .name).submitLabel(.next).onSubmit { focus = .site } }
                                CardDivider()
                            }
                            row("Website") {
                                TextField("github.com", text: $form.site).textContentType(.URL).keyboardType(.URL)
                                    .focused($focus, equals: .site).submitLabel(.next).onSubmit { focus = .user }
                            }
                            CardDivider()
                            row("Username") {
                                TextField("Email or username", text: $form.username).textContentType(.username).keyboardType(.emailAddress)
                                    .focused($focus, equals: .user).submitLabel(.next).onSubmit { focus = .password }
                            }
                            CardDivider()
                            row("Password") {
                                Group {
                                    if revealed { TextField("Optional", text: $form.password) } else { SecureField("Optional", text: $form.password) }
                                }
                                .font(.dbMono(16)).focused($focus, equals: .password)
                                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                                    .foregroundStyle(DB.text2).accessibilityLabel(revealed ? "Hide password" : "Show password")
                                Button {
                                    form.password = session.newPassword(); revealed = true; Haptics.tap()
                                } label: {
                                    Text("Generate").font(.db(14, .semibold)).foregroundStyle(DB.brass)
                                        .padding(.horizontal, 10).frame(height: 30).background(DB.brassWash, in: Capsule())
                                }
                            }
                        }
                        hints
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Two-factor")
                        if let code = form.code {
                            Card {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.badge.checkmark").foregroundStyle(DB.good)
                                        .frame(width: 36, height: 36).background(DB.goodWash, in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("One-time code on").font(.db(16, .semibold))
                                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                            Text("Now \(TOTP.grouped(code.code(at: ctx.date))) · \(code.secondsRemaining(at: ctx.date)) s")
                                                .font(.dbMono(13)).foregroundStyle(DB.text2)
                                        }
                                    }
                                    Spacer()
                                    Menu {
                                        Button { addingCode = true } label: { Label("Replace…", systemImage: "arrow.triangle.2.circlepath") }
                                        Button(role: .destructive) { form.totp = "" } label: { Label("Remove", systemImage: "trash") }
                                    } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(DB.text2) }
                                        .accessibilityLabel("One-time code options")
                                }
                                .padding(14)
                            }
                        } else {
                            Card {
                                Button { addingCode = true } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "qrcode.viewfinder").foregroundStyle(DB.brass)
                                            .frame(width: 36, height: 36).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Add one-time code").font(.db(16, .semibold)).foregroundStyle(DB.text)
                                            Text("Scan the QR code from the website’s two-factor setup").font(.db(13)).foregroundStyle(DB.text2)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                                    }
                                    .padding(14).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button { withAnimation(.snappy) { showMore.toggle() } } label: {
                            HStack(spacing: 6) {
                                Text("MORE OPTIONS").font(.db(13, .semibold)).tracking(0.8)
                                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(showMore ? 0 : -90))
                            }
                            .foregroundStyle(DB.text3).padding(.leading, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showMore {
                            OtherWebsitesEditor(form: form)
                            CustomFieldsEditor(form: form)
                            Card {
                                row("Label") { TextField("Personal, Work…", text: $form.label) }
                                CardDivider()
                                row("Notes", top: true) { TextField("Anything else", text: $form.notes, axis: .vertical).lineLimit(2...6) }
                            }
                        }
                    }

                    if let error = form.error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DB.ground).foregroundStyle(DB.text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(form.isNew ? "New login" : "Edit login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(form.missing != nil) }
            }
            .sheet(isPresented: $addingCode) {
                OneTimeCodeSetupView(site: form.primarySite) { raw, t in form.useCode(raw, t) }
            }
            .onAppear { if form.isNew && form.site.isEmpty { focus = .site } }
        }
        .presentationBackground(DB.ground)
    }

    @ViewBuilder private var hints: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let h = form.siteHint {
                Label(h.text, systemImage: h.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(h.ok ? DB.text3 : DB.danger)
            }
            if let s = PasswordStrength.describe(form.password) {
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(0..<3) { i in Capsule().fill(i <= s.level ? PasswordStrength.color(s.level) : DB.line).frame(width: 22, height: 4) }
                    }
                    Text(form.passwordChanged ? "\(s.text) · the current password moves to history" : s.text)
                }
                .foregroundStyle(DB.text3)
            }
            if form.password.isEmpty, let h = form.noPasswordHint { Text(h) }
            if let m = form.missing, form.site.isEmpty == false || form.username.isEmpty == false || form.password.isEmpty == false {
                Text(m).foregroundStyle(DB.text3)
            }
        }
        .font(.db(13)).padding(.leading, 4)
    }

    private func row<C: View>(_ title: String, top: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: top ? .firstTextBaseline : .center, spacing: 12) {
            Text(title).font(.db(15)).foregroundStyle(DB.text2).frame(width: 84, alignment: .leading)
            content().font(.db(16))
        }
        .padding(.horizontal, 16).padding(.vertical, top ? 14 : 0).frame(minHeight: 52)
    }

    private func save() {
        do {
            let (title, detail) = try form.save(in: session)
            session.show(title, detail)
            Haptics.success()
            dismiss()
        } catch { form.error = error.friendly }
    }
}
#endif
