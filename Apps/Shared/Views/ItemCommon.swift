import DeadboltCore
import SwiftUI

// Pieces of the card / identity / secure-note screens that are the same on iPhone and Mac.

enum ItemKind: Hashable {
    case card, identity, note

    var noun: String { switch self { case .card: "card"; case .identity: "identity"; case .note: "note" } }
    var symbol: String { switch self { case .card: "creditcard"; case .identity: "person.text.rectangle"; case .note: "note.text" } }
}

/// Navigation value for a pushed card / identity / note screen (iPhone).
struct ItemRef: Hashable { let kind: ItemKind; let id: UUID }

/// Which editor to show: a new item of a kind, or an existing one.
enum ItemSheet: Identifiable, Equatable {
    case card(UUID?), identity(UUID?), note(UUID?)
    var id: String {
        switch self {
        case .card(let i): "card-\(i?.uuidString ?? "new")"
        case .identity(let i): "identity-\(i?.uuidString ?? "new")"
        case .note(let i): "note-\(i?.uuidString ?? "new")"
        }
    }
}

struct PendingDelete: Equatable { let kind: ItemKind; let id: UUID; let title: String }

/// The little square in front of a row or header, like `SiteTile` but for things that aren't websites.
struct TypeTile: View {
    let symbol: String
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(DB.brass)
            .frame(width: size, height: size)
            .background(DB.control, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One row of a detail screen. `secret` rows are masked and every show / copy of them needs `VaultSession.confirmOwner`.
struct FieldSpec {
    var label: String
    var value: String
    var secret = false
    /// What to say in the Touch ID / Face ID prompt and toast: "card number", "security code"…
    var what: String? = nil
    var mono = false
    var masked: String? = nil        // shown instead of bullets while hidden ("•••• 4242")
    var shown: String? = nil         // shown when revealed, if different from `value` (the number in groups)
    var copy: String? = nil          // what the copy button copies, if different from `value`
    var multiline = false
}

func customFieldSpecs(_ fields: [CustomField]?) -> [FieldSpec] {
    (fields ?? []).map { f in FieldSpec(label: f.name, value: f.value, secret: f.hidden, what: f.name.lowercased(), mono: f.hidden) }
}

extension CardItem {
    var fieldSpecs: [FieldSpec] {
        var s: [FieldSpec] = []
        if !cardholderName.isEmpty { s.append(FieldSpec(label: "Cardholder", value: cardholderName)) }
        if !number.isEmpty {
            s.append(FieldSpec(label: "Number", value: number, secret: true, what: "card number", mono: true,
                               masked: "•••• •••• •••• \(last4)", shown: formattedNumber, copy: number))
        }
        if let e = expiry, let m = expMonth, let y = expYear {
            s.append(FieldSpec(label: "Expires", value: e, mono: true, copy: String(format: "%02d/%02d", m, y % 100)))
        }
        if !securityCode.isEmpty { s.append(FieldSpec(label: "Security code", value: securityCode, secret: true, what: "security code", mono: true)) }
        if !pin.isEmpty { s.append(FieldSpec(label: "PIN", value: pin, secret: true, what: "PIN", mono: true)) }
        s.append(FieldSpec(label: "Brand", value: resolvedBrand.displayName))
        return s
    }
}

extension IdentityItem {
    /// Name, contact, address and ID numbers, each its own group; empty fields and empty groups are left out.
    var specGroups: [[FieldSpec]] {
        func plain(_ pairs: [(String, String)]) -> [FieldSpec] { pairs.filter { !$0.1.isEmpty }.map { FieldSpec(label: $0.0, value: $0.1) } }
        let ids = [("SSN / national ID", ssn, "national ID number"), ("Passport number", passportNumber, "passport number"),
                   ("Licence number", licenseNumber, "licence number")]
            .filter { !$0.1.isEmpty }.map { FieldSpec(label: $0.0, value: $0.1, secret: true, what: $0.2, mono: true) }
        return [
            plain([("Title", salutation), ("First name", firstName), ("Middle name", middleName), ("Last name", lastName),
                   ("Company", company), ("Username", username)]),
            plain([("Email", email), ("Phone", phone)]),
            plain([("Address 1", address1), ("Address 2", address2), ("Address 3", address3), ("City", city),
                   ("State / region", state), ("Postal code", postalCode), ("Country", country)]),
            ids,
            customFieldSpecs(customFields),
        ].filter { !$0.isEmpty }
    }
}

extension NoteItem {
    var fieldSpecs: [FieldSpec] {
        [FieldSpec(label: "Text", value: body, secret: true, what: "note text", masked: "Hidden. Press the eye to read it.", multiline: true)]
    }
}

// MARK: - copy menus (context menus on both platforms, ⋯ menu on the Mac)

struct CardMenu: View {
    @Environment(VaultSession.self) private var session
    let card: CardItem
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        if !card.number.isEmpty {
            Button { session.copyProtected(card.number, what: "card number", used: card.id) } label: { Label("Copy Card Number", systemImage: "creditcard") }
        }
        if !card.securityCode.isEmpty {
            Button { session.copyProtected(card.securityCode, what: "security code", used: card.id) } label: { Label("Copy Security Code", systemImage: "lock") }
        }
        if !card.cardholderName.isEmpty {
            Button { Clipboard.copySecret(card.cardholderName); try? session.mutate { $0.markItemUsed(card.id) }; session.show("Name copied") } label: { Label("Copy Cardholder Name", systemImage: "person") }
        }
        if let m = card.expMonth, let y = card.expYear {
            Menu {
                Button("MM/YY  (\(String(format: "%02d/%02d", m, y % 100)))") { Clipboard.copySecret(String(format: "%02d/%02d", m, y % 100)); session.show("Expiry copied") }
                Button("MM/YYYY  (\(String(format: "%02d/%04d", m, y)))") { Clipboard.copySecret(String(format: "%02d/%04d", m, y)); session.show("Expiry copied") }
                Button("Month  (\(String(format: "%02d", m)))") { Clipboard.copySecret(String(format: "%02d", m)); session.show("Month copied") }
                Button("Year  (\(y))") { Clipboard.copySecret(String(y)); session.show("Year copied") }
            } label: { Label("Copy Expiry", systemImage: "calendar") }
        }
        Divider()
        Button(action: edit) { Label("Edit…", systemImage: "pencil") }
        Button(role: .destructive, action: delete) { Label("Delete…", systemImage: "trash") }
    }
}

struct IdentityMenu: View {
    @Environment(VaultSession.self) private var session
    let identity: IdentityItem
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        if !identity.fullName.isEmpty { plain("Copy Full Name", "person", identity.fullName, "Name copied") }
        if !identity.email.isEmpty { plain("Copy Email", "envelope", identity.email, "Email copied") }
        if !identity.phone.isEmpty { plain("Copy Phone", "phone", identity.phone, "Phone copied") }
        if !identity.addressLines.isEmpty { plain("Copy Address", "house", identity.addressLines.joined(separator: "\n"), "Address copied") }
        if !identity.ssn.isEmpty {
            Button { session.copyProtected(identity.ssn, what: "national ID number", used: identity.id) } label: { Label("Copy SSN / National ID", systemImage: "lock") }
        }
        if !identity.passportNumber.isEmpty {
            Button { session.copyProtected(identity.passportNumber, what: "passport number", used: identity.id) } label: { Label("Copy Passport Number", systemImage: "lock") }
        }
        if !identity.licenseNumber.isEmpty {
            Button { session.copyProtected(identity.licenseNumber, what: "licence number", used: identity.id) } label: { Label("Copy Licence Number", systemImage: "lock") }
        }
        Divider()
        Button(action: edit) { Label("Edit…", systemImage: "pencil") }
        Button(role: .destructive, action: delete) { Label("Delete…", systemImage: "trash") }
    }

    private func plain(_ title: String, _ icon: String, _ text: String, _ toast: String) -> some View {
        Button { Clipboard.copySecret(text); try? session.mutate { $0.markItemUsed(identity.id) }; session.show(toast) } label: { Label(title, systemImage: icon) }
    }
}

struct NoteMenu: View {
    @Environment(VaultSession.self) private var session
    let note: NoteItem
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        if !note.body.isEmpty {
            Button { session.copyProtected(note.body, what: "note text") } label: { Label("Copy Text", systemImage: "doc.on.doc") }
        }
        Divider()
        Button(action: edit) { Label("Edit…", systemImage: "pencil") }
        Button(role: .destructive, action: delete) { Label("Delete…", systemImage: "trash") }
    }
}

// MARK: - list row

struct TypedItemRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var expired = false

    var body: some View {
        HStack(spacing: 14) {
            TypeTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.db(14.5, .semibold)).foregroundStyle(DB.text).lineLimit(1)
                Text(subtitle).font(.db(12.5)).foregroundStyle(DB.text2).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if expired { Text("Expired").font(.db(11.5, .semibold)).foregroundStyle(DB.danger) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

extension CardItem {
    var rowSubtitle: String { [maskedSummary, expiry].compactMap { $0 }.joined(separator: " · ") }
}
extension IdentityItem {
    var shownTitle: String { title.isEmpty ? fullName : title }
    var rowSubtitle: String { [fullName, email].first { !$0.isEmpty && $0 != title } ?? "Identity" }
}
extension NoteItem {
    var rowSubtitle: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? "Secure note" }
}

