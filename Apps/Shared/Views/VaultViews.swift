import DeadboltCore
import SwiftUI

/// One row in the vault list: a single login, or a site with several accounts.
struct SiteGroup: Identifiable, Hashable {
    let site: String
    let title: String
    let logins: [LoginItem]
    var id: String { site }
    var hasPasskey: Bool { logins.contains { !$0.passkeyIDs.isEmpty } }

    static func == (a: SiteGroup, b: SiteGroup) -> Bool { a.site == b.site && a.logins.map(\.id) == b.logins.map(\.id) }
    func hash(into h: inout Hasher) { h.combine(site); h.combine(logins.map(\.id)) }
}

enum VaultFilter: String, CaseIterable { case all = "All", logins = "Logins", passkeys = "Passkeys" }

struct VaultListView: View {
    @Environment(VaultSession.self) private var session
    @State private var query = ""
    @State private var filter = VaultFilter.all
    @State private var editing: LoginItem?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    ForEach(VaultFilter.allCases, id: \.self) { f in
                        Button { filter = f } label: {
                            Text(f == .all ? f.rawValue : "\(f.rawValue) \(count(f))")
                                .font(.db(14, filter == f ? .semibold : .regular))
                                .foregroundStyle(filter == f ? DB.ground : Color(hex: 0xC9CCD2))
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(filter == f ? DB.text : .clear, in: Capsule())
                                .overlay(Capsule().stroke(filter == f ? .clear : DB.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }

            if session.vault.logins.isEmpty {
                EmptyVault(add: { adding = true })
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else if groups.isEmpty {
                Text("Nothing matches “\(query)”").font(.db(15)).foregroundStyle(DB.text2)
                    .listRowBackground(Color.clear)
            }

            ForEach(groups) { g in
                NavigationLink(value: g) { GroupRow(group: g) }
                    .listRowBackground(DB.ground)
                    .listRowSeparatorTint(DB.line)
                    .swipeActions {
                        if g.logins.count == 1 {
                            Button("Copy password") { copyPassword(g.logins[0]) }.tint(DB.brass)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(DB.ground)
        .searchable(text: $query, prompt: "Search \(session.vault.logins.count) items")
        .navigationTitle("Vault")
        .navigationDestination(for: SiteGroup.self) { g in
            if g.logins.count == 1 { LoginDetailView(id: g.logins[0].id) } else { SiteAccountsView(site: g.site) }
        }
        .navigationDestination(for: UUID.self) { LoginDetailView(id: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add login")
            }
            ToolbarItem(placement: .cancellationAction) {
                Button { session.lock() } label: { Image(systemName: "lock") }.accessibilityLabel("Lock now")
            }
        }
        .sheet(isPresented: $adding) { EditLoginView(original: nil) }
    }

    private var groups: [SiteGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let logins = session.vault.logins.filter { l in
            (filter != .passkeys || !l.passkeyIDs.isEmpty)
            && (q.isEmpty || l.title.lowercased().contains(q) || l.username.lowercased().contains(q) || l.sites.contains { $0.contains(q) })
        }
        let bySite = Dictionary(grouping: logins) { $0.sites.first ?? $0.id.uuidString }
        return bySite.map { site, items in
            SiteGroup(site: site, title: items[0].title, logins: session.vault.accounts(for: site).filter { items.contains($0) })
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func count(_ f: VaultFilter) -> Int {
        f == .passkeys ? session.vault.passkeys.count : session.vault.logins.count
    }

    private func copyPassword(_ l: LoginItem) {
        Clipboard.copySecret(l.password)
        session.show("Password copied", "Clipboard clears in 60 seconds")
    }
}

private struct GroupRow: View {
    let group: SiteGroup
    var body: some View {
        HStack(spacing: 14) {
            SiteTile(title: group.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).font(.db(16, .semibold)).foregroundStyle(DB.text)
                Text(group.logins.count == 1 ? group.logins[0].username : "\(group.logins.count) accounts")
                    .font(.db(14)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if group.hasPasskey {
                Label("Passkey", systemImage: "key.horizontal.fill")
                    .font(.db(12, .semibold)).foregroundStyle(DB.brass)
                    .padding(.horizontal, 8).frame(height: 24).background(DB.control, in: Capsule())
            }
        }
        .padding(.vertical, 6)
    }
}

private struct EmptyVault: View {
    let add: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.horizontal").font(.system(size: 34, weight: .light)).foregroundStyle(DB.brass)
            Text("Your vault is empty").font(.db(18, .semibold)).foregroundStyle(DB.text)
            Text("Sign in to a site in Safari and Deadbolt will offer to save it, or add one yourself.")
                .font(.db(14)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
            Button("Add a login", action: add).buttonStyle(PrimaryButtonStyle(height: 48)).frame(maxWidth: 220).padding(.top, 6)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: several accounts on one site

struct SiteAccountsView: View {
    @Environment(VaultSession.self) private var session
    let site: String
    @State private var adding = false

    var body: some View {
        let accounts = session.vault.accounts(for: site)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    SiteTile(title: accounts.first?.title ?? site, size: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accounts.first?.title ?? site).font(.db(26, .bold))
                        Text("\(accounts.count) accounts on \(site)").font(.db(14)).foregroundStyle(DB.text2)
                    }
                }
                Card {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { CardDivider() }
                        HStack(spacing: 14) {
                            NavigationLink(value: a.id) {
                                HStack(spacing: 14) {
                                    SiteTile(title: a.username, size: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 8) {
                                            Text(a.username).font(.db(16, .semibold))
                                            if let label = a.label, !label.isEmpty {
                                                Text(label).font(.db(11, .semibold)).foregroundStyle(Color(hex: 0xC9CCD2))
                                                    .padding(.horizontal, 8).frame(height: 20).background(DB.control, in: Capsule())
                                            }
                                        }
                                        Text(a.passkeyIDs.isEmpty ? "Password" : "Passkey + password").font(.db(13)).foregroundStyle(DB.text2)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            Button {
                                try? session.mutate { $0.setPreferred(a.id) }
                                session.show("\(a.username) will be suggested first")
                            } label: {
                                Image(systemName: a.preferred ? "star.fill" : "star")
                                    .foregroundStyle(a.preferred ? DB.brass : DB.text3)
                                    .frame(width: 44, height: 44)
                                    .background(a.preferred ? DB.brassWash : DB.control, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(a.preferred ? "\(a.username) is suggested first" : "Suggest \(a.username) first")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    CardDivider()
                    Button { adding = true } label: {
                        Label("Add another account", systemImage: "plus").font(.db(16, .semibold)).foregroundStyle(DB.brass)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 56)
                    }
                    .buttonStyle(.plain)
                }
                Text("The starred account is suggested first when you sign in here. Every account keeps its own password and passkey.")
                    .font(.db(13)).foregroundStyle(DB.text3).padding(.horizontal, 4)
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .sheet(isPresented: $adding) { EditLoginView(original: nil, site: site) }
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

    var body: some View {
        if let login = session.vault.login(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        SiteTile(title: login.title, size: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(login.title).font(.db(26, .bold))
                            Text("\(login.sites.first ?? "") · edited \(login.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.db(14)).foregroundStyle(DB.text2)
                        }
                    }
                    .padding(.bottom, 8)

                    Card {
                        field("Username", login.username) {
                            IconButton(systemName: "doc.on.doc", label: "Copy username") {
                                Clipboard.copySecret(login.username); session.show("Username copied")
                            }
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
                                    session.show("Password copied", "Clipboard clears in 60 seconds")
                                }
                            }
                        }
                        }
                    }

                    if !login.passkeyIDs.isEmpty {
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: "key.horizontal.fill").foregroundStyle(DB.brass)
                                    .frame(width: 36, height: 36).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Passkey").font(.db(16, .semibold))
                                    Text("Sign in with \(KeychainKey.biometryName) on \(login.sites.first ?? "this site")").font(.db(13)).foregroundStyle(DB.text2)
                                }
                                Spacer()
                            }
                            .padding(16)
                        }
                    }

                    Card {
                        row("Websites", login.sites.joined(separator: ", "))
                        if let label = login.label, !label.isEmpty { CardDivider(); row("Label", label) }
                        CardDivider()
                        NavigationLink { HistoryView(id: login.id) } label: {
                            HStack {
                                Text("Password history").font(.db(16))
                                Spacer()
                                Text(login.history.isEmpty ? "None" : "\(login.history.count) older").font(.db(15)).foregroundStyle(DB.text2)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 52)
                        }
                        .buttonStyle(.plain)
                    }

                    if let notes = login.notes, !notes.isEmpty {
                        Card { Text(notes).font(.db(15)).foregroundStyle(DB.text2).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    }

                    Button("Delete login", role: .destructive) { confirmDelete = true }
                        .font(.db(16)).foregroundStyle(DB.danger).frame(maxWidth: .infinity).padding(.top, 10)
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
            .sheet(isPresented: $editing) { EditLoginView(original: login) }
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
                Text(label).font(.db(13)).foregroundStyle(DB.text3)
                Text(value).font(mono ? .dbMono(17) : .db(17)).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.db(16))
            Spacer()
            Text(value).font(.db(15)).foregroundStyle(DB.text2).lineLimit(1)
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
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
                    Text("No older passwords yet. When a password changes, the old one is kept here.").font(.db(15)).foregroundStyle(DB.text2)
                } else {
                    Card {
                        ForEach(Array(history.enumerated()), id: \.offset) { i, entry in
                            if i > 0 { CardDivider() }
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(revealed.contains(i) ? entry.password : String(repeating: "•", count: 12)).font(.dbMono(15)).lineLimit(1)
                                    Text("Replaced \(entry.replacedAt.formatted(date: .abbreviated, time: .shortened))").font(.db(13)).foregroundStyle(DB.text3)
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
                                .buttonStyle(.plain).font(.db(14, .semibold)).foregroundStyle(DB.brass)
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

struct EditLoginView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let original: LoginItem?
    @State private var site: String
    @State private var username: String
    @State private var password: String
    @State private var label: String
    @State private var notes: String
    @State private var error: String?

    init(original: LoginItem?, site: String = "") {
        self.original = original
        _site = State(initialValue: original?.sites.joined(separator: ", ") ?? site)
        _username = State(initialValue: original?.username ?? "")
        _password = State(initialValue: original?.password ?? "")
        _label = State(initialValue: original?.label ?? "")
        _notes = State(initialValue: original?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    labeled("Website") { TextField("github.com", text: $site).textContentType(.URL).fieldStyle() }
                    labeled("Username or email") { TextField("you@example.com", text: $username).textContentType(.username).fieldStyle() }
                    labeled("Password") {
                        HStack(spacing: 8) {
                            TextField("Password", text: $password).font(.dbMono(16)).fieldStyle()
                            IconButton(systemName: "wand.and.stars", label: "Generate password") {
                                password = PasswordGenerator.password()
                                Haptics.tap()
                            }
                        }
                    }
                    labeled("Label (optional)") { TextField("Personal, Work…", text: $label).fieldStyle() }
                    labeled("Notes (optional)") { TextField("", text: $notes, axis: .vertical).lineLimit(3...6).fieldStyle() }
                    if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .navigationTitle(original == nil ? "New login" : "Edit login")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!valid) }
            }
        }
        .presentationBackground(DB.ground)
    }

    private var valid: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !sites.isEmpty }
    private var sites: [String] { site.split(separator: ",").compactMap { Site.normalize(String($0)) } }

    private func save() {
        do {
            if var item = original {
                item.sites = sites
                item.username = username.trimmingCharacters(in: .whitespaces)
                item.changePassword(to: password)
                item.label = label.isEmpty ? nil : label
                item.notes = notes.isEmpty ? nil : notes
                try session.mutate { $0.upsert(item) }
                session.show("Saved")
            } else {
                let proposal = session.vault.proposeSave(host: sites[0], username: username, password: password)
                let id = try session.mutate { v in try v.save(host: sites[0], username: username.trimmingCharacters(in: .whitespaces), password: password) }
                try session.mutate { v in
                    guard var item = v.login(id) else { return }
                    item.sites = Array(Set(item.sites + sites)).sorted()
                    if !label.isEmpty { item.label = label }
                    if !notes.isEmpty { item.notes = notes }
                    v.upsert(item)
                }
                switch proposal {
                case .update: session.show("Updated existing login", "The old password is in history")
                case .unchanged: session.show("Already saved", "Nothing changed")
                case .new: session.show("Login saved")
                }
            }
            dismiss()
        } catch { self.error = error.friendly }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.db(13)).foregroundStyle(DB.text3).padding(.leading, 4)
            content()
        }
    }
}
