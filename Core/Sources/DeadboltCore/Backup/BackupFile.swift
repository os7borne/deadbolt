import Foundation

/// An encrypted backup of the whole vault, sealed under a key derived from the **recovery key**
/// (not the master password), so a stolen backup file can't be attacked by guessing a password.
///
///     { "kind": "deadbolt-backup", "format": 1, "createdAt": <Date>, "items": 214, "sealed": "<Envelope, base64>" }
///
/// `items` is the only plaintext detail, shown when picking a file to restore.
public struct BackupFile: Codable, Equatable, Sendable {
    public static let kind = "deadbolt-backup"
    public static let format = 1
    public static let fileExtension = "deadbolt"
    static let context = "backup/v1"

    public let kind: String
    public let format: Int
    public let createdAt: Date
    public let items: Int
    public let sealed: Data

    public static func make(_ vault: Vault, recoveryKey: RecoveryKey, now: Date = Date()) throws -> BackupFile {
        let json = try JSONEncoder.deadbolt.encode(vault)
        let sealed = try Envelope.seal(json, key: recoveryKey.backupKey(), epoch: 0, context: context)
        return BackupFile(kind: kind, format: format, createdAt: now, items: vault.itemCount, sealed: sealed)
    }

    public static func read(_ data: Data) throws -> BackupFile {
        let file = try JSONDecoder.deadbolt.decode(BackupFile.self, from: data)
        guard file.kind == kind else { throw DeadboltError.malformed }
        guard file.format == format else { throw DeadboltError.unsupportedVersion(UInt8(clamping: file.format)) }
        return file
    }

    /// Wrong recovery words → `.authenticationFailed`.
    public func open(recoveryKey: RecoveryKey) throws -> Vault {
        let json = try Envelope.open(sealed, key: recoveryKey.backupKey(), context: Self.context)
        return try JSONDecoder.deadbolt.decode(Vault.self, from: json)
    }

    public func encoded() throws -> Data { try JSONEncoder.deadbolt.encode(self) }

    /// "Deadbolt Backup 2026-11-18 1432.deadbolt"
    public static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "Deadbolt Backup \(f.string(from: date)).\(fileExtension)"
    }
}

extension VaultFile {
    /// A brand-new vault file holding restored contents: new vault key, new master password,
    /// the SAME recovery key (so the printed Recovery Kit keeps working).
    public static func restore(_ vault: Vault, recoveryKey: RecoveryKey, password: String, kdf: KDFParams = .fresh()) throws -> (VaultFile, VaultKey) {
        var vault = vault
        vault.recoveryPhrase = recoveryKey.phrase
        let key = VaultKey.generate()
        return (try create(vault: vault, key: key, password: password, recoveryKey: recoveryKey, kdf: kdf), key)
    }
}
