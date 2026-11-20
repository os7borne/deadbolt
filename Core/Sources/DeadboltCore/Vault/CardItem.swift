import Foundation

public enum CardBrand: String, Codable, CaseIterable, Sendable {
    case visa, mastercard, amex, discover, diners, jcb, unionpay, rupay, other

    public var displayName: String {
        switch self {
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .amex: "American Express"
        case .discover: "Discover"
        case .diners: "Diners Club"
        case .jcb: "JCB"
        case .unionpay: "UnionPay"
        case .rupay: "RuPay"
        case .other: "Card"
        }
    }

    /// Best guess from the first digits. Returns nil when there is nothing to go on; the owner can always choose a brand.
    public static func detect(_ number: String) -> CardBrand? {
        let d = number.filter(\.isNumber)
        func prefix(_ n: Int) -> Int? { d.count >= n ? Int(d.prefix(n)) : nil }
        guard !d.isEmpty else { return nil }
        if let p = prefix(2), [34, 37].contains(p) { return .amex }
        if d.hasPrefix("4") { return .visa }
        if let p = prefix(2), (51...55).contains(p) { return .mastercard }
        if let p = prefix(4), (2221...2720).contains(p) { return .mastercard }
        if let p = prefix(3), p == 508 { return .rupay }
        if let p = prefix(2), [81, 82].contains(p) { return .rupay }
        if let p = prefix(4), p == 6011 { return .discover }
        if let p = prefix(3), (644...649).contains(p) { return .discover }
        if let p = prefix(2), p == 65 { return .discover }
        if let p = prefix(4), (3528...3589).contains(p) { return .jcb }
        if let p = prefix(3), (300...305).contains(p) { return .diners }
        if let p = prefix(2), [36, 38, 39].contains(p) { return .diners }
        if let p = prefix(2), p == 62 { return .unionpay }
        return nil
    }
}

/// A payment card. Not tied to any website, and never offered to the AutoFill system or to a web page without an explicit pick.
public struct CardItem: Codable, Equatable, Identifiable, Sendable, SyncedItem {
    public var id: UUID
    public var title: String
    public var cardholderName: String
    /// Digits as typed (spaces and dashes are removed on input via `normalizedNumber`).
    public var number: String
    public var brand: CardBrand?          // nil = detect from the number
    public var expMonth: Int?             // 1...12
    public var expYear: Int?              // four digits
    public var securityCode: String
    public var pin: String
    /// Optional billing address: an identity in this vault.
    public var identityID: UUID?
    public var label: String?
    public var notes: String?
    public var customFields: [CustomField]?
    /// When it was last filled or copied (from the browser or an app). Orders suggestions, newest first. nil = never used.
    public var lastUsedAt: Date? = nil
    public var createdAt: Date
    public var updatedAt: Date
    public var clocks: [String: HLC]? = nil

    public init(id: UUID = UUID(), title: String = "", cardholderName: String = "", number: String = "", brand: CardBrand? = nil,
                expMonth: Int? = nil, expYear: Int? = nil, securityCode: String = "", pin: String = "",
                identityID: UUID? = nil, label: String? = nil, notes: String? = nil, now: Date = Date()) {
        self.id = id
        self.title = title
        self.cardholderName = cardholderName
        self.number = Self.normalizedNumber(number)
        self.brand = brand
        self.expMonth = expMonth
        self.expYear = expYear.map(Self.fullYear)
        self.securityCode = securityCode
        self.pin = pin
        self.identityID = identityID
        self.label = label
        self.notes = notes
        self.createdAt = now
        self.updatedAt = now
    }

    static let kind = "card"
    static var fields: [ItemField<CardItem>] {
        [ItemField("title", \.title), ItemField("cardholderName", \.cardholderName), ItemField("number", \.number),
         ItemField("brand", \.brand), ItemField("expMonth", \.expMonth), ItemField("expYear", \.expYear),
         ItemField("securityCode", \.securityCode), ItemField("pin", \.pin), ItemField("identityID", \.identityID),
         ItemField("label", \.label), ItemField("notes", \.notes), ItemField("customFields", \.customFields),
         ItemField("lastUsedAt", \.lastUsedAt)]
    }

    // MARK: derived

    public static func normalizedNumber(_ s: String) -> String { s.filter(\.isNumber) }

    /// "26" -> 2026. Four-digit years are kept.
    public static func fullYear(_ y: Int) -> Int { y < 100 ? 2000 + y : y }

    public var resolvedBrand: CardBrand { brand ?? CardBrand.detect(number) ?? .other }
    public var last4: String { String(number.suffix(4)) }

    /// "Visa •••• 4242" for lists. Never the full number.
    public var maskedSummary: String {
        number.isEmpty ? resolvedBrand.displayName : "\(resolvedBrand.displayName) •••• \(last4)"
    }

    /// The number in groups for reading aloud / copying by eye: 4-6-5 for American Express, else 4-4-4-4.
    public var formattedNumber: String {
        let d = Array(number)
        let sizes = resolvedBrand == .amex && d.count == 15 ? [4, 6, 5] : Array(repeating: 4, count: max(1, (d.count + 3) / 4))
        var out: [String] = [], i = 0
        for s in sizes where i < d.count { out.append(String(d[i..<min(i + s, d.count)])); i += s }
        return out.joined(separator: " ")
    }

    /// "04/2027"
    public var expiry: String? {
        guard let m = expMonth, let y = expYear else { return nil }
        return String(format: "%02d/%04d", m, y)
    }

    /// A card is valid through the last day of its expiry month.
    public func isExpired(now: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        guard let m = expMonth, let y = expYear else { return false }
        let c = calendar.dateComponents([.year, .month], from: now)
        guard let cy = c.year, let cm = c.month else { return false }
        return (y, m) < (cy, cm)
    }

    /// Luhn checksum. A failure is a warning in the UI, never a reason to refuse saving (some cards don't pass).
    public var passesLuhn: Bool {
        let d = number.compactMap(\.wholeNumberValue)
        guard d.count >= 12, d.count == number.count else { return false }
        var sum = 0
        for (i, n) in d.reversed().enumerated() {
            if i % 2 == 1 { let x = n * 2; sum += x > 9 ? x - 9 : x } else { sum += n }
        }
        return sum % 10 == 0
    }

    /// What a search may look at. **Never** the full number, security code or PIN.
    public var searchText: String {
        [title, resolvedBrand.displayName, last4, cardholderName, label ?? ""].joined(separator: " ").lowercased()
    }
}
