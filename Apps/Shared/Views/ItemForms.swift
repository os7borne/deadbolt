import DeadboltCore
import SwiftUI

// MARK: - form models for cards, identities and secure notes (shared by the Mac sheets and the iPhone forms)

/// Custom fields worth keeping: a field with neither a name nor a value is just an empty row.
func cleanedCustomFields(_ fields: [CustomField]) -> [CustomField]? {
    let kept = fields.compactMap { f -> CustomField? in
        let name = f.name.trimmingCharacters(in: .whitespaces)
        guard !(name.isEmpty && f.value.isEmpty) else { return nil }
        var c = f; c.name = name.isEmpty ? "Field" : name; return c
    }
    return kept.isEmpty ? nil : kept
}

private func blankToNil(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

@MainActor @Observable
final class CardFormModel {
    let original: CardItem?
    var title: String
    var cardholder: String
    var number: String
    /// nil = work it out from the number.
    var brand: CardBrand?
    var month: Int?
    var year: String
    var code: String
    var pin: String
    var identityID: UUID?
    var label: String
    var notes: String
    var customFields: [CustomField]
    var error: String?

    init(original: CardItem?) {
        self.original = original
        title = original?.title ?? ""
        cardholder = original?.cardholderName ?? ""
        number = original.map { $0.number.isEmpty ? "" : $0.formattedNumber } ?? ""
        brand = original?.brand
        month = original?.expMonth
        year = original?.expYear.map(String.init) ?? ""
        code = original?.securityCode ?? ""
        pin = original?.pin ?? ""
        identityID = original?.identityID
        label = original?.label ?? ""
        notes = original?.notes ?? ""
        customFields = original?.customFields ?? []
    }

    var isNew: Bool { original == nil }
    var digits: String { CardItem.normalizedNumber(number) }
    var shownBrand: CardBrand? { brand ?? CardBrand.detect(digits) }
    var hasMore: Bool { !label.isEmpty || !notes.isEmpty || !customFields.isEmpty }

    /// The expiry year as four digits, or nil when empty or not a year.
    var yearValue: Int? {
        let t = year.trimmingCharacters(in: .whitespaces)
        guard let y = Int(t), t.count == 2 || t.count == 4 else { return nil }
        let full = CardItem.fullYear(y)
        return (2000...2100).contains(full) ? full : nil
    }

    /// A gentle note under the number: the brand, or a warning that the check digit doesn't fit. Never blocks saving.
    var numberHint: (text: String, ok: Bool)? {
        guard !digits.isEmpty else { return nil }
        let probe = CardItem(number: digits)
        if digits.count >= 12, !probe.passesLuhn { return ("This number doesn’t pass the card check digit. Double-check it for typos.", false) }
        return shownBrand.map { ($0.displayName, true) }
    }

    /// The first thing still missing, said plainly; nil when it can be saved.
    var missing: String? {
        if digits.isEmpty { return "Add the card number" }
        if digits.count < 12 || digits.count > 19 { return "A card number has 12 to 19 digits" }
        let yearText = year.trimmingCharacters(in: .whitespaces)
        if !yearText.isEmpty && yearValue == nil { return "Enter the expiry year like 2028" }
        if (month == nil) != yearText.isEmpty { return "Add both the month and the year of expiry, or neither" }
        return nil
    }

    func save(in session: VaultSession) throws -> (String, String?) {
        var item = original ?? CardItem()
        item.number = digits
        item.brand = brand
        item.cardholderName = cardholder.trimmingCharacters(in: .whitespaces)
        item.expMonth = month
        item.expYear = yearValue
        item.securityCode = code.trimmingCharacters(in: .whitespaces)
        item.pin = pin.trimmingCharacters(in: .whitespaces)
        item.identityID = identityID
        item.label = blankToNil(label)
        item.notes = blankToNil(notes)
        item.customFields = cleanedCustomFields(customFields)
        let typed = title.trimmingCharacters(in: .whitespaces)
        item.title = typed.isEmpty ? "\(item.resolvedBrand.displayName) \(item.last4)" : typed
        item.lastUsedAt = session.vault.card(item.id)?.lastUsedAt ?? item.lastUsedAt   // a use while this form was open must survive
        try session.mutate { $0.upsert(item) }
        return (original == nil ? "Card saved" : "Saved", nil)
    }
}

@MainActor @Observable
final class IdentityFormModel {
    let original: IdentityItem?
    var draft: IdentityItem
    var error: String?

    init(original: IdentityItem?) {
        self.original = original
        draft = original ?? IdentityItem()
    }

    var isNew: Bool { original == nil }
    var hasMore: Bool { !(draft.label ?? "").isEmpty || !(draft.notes ?? "").isEmpty || !(draft.customFields ?? []).isEmpty }

    var missing: String? {
        draft.title.trimmingCharacters(in: .whitespaces).isEmpty && draft.fullName.isEmpty ? "Add a name for this identity" : nil
    }

    func save(in session: VaultSession) throws -> (String, String?) {
        var item = draft
        let typed = item.title.trimmingCharacters(in: .whitespaces)
        item.title = typed.isEmpty ? item.fullName : typed
        item.label = blankToNil(item.label ?? "")
        item.notes = blankToNil(item.notes ?? "")
        item.customFields = cleanedCustomFields(item.customFields ?? [])
        item.lastUsedAt = session.vault.identity(item.id)?.lastUsedAt ?? item.lastUsedAt
        try session.mutate { $0.upsert(item) }
        return (original == nil ? "Identity saved" : "Saved", nil)
    }
}

@MainActor @Observable
final class NoteFormModel {
    let original: NoteItem?
    var draft: NoteItem
    var error: String?

    init(original: NoteItem?) {
        self.original = original
        draft = original ?? NoteItem()
    }

    var isNew: Bool { original == nil }
    var missing: String? { draft.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Add a title" : nil }

    func save(in session: VaultSession) throws -> (String, String?) {
        var item = draft
        item.title = item.title.trimmingCharacters(in: .whitespaces)
        item.label = blankToNil(item.label ?? "")
        item.customFields = cleanedCustomFields(item.customFields ?? [])
        try session.mutate { $0.upsert(item) }
        return (original == nil ? "Note saved" : "Saved", nil)
    }
}
