#if os(macOS)
import AppKit
import DeadboltCore
import SwiftUI

// Mac views for cards, identities and secure notes: list rows, detail panes, edit sheets, context menus.
// Rule for all of them: a secret (card number, security code, PIN, ID numbers, note text, hidden custom fields) is masked,
// and showing, copying or editing it needs a fresh Touch ID check (`VaultSession.confirmOwner`) every time.

// MARK: - detail building blocks

private struct DetailDivider: View { var body: some View { Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1) } }

/// A bordered group of rows with hairlines between them.
struct DetailFields: View {
    let specs: [FieldSpec]
    var body: some View {
        if !specs.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(specs.enumerated()), id: \.offset) { i, s in
                    if i > 0 { DetailDivider() }
                    if s.secret { SecretRow(spec: s) } else { ValueRow(spec: s) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DB.line))
        }
    }
}

private struct RowFrame<C: View>: View {
    let label: String
    @ViewBuilder let content: () -> C
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.db(12)).foregroundStyle(DB.text3).frame(width: 110, alignment: .leading)
            content()
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 9).frame(minHeight: 40)
    }
}

private struct RoundIcon: View {
    let name: String
    var done = false
    var prominent = false
    var body: some View {
        Image.tick(name, done: done).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(done ? DB.good : (prominent ? DB.brass : DB.text2))
            .frame(width: 26, height: 26)
            .background(done ? DB.goodWash : (prominent ? DB.brassWash : .clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

private struct ValueRow: View {
    let spec: FieldSpec
    var body: some View {
        RowFrame(label: spec.label) {
            Text(spec.value).font(spec.mono ? .dbMono(13) : .db(13)).textSelection(.enabled)
                .lineLimit(spec.multiline ? nil : 3).frame(maxWidth: .infinity, alignment: .leading)
            TickButton(action: { Clipboard.copySecret(spec.copy ?? spec.value) }) { RoundIcon(name: "doc.on.doc", done: $0) }
                .buttonStyle(.plain).help("Copy \(spec.label.lowercased())").accessibilityLabel("Copy \(spec.label)")
        }
    }
}

private struct SecretRow: View {
    @Environment(VaultSession.self) private var session
    let spec: FieldSpec
    @State private var shown = false
    @State private var copied = false
    @State private var hideTask: Task<Void, Never>?

    private var what: String { spec.what ?? spec.label.lowercased() }

    var body: some View {
        RowFrame(label: spec.label) {
            Text(shown ? (spec.shown ?? spec.value) : (spec.masked ?? String(repeating: "•", count: max(6, min(spec.value.count, 14)))))
                .font(spec.mono || !shown ? .dbMono(13) : .db(13)).textSelection(.enabled)   // while hidden, only the masked text can be selected
                .lineLimit(shown && spec.multiline ? nil : 3).frame(maxWidth: .infinity, alignment: .leading)
            Button { toggle() } label: { RoundIcon(name: shown ? "eye.slash" : "eye") }
                .buttonStyle(.plain).help(shown ? "Hide \(what)" : "Show \(what)").accessibilityLabel(shown ? "Hide \(what)" : "Show \(what)")
            Button { copy() } label: { RoundIcon(name: "doc.on.doc", done: copied, prominent: true) }
                .buttonStyle(.plain).help("Copy \(what)").accessibilityLabel("Copy \(what)")
        }
        .onDisappear { hideTask?.cancel() }
    }

    private func toggle() {
        if shown { hideTask?.cancel(); shown = false; return }
        Task {
            guard await session.confirmOwner("Show \(what)") else { return }
            shown = true
            hideTask?.cancel()
            hideTask = Task {   // it doesn't stay on screen
                try? await Task.sleep(for: .seconds(20))
                if !Task.isCancelled { shown = false }
            }
        }
    }

    private func copy() {
        Task {
            guard await session.confirmOwner("Copy \(what)") else { return }
            Clipboard.copySecret(spec.copy ?? spec.value, clearAfter: Clipboard.sensitiveClearAfter)
            withAnimation(.snappy(duration: 0.2)) { copied = true }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy(duration: 0.2)) { copied = false }
        }
    }
}

private struct DetailHeader<Menu_: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let edit: () -> Void
    @ViewBuilder let menu: () -> Menu_
    var body: some View {
        HStack(spacing: 14) {
            TypeTile(symbol: symbol, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.db(18, .semibold)).lineLimit(2)
                Text(subtitle).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
            }
            Spacer()
            Button("Edit", action: edit).buttonStyle(MacButtonStyle()).keyboardShortcut("e", modifiers: .command)
            Menu { menu() } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DB.lineStrong))
                .accessibilityLabel("More actions")
        }
    }
}

private struct NotesBlock: View {
    let text: String?
    var body: some View {
        if let text, !text.isEmpty {
            Text(text).foregroundStyle(DB.text2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DB.line))
        }
    }
}

private func edited(_ d: Date) -> String { "edited \(d.formatted(.relative(presentation: .named)))" }

// MARK: - card

struct MacCardDetail: View {
    @Environment(VaultSession.self) private var session
    let card: CardItem
    let edit: () -> Void
    let delete: () -> Void
    let openIdentity: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(symbol: "creditcard", title: card.title, subtitle: "\(card.maskedSummary) · \(edited(card.updatedAt))", edit: edit) {
                    CardMenu(card: card, edit: edit, delete: delete)
                }
                if card.isExpired() {
                    Label("This card expired on \(card.expiry ?? "").", systemImage: "exclamationmark.triangle").font(.db(12)).foregroundStyle(DB.danger)
                }
                if !card.number.isEmpty, !card.passesLuhn {
                    Label("The number doesn’t pass the card check digit. It may have a typo.", systemImage: "exclamationmark.circle")
                        .font(.db(12)).foregroundStyle(DB.brass)
                }
                DetailFields(specs: card.fieldSpecs)
                if let id = card.identityID, let who = session.vault.identity(id) {
                    HStack(spacing: 12) {
                        Text("Billing address").font(.db(12)).foregroundStyle(DB.text3).frame(width: 110, alignment: .leading)
                        Text(who.title.isEmpty ? who.fullName : who.title).lineLimit(1)
                        Spacer()
                        Button("Show") { openIdentity(id) }.buttonStyle(.plain).foregroundStyle(DB.brass).font(.db(12))
                    }
                    .padding(.horizontal, 14).frame(minHeight: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DB.line))
                }
                DetailFields(specs: customFieldSpecs(card.customFields))
                if let l = card.label, !l.isEmpty { DetailFields(specs: [FieldSpec(label: "Label", value: l)]) }
                NotesBlock(text: card.notes)
            }
            .padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 720, alignment: .leading)
        }
    }
}

// MARK: - identity

struct MacIdentityDetail: View {
    let identity: IdentityItem
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(symbol: "person.text.rectangle", title: identity.title.isEmpty ? identity.fullName : identity.title,
                             subtitle: "\([identity.fullName, identity.company].filter { !$0.isEmpty && $0 != identity.title }.joined(separator: " · ")) · \(edited(identity.updatedAt))",
                             edit: edit) { IdentityMenu(identity: identity, edit: edit, delete: delete) }
                ForEach(Array(identity.specGroups.enumerated()), id: \.offset) { _, g in DetailFields(specs: g) }
                if let l = identity.label, !l.isEmpty { DetailFields(specs: [FieldSpec(label: "Label", value: l)]) }
                NotesBlock(text: identity.notes)
            }
            .padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 720, alignment: .leading)
        }
    }
}

// MARK: - note

struct MacNoteDetail: View {
    let note: NoteItem
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DetailHeader(symbol: "note.text", title: note.title, subtitle: "Secure note · \(edited(note.updatedAt))", edit: edit) {
                    NoteMenu(note: note, edit: edit, delete: delete)
                }
                DetailFields(specs: note.fieldSpecs)
                DetailFields(specs: customFieldSpecs(note.customFields))
                if let l = note.label, !l.isEmpty { DetailFields(specs: [FieldSpec(label: "Label", value: l)]) }
            }
            .padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 720, alignment: .leading)
        }
    }
}

// MARK: - edit sheets

private func formRow<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    GridRow(alignment: .firstTextBaseline) {
        Text(title).font(.db(12)).foregroundStyle(DB.text3).frame(width: 100, alignment: .trailing)
        VStack(alignment: .leading, spacing: 4) { content() }
    }
}

private func formNote(_ text: String, color: Color = DB.text3) -> some View { Text(text).font(.db(11.5)).foregroundStyle(color) }

private struct MoreToggle: View {
    @Binding var open: Bool
    var body: some View {
        GridRow {
            Color.clear.frame(width: 1, height: 1)
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                Label("More options", systemImage: open ? "chevron.down" : "chevron.right").font(.db(12))
            }
            .buttonStyle(.plain).foregroundStyle(DB.text3)
        }
    }
}

/// Name/value rows for any item (the login form has its own bound to `LoginFormModel`).
struct CustomFieldsEditor: View {
    @Binding var fields: [CustomField]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($fields) { $f in
                HStack(spacing: 6) {
                    TextField("Name", text: $f.name).macField().frame(width: 120)
                    Group { if f.hidden { SecureField("Value", text: $f.value) } else { TextField("Value", text: $f.value) } }.macField()
                    Toggle("Hide", isOn: $f.hidden).toggleStyle(.checkbox).font(.db(12))
                    Button { fields.removeAll { $0.id == f.id } } label: { Image(systemName: "minus").frame(width: 12) }
                        .buttonStyle(MacButtonStyle()).help("Remove field")
                }
            }
            Button { fields.append(CustomField()) } label: { Label("Add Field", systemImage: "plus") }.buttonStyle(MacButtonStyle())
        }
    }
}

private extension Binding where Value == [CustomField]? {
    var orEmpty: Binding<[CustomField]> {
        Binding<[CustomField]>(get: { wrappedValue ?? [] }, set: { wrappedValue = $0 })
    }
}

private struct SheetFooter: View {
    let missing: String?
    let deleteTitle: String?
    let delete: () -> Void
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            if let deleteTitle { Button(deleteTitle, action: delete).buttonStyle(.plain).foregroundStyle(DB.danger).font(.db(12.5)) }
            Spacer()
            if let missing { Text(missing).font(.db(12)).foregroundStyle(DB.text3) }
            Button("Cancel") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Save", action: save).buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                .disabled(missing != nil).opacity(missing != nil ? 0.5 : 1)
        }
    }
}

struct MacCardSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: CardFormModel
    @State private var revealed = false
    @State private var showMore: Bool
    @State private var confirmDelete = false
    @FocusState private var numberFocused: Bool

    init(original: CardItem?) {
        let m = CardFormModel(original: original)
        _form = State(initialValue: m)
        _showMore = State(initialValue: m.hasMore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TypeTile(symbol: "creditcard")
                Text(form.original.map { "Edit \($0.title)" } ?? "New Card").font(.db(15, .semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                formRow("Name") { TextField("Travel card", text: $form.title).macField() }
                formRow("Cardholder") { TextField("Name on the card", text: $form.cardholder).macField() }
                formRow("Number") {
                    TextField("1234 5678 9012 3456", text: $form.number).font(.dbMono(12.5)).macField().focused($numberFocused)
                    if let h = form.numberHint { formNote(h.text, color: h.ok ? DB.text3 : DB.brass) }
                }
                formRow("Brand") {
                    Picker("", selection: $form.brand) {
                        Text(form.brand == nil ? "Detect automatically" + (form.shownBrand.map { " (\($0.displayName))" } ?? "") : "Detect automatically")
                            .tag(CardBrand?.none)
                        ForEach(CardBrand.allCases, id: \.self) { Text($0.displayName).tag(CardBrand?.some($0)) }
                    }.labelsHidden().frame(maxWidth: 240, alignment: .leading)
                }
                formRow("Expires") {
                    HStack(spacing: 6) {
                        Picker("", selection: $form.month) {
                            Text("Month").tag(Int?.none)
                            ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag(Int?.some($0)) }
                        }.labelsHidden().frame(width: 100)
                        TextField("Year", text: $form.year).macField().frame(width: 80)
                    }
                }
                formRow("Security code") { secretField("3 or 4 digits", $form.code) }
                formRow("PIN") { secretField("Optional", $form.pin) }
                formRow("Billing address") {
                    Picker("", selection: $form.identityID) {
                        Text("None").tag(UUID?.none)
                        ForEach(session.vault.identities) { Text($0.title.isEmpty ? $0.fullName : $0.title).tag(UUID?.some($0.id)) }
                    }.labelsHidden().frame(maxWidth: 240, alignment: .leading)
                }
                MoreToggle(open: $showMore)
                if showMore {
                    formRow("Custom fields") { CustomFieldsEditor(fields: $form.customFields) }
                    formRow("Label") { TextField("Personal, Work…", text: $form.label).macField() }
                    formRow("Notes") { TextField("", text: $form.notes, axis: .vertical).lineLimit(3...5).macField() }
                }
            }
            if let error = form.error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
            SheetFooter(missing: form.missing, deleteTitle: form.original == nil ? nil : "Delete Card…",
                        delete: { confirmDelete = true }, save: save)
        }
        .padding(20).frame(width: 520)
        .font(.db(13)).background(DB.surface).foregroundStyle(DB.text).preferredColorScheme(.dark)
        .onAppear { if form.isNew { numberFocused = true } }
        .confirmationDialog("Delete \(form.original?.title ?? "this card")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let o = form.original { try? session.mutate { $0.deleteCard(o.id) }; session.show("Card deleted") }
                dismiss()
            }
        } message: { Text("It is removed from all your devices.") }
    }

    private func secretField(_ prompt: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Group { if revealed { TextField(prompt, text: text) } else { SecureField(prompt, text: text) } }.font(.dbMono(12.5)).macField().frame(width: 160)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye").frame(width: 14) }
                .buttonStyle(MacButtonStyle()).help(revealed ? "Hide" : "Show")
        }
    }

    private func save() {
        do {
            let (title, detail) = try form.save(in: session)
            session.show(title, detail)
            dismiss()
        } catch { form.error = error.friendly }
    }
}

// MARK: identity form pieces

private let titleOptions = ["Mr", "Ms", "Mrs", "Mx", "Dr", "Prof"]

private let countryNames: [String] = Locale.Region.isoRegions
    .filter { $0.identifier.count == 2 }
    .compactMap { Locale.current.localizedString(forRegionCode: $0.identifier) }
    .sorted()

/// A small caption over a field, so related fields can sit side by side.
private struct Captioned<C: View>: View {
    let caption: String
    @ViewBuilder let content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.db(11.5)).foregroundStyle(DB.text3)
            content()
        }
    }
}

/// A titled group of fields.
private struct FormSection<C: View>: View {
    let title: String
    let symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> C
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(DB.brass).frame(width: 14)
                Text(title.uppercased()).font(.db(11, .semibold)).tracking(0.7).foregroundStyle(DB.text2)
                Spacer()
                trailing
            }
            content()
        }
    }
}

struct MacIdentitySheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: IdentityFormModel
    @State private var revealed = false
    @State private var showMore: Bool
    @State private var addressLines: Int
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    init(original: IdentityItem?) {
        let m = IdentityFormModel(original: original)
        _form = State(initialValue: m)
        _showMore = State(initialValue: m.hasMore)
        _addressLines = State(initialValue: m.draft.address3.isEmpty ? (m.draft.address2.isEmpty ? 0 : 1) : 2)
    }

    private var initials: String {
        let d = form.draft
        let letters = [d.firstName, d.lastName].compactMap { $0.trimmingCharacters(in: .whitespaces).first }.map { String($0).uppercased() }.joined()
        return letters.isEmpty ? String(d.title.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased() : letters
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    personal
                    contact
                    address
                    ids
                    more
                    if let error = form.error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
                }
                .padding(.horizontal, 24).padding(.vertical, 18)
            }
            .frame(maxHeight: 540)
            Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1)
            SheetFooter(missing: form.missing, deleteTitle: form.original == nil ? nil : "Delete Identity…",
                        delete: { confirmDelete = true }, save: save)
                .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 660)
        .font(.db(13)).background(DB.surface).foregroundStyle(DB.text).preferredColorScheme(.dark)
        .onAppear { if form.isNew { nameFocused = true } }
        .confirmationDialog("Delete \(form.original.map { $0.title.isEmpty ? $0.fullName : $0.title } ?? "this identity")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let o = form.original { try? session.mutate { $0.deleteIdentity(o.id) }; session.show("Identity deleted") }
                dismiss()
            }
        } message: { Text("It is removed from all your devices. Cards that used it as a billing address keep their own details.") }
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 14) {
            Text(initials.isEmpty ? "?" : initials).font(.db(16, .bold)).foregroundStyle(DB.brass)
                .frame(width: 44, height: 44).background(DB.brassWash, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name this identity", text: $form.draft.title)
                    .textFieldStyle(.plain).font(.db(18, .semibold)).focused($nameFocused)
                Text(form.draft.fullName.isEmpty ? "Home, Work, Passport… so you can tell identities apart" : form.draft.fullName)
                    .font(.db(12)).foregroundStyle(DB.text3).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var personal: some View {
        FormSection(title: "Personal", symbol: "person") {
            HStack(alignment: .bottom, spacing: 10) {
                Captioned(caption: "Title") {
                    Picker("", selection: $form.draft.salutation) {
                        Text("None").tag("")
                        ForEach(titleOptions, id: \.self) { Text($0).tag($0) }
                        if !form.draft.salutation.isEmpty && !titleOptions.contains(form.draft.salutation) {
                            Text(form.draft.salutation).tag(form.draft.salutation)
                        }
                    }.labelsHidden().frame(width: 84)
                }
                Captioned(caption: "First name") { TextField("", text: $form.draft.firstName).macField() }
                Captioned(caption: "Middle name") { TextField("", text: $form.draft.middleName).macField() }.frame(width: 140)
                Captioned(caption: "Last name") { TextField("", text: $form.draft.lastName).macField() }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Captioned(caption: "Company") { TextField("", text: $form.draft.company).macField() }
                Captioned(caption: "Username") { TextField("", text: $form.draft.username).macField() }
            }
        }
    }

    private var contact: some View {
        FormSection(title: "Contact", symbol: "envelope") {
            HStack(alignment: .bottom, spacing: 10) {
                Captioned(caption: "Email") { TextField("name@example.com", text: $form.draft.email).macField() }
                Captioned(caption: "Phone") { TextField("", text: $form.draft.phone).macField() }
            }
        }
    }

    private var address: some View {
        FormSection(title: "Address", symbol: "house") {
            Captioned(caption: "Street address") { TextField("", text: $form.draft.address1).macField() }
            if addressLines >= 1 { Captioned(caption: "Address line 2") { TextField("", text: $form.draft.address2).macField() } }
            if addressLines >= 2 { Captioned(caption: "Address line 3") { TextField("", text: $form.draft.address3).macField() } }
            if addressLines < 2 {
                Button { withAnimation(.snappy) { addressLines += 1 } } label: { Label("Add address line", systemImage: "plus").font(.db(12)) }
                    .buttonStyle(.plain).foregroundStyle(DB.brass)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Captioned(caption: "City") { TextField("", text: $form.draft.city).macField() }
                Captioned(caption: "State / region") { TextField("", text: $form.draft.state).macField() }
                Captioned(caption: "Postal code") { TextField("", text: $form.draft.postalCode).macField() }.frame(width: 130)
            }
            Captioned(caption: "Country") {
                HStack(spacing: 6) {
                    TextField("", text: $form.draft.country).macField()
                    Menu {
                        ForEach(countryNames, id: \.self) { n in Button(n) { form.draft.country = n } }
                    } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).frame(width: 14) }
                        .menuStyle(.button).fixedSize().help("Choose a country")
                }
            }
        }
    }

    private var ids: some View {
        FormSection(title: "ID numbers", symbol: "lock", trailing: AnyView(
            Button { revealed.toggle() } label: { Label(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye").font(.db(12)) }
                .buttonStyle(.plain).foregroundStyle(DB.text2)
        )) {
            HStack(alignment: .bottom, spacing: 10) {
                Captioned(caption: "SSN / national ID") { secret($form.draft.ssn) }
                Captioned(caption: "Passport number") { secret($form.draft.passportNumber) }
                Captioned(caption: "Licence number") { secret($form.draft.licenseNumber) }
            }
            Text("Hidden by default. Showing or copying them later asks for Touch ID.").font(.db(11.5)).foregroundStyle(DB.text3)
        }
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { showMore.toggle() } } label: {
                Label("More options", systemImage: showMore ? "chevron.down" : "chevron.right").font(.db(12))
            }
            .buttonStyle(.plain).foregroundStyle(DB.text3)
            if showMore {
                Captioned(caption: "Notes") {
                    TextField("", text: Binding(get: { form.draft.notes ?? "" }, set: { form.draft.notes = $0 }), axis: .vertical)
                        .lineLimit(3...6).macField()
                }
                Captioned(caption: "Label") {
                    TextField("Personal, Work…", text: Binding(get: { form.draft.label ?? "" }, set: { form.draft.label = $0 })).macField()
                }
                Captioned(caption: "Custom fields") { CustomFieldsEditor(fields: $form.draft.customFields.orEmpty) }
            }
        }
    }

    private func secret(_ text: Binding<String>) -> some View {
        Group { if revealed { TextField("", text: text) } else { SecureField("", text: text) } }
            .font(.dbMono(12.5)).macField()
    }

    private func save() {
        do {
            let (title, detail) = try form.save(in: session)
            session.show(title, detail)
            dismiss()
        } catch { form.error = error.friendly }
    }
}

struct MacNoteSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: NoteFormModel
    @State private var showMore: Bool
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    init(original: NoteItem?) {
        let m = NoteFormModel(original: original)
        _form = State(initialValue: m)
        _showMore = State(initialValue: !(m.draft.label ?? "").isEmpty || !(m.draft.customFields ?? []).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TypeTile(symbol: "note.text")
                Text(form.original.map { "Edit \($0.title)" } ?? "New Secure Note").font(.db(15, .semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                formRow("Title") { TextField("Wi-Fi, licence key…", text: $form.draft.title).macField().focused($titleFocused) }
                formRow("Text") {
                    TextEditor(text: $form.draft.body)
                        .font(.db(13)).scrollContentBackground(.hidden)
                        .padding(5).frame(height: 170)
                        .background(Color(hex: 0x0F1014), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DB.lineStrong))
                }
                MoreToggle(open: $showMore)
                if showMore {
                    formRow("Custom fields") { CustomFieldsEditor(fields: $form.draft.customFields.orEmpty) }
                    formRow("Label") { TextField("Personal, Work…", text: Binding(get: { form.draft.label ?? "" }, set: { form.draft.label = $0 })).macField() }
                }
            }
            if let error = form.error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
            SheetFooter(missing: form.missing, deleteTitle: form.original == nil ? nil : "Delete Note…",
                        delete: { confirmDelete = true }, save: save)
        }
        .padding(20).frame(width: 520)
        .font(.db(13)).background(DB.surface).foregroundStyle(DB.text).preferredColorScheme(.dark)
        .onAppear { if form.isNew { titleFocused = true } }
        .confirmationDialog("Delete \(form.original?.title ?? "this note")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let o = form.original { try? session.mutate { $0.deleteNote(o.id) }; session.show("Note deleted") }
                dismiss()
            }
        } message: { Text("It is removed from all your devices.") }
    }

    private func save() {
        do {
            let (title, detail) = try form.save(in: session)
            session.show(title, detail)
            dismiss()
        } catch { form.error = error.friendly }
    }
}
#endif
