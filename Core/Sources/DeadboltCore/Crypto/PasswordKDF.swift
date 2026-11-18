import CryptoKit
import Foundation
import Sodium

/// Argon2id (libsodium) turns the master password into a key-encryption key (KEK).
/// Parameters are stored next to the wrapped key so they can be raised later without breaking old vaults.
public struct KDFParams: Codable, Equatable, Sendable {
    public var algorithm: String = "argon2id13"
    public var opsLimit: Int
    public var memLimitBytes: Int
    public var salt: Data

    /// Default: 3 passes, 64 MiB. Phase 0 must confirm this fits inside the iOS AutoFill
    /// extension's memory budget on an iPhone 11 and unlocks in well under a second.
    public static func fresh(opsLimit: Int = 3, memLimitBytes: Int = 64 << 20) -> KDFParams {
        KDFParams(opsLimit: opsLimit, memLimitBytes: memLimitBytes, salt: Random.bytes(16))
    }

    /// Cheap parameters for unit tests only.
    static func testing() -> KDFParams { fresh(opsLimit: 1, memLimitBytes: 8 << 20) }
}

public enum PasswordKDF {
    public static func deriveKEK(password: String, params: KDFParams) throws -> SymmetricKey {
        guard params.algorithm == "argon2id13", params.salt.count == 16 else { throw DeadboltError.malformed }
        let normalized = Array(password.precomposedStringWithCompatibilityMapping.utf8) // NFKC
        guard let out = Sodium().pwHash.hash(
            outputLength: 32,
            passwd: normalized,
            salt: Array(params.salt),
            opsLimit: params.opsLimit,
            memLimit: params.memLimitBytes,
            alg: .Argon2ID13)
        else { throw DeadboltError.kdfFailed }
        return SymmetricKey(data: out)
    }
}
