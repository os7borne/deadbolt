import DeadboltCore
import SwiftUI

#if os(iOS)

// iPhone screens for cards, identities and secure notes. Same rules as the Mac: secrets are masked, and showing, copying or
// opening an existing item for editing needs a fresh Face ID check (or the master password): `VaultSession.confirmOwner`.
// iOS has no system AutoFill for cards or identities, so these screens are about copying fast: every field is one tap.

// MARK: - detail pieces

/// A card of detail rows. Plain rows copy at once; secret rows are masked and each show / copy asks first.
struct ItemFields: View {
    let specs: [FieldSpec]
    var body: some View {
        if !specs.isEmpty {
            Card {
                ForEach(Array(specs.enumerated()), id: \.offset) { i, s in
                    if i > 0 { CardDivider() }
                    ItemFieldRow(spec: s)
                }
            }
        }
    }
}

private struct RoundFace: View {
    let name: String
    var done = false
    var prominent = false
    var body: some View {
        Image.tick(name, done: done).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(done ? DB.good : (prominent ? DB.onBrass : DB.text))
            .frame(width: 38, height: 38)
            .background(done ? DB.goodWash : (prominent ? DB.brass : DB.control), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ItemFieldRow: View {
    @Environment(VaultSession.self) private var session
    let spec: FieldSpec
    @State private var shown = false
    @State private var copied = false
    @State private var hideTask: Task<Void, Never>?

    private var what: String { spec.what ?? spec.label.lowercased() }

    private var display: String {
        guard spec.secret else { return spec.value }
        return shown ? (spec.shown ?? spec.value) : (spec.masked ?? String(repeating: "•", count: max(6, min(spec.value.count, 14))))
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(spec.label).font(.db(12)).foregroundStyle(DB.text3)
                Text(display).font(spec.mono || (spec.secret && !shown) ? .dbMono(15) : .db(15))
                    .lineLimit(spec.multiline ? (shown ? nil : 3) : 2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if spec.secret {
                Button { toggle() } label: { RoundFace(name: shown ? "eye.slash" : "eye") }
                    .buttonStyle(.plain).accessibilityLabel(shown ? "Hide \(what)" : "Show \(what)")
                Button { copySecret() } label: { RoundFace(name: "doc.on.doc", done: copied, prominent: true) }
                    .buttonStyle(.plain).accessibilityLabel("Copy \(what)")
            } else {
                IconButton(systemName: "doc.on.doc", label: "Copy \(spec.label)") { Clipboard.copySecret(spec.copy ?? spec.value) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
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

    private func copySecret() {
        Task {
            guard await session.confirmOwner("Copy \(what)") else { return }
            Clipboard.copySecret(spec.copy ?? spec.value, clearAfter: Clipboard.sensitiveClearAfter)
            Haptics.success()
            withAnimation(.snappy(duration: 0.2)) { copied = true }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy(duration: 0.2)) { copied = false }
        }
    }
}

/// Header, content, Edit and Delete shared by the three detail screens.
private struct ItemScaffold<Content: View, Editor: View>: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let kind: ItemKind
    let title: String
    let subtitle: String
    let performDelete: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let editor: () -> Editor
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    TypeTile(symbol: kind.symbol, size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.db(22, .bold))
                        Text(subtitle).font(.db(12.5)).foregroundStyle(DB.text2)
                    }
                }
                .padding(.bottom, 8)
                content()
                Button("Delete \(kind.noun)", role: .destructive) { confirmDelete = true }
                    .font(.db(14.5)).foregroundStyle(DB.danger).frame(maxWidth: .infinity).padding(.top, 10)
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The editor shows the secrets, so it asks first, just like Show.
                Button("Edit") { Task { if await session.confirmOwner("Edit this \(kind.noun)") { editing = true } } }
            }
        }
        .sheet(isPresented: $editing) { editor() }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { performDelete(); dismiss() }
        } message: { Text("It is removed from all your devices.") }
    }
}

private struct LabelAndNotes: View {
    let label: String?
    let notes: String?
    var body: some View {
        if let l = label, !l.isEmpty { ItemFields(specs: [FieldSpec(label: "Label", value: l)]) }
        if let n = notes, !n.isEmpty {
            Card { Text(n).font(.db(13.5)).foregroundStyle(DB.text2).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
        }
    }
}

private struct Gone: View {
    let noun: String
    var body: some View {
        Text("This \(noun) was deleted.").foregroundStyle(DB.text2).frame(maxWidth: .infinity, maxHeight: .infinity).background(DB.ground)
    }
}

// MARK: - detail screens

struct CardDetailView: View {
    @Environment(VaultSession.self) private var session
    let id: UUID

    var body: some View {
        if let card = session.vault.card(id) {
            ItemScaffold(kind: .card, title: card.title,
                         subtitle: "\(card.maskedSummary) · edited \(card.updatedAt.formatted(.relative(presentation: .named)))",
                         performDelete: { try? session.mutate { $0.deleteCard(id) }; session.show("Card deleted") }) {
                if card.isExpired() {
                    Label("This card expired on \(card.expiry ?? "").", systemImage: "exclamationmark.triangle").font(.db(12.5)).foregroundStyle(DB.danger)
                }
                if !card.number.isEmpty, !card.passesLuhn {
                    Label("The number doesn’t pass the card check digit. It may have a typo.", systemImage: "exclamationmark.circle")
                        .font(.db(12.5)).foregroundStyle(DB.brass)
                }
                ItemFields(specs: card.fieldSpecs)
                if let wid = card.identityID, let who = session.vault.identity(wid) {
                    NavigationLink(value: ItemRef(kind: .identity, id: wid)) {
                        HStack {
                            Text("Billing address").font(.db(14.5))
                            Spacer()
                            Text(who.shownTitle).font(.db(13.5)).foregroundStyle(DB.text2).lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 46).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DB.line))
                }
                ItemFields(specs: customFieldSpecs(card.customFields))
                LabelAndNotes(label: card.label, notes: card.notes)
            } editor: { EditCardView(original: card) }
        } else { Gone(noun: "card") }
    }
}

struct IdentityDetailView: View {
    @Environment(VaultSession.self) private var session
    let id: UUID

    var body: some View {
        if let who = session.vault.identity(id) {
            ItemScaffold(kind: .identity, title: who.shownTitle,
                         subtitle: "\([who.fullName, who.company].filter { !$0.isEmpty && $0 != who.title }.joined(separator: " · ")) · edited \(who.updatedAt.formatted(.relative(presentation: .named)))",
                         performDelete: { try? session.mutate { $0.deleteIdentity(id) }; session.show("Identity deleted") }) {
                ForEach(Array(who.specGroups.enumerated()), id: \.offset) { _, g in ItemFields(specs: g) }
                LabelAndNotes(label: who.label, notes: who.notes)
            } editor: { EditIdentityView(original: who) }
        } else { Gone(noun: "identity") }
    }
}

struct NoteDetailView: View {
    @Environment(VaultSession.self) private var session
    let id: UUID

    var body: some View {
        if let note = session.vault.note(id) {
            ItemScaffold(kind: .note, title: note.title, subtitle: "Secure note · edited \(note.updatedAt.formatted(.relative(presentation: .named)))",
                         performDelete: { try? session.mutate { $0.deleteNote(id) }; session.show("Note deleted") }) {
                ItemFields(specs: note.fieldSpecs)
                ItemFields(specs: customFieldSpecs(note.customFields))
                LabelAndNotes(label: note.label, notes: nil)
            } editor: { EditNoteView(original: note) }
        } else { Gone(noun: "note") }
    }
}

/// Destination for `ItemRef`.
struct ItemDestination: View {
    let ref: ItemRef
    var body: some View {
        switch ref.kind {
        case .card: CardDetailView(id: ref.id)
        case .identity: IdentityDetailView(id: ref.id)
        case .note: NoteDetailView(id: ref.id)
        }
    }
}

/// The editor for an `ItemSheet`.
struct ItemEditor: View {
    @Environment(VaultSession.self) private var session
    let sheet: ItemSheet
    var body: some View {
        switch sheet {
        case .card(let id): EditCardView(original: id.flatMap { session.vault.card($0) })
        case .identity(let id): EditIdentityView(original: id.flatMap { session.vault.identity($0) })
        case .note(let id): EditNoteView(original: id.flatMap { session.vault.note($0) })
        }
    }
}

// MARK: - forms

private func formRow<C: View>(_ title: String, top: Bool = false, width: CGFloat = 96, @ViewBuilder _ content: () -> C) -> some View {
    HStack(alignment: top ? .firstTextBaseline : .center, spacing: 12) {
        Text(title).font(.db(15)).foregroundStyle(DB.text2).frame(width: width, alignment: .leading)
        content().font(.db(16))
    }
    .padding(.horizontal, 16).padding(.vertical, top ? 14 : 0).frame(minHeight: 52)
}

private struct MoreOptionsHeader: View {
    @Binding var open: Bool
    var body: some View {
        Button { withAnimation(.snappy) { open.toggle() } } label: {
            HStack(spacing: 6) {
                Text("MORE OPTIONS").font(.db(13, .semibold)).tracking(0.8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(open ? 0 : -90))
            }
            .foregroundStyle(DB.text3).padding(.leading, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Name / value / hide rows for any item.
struct ItemCustomFields: View {
    @Binding var fields: [CustomField]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CUSTOM FIELDS").font(.db(12, .semibold)).tracking(0.8).foregroundStyle(DB.text3).padding(.leading, 4)
            ForEach($fields) { $f in
                Card {
                    TextField("Name, like Account ID", text: $f.name).font(.db(15, .semibold)).padding(.horizontal, 16).frame(minHeight: 48)
                    CardDivider()
                    Group { if f.hidden { SecureField("Value", text: $f.value) } else { TextField("Value", text: $f.value) } }
                        .font(.db(16)).padding(.horizontal, 16).frame(minHeight: 48)
                    CardDivider()
                    HStack {
                        Toggle("Hide the value", isOn: $f.hidden).font(.db(14)).tint(DB.brass)
                        Button(role: .destructive) { fields.removeAll { $0.id == f.id } } label: {
                            Image(systemName: "trash").foregroundStyle(DB.danger).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Remove field")
                    }
                    .padding(.leading, 16).frame(minHeight: 48)
                }
            }
            Button { fields.append(CustomField()) } label: {
                Label("Add field", systemImage: "plus").font(.db(15, .semibold)).foregroundStyle(DB.brass)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(minHeight: 48)
                    .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private extension Binding where Value == [CustomField]? {
    var orEmpty: Binding<[CustomField]> { Binding<[CustomField]>(get: { wrappedValue ?? [] }, set: { wrappedValue = $0 }) }
}

private func optionalText(_ b: Binding<String?>) -> Binding<String> { Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0 }) }

struct EditCardView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: CardFormModel
    @State private var revealed: Bool
    @State private var showMore: Bool
    @FocusState private var numberFocused: Bool

    init(original: CardItem?) {
        let m = CardFormModel(original: original)
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
                            formRow("Name") { TextField("Travel card", text: $form.title).textInputAutocapitalization(.words) }
                            CardDivider()
                            formRow("Cardholder") { TextField("Name on the card", text: $form.cardholder).textInputAutocapitalization(.characters) }
                            CardDivider()
                            formRow("Number") {
                                TextField("1234 5678 9012 3456", text: $form.number).font(.dbMono(16)).keyboardType(.numberPad)
                                    .focused($numberFocused)
                            }
                            CardDivider()
                            formRow("Brand") {
                                Picker("Brand", selection: $form.brand) {
                                    Text("Detect automatically" + (form.brand == nil ? (form.shownBrand.map { " (\($0.displayName))" } ?? "") : "")).tag(CardBrand?.none)
                                    ForEach(CardBrand.allCases, id: \.self) { Text($0.displayName).tag(CardBrand?.some($0)) }
                                }
                                .pickerStyle(.menu).labelsHidden().tint(DB.text)
                                Spacer(minLength: 0)
                            }
                            CardDivider()
                            formRow("Expires") {
                                Picker("Month", selection: $form.month) {
                                    Text("Month").tag(Int?.none)
                                    ForEach(1...12, id: \.self) { Text(String(format: "%02d", $0)).tag(Int?.some($0)) }
                                }
                                .pickerStyle(.menu).labelsHidden().tint(DB.text)
                                TextField("Year", text: $form.year).keyboardType(.numberPad).frame(maxWidth: 90)
                                Spacer(minLength: 0)
                            }
                        }
                        if let h = form.numberHint {
                            Label(h.text, systemImage: h.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .font(.db(13)).foregroundStyle(h.ok ? DB.text3 : DB.brass).padding(.leading, 4)
                        }
                    }

                    Card {
                        formRow("Security code") {
                            secret("3 or 4 digits", $form.code, keyboard: .numberPad)
                        }
                        CardDivider()
                        formRow("PIN") { secret("Optional", $form.pin, keyboard: .numberPad) }
                        CardDivider()
                        formRow("Billing address") {
                            Picker("Billing address", selection: $form.identityID) {
                                Text("None").tag(UUID?.none)
                                ForEach(session.vault.identities) { Text($0.shownTitle).tag(UUID?.some($0.id)) }
                            }
                            .pickerStyle(.menu).labelsHidden().tint(DB.text)
                            Spacer(minLength: 0)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MoreOptionsHeader(open: $showMore)
                        if showMore {
                            ItemCustomFields(fields: $form.customFields)
                            Card {
                                formRow("Label") { TextField("Personal, Work…", text: $form.label) }
                                CardDivider()
                                formRow("Notes", top: true) { TextField("Anything else", text: $form.notes, axis: .vertical).lineLimit(2...6) }
                            }
                        }
                    }

                    if let m = form.missing, !form.digits.isEmpty { Text(m).font(.db(13)).foregroundStyle(DB.text3).padding(.leading, 4) }
                    if let error = form.error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DB.ground).foregroundStyle(DB.text)
            .autocorrectionDisabled()
            .navigationTitle(form.isNew ? "New card" : "Edit card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(form.missing != nil) }
            }
            .onAppear { if form.isNew { numberFocused = true } }
        }
        .presentationBackground(DB.ground)
    }

    private func secret(_ prompt: String, _ text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 8) {
            Group { if revealed { TextField(prompt, text: text) } else { SecureField(prompt, text: text) } }
                .font(.dbMono(16)).keyboardType(keyboard)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .foregroundStyle(DB.text2).accessibilityLabel(revealed ? "Hide" : "Show")
        }
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

struct EditIdentityView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: IdentityFormModel
    @State private var revealed = false
    @State private var showMore: Bool
    @FocusState private var nameFocused: Bool

    init(original: IdentityItem?) {
        let m = IdentityFormModel(original: original)
        _form = State(initialValue: m)
        _showMore = State(initialValue: m.hasMore)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Name") {
                        formRow("Name", width: 110) { TextField("Home, Work, Passport…", text: $form.draft.title).textInputAutocapitalization(.words).focused($nameFocused) }
                        CardDivider()
                        formRow("Title", width: 110) { TextField("Mr, Ms, Dr…", text: $form.draft.salutation).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("First name", width: 110) { TextField("", text: $form.draft.firstName).textContentType(.givenName).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Middle name", width: 110) { TextField("", text: $form.draft.middleName).textContentType(.middleName).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Last name", width: 110) { TextField("", text: $form.draft.lastName).textContentType(.familyName).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Company", width: 110) { TextField("", text: $form.draft.company).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Username", width: 110) { TextField("", text: $form.draft.username).textInputAutocapitalization(.never) }
                    }
                    section("Contact") {
                        formRow("Email", width: 110) { TextField("", text: $form.draft.email).keyboardType(.emailAddress).textInputAutocapitalization(.never) }
                        CardDivider()
                        formRow("Phone", width: 110) { TextField("", text: $form.draft.phone).keyboardType(.phonePad) }
                    }
                    section("Address") {
                        formRow("Address 1", width: 110) { TextField("", text: $form.draft.address1).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Address 2", width: 110) { TextField("", text: $form.draft.address2).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Address 3", width: 110) { TextField("", text: $form.draft.address3).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("City", width: 110) { TextField("", text: $form.draft.city).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("State / region", width: 110) { TextField("", text: $form.draft.state).textInputAutocapitalization(.words) }
                        CardDivider()
                        formRow("Postal code", width: 110) { TextField("", text: $form.draft.postalCode).textInputAutocapitalization(.characters) }
                        CardDivider()
                        formRow("Country", width: 110) { TextField("", text: $form.draft.country).textInputAutocapitalization(.words) }
                    }
                    section("ID numbers") {
                        formRow("National ID", width: 110) { secret($form.draft.ssn) }
                        CardDivider()
                        formRow("Passport", width: 110) { secret($form.draft.passportNumber) }
                        CardDivider()
                        formRow("Licence", width: 110) { secret($form.draft.licenseNumber) }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        MoreOptionsHeader(open: $showMore)
                        if showMore {
                            ItemCustomFields(fields: $form.draft.customFields.orEmpty)
                            Card {
                                formRow("Label") { TextField("Personal, Work…", text: optionalText($form.draft.label)) }
                                CardDivider()
                                formRow("Notes", top: true) { TextField("Anything else", text: optionalText($form.draft.notes), axis: .vertical).lineLimit(2...6) }
                            }
                        }
                    }

                    if let m = form.missing { Text(m).font(.db(13)).foregroundStyle(DB.text3).padding(.leading, 4) }
                    if let error = form.error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DB.ground).foregroundStyle(DB.text)
            .autocorrectionDisabled()
            .navigationTitle(form.isNew ? "New identity" : "Edit identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(form.missing != nil) }
            }
            .onAppear { if form.isNew { nameFocused = true } }
        }
        .presentationBackground(DB.ground)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            Card { rows() }
        }
    }

    private func secret(_ text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Group { if revealed { TextField("", text: text) } else { SecureField("", text: text) } }
                .font(.dbMono(16)).textInputAutocapitalization(.characters)
            Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                .foregroundStyle(DB.text2).accessibilityLabel(revealed ? "Hide" : "Show")
        }
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

struct EditNoteView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form: NoteFormModel
    @State private var showMore: Bool
    @FocusState private var titleFocused: Bool

    init(original: NoteItem?) {
        let m = NoteFormModel(original: original)
        _form = State(initialValue: m)
        _showMore = State(initialValue: !(m.draft.label ?? "").isEmpty || !(m.draft.customFields ?? []).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Card {
                        formRow("Title") { TextField("Wi-Fi, licence key…", text: $form.draft.title).textInputAutocapitalization(.sentences).focused($titleFocused) }
                        CardDivider()
                        TextEditor(text: $form.draft.body)
                            .font(.db(16)).scrollContentBackground(.hidden)
                            .frame(minHeight: 220).padding(.horizontal, 11).padding(.vertical, 8)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        MoreOptionsHeader(open: $showMore)
                        if showMore {
                            ItemCustomFields(fields: $form.draft.customFields.orEmpty)
                            Card { formRow("Label") { TextField("Personal, Work…", text: optionalText($form.draft.label)) } }
                        }
                    }
                    if let error = form.error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(DB.ground).foregroundStyle(DB.text)
            .navigationTitle(form.isNew ? "New secure note" : "Edit secure note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold().disabled(form.missing != nil) }
            }
            .onAppear { if form.isNew { titleFocused = true } }
        }
        .presentationBackground(DB.ground)
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
#else
// The Mac window has its own screens (MacItemViews.swift); these keep the shared iPhone list compiling there.
struct ItemDestination: View { let ref: ItemRef; var body: some View { EmptyView() } }
struct ItemEditor: View { let sheet: ItemSheet; var body: some View { EmptyView() } }
#endif
