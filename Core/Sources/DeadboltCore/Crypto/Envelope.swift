import CryptoKit
import Foundation

/// Authenticated encryption for everything Deadbolt stores or sends.
///
/// Wire format v1 (all integers big-endian):
///
///     [0]      version   = 0x01
///     [1..4]   key epoch (UInt32) — which vault key generation sealed this
///     [5..16]  nonce     (12 bytes, random per seal)
///     [17..]   AES-256-GCM ciphertext || 16-byte tag
///
/// The header (version + epoch) and a caller-supplied context string are bound as AAD,
/// so a ciphertext can't be moved to another record, purpose or epoch without failing to open.
public enum Envelope {
    public static let version: UInt8 = 1
    static let headerLength = 1 + 4
    static let nonceLength = 12
    static let tagLength = 16

    public static func seal(_ plaintext: Data, key: SymmetricKey, epoch: UInt32, context: String) throws -> Data {
        let header = makeHeader(epoch: epoch)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(), authenticating: aad(header, context))
        var out = header
        out.append(contentsOf: box.nonce)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    /// The epoch a sealed blob claims. Use it to pick the key; `open` still authenticates it.
    public static func epoch(of sealed: Data) throws -> UInt32 {
        let bytes = [UInt8](sealed)
        guard bytes.count >= headerLength + nonceLength + tagLength else { throw DeadboltError.malformed }
        guard bytes[0] == version else { throw DeadboltError.unsupportedVersion(bytes[0]) }
        return bytes[1...4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func open(_ sealed: Data, key: SymmetricKey, context: String) throws -> Data {
        let bytes = [UInt8](sealed)
        let epoch = try epoch(of: sealed)
        let header = makeHeader(epoch: epoch)
        let nonceEnd = headerLength + nonceLength
        let tagStart = bytes.count - tagLength
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: bytes[headerLength..<nonceEnd]),
                ciphertext: bytes[nonceEnd..<tagStart],
                tag: bytes[tagStart...])
            return try AES.GCM.open(box, using: key, authenticating: aad(header, context))
        } catch {
            throw DeadboltError.authenticationFailed
        }
    }

    private static func makeHeader(epoch: UInt32) -> Data {
        Data([version, UInt8(epoch >> 24), UInt8(epoch >> 16 & 0xff), UInt8(epoch >> 8 & 0xff), UInt8(epoch & 0xff)])
    }

    private static func aad(_ header: Data, _ context: String) -> Data {
        var aad = Data("deadbolt/envelope/v1\u{0}".utf8)
        aad.append(header)
        aad.append(Data(context.utf8))
        return aad
    }
}
