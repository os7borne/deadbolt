import Foundation

/// RFC 4180 CSV: quoted fields, "" escapes, commas and newlines inside quotes, CRLF or LF, optional BOM.
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n") // flush the last row
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        return rows
    }
}

/// One login read from another password manager's export.
public struct ImportedLogin: Equatable, Sendable {
    public var title: String?
    public var url: String
    public var username: String
    public var password: String
    public var notes: String?
    public var totp: String?
    /// Extra websites on the same login (Bitwarden allows several URIs). The first is `url`.
    public var extraURLs: [String] = []
    public var customFields: [CustomField] = []
}

public enum ImportSource: String, Sendable {
    case applePasswords = "Apple Passwords"
    case chrome = "Chrome"
    case onePassword = "1Password"
    case bitwarden = "Bitwarden"
    case generic = "CSV file"
}

public struct ImportFile: Sendable {
    public let source: ImportSource
    public let logins: [ImportedLogin]
    public let skipped: [Skip]
    public let cards: [CardItem]
    public let identities: [IdentityItem]
    public let notes: [NoteItem]

    init(source: ImportSource, logins: [ImportedLogin], skipped: [Skip],
         cards: [CardItem] = [], identities: [IdentityItem] = [], notes: [NoteItem] = []) {
        self.source = source; self.logins = logins; self.skipped = skipped
        self.cards = cards; self.identities = identities; self.notes = notes
    }

    /// Everything that would be written, for the "Import N items" button.
    public var itemCount: Int { logins.count + cards.count + identities.count + notes.count }

    public struct Skip: Equatable, Sendable {
        public let row: Int          // 1-based, header = row 1
        public let reason: String
    }
}

public enum ImportError: Error, Equatable, Sendable {
    case empty
    case unrecognizedColumns(found: [String])
    /// A Bitwarden export that was password-protected or account-encrypted: Deadbolt can't read it.
    case encryptedExport
    /// JSON, but not a Bitwarden vault export.
    case notBitwardenJSON
}

/// Reads exports by header name rather than position, so column order and extra columns don't matter.
public enum PasswordImporter {
    static let urlKeys = ["url", "website", "login_uri", "login url", "web site", "uri", "urls"]
    static let userKeys = ["username", "login_username", "user name", "login", "email", "user"]
    static let passKeys = ["password", "login_password"]
    static let titleKeys = ["title", "name"]
    static let noteKeys = ["notes", "note", "comments", "extra"]
    static let otpKeys = ["otpauth", "otp", "totp", "login_totp", "one-time password", "otp auth"]

    public static func parse(_ text: String) throws -> ImportFile {
        if text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).first == "{" { return try BitwardenJSON.parse(text) }
        let rows = CSV.parse(text)
        guard let header = rows.first, rows.count > 1 else { throw ImportError.empty }
        let cols = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func idx(_ keys: [String]) -> Int? { keys.lazy.compactMap { cols.firstIndex(of: $0) }.first }
        guard let u = idx(urlKeys), let p = idx(passKeys) else { throw ImportError.unrecognizedColumns(found: header) }
        let user = idx(userKeys), title = idx(titleKeys), note = idx(noteKeys), otp = idx(otpKeys)

        var logins: [ImportedLogin] = []
        var skipped: [ImportFile.Skip] = []
        for (n, r) in rows.dropFirst().enumerated() {
            func v(_ i: Int?) -> String? {
                guard let i, i < r.count else { return nil }
                let s = r[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            let rowNumber = n + 2
            guard let url = v(u) else { skipped.append(.init(row: rowNumber, reason: "No website")); continue }
            guard let password = v(p) else { skipped.append(.init(row: rowNumber, reason: "No password")); continue }
            // Bitwarden/1Password can put several URLs in one cell; use the first.
            let firstURL = url.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).first.map(String.init) ?? url
            guard Site.normalize(firstURL) != nil else { skipped.append(.init(row: rowNumber, reason: "Not a website: \(firstURL.prefix(40))")); continue }
            logins.append(ImportedLogin(title: v(title), url: firstURL, username: v(user) ?? "", password: password,
                                        notes: v(note), totp: v(otp)))
        }
        return ImportFile(source: detect(cols), logins: logins, skipped: skipped)
    }

    static func detect(_ cols: [String]) -> ImportSource {
        let set = Set(cols)
        if set.isSuperset(of: ["title", "url", "username", "password", "otpauth"]) && !set.contains("favorite") { return .applePasswords }
        if set.contains("login_uri") { return .bitwarden }
        if set.isSuperset(of: ["name", "url", "username", "password"]) && set.count <= 5 { return .chrome }
        if set.contains("favorite") || set.contains("archived") { return .onePassword }
        return .generic
    }
}

/// What an import would do, worked out before anything is written.
public struct ImportPlan: Sendable {
    public enum Action: Equatable, Sendable { case add, update(UUID), unchanged(UUID) }
    public struct Entry: Sendable { public let login: ImportedLogin; public let action: Action }

    public let entries: [Entry]
    /// Cards, identities and notes are only ever added (a repeat of one already saved is skipped, never overwritten).
    public var newCards = 0, duplicateCards = 0
    public var newIdentities = 0, duplicateIdentities = 0
    public var newNotes = 0, duplicateNotes = 0
    public var added: Int { entries.filter { $0.action == .add }.count }
    public var updated: Int { entries.filter { if case .update = $0.action { return true } else { return false } }.count }
    public var unchanged: Int { entries.filter { if case .unchanged = $0.action { return true } else { return false } }.count }
    /// What pressing Import changes in the vault.
    public var writes: Int { added + updated + newCards + newIdentities + newNotes }
}

extension Vault {
    /// Same rules as saving from a form: same site + username updates (old password to history), never duplicates.
    public func plan(_ file: ImportFile) -> ImportPlan {
        var simulated = self
        var entries: [ImportPlan.Entry] = []
        for l in file.logins {
            let action: ImportPlan.Action
            switch simulated.proposeSave(host: l.url, username: l.username, password: l.password) {
            case .new: action = .add
            case .update(let id): action = .update(id)
            case .unchanged(let id): action = .unchanged(id)
            }
            _ = try? simulated.save(host: l.url, username: l.username, password: l.password) // duplicates inside the file collapse too
            entries.append(.init(login: l, action: action))
        }
        var plan = ImportPlan(entries: entries)
        for c in file.cards { if simulated.hasDuplicate(c) { plan.duplicateCards += 1 } else { plan.newCards += 1; simulated.upsert(c) } }
        for i in file.identities { if simulated.hasDuplicate(i) { plan.duplicateIdentities += 1 } else { plan.newIdentities += 1; simulated.upsert(i) } }
        for n in file.notes { if simulated.hasDuplicate(n) { plan.duplicateNotes += 1 } else { plan.newNotes += 1; simulated.upsert(n) } }
        return plan
    }

    // Same item already saved? Re-importing the same export must not double everything.
    func hasDuplicate(_ c: CardItem) -> Bool {
        cards.contains {
            if !c.number.isEmpty { return $0.number == c.number }
            return $0.number.isEmpty && Self.canonical($0.title) == Self.canonical(c.title) && Self.canonical($0.cardholderName) == Self.canonical(c.cardholderName)
        }
    }
    func hasDuplicate(_ i: IdentityItem) -> Bool {
        identities.contains {
            Self.canonical($0.title) == Self.canonical(i.title) && Self.canonical($0.fullName) == Self.canonical(i.fullName)
                && Self.canonical($0.email) == Self.canonical(i.email) && Self.canonical($0.address1) == Self.canonical(i.address1)
                && Self.canonical($0.postalCode) == Self.canonical(i.postalCode)
        }
    }
    func hasDuplicate(_ n: NoteItem) -> Bool {
        notes.contains { Self.canonical($0.title) == Self.canonical(n.title) && $0.body == n.body }
    }

    /// Applies an import. Titles, notes, one-time code keys and custom fields fill in only where the existing login has none.
    public mutating func apply(_ file: ImportFile, now: Date = Date()) {
        for l in file.logins {
            guard let id = try? save(host: l.url, username: l.username, password: l.password, now: now),
                  var item = login(id) else { continue }
            if let t = l.title, !t.isEmpty, item.createdAt == now { item.title = t }
            if item.notes == nil, let n = l.notes { item.notes = n }
            if item.totpSecret == nil, let o = l.totp, (try? TOTP(o)) != nil { item.totpSecret = o }
            for extra in l.extraURLs.compactMap(Site.normalize) where !item.sites.contains(extra) { item.sites.append(extra) }
            if (item.customFields ?? []).isEmpty, !l.customFields.isEmpty { item.customFields = l.customFields }
            upsert(item, now: now)
        }
        for var c in file.cards where !hasDuplicate(c) { c.createdAt = now; upsert(c, now: now) }
        for var i in file.identities where !hasDuplicate(i) { i.createdAt = now; upsert(i, now: now) }
        for var n in file.notes where !hasDuplicate(n) { n.createdAt = now; upsert(n, now: now) }
    }
}
