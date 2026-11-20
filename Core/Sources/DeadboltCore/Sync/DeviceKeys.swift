import CryptoKit
import Foundation

/// This device's identity: a P-256 signing key (signs sync messages and relay requests) and a P-256
/// key-agreement key (receives a new vault key when another device is removed).
/// On devices with a Secure Enclave the private keys are created inside it and can't be exported;
/// `signing`/`agreement` then hold the enclave's opaque, device-bound handles.
public struct DeviceKeys: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case secureEnclave, software }

    public let kind: Kind
    let signing: Data
    let agreement: Data

    public static func generate(preferSecureEnclave: Bool = true) throws -> DeviceKeys {
        if preferSecureEnclave && SecureEnclave.isAvailable {
            return DeviceKeys(kind: .secureEnclave,
                              signing: try SecureEnclave.P256.Signing.PrivateKey().dataRepresentation,
                              agreement: try SecureEnclave.P256.KeyAgreement.PrivateKey().dataRepresentation)
        }
        return DeviceKeys(kind: .software,
                          signing: P256.Signing.PrivateKey().rawRepresentation,
                          agreement: P256.KeyAgreement.PrivateKey().rawRepresentation)
    }

    public var signingPublicKey: Data {
        get throws {
            switch kind {
            case .secureEnclave: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: signing).publicKey.x963Representation
            case .software: try P256.Signing.PrivateKey(rawRepresentation: signing).publicKey.x963Representation
            }
        }
    }

    public var agreementPublicKey: Data {
        get throws {
            switch kind {
            case .secureEnclave: try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agreement).publicKey.x963Representation
            case .software: try P256.KeyAgreement.PrivateKey(rawRepresentation: agreement).publicKey.x963Representation
            }
        }
    }

    /// ECDSA P-256 / SHA-256, raw r‖s (64 bytes) — the same format WebCrypto verifies.
    public func sign(_ message: Data) throws -> Data {
        switch kind {
        case .secureEnclave: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: signing).signature(for: message).rawRepresentation
        case .software: try P256.Signing.PrivateKey(rawRepresentation: signing).signature(for: message).rawRepresentation
        }
    }

    public func sharedSecret(with peer: Data) throws -> SharedSecret {
        let pub = try P256.KeyAgreement.PublicKey(x963Representation: peer)
        switch kind {
        case .secureEnclave: return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: agreement).sharedSecretFromKeyAgreement(with: pub)
        case .software: return try P256.KeyAgreement.PrivateKey(rawRepresentation: agreement).sharedSecretFromKeyAgreement(with: pub)
        }
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: message)
    }

    /// Signs "device X removed by me".
    public func revoke(device: String, by me: String, at: Date = Date()) throws -> Revocation {
        let at = Date(timeIntervalSince1970: (at.timeIntervalSince1970 * 1000).rounded() / 1000)
        return Revocation(device: device, by: me, at: at, signature: try sign(Revocation.message(device: device, by: me, at: at)))
    }
}

extension Revocation {
    /// True if `signer` (a device record from the vault) really signed this removal.
    public func isValid(signer: DeviceRecord) -> Bool {
        signer.id == by && DeviceKeys.verify(signature: signature, message: Self.message(device: device, by: by, at: at), publicKey: signer.signingKey)
    }
}

extension VaultKey {
    /// The relay mailbox for this vault-key epoch: unguessable without the key, and unlinkable to the account number.
    public var mailboxID: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("mailbox".utf8), using: subkey(.relayAddress))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}
