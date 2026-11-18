import Foundation

/// The decrypted vault, in memory only while unlocked. All the rules about accounts live here,
/// so the iOS app, the AutoFill extension, the Mac app and Chrome behave identically.
public struct Vault: Codable, Equatable, Sendable {
    public private(set) var logins: [LoginItem]
    public private(set) var passkeys: [Passkey]
    /// The 24 recovery words, kept inside the encrypted vault so they can be shown or printed again
    /// while unlocked (after a fresh Face ID check). Anyone who can open the vault already has everything in it.
    public var recoveryPhrase: String?

    public init(logins: [LoginItem] = [], passkeys: [Passkey] = []) {
        self.logins = logins
        self.passkeys = passkeys
    }

    // MARK: lookup

    /// Every account for a site: the preferred one first, then most recently used, then alphabetical.
    public func accounts(for host: String) -> [LoginItem] {
        logins.filter { $0.matches(host: host) }.sorted { a, b in
            if a.preferred != b.preferred { return a.preferred }
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
            }
        }
    }

    public func login(_ id: UUID) -> LoginItem? { logins.first { $0.id == id } }

    public func passkeys(for relyingPartyID: String) -> [Passkey] {
        passkeys.filter { $0.relyingPartyID == relyingPartyID }
    }

    // MARK: saving — never duplicates

    public enum SaveProposal: Equatable, Sendable {
        /// No account with this username on this site: offer "Save".
        case new
        /// Same site + username, different password: offer "Update" (old password → history).
        case update(existing: UUID)
        /// Same site + username + password: nothing to do, don't prompt.
        case unchanged(existing: UUID)
    }

    /// What to offer when a sign-in or sign-up form is submitted.
    public func proposeSave(host: String, username: String, password: String) -> SaveProposal {
        let user = Self.canonicalUsername(username)
        guard let existing = logins.first(where: { $0.matches(host: host) && Self.canonicalUsername($0.username) == user }) else {
            return .new
        }
        return existing.password == password ? .unchanged(existing: existing.id) : .update(existing: existing.id)
    }

    /// Applies the owner's choice. `asNewAccount` is the explicit "Save as a separate login" escape hatch.
    @discardableResult
    public mutating func save(host: String, username: String, password: String, asNewAccount: Bool = false, now: Date = Date()) throws -> UUID {
        guard let site = Site.normalize(host) else { throw VaultError.invalidSite }
        if !asNewAccount {
            switch proposeSave(host: host, username: username, password: password) {
            case .unchanged(let id):
                return id
            case .update(let id):
                let i = logins.firstIndex { $0.id == id }!
                logins[i].changePassword(to: password, now: now)
                return id
            case .new:
                break
            }
        }
        let isFirstOnSite = accounts(for: site).isEmpty
        let item = LoginItem(sites: [site], username: username, password: password, preferred: isFirstOnSite, now: now)
        logins.append(item)
        return item.id
    }

    // MARK: editing

    public mutating func upsert(_ item: LoginItem, now: Date = Date()) {
        var item = item
        item.updatedAt = now
        if let i = logins.firstIndex(where: { $0.id == item.id }) { logins[i] = item } else { logins.append(item) }
    }

    public mutating func delete(_ id: UUID) {
        logins.removeAll { $0.id == id }
    }

    /// Makes one account the first suggestion on every site it shares with others.
    public mutating func setPreferred(_ id: UUID) {
        guard let chosen = login(id) else { return }
        for i in logins.indices where logins[i].id != id && !Set(logins[i].sites).isDisjoint(with: chosen.sites) {
            logins[i].preferred = false
        }
        logins[logins.firstIndex { $0.id == id }!].preferred = true
    }

    public mutating func markUsed(_ id: UUID, now: Date = Date()) {
        if let i = logins.firstIndex(where: { $0.id == id }) { logins[i].lastUsedAt = now }
    }

    // MARK: passkeys

    public mutating func add(_ passkey: Passkey, linkTo loginID: UUID? = nil) {
        passkeys.append(passkey)
        if let loginID, let i = logins.firstIndex(where: { $0.id == loginID }) {
            logins[i].passkeyIDs.append(passkey.credentialID)
        }
    }

    public mutating func deletePasskey(_ credentialID: Data) {
        passkeys.removeAll { $0.credentialID == credentialID }
        for i in logins.indices { logins[i].passkeyIDs.removeAll { $0 == credentialID } }
    }

    /// Usernames compare case-insensitively and ignore surrounding spaces ("Alex@Example.com " == "alex@example.com").
    public static func canonical(_ s: String) -> String { canonicalUsername(s) }

    static func canonicalUsername(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum VaultError: Error, Equatable, Sendable {
    case invalidSite
    case locked
}
