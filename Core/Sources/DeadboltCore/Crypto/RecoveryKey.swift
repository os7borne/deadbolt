import CryptoKit
import Foundation

/// The 256-bit recovery key, shown to the owner as 24 words (BIP39 English list, SHA-256 checksum).
/// Wraps the vault key and encrypts backup files. Printed in the Recovery Kit; never stored on a server.
public struct RecoveryKey: Sendable, Equatable {
    public static let wordCount = 24
    let entropy: Data // 32 bytes

    public static func generate() -> RecoveryKey { RecoveryKey(entropy: Random.bytes(32)) }

    init(entropy: Data) {
        precondition(entropy.count == 32)
        self.entropy = entropy
    }

    /// 256 bits of entropy + 8 checksum bits = 264 bits = 24 × 11-bit word indices.
    public var words: [String] {
        let checksum = Array(SHA256.hash(data: entropy))[0]
        let bits = BitReader(bytes: [UInt8](entropy) + [checksum])
        let list = Wordlist.english
        return (0..<Self.wordCount).map { list[bits.read(11, at: $0 * 11)] }
    }

    public var phrase: String { words.joined(separator: " ") }

    /// Accepts any spacing/case. Also accepts each word's unique 4-letter prefix, as BIP39 guarantees.
    public init(phrase: String) throws {
        let typed = phrase.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        guard typed.count == Self.wordCount else {
            throw DeadboltError.invalidRecoveryPhrase("Expected \(Self.wordCount) words, got \(typed.count)")
        }
        var indices: [Int] = []
        for (n, word) in typed.enumerated() {
            guard let index = Wordlist.index(of: word) else {
                throw DeadboltError.invalidRecoveryPhrase("Word \(n + 1) isn't in the list")
            }
            indices.append(index)
        }
        var bytes = [UInt8](repeating: 0, count: 33)
        for (n, index) in indices.enumerated() {
            for bit in 0..<11 where index & (1 << (10 - bit)) != 0 {
                let pos = n * 11 + bit
                bytes[pos / 8] |= 0x80 >> UInt8(pos % 8)
            }
        }
        let entropy = Data(bytes[0..<32])
        guard Array(SHA256.hash(data: entropy))[0] == bytes[32] else {
            throw DeadboltError.invalidRecoveryPhrase("The words don't add up — check for a typo or a swapped word")
        }
        self.init(entropy: entropy)
    }

    func wrappingKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: entropy), salt: Data("deadbolt/recovery/v1".utf8), info: Data("wrap".utf8), outputByteCount: 32)
    }

    func backupKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: entropy), salt: Data("deadbolt/recovery/v1".utf8), info: Data("backup".utf8), outputByteCount: 32)
    }
}

private struct BitReader {
    let bytes: [UInt8]
    func read(_ count: Int, at offset: Int) -> Int {
        (0..<count).reduce(0) { acc, i in
            let pos = offset + i
            return acc << 1 | Int(bytes[pos / 8] >> (7 - UInt8(pos % 8)) & 1)
        }
    }
}

enum Wordlist {
    static let english: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("bip39-english.txt missing from DeadboltCore resources")
        }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        precondition(words.count == 2048, "BIP39 wordlist must have 2048 words")
        return words
    }()

    private static let exact: [String: Int] = Dictionary(uniqueKeysWithValues: english.enumerated().map { ($1, $0) })
    private static let prefixes: [String: Int] = Dictionary(uniqueKeysWithValues: english.enumerated().map { (String($1.prefix(4)), $0) })

    static func index(of word: String) -> Int? {
        if let i = exact[word] { return i }
        guard word.count >= 4, let i = prefixes[String(word.prefix(4))], english[i].hasPrefix(word) else { return nil }
        return i
    }
}
