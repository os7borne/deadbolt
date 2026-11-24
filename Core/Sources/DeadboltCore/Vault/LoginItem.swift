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
    /// Extra name/value pairs: security answers, account IDs, PINs. nil on logins made before custom fields existed.
    public var customFields: [CustomField]?
    public var preferred: Bool            // suggested first among accounts on the same site
    public var history: [PasswordHistoryEntry]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    /// True when the owner saved this account on purpose without a password (sign-in by emailed link or code).
    /// nil on logins made before this existed. Needed because an empty password alone is ambiguous: it also means
    /// "passkey only" and "code only".
    public var passwordless: Bool? = nil
    /// When each field last changed, for merging edits from other devices. nil on vaults made before sync.
    public var clocks: [String: HLC]? = nil

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
    /// An empty old password (passkey-only or passwordless accounts) is not worth a history entry.
    public mutating func changePassword(to newPassword: String, now: Date = Date()) {
        guard newPassword != password else { return }
        if !password.isEmpty {
            history.insert(PasswordHistoryEntry(password: password, replacedAt: now), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        password = newPassword
        // Clearing the password of an account with no passkey is a deliberate "this account has no password".
        passwordless = newPassword.isEmpty && passkeyIDs.isEmpty ? true : nil
        updatedAt = now
    }

    /// Brings back an old password; the current one goes into history, so restore is undoable too.
    public mutating func restore(_ entry: PasswordHistoryEntry, now: Date = Date()) {
        history.removeAll { $0 == entry }
        changePassword(to: entry.password, now: now)
    }

    /// A one-time code on its own: no password, no passkey. Shown in code lists, never offered to fill a sign-in.
    public var isCodeOnly: Bool { password.isEmpty && passkeyIDs.isEmpty && totpSecret != nil && passwordless != true }

    /// The name a login gets from its website when the owner hasn't chosen one ("github.com" → "Github").
    public static func defaultTitle(for sites: [String]) -> String {
        sites.compactMap(Site.normalize).first.map(Site.displayName) ?? "Login"
    }
    /// The owner's own name for this login (shown in lists, AutoFill and the browser), or nil when it still uses the website's.
    public var customName: String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == Self.defaultTitle(for: sites) ? nil : t
    }

    /// An account saved without a password on purpose: signs in by emailed link or code. Listed like any login;
    /// only the username is useful to copy or fill.
    public var isPasswordless: Bool { password.isEmpty && passkeyIDs.isEmpty && !isCodeOnly }

    func matches(host: String) -> Bool { sites.contains { Site.host(host, isCoveredBy: $0) } }
}

/// A custom field on a login. "Hidden" values (PINs, security answers) are masked until revealed.
public struct CustomField: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String
    public var hidden: Bool
    public init(id: UUID = UUID(), name: String = "", value: String = "", hidden: Bool = false) {
        self.id = id; self.name = name; self.value = value; self.hidden = hidden
    }
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
        if let schemeEnd = s.range(of: "://") {
            // Only web addresses are sites. "android://com.app" or "ftp://…" must not become "com.app".
            guard ["http", "https"].contains(String(s[..<schemeEnd.lowerBound])) else { return nil }
        } else {
            s = "https://" + s
        }
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
    public static func displayName(_ host: String) -> String {
        let parts = host.split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first ?? Substring(host)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
