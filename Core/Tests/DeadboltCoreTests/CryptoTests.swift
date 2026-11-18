import CryptoKit
import Foundation
import Testing
@testable import DeadboltCore

@Suite struct EnvelopeTests {
    let key = SymmetricKey(size: .bits256)

    @Test func roundTrips() throws {
        let sealed = try Envelope.seal(Data("hunter2".utf8), key: key, epoch: 7, context: "item/a")
        #expect(try Envelope.epoch(of: sealed) == 7)
        #expect(try Envelope.open(sealed, key: key, context: "item/a") == Data("hunter2".utf8))
    }

    @Test func freshNonceEverySeal() throws {
        let a = try Envelope.seal(Data("x".utf8), key: key, epoch: 1, context: "c")
        let b = try Envelope.seal(Data("x".utf8), key: key, epoch: 1, context: "c")
        #expect(a != b)
    }

    @Test func rejectsWrongContextKeyTamperAndEpochSwap() throws {
        var sealed = try Envelope.seal(Data("secret".utf8), key: key, epoch: 1, context: "item/a")
        #expect(throws: DeadboltError.authenticationFailed) { try Envelope.open(sealed, key: key, context: "item/b") }
        #expect(throws: DeadboltError.authenticationFailed) { try Envelope.open(sealed, key: SymmetricKey(size: .bits256), context: "item/a") }

        var flipped = sealed
        flipped[flipped.count - 1] ^= 0x01
        #expect(throws: DeadboltError.authenticationFailed) { try Envelope.open(flipped, key: key, context: "item/a") }

        sealed[4] = 2 // claim epoch 2: header is AAD, so this must fail
        #expect(throws: DeadboltError.authenticationFailed) { try Envelope.open(sealed, key: key, context: "item/a") }
    }

    @Test func rejectsShortAndUnknownVersion() {
        #expect(throws: DeadboltError.malformed) { try Envelope.open(Data([1, 0, 0]), key: key, context: "c") }
        let bogus = Data([9] + [UInt8](repeating: 0, count: 40))
        #expect(throws: DeadboltError.unsupportedVersion(9)) { try Envelope.open(bogus, key: key, context: "c") }
    }
}

@Suite struct VaultKeyTests {
    @Test func subkeysDifferPerPurposeAndEpoch() {
        let raw = Data(repeating: 0x42, count: 32)
        let e1 = try! VaultKey(epoch: 1, rawBytes: raw)
        let e2 = try! VaultKey(epoch: 2, rawBytes: raw)
        let bytes = { (k: SymmetricKey) in k.withUnsafeBytes { Data($0) } }
        let all = VaultKey.Purpose.allCases.map { bytes(e1.subkey($0)) } + [bytes(e2.subkey(.items))]
        #expect(Set(all).count == all.count)
        #expect(!all.contains(raw))
    }

    @Test func sealOpenAndEpochMismatch() throws {
        let vk = VaultKey.generate(epoch: 3)
        let sealed = try vk.seal(Data("p".utf8), context: "item/1")
        #expect(try vk.open(sealed, context: "item/1") == Data("p".utf8))
        #expect(throws: DeadboltError.authenticationFailed) { try vk.open(sealed, purpose: .sync, context: "item/1") }
        let rotated = try VaultKey(epoch: 4, rawBytes: vk.rawBytes())
        #expect(throws: DeadboltError.authenticationFailed) { try rotated.open(sealed, context: "item/1") }
    }
}

@Suite struct KeyWrapTests {
    @Test func masterPasswordWrap() throws {
        let vk = VaultKey.generate()
        let wrapped = try KeyWrap.wrap(vk, password: "copper-lantern-orbit-maple", params: .testing())
        let back = try KeyWrap.unwrap(wrapped, password: "copper-lantern-orbit-maple")
        #expect(back.rawBytes() == vk.rawBytes())
        #expect(throws: DeadboltError.authenticationFailed) { try KeyWrap.unwrap(wrapped, password: "copper-lantern-orbit-maplE") }
    }

    @Test func passwordIsUnicodeNormalized() throws {
        let vk = VaultKey.generate()
        let wrapped = try KeyWrap.wrap(vk, password: "caf\u{00E9}", params: .testing())   // é precomposed
        #expect(try KeyWrap.unwrap(wrapped, password: "cafe\u{0301}").rawBytes() == vk.rawBytes()) // e + combining accent
    }

    @Test func wrappedKeySurvivesJSON() throws {
        let vk = VaultKey.generate(epoch: 5)
        let wrapped = try KeyWrap.wrap(vk, password: "pw", params: .testing())
        let decoded = try JSONDecoder().decode(WrappedVaultKey.self, from: JSONEncoder().encode(wrapped))
        #expect(try KeyWrap.unwrap(decoded, password: "pw").epoch == 5)
    }

    @Test func recoveryKeyWrap() throws {
        let vk = VaultKey.generate()
        let rk = RecoveryKey.generate()
        let wrapped = try KeyWrap.wrap(vk, recoveryKey: rk)
        #expect(try KeyWrap.unwrap(wrapped, recoveryKey: RecoveryKey(phrase: rk.phrase)).rawBytes() == vk.rawBytes())
        #expect(throws: DeadboltError.authenticationFailed) { try KeyWrap.unwrap(wrapped, recoveryKey: .generate()) }
        #expect(throws: DeadboltError.malformed) { try KeyWrap.unwrap(wrapped, password: "x") }
    }
}

@Suite struct RecoveryKeyTests {
    // Official BIP39 vectors (trezor/python-mnemonic vectors.json), 256-bit entropy.
    @Test(arguments: [
        ("00", "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"),
        ("7f", "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"),
        ("ff", "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"),
    ])
    func vectors(byte: String, phrase: String) throws {
        let entropy = Data(repeating: UInt8(byte, radix: 16)!, count: 32)
        #expect(RecoveryKey(entropy: entropy).phrase == phrase)
        #expect(try RecoveryKey(phrase: phrase).entropy == entropy)
    }

    @Test func roundTripsAndAcceptsPrefixesAndSpacing() throws {
        let rk = RecoveryKey.generate()
        #expect(try RecoveryKey(phrase: rk.phrase) == rk)
        let messy = "  " + rk.words.map { String($0.prefix(4)).uppercased() }.joined(separator: "  \n") + " "
        #expect(try RecoveryKey(phrase: messy) == rk)
    }

    @Test func rejectsBadPhrases() {
        let words = RecoveryKey.generate().words
        #expect(throws: DeadboltError.self) { try RecoveryKey(phrase: words.dropLast().joined(separator: " ")) }
        #expect(throws: DeadboltError.self) { try RecoveryKey(phrase: (words.dropLast() + ["notaword"]).joined(separator: " ")) }
        // The 8-bit checksum catches ~255/256 swaps, so test a fixed phrase rather than a random one.
        let swapped = "winner legal thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
        #expect(throws: DeadboltError.self) { try RecoveryKey(phrase: swapped) }
    }
}

@Suite struct AccountNumberTests {
    @Test func knownLuhn() throws {
        #expect(AccountNumber.luhnDigit(for: "411111111111111") == 1)
        #expect(try AccountNumber("4111-1111 1111-1111").description == "4111 1111 1111 1111")
        #expect(throws: DeadboltError.invalidAccountNumber) { try AccountNumber("4111111111111112") }
    }

    @Test func generatedNumbersValidateAndCatchTypos() throws {
        for _ in 0..<200 {
            let n = AccountNumber.generate()
            #expect(try AccountNumber(n.description) == n)
            var d = Array(n.digits)
            d[3] = d[3] == "0" ? "1" : "0"
            #expect(throws: DeadboltError.invalidAccountNumber) { try AccountNumber(String(d)) }
        }
    }

    @Test func rejectsWrongShape() {
        for bad in ["", "123", "41111111111111111", "4111 1111 1111 111a", "４１１１１１１１１１１１１１１１"] {
            #expect(throws: DeadboltError.invalidAccountNumber) { try AccountNumber(bad) }
        }
    }
}
