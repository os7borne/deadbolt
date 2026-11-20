import Foundation

/// What the browser extension may be given to fill into a page's form. The extension asks for only the keys its form
/// actually has (no CVV field on the page → the security code is never requested, so never released).
/// `number` and `code` are secret: a request that includes either needs a fresh Touch ID on the Mac first.
/// ID numbers, PINs and note text are deliberately not fillable: copy them instead.
public struct FilledItem: Equatable, Sendable {
    public let title: String
    /// For the Touch ID note: "Visa •••• 1111" or the person's name.
    public let summary: String
    public let values: [String: String]
    public let hasSecret: Bool
}

extension Vault {
    public static let secretFillKeys: Set<String> = ["number", "code"]

    /// Values for the requested keys from one card or identity. Unknown keys and empty values are left out.
    /// nil when the id isn't a card or identity (logins are never reachable this way).
    public func fillValues(item id: UUID, want: [String]) -> FilledItem? {
        let wanted = Set(want)
        if let c = card(id) {
            let all = c.fillTable
            let values = all.filter { wanted.contains($0.key) && !$0.value.isEmpty }
            return FilledItem(title: c.title, summary: c.maskedSummary, values: values, hasSecret: !wanted.isDisjoint(with: Self.secretFillKeys.intersection(values.keys)))
        }
        if let i = identity(id) {
            let values = i.fillTable.filter { wanted.contains($0.key) && !$0.value.isEmpty }
            return FilledItem(title: i.title.isEmpty ? i.fullName : i.title, summary: i.fullName.isEmpty ? i.title : i.fullName, values: values, hasSecret: false)
        }
        return nil
    }
}

extension CardItem {
    var fillTable: [String: String] {
        var t: [String: String] = [:]
        t["number"] = number
        t["code"] = securityCode
        t["holder"] = cardholderName
        let parts = cardholderName.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count >= 2 { t["holderFirst"] = parts.dropLast().joined(separator: " "); t["holderLast"] = parts.last }
        else if parts.count == 1 { t["holderFirst"] = parts[0] }
        if let m = expMonth, let y = expYear {
            t["expMonth"] = String(format: "%02d", m)
            t["expYear"] = String(y)
            t["expYear2"] = String(format: "%02d", y % 100)
            t["expiry"] = String(format: "%02d/%02d", m, y % 100)
            t["expiryLong"] = String(format: "%02d/%04d", m, y)
            t["expiryCompact"] = String(format: "%02d%02d", m, y % 100)
        }
        return t
    }
}

extension IdentityItem {
    var fillTable: [String: String] {
        [
            "salutation": salutation, "first": firstName, "middle": middleName, "last": lastName, "name": fullName,
            "company": company, "username": username, "email": email, "phone": phone,
            "address": addressLines.joined(separator: ", "), "address1": address1, "address2": address2, "address3": address3,
            "city": city, "state": state, "postal": postalCode, "country": country,
        ]
    }
}
