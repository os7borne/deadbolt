import CryptoKit
import Foundation

/// Talks to the Deadbolt relay (a Cloudflare Worker). Every mailbox request is signed by this device's key;
/// the relay only accepts devices that an existing device added. Link rooms are open but short-lived.
public struct RelayClient: Sendable {
    public let base: URL
    public let device: String
    let keys: DeviceKeys
    let session: URLSession

    public init(base: URL, device: String, keys: DeviceKeys, session: URLSession = .shared) {
        self.base = base; self.device = device; self.keys = keys; self.session = session
    }

    public struct Envelope: Codable, Sendable {
        public let seq: Int
        public let from: String
        public let at: Date
        public let body: Data
    }

    public struct Page: Codable, Sendable {
        public let messages: [Envelope]
        public let latest: Int
        public let oldest: Int     // lowest seq still stored; if > after + 1, messages were missed
    }

    // MARK: mailbox (signed)

    /// Creates the mailbox with this device as its first member. Fails if it already exists.
    public func create(mailbox: String) async throws {
        try await signed("POST", "/v1/mailbox/\(mailbox)/create", json: ["device": device, "key": try keys.signingPublicKey.base64EncodedString()])
    }

    public func addMember(mailbox: String, device id: String, signingKey: Data) async throws {
        try await signed("POST", "/v1/mailbox/\(mailbox)/members", json: ["device": id, "key": signingKey.base64EncodedString()])
    }

    /// Removes a device; the relay keeps the signed revocation to hand to that device.
    public func revoke(mailbox: String, _ r: Revocation) async throws {
        let body = try JSONEncoder.relay.encode(r)
        _ = try await request("POST", "/v1/mailbox/\(mailbox)/revoke", body: body, sign: true)
    }

    @discardableResult
    public func send(mailbox: String, _ message: SyncMessage) async throws -> Int {
        let data = try await request("POST", "/v1/mailbox/\(mailbox)/messages", body: try JSONEncoder.relay.encode(message), sign: true)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["seq"] as? Int ?? 0
    }

    public func fetch(mailbox: String, after: Int) async throws -> Page {
        try JSONDecoder.relay.decode(Page.self, from: try await request("GET", "/v1/mailbox/\(mailbox)/messages?after=\(after)", body: nil, sign: true))
    }

    /// Registers (or clears, with nil) this device's APNs token, so the relay can wake it after new messages.
    public func registerPush(mailbox: String, token: String?) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["token": token as Any? ?? NSNull()])
        _ = try await request("POST", "/v1/mailbox/\(mailbox)/push", body: body, sign: true)
    }

    public func ack(mailbox: String, seq: Int) async throws {
        try await signed("POST", "/v1/mailbox/\(mailbox)/ack", json: ["seq": seq])
    }

    // MARK: link rooms (unsigned, short-lived)

    public func post(link room: String, _ m: LinkMessage) async throws {
        _ = try await request("POST", "/v1/link/\(room)", body: try JSONEncoder.relay.encode(m), sign: false)
    }

    public func fetch(link room: String, after: Int) async throws -> [(seq: Int, message: LinkMessage)] {
        let page = try JSONDecoder.relay.decode(Page.self, from: try await request("GET", "/v1/link/\(room)?after=\(after)", body: nil, sign: false))
        return page.messages.compactMap { e in (try? JSONDecoder.relay.decode(LinkMessage.self, from: e.body)).map { (e.seq, $0) } }
    }

    // MARK: plumbing

    private func signed(_ method: String, _ path: String, json: [String: Any]) async throws {
        _ = try await request(method, path, body: try JSONSerialization.data(withJSONObject: json), sign: true)
    }

    /// Signature over "deadbolt-relay/v1\n{METHOD}\n{path+query}\n{unix ms}\n{sha256(body) hex}".
    static func canonical(method: String, path: String, time: String, body: Data?) -> Data {
        let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        return Data("deadbolt-relay/v1\n\(method)\n\(path)\n\(time)\n\(hash)".utf8)
    }

    private func request(_ method: String, _ path: String, body: Data?, sign: Bool) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw RelayError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 20
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if sign {
            let time = String(Int64(Date().timeIntervalSince1970 * 1000))
            req.setValue(device, forHTTPHeaderField: "X-Deadbolt-Device")
            req.setValue(time, forHTTPHeaderField: "X-Deadbolt-Time")
            req.setValue(try keys.sign(Self.canonical(method: method, path: path, time: time, body: body)).base64EncodedString(),
                         forHTTPHeaderField: "X-Deadbolt-Signature")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 410:
            if let r = try? JSONDecoder.relay.decode(Revocation.self, from: data) { throw RelayError.revoked(r) }
            throw RelayError.http(410, "Removed")
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw RelayError.http(status, msg ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }
}

public enum RelayError: Error, Equatable, Sendable {
    case badURL
    case http(Int, String)
    case revoked(Revocation)
}

extension JSONEncoder {
    /// Relay wire format: dates as unix milliseconds, binary as base64.
    static var relay: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var relay: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
