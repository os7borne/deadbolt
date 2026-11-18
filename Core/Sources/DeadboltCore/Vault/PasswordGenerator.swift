import Foundation

/// Password and passphrase generation from the system CSPRNG, with no modulo bias.
public enum PasswordGenerator {
    public struct Options: Equatable, Sendable {
        public var length: Int = 20
        public var symbols: Bool = true
        public var digits: Bool = true
        public init(length: Int = 20, symbols: Bool = true, digits: Bool = true) {
            self.length = length; self.symbols = symbols; self.digits = digits
        }
    }

    // No look-alikes (0/O, 1/l/I) so a password can be read aloud or typed from another screen.
    static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digitSet = Array("23456789")
    static let symbolSet = Array("!#$%&*+-=?@^_")

    /// Random characters, guaranteed to contain each enabled class at least once.
    public static func password(_ o: Options = Options()) -> String {
        let length = max(8, min(o.length, 128))
        var classes: [[Character]] = [lower, upper]
        if o.digits { classes.append(digitSet) }
        if o.symbols { classes.append(symbolSet) }
        let all = classes.flatMap { $0 }
        var chars = classes.map { pick($0) }
        while chars.count < length { chars.append(pick(all)) }
        // Fisher–Yates so the guaranteed characters aren't always at the front.
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            chars.swapAt(i, Int(Random.uniform(below: UInt64(i + 1))))
        }
        return String(chars)
    }

    /// Words from the BIP39 list joined by "-", plus one digit: "copper-lantern-orbit-maple-7".
    /// 5 words ≈ 55 bits + digit; good for a master password you have to remember.
    public static func passphrase(words: Int = 5) -> String {
        let list = Wordlist.english
        let chosen = (0..<max(3, words)).map { _ in list[Int(Random.uniform(below: UInt64(list.count)))] }
        return chosen.joined(separator: "-") + "-" + String(Random.uniform(below: 10))
    }

    private static func pick(_ set: [Character]) -> Character { set[Int(Random.uniform(below: UInt64(set.count)))] }
}
