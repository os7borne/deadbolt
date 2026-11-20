import AppKit
import DeadboltCore
import SwiftUI

/// Menu-bar app: always running, quick search + copy from the menu bar, full vault in a window.
@main
struct DeadboltMacApp: App {
    // SwiftUI may build this struct more than once: the session and bridge live in a singleton so there is exactly one.
    @State private var session = MacRuntime.shared.session

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().environment(session)
        } label: {
            Image("MenuBarIcon")
                .opacity(session.state == .unlocked ? 1 : 0.55)   // dimmed while locked
                .accessibilityLabel(session.state == .unlocked ? "Deadbolt, unlocked" : "Deadbolt, locked")
        }
        .menuBarExtraStyle(.window)

        Window("Deadbolt", id: "main") {
            RootView()
                .environment(session)
                .frame(minWidth: 960, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 680)
        .commands { SettingsCommand(session: session) }
    }
}

/// ⌘, and the app menu's Settings… open Settings inside the main window instead of a second window.
struct SettingsCommand: Commands {
    let session: VaultSession
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if session.state == .unlocked { session.settingsOpen = true }
                openWindow(id: "main")
                NSApp.activate()
            }
            .keyboardShortcut(",")
        }
    }
}

/// The menu-bar popover from the design: search, copy password / username, open the full window.
struct MenuBarPanel: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var password = ""
    @State private var error: String?
    @State private var prompting = false
    @State private var requests = LinkRequests()
    @State private var reviewing: ApproveModel?
    @State private var selected = 0
    @State private var deleting: LoginItem?
    @State private var deletingItem: PendingDelete?
    @FocusState private var focused: Bool

    /// What the panel lists: logins (most recently used first), then cards, identities and notes.
    private enum Entry: Identifiable {
        case login(LoginItem), card(CardItem), identity(IdentityItem), note(NoteItem)
        var id: UUID {
            switch self { case .login(let x): x.id; case .card(let x): x.id; case .identity(let x): x.id; case .note(let x): x.id }
        }
    }

    var body: some View {
        if let reviewing {
            ApproveLinkView(model: reviewing)
                .environment(session)
                .frame(width: 380, height: 560)
                .preferredColorScheme(.dark)
                .onDisappear { self.reviewing = nil; requests.prune() }
        } else {
            panel
                .ownerCheckSheet(session)   // the password fallback for Touch ID checks started from here
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DeadboltGlyph(height: 19)
                Text("Deadbolt").font(.db(15, .bold))
                Spacer()
                if session.state == .unlocked {
                    Button { session.lock() } label: { Image(systemName: "lock") }
                        .buttonStyle(.plain).frame(width: 30, height: 30).background(DB.control, in: RoundedRectangle(cornerRadius: 8))
                        .help("Lock now")
                }
            }
            .padding(14)

            switch session.state {
            case .unlocked: unlocked
            case .noVault:
                prompt("Set up your vault in the Deadbolt window.") { open() }
            default: locked
            }

            Divider().overlay(DB.line)
            HStack(spacing: 12) {
                if session.state == .unlocked {
                    hint("↵", "Copy")
                    hint("⌘E", "Edit")
                }
                Spacer()
                Button("Open Deadbolt") { open() }.buttonStyle(.plain)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(DB.text3)
            }
            .font(.db(12)).foregroundStyle(Color(hex: 0xC9CCD2)).padding(.horizontal, 14).frame(height: 38)
        }
        .frame(width: 380)
        .background(DB.raised).foregroundStyle(DB.text)
        .preferredColorScheme(.dark)
        .modifier(ToastOverlay())
    }

    private var unlocked: some View {
        VStack(spacing: 8) {
            if requests.pending.count > 1 {
                Text("\(requests.pending.count) devices are asking at once — approve only the one showing the same code.")
                    .font(.db(12)).foregroundStyle(DB.danger).padding(.horizontal, 14)
            }
            ForEach(requests.pending) { r in
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(DB.brass)
                    Text("A new device wants to link").font(.db(13))
                    Spacer()
                    Button("Review…") { reviewing = r }
                        .buttonStyle(.plain).font(.db(13, .semibold)).foregroundStyle(DB.onBrass)
                        .padding(.horizontal, 10).frame(height: 28).background(DB.brass, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(12).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14)
            }
            TextField("Search Deadbolt", text: $query).focused($focused).textFieldStyle(.plain).font(.db(14))
                .onKeyPress(.downArrow) { selected = min(selected + 1, max(entries.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                .onKeyPress(.return) { if entries.indices.contains(selected) { primary(entries[selected]) }; return .handled }
                .onKeyPress(characters: ["e"]) { press in
                    guard press.modifiers.contains(.command), entries.indices.contains(selected) else { return .ignored }
                    edit(entries[selected]); return .handled
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color(hex: 0x1A1C22), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? DB.brass : DB.lineStrong))
                .padding(.horizontal, 14)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                            entryRow(e, selected: i == selected)
                                .id(e.id)
                                .onHover { if $0 { selected = i } }
                        }
                        if entries.isEmpty {
                            Text(query.isEmpty ? "Nothing saved yet" : "Nothing matches").font(.db(13)).foregroundStyle(DB.text2).padding(20)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: 340)
                .onChange(of: selected) { _, i in if entries.indices.contains(i) { proxy.scrollTo(entries[i].id) } }
            }
        }
        .onChange(of: query) { selected = 0 }
        .confirmationDialog(deleting.map { "Delete \($0.username) on \($0.title)?" } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { try? session.mutate { $0.delete(d.id) }; session.show("Login deleted") }
                deleting = nil
            }
        } message: { Text("Its password, history and any passkey links are removed from all your devices.") }
        .alert(deletingItem.map { "Delete \($0.title)?" } ?? "", isPresented: Binding(
            get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
            Button("Delete", role: .destructive) { if let d = deletingItem { deleteItem(d) }; deletingItem = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("It is removed from all your devices.") }
        .onAppear { focused = true; requests.watch(accountNumber: session.vault.accountNumber) }
        .onDisappear { requests.stop() }
    }

    /// A row: click = copy password; hover/selection reveals the copy icons; right-click = actions menu.
    private func row(_ l: LoginItem, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Button { copyPassword(l) } label: {
                HStack(spacing: 11) {
                    SiteTile(title: l.title, site: l.sites.first, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.title).font(.db(13.5, .semibold))
                        Text(l.username).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l.password.isEmpty ? "Passkey only" : "Click to copy the password")
            if selected {
                CopyButtons(login: l, size: 26)
            } else if let s = l.totpSecret {
                InlineCode(secret: s).font(.dbMono(13))
            }
        }
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 52)
        .background(selected ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contextMenu { LoginContextMenu(login: l, edit: { edit(l) }, delete: { deleting = l }) }
    }

    @ViewBuilder private func entryRow(_ e: Entry, selected: Bool) -> some View {
        switch e {
        case .login(let l): row(l, selected: selected)
        case .card(let c):
            otherRow(e, symbol: ItemKind.card.symbol, title: c.title, subtitle: c.rowSubtitle, hint: "Click to copy the card number", selected: selected) {
                CardMenu(card: c, edit: { edit(e) }, delete: { deletingItem = .init(kind: .card, id: c.id, title: c.title) })
            }
        case .identity(let i):
            otherRow(e, symbol: ItemKind.identity.symbol, title: i.shownTitle, subtitle: i.rowSubtitle, hint: "Click to copy the email (or name)", selected: selected) {
                IdentityMenu(identity: i, edit: { edit(e) }, delete: { deletingItem = .init(kind: .identity, id: i.id, title: i.shownTitle) })
            }
        case .note(let n):
            otherRow(e, symbol: ItemKind.note.symbol, title: n.title, subtitle: n.rowSubtitle, hint: "Click to copy the note text", selected: selected) {
                NoteMenu(note: n, edit: { edit(e) }, delete: { deletingItem = .init(kind: .note, id: n.id, title: n.title) })
            }
        }
    }

    /// Cards, identities and notes: click or ↵ = the main thing (Touch ID first for secrets); the ⋯ menu and right-click have the rest.
    private func otherRow<M: View>(_ e: Entry, symbol: String, title: String, subtitle: String, hint: String, selected: Bool,
                                   @ViewBuilder menu: () -> M) -> some View {
        HStack(spacing: 11) {
            Button { primary(e) } label: {
                HStack(spacing: 11) {
                    TypeTile(symbol: symbol, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.db(13.5, .semibold)).lineLimit(1)
                        Text(subtitle).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(hint)
            if selected {
                Menu { menu() } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 26).accessibilityLabel("More actions")
            }
        }
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 52)
        .background(selected ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contextMenu { menu() }
    }

    /// ↵ / click: a login's password; a card's number; an identity's email (else name); a note's text.
    private func primary(_ e: Entry) {
        switch e {
        case .login(let l): copyPassword(l)
        case .card(let c):
            if c.number.isEmpty { session.show("No card number", style: .error) } else { session.copyProtected(c.number, what: "card number", used: c.id) }
        case .identity(let i):
            let text = i.email.isEmpty ? i.fullName : i.email
            if text.isEmpty { session.show("Nothing to copy", style: .error) } else { Clipboard.copySecret(text); try? session.mutate { $0.markItemUsed(i.id) }; session.show(i.email.isEmpty ? "Name copied" : "Email copied") }
        case .note(let n):
            if n.body.isEmpty { session.show("This note is empty", style: .error) } else { session.copyProtected(n.body, what: "note text") }
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
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) { Text(key).foregroundStyle(Color(hex: 0xC9CCD2)); Text(label).foregroundStyle(DB.text3) }
    }

    private func copyPassword(_ l: LoginItem) {
        guard !l.password.isEmpty else { session.show("No password", "This login signs in with a passkey", style: .error); return }
        Clipboard.copySecret(l.password)
        try? session.mutate { $0.markUsed(l.id) }
        session.show("Password copied", "Clipboard clears in 60 seconds")
    }

    private func edit(_ l: LoginItem) {
        session.editTarget = .init(id: l.id)
        open()
    }

    /// Logins open in the window as before. Cards, identities and notes ask for Touch ID first (the editor shows their secrets).
    private func edit(_ e: Entry) {
        let sheet: ItemSheet, noun: String
        switch e {
        case .login(let l): edit(l); return
        case .card(let c): sheet = .card(c.id); noun = "card"
        case .identity(let i): sheet = .identity(i.id); noun = "identity"
        case .note(let n): sheet = .note(n.id); noun = "note"
        }
        Task {
            guard await session.confirmOwner("Edit this \(noun)") else { return }
            session.pendingItemSheet = sheet
            open()
        }
    }

    private var locked: some View {
        VStack(spacing: 10) {
            if session.biometricUnlockAllowed {
                Button { Task { await touchID() } } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
                    .buttonStyle(PrimaryButtonStyle(height: 40))
                    .disabled(prompting)
            }
            SecureField("Master password", text: $password).textFieldStyle(.plain).font(.db(14))
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color(hex: 0x1A1C22), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit {
                    Task {
                        do { try await session.unlock(password: password); password = "" }
                        catch { self.error = error.friendly }
                    }
                }
            if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
        .task { await touchID() } // Touch ID is the default: start it as soon as the panel opens
    }

    private func touchID() async {
        guard session.state == .locked, session.biometricUnlockAllowed, !prompting else { return }
        prompting = true
        defer { prompting = false }
        do { try await session.unlockWithBiometrics(reason: "Unlock Deadbolt") }
        catch { self.error = error.friendly }
    }

    private func prompt(_ text: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(text).font(.db(13)).foregroundStyle(DB.text2)
            Button("Open Deadbolt", action: action).buttonStyle(PrimaryButtonStyle(height: 36))
        }
        .padding(14)
    }

    private var entries: [Entry] {
        let q = query.lowercased()
        func ok(_ text: String) -> Bool { q.isEmpty || text.contains(q) }
        func byTitle(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
        let logins = session.vault.logins
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q) || $0.sites.contains { $0.contains(q) } }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(30).map(Entry.login)
        // Searching never shows a card number or code: only names, brand, last four digits and the like (`searchText`).
        let cards = session.vault.cardsByRecency.filter { ok($0.searchText) }.prefix(10).map(Entry.card)
        let people = session.vault.identitiesByRecency.filter { ok($0.searchText) }.prefix(10).map(Entry.identity)
        let notes = session.vault.notes.filter { ok($0.searchText) }.sorted { byTitle($0.title, $1.title) }.prefix(10).map(Entry.note)
        return Array(logins) + Array(cards) + Array(people) + Array(notes)
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
