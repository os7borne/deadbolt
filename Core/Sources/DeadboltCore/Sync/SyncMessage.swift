import CryptoKit
import Foundation

/// What devices send each other through the relay mailbox: sealed under the vault key's `sync` subkey,
/// then signed by the sending device. The relay sees only `from`, `kind`, `epoch` and the size.
public struct SyncMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case delta              // changes since the sender's last send
        case snapshot           // everything (answer to a snapshotRequest)
        case snapshotRequest    // "I missed messages; someone send me everything"
        case rotate             // a device was removed: here is the next vault key, sealed to each remaining device
    }

    public let v: Int
    public let from: String
    public let kind: Kind
    public let epoch: UInt32
    public let sealed: Data
    public let signature: Data

    static func signedPart(from: String, kind: Kind, epoch: UInt32, sealed: Data) -> Data {
        var d = Data("deadbolt/sync/v1\n\(from)\n\(kind.rawValue)\n\(epoch)\n".utf8)
        d.append(SHA256.hash(data: sealed).withUnsafeBytes { Data($0) })
        return d
    }

    public static func make(_ kind: Kind, payload: Vault, from device: String, keys: DeviceKeys, vaultKey: VaultKey) throws -> SyncMessage {
        try make(kind, data: try JSONEncoder.deadbolt.encode(payload), from: device, keys: keys, vaultKey: vaultKey)
    }

    public static func make(_ kind: Kind, data json: Data, from device: String, keys: DeviceKeys, vaultKey: VaultKey) throws -> SyncMessage {
        let sealed = try vaultKey.seal(json, purpose: .sync, context: "sync/v1/\(kind.rawValue)/\(device)")
        let sig = try keys.sign(signedPart(from: device, kind: kind, epoch: vaultKey.epoch, sealed: sealed))
        return SyncMessage(v: 1, from: device, kind: kind, epoch: vaultKey.epoch, sealed: sealed, signature: sig)
    }

    /// Verifies the sender is an active device of this vault, then decrypts.
    public func open(vaultKey: VaultKey, devices: [DeviceRecord]) throws -> Vault {
        try JSONDecoder.deadbolt.decode(Vault.self, from: openData(vaultKey: vaultKey, devices: devices))
    }

    public func openData(vaultKey: VaultKey, devices: [DeviceRecord]) throws -> Data {
        guard v == 1 else { throw DeadboltError.unsupportedVersion(UInt8(clamping: v)) }
        guard let sender = devices.first(where: { $0.id == from }), sender.isActive else { throw SyncError.unknownSender(from) }
        guard DeviceKeys.verify(signature: signature, message: Self.signedPart(from: from, kind: kind, epoch: epoch, sealed: sealed),
                                publicKey: sender.signingKey) else { throw SyncError.badSignature }
        guard epoch == vaultKey.epoch else { throw SyncError.wrongEpoch(epoch) }
        return try vaultKey.open(sealed, purpose: .sync, context: "sync/v1/\(kind.rawValue)/\(from)")
    }
}

public enum SyncError: Error, Equatable, Sendable {
    case unknownSender(String)
    case badSignature
    case wrongEpoch(UInt32)
    case badLink(String)
}

// MARK: linking a new device

/// Messages in a short-lived link room on the relay. `hello` and `accept` carry only public keys and
/// a device name; the vault itself travels in `vault`, sealed with a key from the ECDH handshake.
public struct LinkMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case hello, accept, details, vault, deny }
    public let kind: Kind
    public var hello: Hello?
    public var ephemeral: Data?           // accept: the approver's ephemeral public key
    public var approver: String?          // unused since v1.1 (approver name now travels sealed); kept for decoding
    public var sealed: Data?              // accept: approver Details · details: new device Details · vault: VaultFile

    public init(kind: Kind, hello: Hello? = nil, ephemeral: Data? = nil, approver: String? = nil, sealed: Data? = nil) {
        self.kind = kind; self.hello = hello; self.ephemeral = ephemeral; self.approver = approver; self.sealed = sealed
    }

    /// Public keys only: nothing here identifies the person or the device to the relay.
    public struct Hello: Codable, Equatable, Sendable {
        public let device: String          // random per installation
        public let signingKey: Data
        public let agreementKey: Data
        public let ephemeral: Data

        public init(device: String, signingKey: Data, agreementKey: Data, ephemeral: Data) {
            self.device = device; self.signingKey = signingKey; self.agreementKey = agreementKey; self.ephemeral = ephemeral
        }
    }

    /// Name, model and platform. Sent only after the key exchange, sealed with the link key.
    public struct Details: Codable, Equatable, Sendable {
        public let name: String
        public let model: String
        public let platform: String
        public init(name: String, model: String, platform: String) { self.name = name; self.model = model; self.platform = platform }
    }
}

/// What a QR code on the new device carries: `deadbolt://link?v=1&r=<room>&k=<ephemeral>&s=<secret>`.
public struct LinkInvite: Equatable, Sendable {
    public let room: String
    public let ephemeral: Data
    public let secret: Data

    public var uri: String {
        "deadbolt://link?v=1&r=\(room)&k=\(ephemeral.base64URL)&s=\(secret.base64URL)"
    }

    public init(room: String, ephemeral: Data, secret: Data) {
        self.room = room; self.ephemeral = ephemeral; self.secret = secret
    }

    public init(uri: String) throws {
        guard let c = URLComponents(string: uri), c.scheme == "deadbolt", c.host == "link" else { throw SyncError.badLink("Not a Deadbolt link code") }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["v"] == "1", let r = q["r"], r.count == 32, r.allSatisfy(\.isHexDigit),
              let k = q["k"].flatMap(Data.init(base64URL:)), k.count == 65,
              let s = q["s"].flatMap(Data.init(base64URL:)), s.count == 32 else { throw SyncError.badLink("This link code is damaged or from a newer version") }
        self.init(room: r, ephemeral: k, secret: s)
    }
}

public enum Link {
    /// A fresh random room for a QR link (16 bytes, hex).
    public static func newRoom() -> String { Random.bytes(16).map { String(format: "%02x", $0) }.joined() }

    /// The room a new device uses when the owner types the account number instead of scanning.
    public static func room(forAccountNumber digits: String) -> String {
        Data(SHA256.hash(data: Data("deadbolt/link/v1/\(digits)".utf8))).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Both sides derive the same sealing key and 4-digit code. The hello (with the new device's identity keys)
    /// is bound in, so a relay that swaps keys produces different codes on the two screens.
    public static func derive(myEphemeral: P256.KeyAgreement.PrivateKey, peerEphemeral: Data,
                              hello: LinkMessage.Hello, approverEphemeral: Data, secret: Data) throws -> (key: SymmetricKey, code: String) {
        let shared = try myEphemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peerEphemeral))
        var info = Data("deadbolt/link/v1".utf8)
        info.append(SHA256.hash(data: try JSONEncoder.deadbolt.encode(hello)).withUnsafeBytes { Data($0) })
        info.append(approverEphemeral)
        let okm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret, sharedInfo: info, outputByteCount: 36)
        let bytes = okm.withUnsafeBytes { Data($0) }
        let n = bytes.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 10_000
        let code = String(format: "%04d", n)
        return (SymmetricKey(data: bytes.prefix(32)), code)
    }

    public static func seal(_ d: LinkMessage.Details, key: SymmetricKey, from role: String) throws -> Data {
        try Envelope.seal(try JSONEncoder.deadbolt.encode(d), key: key, epoch: 0, context: "link/v1/details/\(role)")
    }

    public static func openDetails(_ sealed: Data, key: SymmetricKey, from role: String) throws -> LinkMessage.Details {
        try JSONDecoder.deadbolt.decode(LinkMessage.Details.self, from: Envelope.open(sealed, key: key, context: "link/v1/details/\(role)"))
    }

    public static func sealVault(_ file: VaultFile, key: SymmetricKey) throws -> Data {
        try Envelope.seal(try JSONEncoder.deadbolt.encode(file), key: key, epoch: 0, context: "link/v1/vault")
    }

    public static func openVault(_ sealed: Data, key: SymmetricKey) throws -> VaultFile {
        try JSONDecoder.deadbolt.decode(VaultFile.self, from: Envelope.open(sealed, key: key, context: "link/v1/vault"))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        self.init(base64Encoded: b)
    }
}
