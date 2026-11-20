import Foundation

/// One thing a person can copy from a card, identity or note, and whether it is a secret.
/// Used by the browser bridge: the extension is told which fields exist (never their values), and asks the Mac app to
/// copy one by key. Secret fields need a fresh Touch ID check on the Mac first.
public struct CopyField: Equatable, Sendable {
    public let key: String
    public let label: String
    public let secret: Bool
    public let value: String

    init(_ key: String, _ label: String, _ value: String, secret: Bool = false) {
        self.key = key; self.label = label; self.value = value; self.secret = secret
    }
}

extension CardItem {
    /// Only fields that have a value, so a menu never offers an empty copy. The number and codes are secret.
    public var copyFields: [CopyField] {
        var f: [CopyField] = []
        if !number.isEmpty { f.append(CopyField("number", "Card number", number, secret: true)) }
        if !securityCode.isEmpty { f.append(CopyField("code", "Security code", securityCode, secret: true)) }
        if !pin.isEmpty { f.append(CopyField("pin", "PIN", pin, secret: true)) }
        if !cardholderName.isEmpty { f.append(CopyField("holder", "Cardholder name", cardholderName)) }
        if let m = expMonth, let y = expYear {
            f.append(CopyField("expiry", "Expiry (MM/YY)", String(format: "%02d/%02d", m, y % 100)))
            f.append(CopyField("expiryLong", "Expiry (MM/YYYY)", String(format: "%02d/%04d", m, y)))
            f.append(CopyField("month", "Expiry month", String(format: "%02d", m)))
            f.append(CopyField("year", "Expiry year", String(y)))
        }
        return f
    }
}

extension IdentityItem {
    public var copyFields: [CopyField] {
        var f: [CopyField] = []
        func add(_ key: String, _ label: String, _ value: String, secret: Bool = false) {
            if !value.isEmpty { f.append(CopyField(key, label, value, secret: secret)) }
        }
        add("name", "Full name", fullName)
        add("email", "Email", email)
        add("phone", "Phone", phone)
        add("address", "Address", addressLines.joined(separator: "\n"))
        add("company", "Company", company)
        add("username", "Username", username)
        add("ssn", "SSN / national ID", ssn, secret: true)
        add("passport", "Passport number", passportNumber, secret: true)
        add("license", "Licence number", licenseNumber, secret: true)
        return f
    }

    /// What the one-click button copies: the email, else the name.
    public var primaryCopyKey: String? { !email.isEmpty ? "email" : (fullName.isEmpty ? nil : "name") }
}

extension NoteItem {
    public var copyFields: [CopyField] { body.isEmpty ? [] : [CopyField("body", "Note text", body, secret: true)] }
}

/// A field found by item id and key, with the item's name for the Touch ID prompt.
public struct FoundCopyField: Equatable, Sendable {
    public let itemTitle: String
    public let field: CopyField
}

extension Vault {
    /// Finds one copyable field on a card, identity or note. nil when the id or key doesn't exist. Logins are never found here.
    public func copyField(item id: UUID, key: String) -> FoundCopyField? {
        if let c = card(id), let f = c.copyFields.first(where: { $0.key == key }) { return FoundCopyField(itemTitle: c.title, field: f) }
        if let i = identity(id), let f = i.copyFields.first(where: { $0.key == key }) {
            return FoundCopyField(itemTitle: i.title.isEmpty ? i.fullName : i.title, field: f)
        }
        if let n = note(id), let f = n.copyFields.first(where: { $0.key == key }) { return FoundCopyField(itemTitle: n.title, field: f) }
        return nil
    }
}
