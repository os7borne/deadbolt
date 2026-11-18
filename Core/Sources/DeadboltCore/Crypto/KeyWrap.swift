import CryptoKit
import Foundation

/// A vault key sealed under some other key: the master-password KEK or the recovery key.
/// This is what sits on disk; the raw VK only ever lives in memory.
public struct WrappedVaultKey: Codable, Equatable, Sendable {
    public enum Wrapper: String, Codable, Sendable { case masterPassword, recoveryKey }

    public let wrapper: Wrapper
    public let epoch: UInt32
    public let kdf: KDFParams?   // present for masterPassword
    public let sealed: Data

    static func context(_ wrapper: Wrapper, epoch: UInt32) -> String { "wrap/\(wrapper.rawValue)/vk-epoch-\(epoch)" }
}

public enum KeyWrap {
    public static func wrap(_ vk: VaultKey, password: String, params: KDFParams = .fresh()) throws -> WrappedVaultKey {
        let kek = try PasswordKDF.deriveKEK(password: password, params: params)
        let sealed = try Envelope.seal(vk.rawBytes(), key: kek, epoch: vk.epoch, context: WrappedVaultKey.context(.masterPassword, epoch: vk.epoch))
        return WrappedVaultKey(wrapper: .masterPassword, epoch: vk.epoch, kdf: params, sealed: sealed)
    }

    public static func wrap(_ vk: VaultKey, recoveryKey: RecoveryKey) throws -> WrappedVaultKey {
        let sealed = try Envelope.seal(vk.rawBytes(), key: recoveryKey.wrappingKey(), epoch: vk.epoch, context: WrappedVaultKey.context(.recoveryKey, epoch: vk.epoch))
        return WrappedVaultKey(wrapper: .recoveryKey, epoch: vk.epoch, kdf: nil, sealed: sealed)
    }

    /// Throws `.authenticationFailed` for a wrong password; callers show "wrong password" and nothing more.
    public static func unwrap(_ wrapped: WrappedVaultKey, password: String) throws -> VaultKey {
        guard wrapped.wrapper == .masterPassword, let params = wrapped.kdf else { throw DeadboltError.malformed }
        let kek = try PasswordKDF.deriveKEK(password: password, params: params)
        return try open(wrapped, key: kek)
    }

    public static func unwrap(_ wrapped: WrappedVaultKey, recoveryKey: RecoveryKey) throws -> VaultKey {
        guard wrapped.wrapper == .recoveryKey else { throw DeadboltError.malformed }
        return try open(wrapped, key: recoveryKey.wrappingKey())
    }

    private static func open(_ wrapped: WrappedVaultKey, key: SymmetricKey) throws -> VaultKey {
        guard try Envelope.epoch(of: wrapped.sealed) == wrapped.epoch else { throw DeadboltError.authenticationFailed }
        let raw = try Envelope.open(wrapped.sealed, key: key, context: WrappedVaultKey.context(wrapped.wrapper, epoch: wrapped.epoch))
        return try VaultKey(epoch: wrapped.epoch, rawBytes: raw)
    }
}
