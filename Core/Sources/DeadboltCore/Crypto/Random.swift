import Foundation
import Security

/// Cryptographically secure random bytes for app code (link secrets etc.). Same source as `Random`.
public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data { Random.bytes(count) }
}

enum Random {
    /// Cryptographically secure random bytes from the system CSPRNG.
    static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed") // unrecoverable: never fall back
        return data
    }

    /// Uniform integer in 0..<upperBound with no modulo bias.
    static func uniform(below upperBound: UInt64) -> UInt64 {
        var rng = SystemRandomNumberGenerator() // CSPRNG on Apple platforms
        return UInt64.random(in: 0..<upperBound, using: &rng)
    }
}
