import Foundation

/// Mullvad-style 16-digit account number: 15 random digits + a Luhn check digit (catches typos and swaps).
/// It is an address for linking, not a secret: knowing it lets someone *ask* to link, never decrypt.
public struct AccountNumber: Hashable, Sendable, CustomStringConvertible {
    public let digits: String

    public static func generate() -> AccountNumber {
        var body = ""
        for _ in 0..<15 { body.append(String(Random.uniform(below: 10))) }
        return AccountNumber(unchecked: body + String(luhnDigit(for: body)))
    }

    /// Accepts spaces and dashes: "4821 0937 1156 2204" or "4821-0937-1156-2204".
    public init(_ input: String) throws {
        let digits = input.filter { !$0.isWhitespace && $0 != "-" }
        guard digits.count == 16, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              Self.luhnDigit(for: String(digits.prefix(15))) == Int(String(digits.last!))
        else { throw DeadboltError.invalidAccountNumber }
        self.digits = digits
    }

    private init(unchecked digits: String) { self.digits = digits }

    /// Grouped for display: "4821 0937 1156 2204".
    public var description: String {
        stride(from: 0, to: 16, by: 4).map { i in
            String(digits[digits.index(digits.startIndex, offsetBy: i)..<digits.index(digits.startIndex, offsetBy: i + 4)])
        }.joined(separator: " ")
    }

    static func luhnDigit(for body: String) -> Int {
        // Double every second digit from the right of the full number (i.e. from the right of `body`, starting with the last).
        let sum = body.reversed().enumerated().reduce(0) { acc, pair in
            let d = Int(String(pair.element))!
            if pair.offset % 2 == 0 { let x = d * 2; return acc + (x > 9 ? x - 9 : x) }
            return acc + d
        }
        return (10 - sum % 10) % 10
    }
}
