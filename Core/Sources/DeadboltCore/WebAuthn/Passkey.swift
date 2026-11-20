import CryptoKit
import Foundation

/// A Deadbolt passkey: an ES256 (P-256) key pair bound to one relying party.
/// Synced through the vault, so it is a "backup eligible + backed up" credential (BE/BS flags).
public struct Passkey: Codable, Equatable, Sendable {
    public let credentialID: Data
    public let relyingPartyID: String
    public let userName: String
    public let userHandle: Data
    public let privateKey: Data      // P-256 raw representation; lives only inside the encrypted vault
    public let createdAt: Date
    /// When this passkey was added, for sync. nil on vaults made before sync.
    public var addedAt: HLC? = nil

    public static func create(relyingPartyID: String, userName: String, userHandle: Data) -> Passkey {
        Passkey(credentialID: Random.bytes(16), relyingPartyID: relyingPartyID, userName: userName,
                userHandle: userHandle, privateKey: P256.Signing.PrivateKey().rawRepresentation, createdAt: Date())
    }

    public var publicKey: P256.Signing.PublicKey {
        get throws { try P256.Signing.PrivateKey(rawRepresentation: privateKey).publicKey }
    }
}

public enum WebAuthn {
    /// COSE algorithm identifier for ES256. The only algorithm Deadbolt creates.
    public static let es256 = -7

    /// Deadbolt's authenticator AAGUID. Fixed forever: relying parties may use it to show which manager holds a passkey.
    public static let aaguid = Data(UUID(uuidString: "6E2A9C14-58B3-4F0D-9B7E-2D41C8A3F5E6")!.uuidBytes)

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let userPresent         = Flags(rawValue: 0x01)
        public static let userVerified        = Flags(rawValue: 0x04)
        public static let backupEligible      = Flags(rawValue: 0x08)
        public static let backedUp            = Flags(rawValue: 0x10)
        public static let attestedCredential  = Flags(rawValue: 0x40)
    }

    /// Flags for a synced passkey after the owner passed Face ID / Touch ID / master password.
    static let verifiedSynced: Flags = [.userPresent, .userVerified, .backupEligible, .backedUp]

    public struct Registration: Sendable {
        public let credentialID: Data
        public let attestationObject: Data
        public let authenticatorData: Data   // for browsers' getAuthenticatorData()
        public let publicKeyDER: Data        // SubjectPublicKeyInfo, for browsers' getPublicKey()
    }

    public struct Assertion: Sendable {
        public let credentialID: Data
        public let userHandle: Data
        public let authenticatorData: Data
        public let signature: Data   // DER-encoded ECDSA, as WebAuthn expects
    }

    /// Builds the registration response with "none" attestation (no device-identifying certificate).
    /// The caller must have verified the user first; `supportedAlgorithms` comes from the request.
    public static func register(_ passkey: Passkey, supportedAlgorithms: [Int]) throws -> Registration {
        guard supportedAlgorithms.isEmpty || supportedAlgorithms.contains(es256) else { throw WebAuthnError.unsupportedAlgorithm }
        let authData = try authenticatorData(rpID: passkey.relyingPartyID,
                                             flags: verifiedSynced.union(.attestedCredential),
                                             attested: attestedCredentialData(passkey))
        let attestation = CBOR.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authData)),
        ]).encoded
        return Registration(credentialID: passkey.credentialID, attestationObject: attestation,
                            authenticatorData: authData, publicKeyDER: try passkey.publicKey.derRepresentation)
    }

    /// Signs `authenticatorData || clientDataHash` for a sign-in. The caller must have verified the user first.
    public static func assert(_ passkey: Passkey, clientDataHash: Data) throws -> Assertion {
        guard clientDataHash.count == 32 else { throw WebAuthnError.badClientDataHash }
        let authData = try authenticatorData(rpID: passkey.relyingPartyID, flags: verifiedSynced, attested: nil)
        let key = try P256.Signing.PrivateKey(rawRepresentation: passkey.privateKey)
        let signature = try key.signature(for: authData + clientDataHash).derRepresentation
        return Assertion(credentialID: passkey.credentialID, userHandle: passkey.userHandle,
                         authenticatorData: authData, signature: signature)
    }

    /// rpIdHash(32) | flags(1) | signCount(4, always 0 for synced passkeys) | [attestedCredentialData]
    static func authenticatorData(rpID: String, flags: Flags, attested: Data?) throws -> Data {
        guard !rpID.isEmpty else { throw WebAuthnError.badRelyingParty }
        var data = Data(SHA256.hash(data: Data(rpID.utf8)))
        data.append(flags.rawValue)
        data.append(contentsOf: [0, 0, 0, 0])
        if let attested { data.append(attested) }
        return data
    }

    /// aaguid(16) | credentialIdLength(2, big-endian) | credentialId | COSE public key
    static func attestedCredentialData(_ passkey: Passkey) throws -> Data {
        let id = passkey.credentialID
        guard id.count <= 1023 else { throw WebAuthnError.badCredentialID }
        var data = aaguid
        data.append(contentsOf: [UInt8(id.count >> 8), UInt8(id.count & 0xff)])
        data.append(id)
        data.append(try coseKey(passkey.publicKey))
        return data
    }

    /// COSE_Key for EC2 / P-256 / ES256, keys in CTAP2 canonical order: 1, 3, -1, -2, -3.
    static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
        let point = key.x963Representation // 0x04 | x(32) | y(32)
        return CBOR.map([
            (.int(1), .int(2)),          // kty: EC2
            (.int(3), .int(es256)),      // alg: ES256
            (.int(-1), .int(1)),         // crv: P-256
            (.int(-2), .bytes(point[1..<33])),
            (.int(-3), .bytes(point[33..<65])),
        ]).encoded
    }
}

public enum WebAuthnError: Error, Equatable, Sendable {
    case unsupportedAlgorithm, badClientDataHash, badRelyingParty, badCredentialID
}

private extension UUID {
    var uuidBytes: [UInt8] { withUnsafeBytes(of: uuid) { Array($0) } }
}
