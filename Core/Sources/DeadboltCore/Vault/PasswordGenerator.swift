import Foundation

/// Password and passphrase generation from the system CSPRNG, with no modulo bias.
public enum PasswordGenerator {
    public struct Options: Codable, Equatable, Sendable {
        public var length: Int = 20
        public var upper: Bool = true       // A-Z
        public var lower: Bool = true       // a-z
        public var digits: Bool = true      // 0-9
        public var symbols: Bool = true     // !#$%&*…
        public var minDigits: Int = 1
        public var minSymbols: Int = 1
        public var avoidAmbiguous: Bool = true   // no 0/O, 1/l/I

        public init(length: Int = 20, symbols: Bool = true, digits: Bool = true, upper: Bool = true, lower: Bool = true,
                    minDigits: Int = 1, minSymbols: Int = 1, avoidAmbiguous: Bool = true) {
            self.length = length; self.symbols = symbols; self.digits = digits; self.upper = upper; self.lower = lower
            self.minDigits = minDigits; self.minSymbols = minSymbols; self.avoidAmbiguous = avoidAmbiguous
        }

        /// The same options, made safe to use: at least one character kind on, length 8…128, minimums that fit.
        public var normalized: Options {
            var o = self
            if !o.upper && !o.lower && !o.digits && !o.symbols { o.lower = true; o.upper = true }
            o.length = max(8, min(o.length, 128))
            o.minDigits = o.digits ? max(1, min(o.minDigits, 32)) : 0
            o.minSymbols = o.symbols ? max(1, min(o.minSymbols, 32)) : 0
            let letters = (o.upper ? 1 : 0) + (o.lower ? 1 : 0)
            // Leave room for one of each letter kind.
            while o.minDigits + o.minSymbols + letters > o.length {
                if o.minSymbols > (o.symbols ? 1 : 0) { o.minSymbols -= 1 } else if o.minDigits > (o.digits ? 1 : 0) { o.minDigits -= 1 } else { break }
            }
            return o
        }
    }

    /// What is synced between devices (inside the encrypted vault): password options plus passphrase length.
    public struct Settings: Codable, Equatable, Sendable {
        public var options = Options()
        public var words = 5
        public var passphrase = false   // last used kind in the generator screen
        public init(options: Options = Options(), words: Int = 5, passphrase: Bool = false) {
            self.options = options; self.words = words; self.passphrase = passphrase
        }
    }

    // Look-alike-free sets (0/O, 1/l/I) so a password can be read aloud or typed from another screen.
    static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digitSet = Array("23456789")
    static let symbolSet = Array("!#$%&*+-=?@^_")
    // Full sets, used when "avoid ambiguous characters" is off.
    static let lowerFull = Array("abcdefghijklmnopqrstuvwxyz")
    static let upperFull = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digitFull = Array("0123456789")

    /// Random characters: every enabled kind at least once, with the requested minimum of digits and symbols.
    public static func password(_ requested: Options = Options()) -> String {
        let o = requested.normalized
        let amb = o.avoidAmbiguous
        var chars: [Character] = []
        var pool: [Character] = []
        func add(_ on: Bool, _ set: [Character], required: Int) {
            guard on else { return }
            pool += set
            for _ in 0..<required { chars.append(pick(set)) }
        }
        add(o.lower, amb ? lower : lowerFull, required: 1)
        add(o.upper, amb ? upper : upperFull, required: 1)
        add(o.digits, amb ? digitSet : digitFull, required: o.minDigits)
        add(o.symbols, symbolSet, required: o.minSymbols)
        while chars.count < o.length { chars.append(pick(pool)) }
        // Fisher–Yates so the guaranteed characters aren't always at the front.
        for i in stride(from: chars.count - 1, to: 0, by: -1) {
            chars.swapAt(i, Int(Random.uniform(below: UInt64(i + 1))))
        }
        return String(chars)
    }

    public static func generate(_ s: Settings) -> String {
        s.passphrase ? passphrase(words: s.words) : password(s.options)
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
