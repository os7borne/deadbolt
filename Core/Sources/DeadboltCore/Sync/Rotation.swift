import CryptoKit
import Foundation

/// The next vault key, sealed to one remaining device's key-agreement key (ephemeral ECDH + HKDF + AES-GCM).
/// Only that device's private agreement key — in its Secure Enclave — can open it.
public struct KeyGrant: Codable, Equatable, Sendable {
    public let device: String
    public let ephemeral: Data
    public let sealed: Data

    static func info(_ device: String, _ epoch: UInt32) -> Data { Data("deadbolt/rotate/v1/\(device)/\(epoch)".utf8) }

    public static func make(_ key: VaultKey, for device: DeviceRecord) throws -> KeyGrant {
        let eph = P256.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: device.agreementKey))
        let k = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: eph.publicKey.x963Representation, sharedInfo: info(device.id, key.epoch), outputByteCount: 32)
        var raw = withUnsafeBytes(of: key.epoch.bigEndian) { Data($0) }
        raw.append(key.keychainRepresentation)
        return KeyGrant(device: device.id, ephemeral: eph.publicKey.x963Representation,
                        sealed: try Envelope.seal(raw, key: k, epoch: key.epoch, context: "rotate/v1/grant"))
    }

    public func open(with keys: DeviceKeys) throws -> VaultKey {
        let epoch = try Envelope.epoch(of: sealed)
        let shared = try keys.sharedSecret(with: ephemeral)
        let k = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral, sharedInfo: Self.info(device, epoch), outputByteCount: 32)
        let raw = try Envelope.open(sealed, key: k, context: "rotate/v1/grant")
        guard raw.count == 36, raw.prefix(4).reduce(UInt32(0), { $0 << 8 | UInt32($1) }) == epoch else { throw DeadboltError.malformed }
        return try VaultKey(epoch: epoch, rawBytes: raw.suffix(32))
    }
}

/// Sent in the OLD mailbox (sealed under the old key and signed) after a device is removed.
public struct RotatePayload: Codable, Equatable, Sendable {
    public let epoch: UInt32
    public let removed: String
    public let grants: [KeyGrant]
    /// The new key wrapped by the master password and by the recovery key, so every device can still unlock.
    public let wrapped: [WrappedVaultKey]

    public init(epoch: UInt32, removed: String, grants: [KeyGrant], wrapped: [WrappedVaultKey]) {
        self.epoch = epoch; self.removed = removed; self.grants = grants; self.wrapped = wrapped
    }
}

extension VaultFile {
    /// The same vault sealed under a new key, with that key's wrapped copies.
    public static func rekeyed(_ vault: Vault, key: VaultKey, wrapped: [WrappedVaultKey]) throws -> VaultFile {
        guard !wrapped.isEmpty, wrapped.allSatisfy({ $0.epoch == key.epoch }) else { throw DeadboltError.malformed }
        var file = VaultFile(format: format, wrapped: wrapped, sealedVault: Data())
        try file.update(vault, key: key)
        return file
    }
}
