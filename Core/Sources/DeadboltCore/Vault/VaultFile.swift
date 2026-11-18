import Foundation

/// The vault on disk: one file, everything inside sealed under the vault key.
///
///     { "format": 1, "epoch": 1, "wrapped": [WrappedVaultKey…], "vault": "<Envelope, base64>" }
///
/// `wrapped` holds the VK sealed under the master password (Argon2id) and the recovery key, so either can
/// open it. The Keychain/biometric copy of the VK lives in the Keychain, not here. Writes are atomic.
/// Phase 4 replaces the single sealed blob with per-record sealing + an op log for sync; the format number covers that.
public struct VaultFile: Codable, Equatable, Sendable {
    public static let format = 1
    static let context = "vault/v1"

    public var format: Int
    public var wrapped: [WrappedVaultKey]
    public var sealedVault: Data

    enum CodingKeys: String, CodingKey { case format, wrapped, sealedVault = "vault" }

    /// Creates a brand-new vault file.
    public static func create(vault: Vault, key: VaultKey, password: String, recoveryKey: RecoveryKey,
                              kdf: KDFParams = .fresh()) throws -> VaultFile {
        VaultFile(format: format,
                  wrapped: [try KeyWrap.wrap(key, password: password, params: kdf), try KeyWrap.wrap(key, recoveryKey: recoveryKey)],
                  sealedVault: try seal(vault, key: key))
    }

    public func unlock(password: String) throws -> (VaultKey, Vault) {
        guard let w = wrapped.first(where: { $0.wrapper == .masterPassword }) else { throw DeadboltError.malformed }
        let key = try KeyWrap.unwrap(w, password: password)
        return (key, try open(key: key))
    }

    public func unlock(recoveryKey: RecoveryKey) throws -> (VaultKey, Vault) {
        guard let w = wrapped.first(where: { $0.wrapper == .recoveryKey }) else { throw DeadboltError.malformed }
        let key = try KeyWrap.unwrap(w, recoveryKey: recoveryKey)
        return (key, try open(key: key))
    }

    public func open(key: VaultKey) throws -> Vault {
        guard format == Self.format else { throw DeadboltError.unsupportedVersion(UInt8(clamping: format)) }
        let json = try key.open(sealedVault, context: Self.context)
        return try JSONDecoder.deadbolt.decode(Vault.self, from: json)
    }

    /// Re-seals after a change. The wrapped keys are untouched.
    public mutating func update(_ vault: Vault, key: VaultKey) throws {
        sealedVault = try Self.seal(vault, key: key)
    }

    /// New master password: needs the unlocked VK (Face ID or the old password), re-wraps only the password slot.
    public mutating func changeMasterPassword(to password: String, key: VaultKey, kdf: KDFParams = .fresh()) throws {
        wrapped.removeAll { $0.wrapper == .masterPassword }
        wrapped.insert(try KeyWrap.wrap(key, password: password, params: kdf), at: 0)
    }

    private static func seal(_ vault: Vault, key: VaultKey) throws -> Data {
        try key.seal(JSONEncoder.deadbolt.encode(vault), context: context)
    }

    // MARK: disk

    public static func read(from url: URL) throws -> VaultFile {
        try JSONDecoder.deadbolt.decode(VaultFile.self, from: Data(contentsOf: url))
    }

    /// Atomic write, excluded from device backups (our own encrypted backup file covers recovery).
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.deadbolt.encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
    }
}

extension JSONEncoder {
    static var deadbolt: JSONEncoder {
        let e = JSONEncoder()   // default date strategy: exact round-trip
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var deadbolt: JSONDecoder {
        JSONDecoder()
    }
}
