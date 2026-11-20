import Foundation

/// Bitwarden's **unencrypted JSON export** (Tools › Export vault › .json). It is the only common export that carries
/// cards, identities and secure notes. Item types: 1 login, 2 secure note, 3 card, 4 identity.
/// Folders, favourites and attachments are not imported. Encrypted exports are refused with a clear error.
enum BitwardenJSON {
    private struct Export: Decodable {
        var encrypted: Bool?
        var items: [Item]?
    }
    private struct Item: Decodable {
        var type: Int?
        var name: String?
        var notes: String?
        var fields: [Field]?
        var login: Login?
        var card: Card?
        var identity: Identity?
    }
    private struct Field: Decodable { var name: String?; var value: String?; var type: Int? }
    private struct Login: Decodable {
        struct URI: Decodable { var uri: String? }
        var uris: [URI]?
        var username: String?
        var password: String?
        var totp: String?
    }
    private struct Card: Decodable {
        var cardholderName: String?, brand: String?, number: String?, expMonth: String?, expYear: String?, code: String?
    }
    private struct Identity: Decodable {
        var title: String?, firstName: String?, middleName: String?, lastName: String?, address1: String?, address2: String?
        var address3: String?, city: String?, state: String?, postalCode: String?, country: String?, company: String?
        var email: String?, phone: String?, ssn: String?, username: String?, passportNumber: String?, licenseNumber: String?
    }

    static func parse(_ text: String) throws -> ImportFile {
        let export: Export
        do { export = try JSONDecoder().decode(Export.self, from: Data(text.utf8)) } catch { throw ImportError.notBitwardenJSON }
        if export.encrypted == true { throw ImportError.encryptedExport }
        guard let items = export.items else { throw ImportError.notBitwardenJSON }
        guard !items.isEmpty else { throw ImportError.empty }

        var logins: [ImportedLogin] = [], cards: [CardItem] = [], identities: [IdentityItem] = [], notes: [NoteItem] = []
        var skipped: [ImportFile.Skip] = []
        let now = Date()

        for (n, item) in items.enumerated() {
            let row = n + 1
            let name = clean(item.name)
            let label = name.map { "“\($0.prefix(30))” " } ?? ""
            let fields = customFields(item.fields)
            switch item.type {
            case 1:
                let uris = (item.login?.uris ?? []).compactMap { clean($0.uri) }
                guard let first = uris.first(where: { Site.normalize($0) != nil }) else {
                    skipped.append(.init(row: row, reason: "\(label)login has no website")); continue
                }
                guard let password = clean(item.login?.password) else {
                    skipped.append(.init(row: row, reason: "\(label)login has no password")); continue
                }
                logins.append(ImportedLogin(title: name, url: first, username: clean(item.login?.username) ?? "", password: password,
                                            notes: clean(item.notes), totp: clean(item.login?.totp),
                                            extraURLs: uris.filter { $0 != first }, customFields: fields))
            case 2:
                guard name != nil || clean(item.notes) != nil else { skipped.append(.init(row: row, reason: "Empty note")); continue }
                var note = NoteItem(title: name ?? "Note", body: item.notes ?? "", now: now)
                if !fields.isEmpty { note.customFields = fields }
                notes.append(note)
            case 3:
                guard let c = item.card, clean(c.number) != nil || name != nil else { skipped.append(.init(row: row, reason: "Empty card")); continue }
                var card = CardItem(title: name ?? "Card", cardholderName: clean(c.cardholderName) ?? "", number: c.number ?? "",
                                    brand: brand(c.brand), expMonth: month(c.expMonth), expYear: year(c.expYear),
                                    securityCode: clean(c.code) ?? "", notes: clean(item.notes), now: now)
                if !fields.isEmpty { card.customFields = fields }
                cards.append(card)
            case 4:
                guard let i = item.identity else { skipped.append(.init(row: row, reason: "Empty identity")); continue }
                var id = IdentityItem(title: name ?? "Identity", firstName: clean(i.firstName) ?? "", lastName: clean(i.lastName) ?? "", now: now)
                id.salutation = clean(i.title) ?? ""; id.middleName = clean(i.middleName) ?? ""; id.username = clean(i.username) ?? ""
                id.company = clean(i.company) ?? ""; id.email = clean(i.email) ?? ""; id.phone = clean(i.phone) ?? ""
                id.address1 = clean(i.address1) ?? ""; id.address2 = clean(i.address2) ?? ""; id.address3 = clean(i.address3) ?? ""
                id.city = clean(i.city) ?? ""; id.state = clean(i.state) ?? ""; id.postalCode = clean(i.postalCode) ?? ""; id.country = clean(i.country) ?? ""
                id.ssn = clean(i.ssn) ?? ""; id.passportNumber = clean(i.passportNumber) ?? ""; id.licenseNumber = clean(i.licenseNumber) ?? ""
                id.notes = clean(item.notes)
                if !fields.isEmpty { id.customFields = fields }
                identities.append(id)
            default:
                skipped.append(.init(row: row, reason: "\(label)unsupported item type"))
            }
        }
        return ImportFile(source: .bitwarden, logins: logins, skipped: skipped, cards: cards, identities: identities, notes: notes)
    }

    private static func clean(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    /// Text (0), hidden (1) and yes/no (2) fields. Linked fields (3) point at other fields and carry no value.
    private static func customFields(_ fields: [Field]?) -> [CustomField] {
        (fields ?? []).compactMap { f in
            guard let name = clean(f.name), f.type != 3 else { return nil }
            return CustomField(name: name, value: f.value ?? "", hidden: f.type == 1)
        }
    }

    private static func month(_ s: String?) -> Int? {
        guard let m = clean(s).flatMap({ Int($0) }), (1...12).contains(m) else { return nil }
        return m
    }

    private static func year(_ s: String?) -> Int? {
        guard let y = clean(s).flatMap({ Int($0) }), y >= 0, y < 10_000 else { return nil }
        return CardItem.fullYear(y)
    }

    /// Bitwarden names: Visa, Mastercard, Amex, Discover, Diners Club, JCB, Maestro, UnionPay, RuPay, Other. nil = detect from the number.
    private static func brand(_ s: String?) -> CardBrand? {
        switch clean(s)?.lowercased() {
        case "visa": .visa
        case "mastercard": .mastercard
        case "amex", "american express": .amex
        case "discover": .discover
        case "diners club", "diners": .diners
        case "jcb": .jcb
        case "unionpay": .unionpay
        case "rupay": .rupay
        case nil: nil
        default: .other
        }
    }
}
