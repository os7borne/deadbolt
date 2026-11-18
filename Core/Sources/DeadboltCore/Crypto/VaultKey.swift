import CryptoKit
import Foundation

/// The 256-bit vault key (VK). One per epoch; rotated when a device is removed.
/// Never used directly to encrypt: every purpose gets its own HKDF subkey.
public struct VaultKey: Sendable {
    public let epoch: UInt32
    let key: SymmetricKey

    public static func generate(epoch: UInt32 = 1) -> VaultKey {
        VaultKey(epoch: epoch, key: SymmetricKey(size: .bits256))
    }

    /// Rebuilds a VK from its raw bytes (after unwrapping). Callers should zero their copy afterwards.
    public init(epoch: UInt32, rawBytes: Data) throws {
        guard rawBytes.count == 32 else { throw DeadboltError.malformed }
        self.init(epoch: epoch, key: SymmetricKey(data: rawBytes))
    }

    init(epoch: UInt32, key: SymmetricKey) {
        self.epoch = epoch
        self.key = key
    }

    public enum Purpose: String, Sendable, CaseIterable {
        case items          // vault records at rest
        case sync           // ops sent through the relay
        case relayAddress   // derives the relay mailbox id (not secret-bearing, but unlinkable)
        case search         // keyed hashes for local lookup by domain
    }

    public func subkey(_ purpose: Purpose) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key,
            salt: Data("deadbolt/vk/v1".utf8),
            info: Data("\(purpose.rawValue)/epoch-\(epoch)".utf8),
            outputByteCount: 32)
    }

    /// Seals a record under the `items` subkey. `context` should name the record (e.g. "item/<uuid>").
    public func seal(_ plaintext: Data, purpose: Purpose = .items, context: String) throws -> Data {
        try Envelope.seal(plaintext, key: subkey(purpose), epoch: epoch, context: context)
    }

    public func open(_ sealed: Data, purpose: Purpose = .items, context: String) throws -> Data {
        guard try Envelope.epoch(of: sealed) == epoch else { throw DeadboltError.authenticationFailed }
        return try Envelope.open(sealed, key: subkey(purpose), context: context)
    }

    /// Raw bytes for wrapping. Keep the result short-lived.
    func rawBytes() -> Data { key.withUnsafeBytes { Data($0) } }

    /// Raw bytes for the biometric Keychain item ONLY (biometryCurrentSet, ThisDeviceOnly).
    /// Never log, persist elsewhere, or send these.
    public var keychainRepresentation: Data { rawBytes() }
}
