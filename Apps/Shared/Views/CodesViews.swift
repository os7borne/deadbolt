import DeadboltCore
import SwiftUI

// One-time codes as their own thing (see .agents/plans/09-accounts-and-codes-ux.md):
// iPhone gets an Authenticator-style list (tab "Codes"); the Mac window shows codes beside the logins they belong to.

extension VaultSession {
    /// Every login that has a working one-time code, by name.
    var codeItems: [LoginItem] {
        vault.logins
            .filter { $0.totpSecret.flatMap { try? TOTP($0) } != nil }
            .sorted {
                let c = $0.title.localizedCaseInsensitiveCompare($1.title)
                return c == .orderedSame ? $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending : c == .orderedAscending
            }
    }
}

/// Small icons for what is saved on a login: password, passkey, one-time code.
struct AuthBadges: View {
    let login: LoginItem
    var body: some View {
        HStack(spacing: 8) {
            if !login.password.isEmpty { badge("ellipsis.rectangle", "Password", DB.text2) }
            if login.isPasswordless { badge("envelope", "No password: signs in by email link or code", DB.text2) }
            if !login.passkeyIDs.isEmpty { badge("person.badge.key", "Passkey", DB.brass) }
            if login.totpSecret != nil { badge("clock", "One-time code", DB.text2) }
        }
        .accessibilityElement(children: .combine)
    }
    private func badge(_ icon: String, _ label: String, _ color: Color) -> some View {
        Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            .frame(width: 20, height: 20).accessibilityLabel(label)
    }
}

/// Countdown ring with the seconds left inside; turns red for the last five seconds.
struct CodeRing: View {
    let left: Int
    let period: Int
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            Circle().stroke(DB.line, lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(left) / CGFloat(max(period, 1)))
                .stroke(left <= 5 ? DB.danger : DB.brass, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: left)
            Text("\(left)").font(.dbMono(size * 0.36)).foregroundStyle(left <= 5 ? DB.danger : DB.text2)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(left) seconds left")
    }
}

/// One code, Authenticator style: name, account, big grouped code and the ring.
struct CodeRow: View {
    let login: LoginItem
    let date: Date
    /// Just copied: the ring turns into a checkmark.
    var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SiteTile(title: login.title, site: login.sites.first, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(login.title).font(.db(14.5, .semibold)).foregroundStyle(DB.text).lineLimit(1)
                if !login.username.isEmpty {
                    Text(login.username).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1).truncationMode(.middle)
                }
                if let secret = login.totpSecret, let t = try? TOTP(secret) {
                    let left = t.secondsRemaining(at: date)
                    HStack(spacing: 10) {
                        Text(TOTP.grouped(t.code(at: date))).font(.dbMono(24)).tracking(1)
                            .foregroundStyle(left <= 5 ? DB.danger : DB.brass)
                            .contentTransition(.numericText())
                        if copied {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(DB.good)
                                .transition(.scale.combined(with: .opacity)).accessibilityLabel("Copied")
                        } else {
                            CodeRing(left: left, period: t.period)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Add a one-time code in a single sheet: set it up (scan / pick / type), then name it. One sheet, two steps,
/// because opening a second sheet the moment the first closes is unreliable and can leave the person with nothing.
struct AddCodeFlow: View {
    @State private var code: (raw: String, totp: TOTP)?

    var body: some View {
        if let code {
            CodeEntrySheet(original: nil, code: code)
        } else {
            OneTimeCodeSetupView(site: nil, dismissOnUse: false) { raw, t in code = (raw, t) }
        }
    }
}

#if os(iOS)
// MARK: - iPhone: Codes tab

struct CodesView: View {
    @Environment(VaultSession.self) private var session
    @State private var query = ""
    @State private var adding = false
    @State private var editing: LoginItem?
    @State private var editingCodeOnly: LoginItem?
    @State private var deleting: LoginItem?
    @State private var copiedID: UUID?

    private var items: [LoginItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return session.codeItems.filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            List {
                if session.codeItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.checkmark").font(.system(size: 34, weight: .light)).foregroundStyle(DB.brass)
                        Text("No one-time codes yet").font(.db(18, .semibold))
                        Text("Add the QR code a website shows when you turn on two-factor sign-in. Its code appears here, and tapping it copies it.")
                            .font(.db(14)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
                        Button("Add a code") { adding = true }.buttonStyle(PrimaryButtonStyle(height: 48)).frame(maxWidth: 220).padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else if items.isEmpty {
                    Text("Nothing matches “\(query)”").font(.db(15)).foregroundStyle(DB.text2).listRowBackground(Color.clear)
                }
                ForEach(items) { l in
                    Button { copy(l) } label: { CodeRow(login: l, date: ctx.date, copied: copiedID == l.id) }
                        .buttonStyle(.plain)
                        .listRowBackground(DB.ground).listRowSeparatorTint(DB.line)
                        .contextMenu {
                            Button { copy(l) } label: { Label("Copy Code", systemImage: "doc.on.doc") }
                            if !l.username.isEmpty {
                                Button { Clipboard.copySecret(l.username); session.show("Username copied") } label: { Label("Copy Account", systemImage: "person") }
                            }
                            Divider()
                            Button { if l.isCodeOnly { editingCodeOnly = l } else { editing = l } } label: { Label("Edit…", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = l } label: { Label(l.isCodeOnly ? "Delete…" : "Remove Code…", systemImage: "trash") }
                        }
                }
                if !session.codeItems.isEmpty {
                    Text("Tap a code to copy it. The clipboard clears after 60 seconds.")
                        .font(.db(13)).foregroundStyle(DB.text3).listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
        }
        .scrollContentBackground(.hidden)
        .background(DB.ground)
        .searchable(text: $query, prompt: "Search \(session.codeItems.count) codes")
        .navigationTitle("Codes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add one-time code")
            }
        }
        .sheet(isPresented: $adding) { AddCodeFlow() }   // set it up, then name it, in one sheet
        .sheet(item: $editingCodeOnly) { CodeEntrySheet(original: $0) }
        .sheet(item: $editing) { EditLoginView(original: $0) }
        .confirmationDialog(deleting.map { $0.isCodeOnly ? "Delete the code for \($0.title)?" : "Remove the code from \($0.username) on \($0.title)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(deleting?.isCodeOnly == true ? "Delete" : "Remove Code", role: .destructive) {
                if let d = deleting {
                    if d.isCodeOnly { try? session.mutate { $0.delete(d.id) } }
                    else { try? session.mutate { v in if var i = v.login(d.id) { i.totpSecret = nil; v.upsert(i) } } }
                    session.show(d.isCodeOnly ? "Code deleted" : "Code removed")
                }
                deleting = nil
            }
        } message: { Text("You'll need to set up two-factor again on the website if you delete the only copy.") }
    }

    private func copy(_ l: LoginItem) {
        guard let s = l.totpSecret, let t = try? TOTP(s) else { return }
        Clipboard.copySecret(t.code())
        Haptics.tap()
        withAnimation(.snappy(duration: 0.2)) { copiedID = l.id }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedID == l.id { withAnimation(.snappy(duration: 0.2)) { copiedID = nil } }
        }
    }
}
#endif

// MARK: - name a code (both platforms)

/// Second step of adding a code: a name, the account, and an optional website. Also edits a code-only entry.
struct CodeEntrySheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: LoginFormModel

    init(original: LoginItem?, code: (raw: String, totp: TOTP)? = nil) {
        let m = LoginFormModel(original: original, codeOnly: true)
        if let code { m.useCode(code.raw, code.totp) }
        _form = State(initialValue: m)
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview
                    Card {
                        field("Name") { TextField("GitHub", text: $form.codeTitle) }
                        CardDivider()
                        field("Account") { TextField("Email or username", text: $form.username).keyboardType(.emailAddress).textInputAutocapitalization(.never) }
                        CardDivider()
                        field("Website") { TextField("Optional, like github.com", text: $form.site).keyboardType(.URL).textInputAutocapitalization(.never) }
                    }
                    hints
                    if let e = form.error { Text(e).font(.db(14)).foregroundStyle(DB.danger) }
                    Button(form.missing ?? (form.isNew ? "Save code" : "Save")) { save() }
                        .buttonStyle(PrimaryButtonStyle(height: 52)).disabled(form.missing != nil)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DB.ground).foregroundStyle(DB.text)
            .navigationTitle(form.isNew ? "Name this code" : "Edit code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationBackground(DB.ground)
        #else
        VStack(alignment: .leading, spacing: 14) {
            Text(form.isNew ? "Name this code" : "Edit code").font(.db(15, .semibold))
            preview
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                GridRow { label("Name"); TextField("GitHub", text: $form.codeTitle).macField() }
                GridRow { label("Account"); TextField("Email or username", text: $form.username).macField() }
                GridRow { label("Website"); TextField("Optional, like github.com", text: $form.site).macField() }
            }
            hints
            if let e = form.error { Text(e).font(.db(12)).foregroundStyle(DB.danger) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
                Button(form.missing ?? "Save") { save() }
                    .buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction).disabled(form.missing != nil)
            }
        }
        .padding(20).frame(width: 440)
        .font(.db(13)).foregroundStyle(DB.text).background(DB.raised)
        #endif
    }

    /// The live code, so the person can finish the website's setup with it.
    private var preview: some View {
        Group {
            if let t = form.code {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack(spacing: 12) {
                        Text(TOTP.grouped(t.code(at: ctx.date))).font(.dbMono(24)).tracking(1.2).foregroundStyle(DB.brass)
                        CodeRing(left: t.secondsRemaining(at: ctx.date), period: t.period)
                        Spacer()
                    }
                }
            }
        }
    }

    @ViewBuilder private var hints: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = form.siteSuggestion {
                Button { form.site = s } label: { Label("Use \(s)", systemImage: "plus.circle") }
                    #if os(macOS)
                    .buttonStyle(MacButtonStyle())
                    #else
                    .font(.db(14, .semibold)).foregroundStyle(DB.brass)
                    #endif
            }
            Text(form.site.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "With no website this code lives only in your code list; it won’t be offered on sign-in pages."
                 : "Fills on this website’s sign-in pages.")
                .font(.db(12)).foregroundStyle(DB.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    #if os(iOS)
    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.db(15)).foregroundStyle(DB.text2).frame(width: 84, alignment: .leading)
            content().font(.db(16))
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
    }
    #else
    private func label(_ t: String) -> some View { Text(t).foregroundStyle(DB.text2).frame(width: 70, alignment: .trailing) }
    #endif

    private func save() {
        do {
            let (title, detail) = try form.save(in: session)
            session.show(title, detail)
            Haptics.success()
            dismiss()
        } catch { form.error = error.friendly }
    }
}
