import CryptoKit
import Foundation

/// Time-based one-time codes (RFC 6238). Accepts a bare base32 setup key or an `otpauth://totp/…` link.
public struct TOTP: Equatable, Sendable {
    public enum Algorithm: String, Sendable { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    public let secret: Data
    public var algorithm: Algorithm = .sha1
    public var digits: Int = 6
    public var period: Int = 30
    public var issuer: String?
    public var account: String?

    public init(secret: Data, algorithm: Algorithm = .sha1, digits: Int = 6, period: Int = 30) {
        self.secret = secret; self.algorithm = algorithm; self.digits = digits; self.period = period
    }

    /// "JBSW Y3DP EHPK 3PXP", "jbswy3dpehpk3pxp" or "otpauth://totp/GitHub:alex?secret=…&issuer=GitHub".
    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            try self.init(uri: trimmed)
        } else {
            guard let key = Base32.decode(trimmed), key.count >= 10 else { throw TOTPError.invalidSecret }
            self.init(secret: key)
        }
    }

    private init(uri: String) throws {
        guard let c = URLComponents(string: uri), c.scheme?.lowercased() == "otpauth" else { throw TOTPError.invalidURI }
        guard c.host?.lowercased() == "totp" else { throw TOTPError.unsupportedType }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let key = q["secret"].flatMap(Base32.decode), key.count >= 10 else { throw TOTPError.invalidSecret }
        self.init(secret: key)
        if let a = q["algorithm"] { guard let alg = Algorithm(rawValue: a.uppercased()) else { throw TOTPError.invalidURI }; algorithm = alg }
        if let d = q["digits"] { guard let n = Int(d), (6...8).contains(n) else { throw TOTPError.invalidURI }; digits = n }
        if let p = q["period"] { guard let n = Int(p), (10...300).contains(n) else { throw TOTPError.invalidURI }; period = n }
        let label = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        let parts = label.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        issuer = q["issuer"].flatMap { $0.isEmpty ? nil : $0 } ?? (parts.count == 2 ? parts[0] : nil)
        account = parts.last.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The code for a moment in time.
    public func code(at date: Date = Date()) -> String {
        code(counter: UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period))
    }

    /// Seconds until the current code changes.
    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(UInt64(max(0, date.timeIntervalSince1970)) % UInt64(period))
    }

    func code(counter: UInt64) -> String {
        var c = counter.bigEndian
        let msg = Data(bytes: &c, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        }
        let o = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        let mod = UInt32(pow(10, Double(digits)))
        let s = String(bin % mod)
        return String(repeating: "0", count: digits - s.count) + s
    }

    /// "302718" → "302 718" for display.
    public static func grouped(_ code: String) -> String {
        guard code.count >= 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: code.count / 2)
        return code[..<mid] + " " + code[mid...]
    }
}

public enum TOTPError: Error, Equatable, Sendable { case invalidSecret, invalidURI, unsupportedType }

/// RFC 4648 base32, case-insensitive, ignoring spaces, dashes and padding.
enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ s: String) -> Data? {
        let clean = s.uppercased().filter { !" -=\t\n".contains($0) }
        guard !clean.isEmpty else { return nil }
        var buffer: UInt64 = 0, bits = 0
        var out = Data()
        for ch in clean {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt64(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        return out
    }

    static func encode(_ data: Data) -> String {
        var out = "", buffer: UInt64 = 0, bits = 0
        for b in data {
            buffer = (buffer << 8) | UInt64(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[Int((buffer >> UInt64(bits)) & 31)]) }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt64(5 - bits)) & 31)]) }
        return out
    }
}
