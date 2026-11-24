import Foundation

/// A device that belongs to the vault. Public keys only; private keys never leave the device.
public struct DeviceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String                 // random, per installation
    public var name: String               // "Oz iPhone"
    public var model: String              // "iPhone 11", "MacBook Air"
    public var platform: String           // "iOS", "macOS"
    public let signingKey: Data           // P-256 public key, x9.63
    public let agreementKey: Data         // P-256 public key, x9.63 (for key rotation)
    public let linkedAt: Date
    public var revoked: Revocation?
    public var clock: HLC?

    public init(id: String, name: String, model: String, platform: String, signingKey: Data, agreementKey: Data, linkedAt: Date = Date()) {
        self.id = id; self.name = name; self.model = model; self.platform = platform
        self.signingKey = signingKey; self.agreementKey = agreementKey; self.linkedAt = linkedAt
    }

    public var isActive: Bool { revoked == nil }
}

/// "Device X was removed by device Y", signed by Y. A removed device erases itself only after verifying this.
public struct Revocation: Codable, Equatable, Sendable {
    public let device: String
    public let by: String
    public let at: Date
    public let signature: Data

    static func message(device: String, by: String, at: Date) -> Data {
        // Rounded to whole milliseconds: that's what survives the relay's JSON (dates as unix ms).
        Data("deadbolt/revoke/v1\n\(device)\n\(by)\n\(Int64((at.timeIntervalSince1970 * 1000).rounded()))".utf8)
    }
}

// MARK: field-level clocks

extension LoginItem {
    /// Fields merged last-writer-wins. `history` is merged by union, `createdAt` by min.
    static let mergedFields = ["title", "sites", "username", "password", "label", "totpSecret", "passkeyIDs", "notes", "customFields", "passwordless", "preferred", "lastUsedAt"]

    func clock(_ field: String) -> HLC { clocks?[field] ?? .zero }
    var newestClock: HLC { clocks?.values.max() ?? .zero }

    func changedFields(from old: LoginItem) -> [String] {
        var out: [String] = []
        if title != old.title { out.append("title") }
        if sites != old.sites { out.append("sites") }
        if username != old.username { out.append("username") }
        if password != old.password { out.append("password") }
        if label != old.label { out.append("label") }
        if totpSecret != old.totpSecret { out.append("totpSecret") }
        if passkeyIDs != old.passkeyIDs { out.append("passkeyIDs") }
        if notes != old.notes { out.append("notes") }
        if customFields != old.customFields { out.append("customFields") }
        if passwordless != old.passwordless { out.append("passwordless") }
        if preferred != old.preferred { out.append("preferred") }
        if lastUsedAt != old.lastUsedAt { out.append("lastUsedAt") }
        if history != old.history && !out.contains("password") { out.append("password") } // restore/history edits travel with password
        return out
    }

    /// Field-by-field newest wins. A password that loses is kept in history, so concurrent changes never lose one.
    static func merged(_ a: LoginItem, _ b: LoginItem) -> LoginItem {
        var m = a
        func pick<T>(_ f: String, _ kp: WritableKeyPath<LoginItem, T>) { if b.clock(f) > a.clock(f) { m[keyPath: kp] = b[keyPath: kp] } }
        pick("title", \.title); pick("sites", \.sites); pick("username", \.username); pick("password", \.password)
        pick("label", \.label); pick("totpSecret", \.totpSecret); pick("passkeyIDs", \.passkeyIDs); pick("notes", \.notes); pick("customFields", \.customFields); pick("passwordless", \.passwordless)
        pick("preferred", \.preferred); pick("lastUsedAt", \.lastUsedAt)

        var history = a.history + b.history
        let losingPassword = m.password == a.password ? b.password : a.password
        if losingPassword != m.password && !losingPassword.isEmpty {
            let when = max(a.clock("password"), b.clock("password")).date
            history.append(PasswordHistoryEntry(password: losingPassword, replacedAt: when))
        }
        var seen = Set<String>()
        m.history = history
            .filter { $0.password != m.password && seen.insert("\($0.password)\u{0}\($0.replacedAt.timeIntervalSince1970)").inserted }
            .sorted { $0.replacedAt > $1.replacedAt }
            .prefix(LoginItem.historyLimit).map { $0 }

        var clocks = a.clocks ?? [:]
        for (f, c) in b.clocks ?? [:] where c > clocks[f] ?? .zero { clocks[f] = c }
        m.clocks = clocks
        m.createdAt = min(a.createdAt, b.createdAt)
        m.updatedAt = max(a.updatedAt, b.updatedAt)
        return m
    }
}

extension Vault {
    static func loginKey(_ id: UUID) -> String { "login:\(id.uuidString)" }
    static func passkeyKey(_ id: Data) -> String { "passkey:\(id.base64EncodedString())" }

    /// The newest stamp anywhere in the vault.
    public var newestClock: HLC? {
        var all: [HLC] = logins.map(\.newestClock) + passkeys.compactMap(\.addedAt) + (devices ?? []).compactMap(\.clock)
        all += cards.map(\.newestClock) + identities.map(\.newestClock) + notes.map(\.newestClock)
        all += (tombstones ?? [:]).values
        all += (metaClocks ?? [:]).values
        return all.filter { $0 != .zero }.max()
    }

    /// Stamps everything that differs from `old` with one new clock value. Called on every local change.
    public mutating func stamp(changesFrom old: Vault, node: String, now: Date = Date()) {
        let tick = HLC.next(after: Swift.max(old.newestClock ?? .zero, newestClock ?? .zero), node: node, now: now)
        let oldLogins = Dictionary(uniqueKeysWithValues: old.logins.map { ($0.id, $0) })
        for i in logins.indices {
            let fields = logins[i].clocks == nil ? LoginItem.mergedFields
                : oldLogins[logins[i].id].map { logins[i].changedFields(from: $0) } ?? LoginItem.mergedFields
            guard !fields.isEmpty else { continue }
            var clocks = logins[i].clocks ?? [:]
            for f in fields { clocks[f] = tick }
            logins[i].clocks = clocks
        }
        var tomb = tombstones ?? [:]
        for id in Set(oldLogins.keys).subtracting(logins.map(\.id)) { tomb[Self.loginKey(id)] = tick }
        let oldPasskeys = Set(old.passkeys.map(\.credentialID))
        for i in passkeys.indices where !oldPasskeys.contains(passkeys[i].credentialID) || passkeys[i].addedAt == nil { passkeys[i].addedAt = tick }
        for id in oldPasskeys.subtracting(passkeys.map(\.credentialID)) { tomb[Self.passkeyKey(id)] = tick }
        stampItems(\.cards, old: old, tick: tick, tombstones: &tomb)
        stampItems(\.identities, old: old, tick: tick, tombstones: &tomb)
        stampItems(\.notes, old: old, tick: tick, tombstones: &tomb)
        tombstones = tomb.isEmpty ? nil : tomb
        schema = Self.currentSchema

        var meta = metaClocks ?? [:]
        if recoveryPhrase != old.recoveryPhrase || (recoveryPhrase != nil && meta["recoveryPhrase"] == nil) { meta["recoveryPhrase"] = tick }
        if accountNumber != old.accountNumber || (accountNumber != nil && meta["accountNumber"] == nil) { meta["accountNumber"] = tick }
        if generator != old.generator || (generator != nil && meta["generator"] == nil) { meta["generator"] = tick }
        metaClocks = meta.isEmpty ? nil : meta

        let oldDevices = Dictionary(uniqueKeysWithValues: (old.devices ?? []).map { ($0.id, $0) })
        if var devs = devices {
            for i in devs.indices where oldDevices[devs[i].id] != devs[i] || devs[i].clock == nil { devs[i].clock = tick }
            devices = devs
        }
    }

    /// Everything stamped after `since` (nil = everything). Merging a delta is idempotent, so resending is harmless.
    public func delta(since: HLC?) -> Vault {
        let s = since ?? .zero
        var d = Vault(logins: logins.filter { $0.newestClock > s }, passkeys: passkeys.filter { ($0.addedAt ?? .zero) > s })
        let t = (tombstones ?? [:]).filter { $0.value > s }
        d.tombstones = t.isEmpty ? nil : t
        d.cards = cards.filter { $0.newestClock > s }
        d.identities = identities.filter { $0.newestClock > s }
        d.notes = notes.filter { $0.newestClock > s }
        let devs = (devices ?? []).filter { ($0.clock ?? .zero) > s }
        d.devices = devs.isEmpty ? nil : devs
        let meta = metaClocks ?? [:]
        if let c = meta["recoveryPhrase"], c > s { d.recoveryPhrase = recoveryPhrase; d.metaClocks = (d.metaClocks ?? [:]).merging(["recoveryPhrase": c]) { $1 } }
        if let c = meta["accountNumber"], c > s { d.accountNumber = accountNumber; d.metaClocks = (d.metaClocks ?? [:]).merging(["accountNumber": c]) { $1 } }
        if let c = meta["generator"], c > s { d.generator = generator; d.metaClocks = (d.metaClocks ?? [:]).merging(["generator": c]) { $1 } }
        return d
    }

    public var isEmptyDelta: Bool {
        logins.isEmpty && passkeys.isEmpty && cards.isEmpty && identities.isEmpty && notes.isEmpty && (tombstones ?? [:]).isEmpty && (devices ?? []).isEmpty && (metaClocks ?? [:]).isEmpty
    }

    /// Merges another device's changes. Commutative, associative and idempotent: order and repeats don't matter.
    public mutating func merge(_ other: Vault) {
        var tomb = tombstones ?? [:]
        for (k, c) in other.tombstones ?? [:] where c > tomb[k] ?? .zero { tomb[k] = c }

        var byID = Dictionary(uniqueKeysWithValues: logins.map { ($0.id, $0) })
        for item in other.logins { byID[item.id] = byID[item.id].map { LoginItem.merged($0, item) } ?? item }
        // A delete wins over edits made before it; an edit made after a delete brings the login back.
        logins = byID.values.filter { item in
            guard let t = tomb[Self.loginKey(item.id)] else { return true }
            return item.newestClock > t
        }
        .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }

        mergeItems(\.cards, from: other.cards, tombstones: tomb)
        mergeItems(\.identities, from: other.identities, tombstones: tomb)
        mergeItems(\.notes, from: other.notes, tombstones: tomb)

        var pk = Dictionary(uniqueKeysWithValues: passkeys.map { ($0.credentialID, $0) })
        for p in other.passkeys where pk[p.credentialID] == nil { pk[p.credentialID] = p }
        passkeys = pk.values.filter { tomb[Self.passkeyKey($0.credentialID)] == nil }.sorted { $0.createdAt < $1.createdAt }
        tombstones = tomb.isEmpty ? nil : tomb

        var meta = metaClocks ?? [:]
        let om = other.metaClocks ?? [:]
        if let c = om["recoveryPhrase"], c > meta["recoveryPhrase"] ?? .zero { recoveryPhrase = other.recoveryPhrase; meta["recoveryPhrase"] = c }
        if let c = om["accountNumber"], c > meta["accountNumber"] ?? .zero { accountNumber = other.accountNumber; meta["accountNumber"] = c }
        if let c = om["generator"], c > meta["generator"] ?? .zero { generator = other.generator; meta["generator"] = c }
        metaClocks = meta.isEmpty ? nil : meta

        var devs = Dictionary(uniqueKeysWithValues: (devices ?? []).map { ($0.id, $0) })
        for d in other.devices ?? [] {
            guard var mine = devs[d.id] else { devs[d.id] = d; continue }
            if (d.clock ?? .zero) > (mine.clock ?? .zero) { let keepRevoked = mine.revoked; mine = d; mine.revoked = mine.revoked ?? keepRevoked }
            mine.revoked = mine.revoked ?? d.revoked   // a removal is never undone by a merge
            devs[d.id] = mine
        }
        devices = devs.isEmpty ? nil : devs.values.sorted { $0.linkedAt < $1.linkedAt }
    }

    public var activeDevices: [DeviceRecord] { (devices ?? []).filter(\.isActive) }
    public func device(_ id: String) -> DeviceRecord? { devices?.first { $0.id == id } }

    /// Adds or updates a device record (used when linking and when renaming).
    public mutating func upsertDevice(_ d: DeviceRecord) {
        var devs = devices ?? []
        if let i = devs.firstIndex(where: { $0.id == d.id }) { devs[i] = d } else { devs.append(d) }
        devices = devs
    }

    public mutating func revokeDevice(_ r: Revocation) {
        guard var devs = devices, let i = devs.firstIndex(where: { $0.id == r.device }) else { return }
        devs[i].revoked = r
        devices = devs
    }
}
