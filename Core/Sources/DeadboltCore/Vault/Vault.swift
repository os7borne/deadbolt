import Foundation

/// The decrypted vault, in memory only while unlocked. All the rules about accounts live here,
/// so the iOS app, the AutoFill extension, the Mac app and Chrome behave identically.
public struct Vault: Codable, Equatable, Sendable {
    public internal(set) var logins: [LoginItem]
    public internal(set) var passkeys: [Passkey]
    /// The 24 recovery words, kept inside the encrypted vault so they can be shown or printed again
    /// while unlocked (after a fresh Face ID check). Anyone who can open the vault already has everything in it.
    public var recoveryPhrase: String?
    /// The vault's Mullvad-style account number (digits only). Set when sync is first turned on.
    public var accountNumber: String?
    /// The devices that share this vault.
    public var devices: [DeviceRecord]?
    /// Deleted logins/passkeys and when, so a delete reaches every device: "login:<uuid>", "passkey:<b64>".
    public var tombstones: [String: HLC]?
    /// Clocks for vault-level fields (recoveryPhrase, accountNumber, generator).
    public var metaClocks: [String: HLC]?
    /// Password generator preferences, shared by every device (last writer wins as one unit).
    public var generator: PasswordGenerator.Settings?

    /// Payment cards, identities and secure notes. Empty on vaults made before schema 2.
    public internal(set) var cards: [CardItem] = []
    public internal(set) var identities: [IdentityItem] = []
    public internal(set) var notes: [NoteItem] = []
    /// What this vault's data needs to be read safely. nil = 1 (logins + passkeys only); 2 adds cards, identities, notes.
    /// A build that knows an older schema would drop what it can't see on its next save, so newer vaults are refused, not opened.
    public var schema: Int?
    public static let currentSchema = 2

    public init(logins: [LoginItem] = [], passkeys: [Passkey] = []) {
        self.logins = logins
        self.passkeys = passkeys
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decodeIfPresent(Int.self, forKey: .schema)
        guard (schema ?? 1) <= Self.currentSchema else { throw DeadboltError.unsupportedVersion(UInt8(clamping: schema ?? 0)) }
        self.schema = schema
        logins = try c.decode([LoginItem].self, forKey: .logins)
        passkeys = try c.decode([Passkey].self, forKey: .passkeys)
        recoveryPhrase = try c.decodeIfPresent(String.self, forKey: .recoveryPhrase)
        accountNumber = try c.decodeIfPresent(String.self, forKey: .accountNumber)
        devices = try c.decodeIfPresent([DeviceRecord].self, forKey: .devices)
        tombstones = try c.decodeIfPresent([String: HLC].self, forKey: .tombstones)
        metaClocks = try c.decodeIfPresent([String: HLC].self, forKey: .metaClocks)
        generator = try c.decodeIfPresent(PasswordGenerator.Settings.self, forKey: .generator)
        cards = try c.decodeIfPresent([CardItem].self, forKey: .cards) ?? []
        identities = try c.decodeIfPresent([IdentityItem].self, forKey: .identities) ?? []
        notes = try c.decodeIfPresent([NoteItem].self, forKey: .notes) ?? []
    }

    /// Everything stored, of every kind, for counts. (Passkeys belong to logins and aren't counted twice.)
    public var itemCount: Int { logins.count + cards.count + identities.count + notes.count }

    // MARK: lookup

    /// Every account for a site, **most recently used first**. Accounts never used come after used ones; among those (and among
    /// any with the same use time) the ★ preferred one is first, then alphabetical. So ★ is the default until usage takes over.
    public func accounts(for host: String) -> [LoginItem] {
        logins.filter { $0.matches(host: host) }.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if a.preferred != b.preferred { return a.preferred }
            return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
        }
    }

    /// Cards, most recently used first; never-used ones after, by name.
    public var cardsByRecency: [CardItem] {
        cards.sorted { Self.moreRecent($0.lastUsedAt, $1.lastUsedAt, $0.title, $1.title) }
    }

    /// Identities, most recently used first; never-used ones after, by name.
    public var identitiesByRecency: [IdentityItem] {
        identities.sorted { Self.moreRecent($0.lastUsedAt, $1.lastUsedAt, $0.title.isEmpty ? $0.fullName : $0.title, $1.title.isEmpty ? $1.fullName : $1.title) }
    }

    static func moreRecent(_ a: Date?, _ b: Date?, _ titleA: String, _ titleB: String) -> Bool {
        switch (a, b) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return titleA.localizedCaseInsensitiveCompare(titleB) == .orderedAscending
        }
    }

    /// Records that a card or identity was just filled or copied. Does not count as an edit.
    public mutating func markItemUsed(_ id: UUID, now: Date = Date()) {
        if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].lastUsedAt = now }
        else if let i = identities.firstIndex(where: { $0.id == id }) { identities[i].lastUsedAt = now }
    }

    public func login(_ id: UUID) -> LoginItem? { logins.first { $0.id == id } }

    /// A login, only if it belongs to `host` (itself or a subdomain). Anything that releases a password to a web page
    /// (the browser bridge) must use this, never `login(_:)`: a page must not be able to ask for another site's password.
    public func login(_ id: UUID, for host: String) -> LoginItem? {
        accounts(for: host).first { $0.id == id }
    }

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

    /// The account a submitted sign-in belongs to. A login that covers the host wins; otherwise a login for the same
    /// registrable domain with the same username (saved for account.live.com, signing in on login.live.com).
    /// Only saving uses this wider match: filling stays strict (`accounts(for:)`), so a page is never offered a
    /// sibling subdomain's password.
    func existingLogin(host: String, canonicalUser user: String) -> LoginItem? {
        let sameUser = logins.filter { Self.canonicalUsername($0.username) == user }
        if let exact = sameUser.first(where: { $0.matches(host: host) }) { return exact }
        guard let h = Site.normalize(host) else { return nil }
        return sameUser.first { $0.sites.contains { PublicSuffix.sameSite($0, h) } }
    }

    /// What to offer when a sign-in or sign-up form is submitted.
    public func proposeSave(host: String, username: String, password: String) -> SaveProposal {
        let user = Self.canonicalUsername(username)
        guard let existing = existingLogin(host: host, canonicalUser: user) else { return .new }
        // Saving an account with no password never touches one that exists: an empty value must not erase a real password.
        if password.isEmpty { return .unchanged(existing: existing.id) }
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
        var item = LoginItem(sites: [site], username: username, password: password, preferred: isFirstOnSite, now: now)
        if password.isEmpty { item.passwordless = true }
        logins.append(item)
        return item.id
    }

    /// Adds a one-time code. With a website it goes on the existing account for (site, username), or becomes a code-only
    /// account on that site; with no website it is a standalone code entry (like an authenticator app) that is never
    /// offered for filling. A code-only entry is never the "preferred" account, so it can't push a real login down.
    @discardableResult
    public mutating func saveCode(host: String?, title: String?, username: String, secret: String, now: Date = Date()) throws -> UUID {
        let typed = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var site: String?
        if !typed.isEmpty {
            guard let s = Site.normalize(typed) else { throw VaultError.invalidSite }
            site = s
        }
        let user = Self.canonicalUsername(username)
        if let site, !user.isEmpty,
           let i = logins.firstIndex(where: { $0.matches(host: site) && Self.canonicalUsername($0.username) == user }) {
            logins[i].totpSecret = secret
            logins[i].updatedAt = now
            return logins[i].id
        }
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let item = LoginItem(title: name.isEmpty ? (site.map(Site.displayName) ?? "Code") : name,
                             sites: site.map { [$0] } ?? [], username: username, password: "", totpSecret: secret, now: now)
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

    // MARK: cards, identities, notes

    public mutating func upsert(_ card: CardItem, now: Date = Date()) { upsertItem(\.cards, card, now: now) }
    public mutating func upsert(_ identity: IdentityItem, now: Date = Date()) { upsertItem(\.identities, identity, now: now) }
    public mutating func upsert(_ note: NoteItem, now: Date = Date()) { upsertItem(\.notes, note, now: now) }

    public mutating func deleteCard(_ id: UUID) {
        cards.removeAll { $0.id == id }
        // A card's billing link must not point at nothing, but deleting an identity never touches a card's own data.
    }
    public mutating func deleteIdentity(_ id: UUID) {
        identities.removeAll { $0.id == id }
        for i in cards.indices where cards[i].identityID == id { cards[i].identityID = nil }
    }
    public mutating func deleteNote(_ id: UUID) { notes.removeAll { $0.id == id } }

    public func card(_ id: UUID) -> CardItem? { cards.first { $0.id == id } }
    public func identity(_ id: UUID) -> IdentityItem? { identities.first { $0.id == id } }
    public func note(_ id: UUID) -> NoteItem? { notes.first { $0.id == id } }

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
