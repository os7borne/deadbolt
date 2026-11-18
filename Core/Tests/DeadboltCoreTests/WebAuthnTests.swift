import CryptoKit
import Foundation
import Testing
@testable import DeadboltCore

@Suite struct CBORTests {
    // RFC 8949 Appendix A examples.
    @Test(arguments: [
        (CBOR.int(0), "00"), (.int(23), "17"), (.int(24), "1818"), (.int(1000), "1903e8"),
        (.int(1_000_000), "1a000f4240"), (.int(-1), "20"), (.int(-7), "26"), (.int(-1000), "3903e7"),
        (.bytes(Data([1, 2, 3, 4])), "4401020304"), (.text("IETF"), "6449455446"), (.map([]), "a0"),
    ])
    func rfcVectors(value: CBOR, hex: String) {
        #expect(value.encoded.hex == hex)
    }

    @Test func longByteStringUsesOneByteLength() {
        #expect(CBOR.bytes(Data(count: 148)).encoded.prefix(2).hex == "5894")
    }
}

@Suite struct WebAuthnTests {
    let passkey = Passkey.create(relyingPartyID: "webauthn.io", userName: "osborne", userHandle: Data("user-1".utf8))

    @Test func registrationAttestationObjectLayout() throws {
        let reg = try WebAuthn.register(passkey, supportedAlgorithms: [-7, -257])
        let att = reg.attestationObject
        // a3 | "fmt" "none" | "attStmt" {} | "authData" bytes(len)
        let prefix = "a3" + "63666d74" + "646e6f6e65" + "6761747453746d74" + "a0" + "6861757468446174" + "61"
        #expect(att.hex.hasPrefix(prefix))

        let authData = att.dropFirst(prefix.count / 2 + 2) // skip 0x58 <len>
        let bytes = [UInt8](authData)
        #expect(Data(bytes[0..<32]) == Data(SHA256.hash(data: Data("webauthn.io".utf8))))
        #expect(bytes[32] == 0x5D) // UP | UV | BE | BS | AT
        #expect(bytes[33..<37] == [0, 0, 0, 0])
        #expect(Data(bytes[37..<53]) == WebAuthn.aaguid)
        #expect(Int(bytes[53]) << 8 | Int(bytes[54]) == 16)
        #expect(Data(bytes[55..<71]) == passkey.credentialID)

        let cose = Data(bytes[71...])
        let point = try passkey.publicKey.x963Representation
        let expected = "a5" + "0102" + "0326" + "2001" + "215820" + point[1..<33].hex + "225820" + point[33..<65].hex
        #expect(cose.hex == expected)
        #expect(bytes.count == 71 + 77)
    }

    @Test func rejectsRequestsWithoutES256() {
        #expect(throws: WebAuthnError.unsupportedAlgorithm) { try WebAuthn.register(passkey, supportedAlgorithms: [-257]) }
    }

    @Test func assertionSignatureVerifies() throws {
        let clientDataHash = Data(SHA256.hash(data: Data(#"{"type":"webauthn.get","challenge":"abc"}"#.utf8)))
        let a = try WebAuthn.assert(passkey, clientDataHash: clientDataHash)
        #expect(a.authenticatorData.count == 37)
        #expect(a.authenticatorData[32] == 0x1D) // UP | UV | BE | BS, no AT
        #expect(a.userHandle == passkey.userHandle)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: a.signature)
        #expect(try passkey.publicKey.isValidSignature(sig, for: a.authenticatorData + clientDataHash))
        #expect(try !passkey.publicKey.isValidSignature(sig, for: a.authenticatorData + Data(count: 32)))
    }

    @Test func rejectsBadClientDataHash() {
        #expect(throws: WebAuthnError.badClientDataHash) { try WebAuthn.assert(passkey, clientDataHash: Data(count: 31)) }
    }

    @Test func passkeySurvivesJSON() throws {
        let back = try JSONDecoder().decode(Passkey.self, from: JSONEncoder().encode(passkey))
        #expect(back == passkey)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
