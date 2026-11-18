import Foundation

/// One account on one or more sites. A site can have many LoginItems (personal, work, bot…):
/// the account is identified by (site, username), never by site alone.
public struct LoginItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var sites: [String]            // normalized hosts, e.g. ["github.com", "gist.github.com"]
    public var username: String
    public var password: String
    public var label: String?             // "Personal", "Work"…
    public var totpSecret: String?        // otpauth secret (base32), if any
    public var passkeyIDs: [Data]         // credential IDs of passkeys stored for this account
    public var notes: String?
    public var preferred: Bool            // suggested first among accounts on the same site
    public var history: [PasswordHistoryEntry]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public static let historyLimit = 20

    public init(id: UUID = UUID(), title: String? = nil, sites: [String], username: String, password: String,
                label: String? = nil, totpSecret: String? = nil, passkeyIDs: [Data] = [], notes: String? = nil,
                preferred: Bool = false, now: Date = Date()) {
        let normalized = sites.compactMap(Site.normalize)
        self.id = id
        self.title = title ?? normalized.first.map(Site.displayName) ?? "Login"
        self.sites = normalized
        self.username = username
        self.password = password
        self.label = label
        self.totpSecret = totpSecret
        self.passkeyIDs = passkeyIDs
        self.notes = notes
        self.preferred = preferred
        self.history = []
        self.createdAt = now
        self.updatedAt = now
        self.lastUsedAt = nil
    }

    /// Replaces the password and keeps the old one in history (newest first, capped).
    public mutating func changePassword(to newPassword: String, now: Date = Date()) {
        guard newPassword != password else { return }
        history.insert(PasswordHistoryEntry(password: password, replacedAt: now), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        password = newPassword
        updatedAt = now
    }

    /// Brings back an old password; the current one goes into history, so restore is undoable too.
    public mutating func restore(_ entry: PasswordHistoryEntry, now: Date = Date()) {
        history.removeAll { $0 == entry }
        changePassword(to: entry.password, now: now)
    }

    func matches(host: String) -> Bool { sites.contains { Site.host(host, isCoveredBy: $0) } }
}

public struct PasswordHistoryEntry: Codable, Equatable, Sendable {
    public let password: String
    public let replacedAt: Date
}

/// Site matching. Deliberately strict: a saved site covers itself and its subdomains, nothing else,
/// so "github.com.evil.example" never matches "github.com".
public enum Site {
    /// "https://WWW.GitHub.com/login" → "github.com". Returns nil for things that aren't a host.
    public static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard var host = URLComponents(string: s)?.host, !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        guard host.contains(".") || host == "localhost",
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return host
    }

    public static func host(_ host: String, isCoveredBy saved: String) -> Bool {
        guard let h = normalize(host) else { return false }
        return h == saved || h.hasSuffix("." + saved)
    }

    /// "github.com" → "Github", "accounts.google.com" → "Google". Good enough for a default title.
    static func displayName(_ host: String) -> String {
        let parts = host.split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? Substring(host)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
