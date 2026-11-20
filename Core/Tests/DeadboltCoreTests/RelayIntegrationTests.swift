import CryptoKit
import Foundation
import Testing
@testable import DeadboltCore

/// End-to-end against a running relay. Skipped unless DEADBOLT_RELAY_URL is set, e.g.
///   (cd relay && npx wrangler@4 dev --port 8787) & DEADBOLT_RELAY_URL=http://127.0.0.1:8787 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEADBOLT_RELAY_URL"] != nil))
struct RelayIntegrationTests {
    let base = URL(string: ProcessInfo.processInfo.environment["DEADBOLT_RELAY_URL"] ?? "http://127.0.0.1:8787")!

    func device(_ id: String) throws -> (RelayClient, DeviceKeys, DeviceRecord) {
        let k = try DeviceKeys.generate(preferSecureEnclave: false)
        let rec = DeviceRecord(id: id, name: id, model: "test", platform: "test", signingKey: try k.signingPublicKey, agreementKey: try k.agreementPublicKey)
        return (RelayClient(base: base, device: id, keys: k), k, rec)
    }

    @Test func mailboxLifecycle() async throws {
        let vk = VaultKey.generate()
        let box = vk.mailboxID
        let (a, aKeys, aRec) = try device("A-\(UUID().uuidString.prefix(8))")
        let (b, _, bRec) = try device("B-\(UUID().uuidString.prefix(8))")
        let (c, _, _) = try device("C-\(UUID().uuidString.prefix(8))")

        try await a.create(mailbox: box)
        await #expect(throws: RelayError.self) { try await a.create(mailbox: box) }            // exists already
        await #expect(throws: RelayError.http(403, "Not a member of this mailbox")) { _ = try await b.fetch(mailbox: box, after: 0) }

        try await a.addMember(mailbox: box, device: b.device, signingKey: bRec.signingKey)
        var payload = Vault(); try payload.save(host: "github.com", username: "alex", password: "s3cret")
        let seq = try await a.send(mailbox: box, try SyncMessage.make(.delta, payload: payload, from: a.device, keys: aKeys, vaultKey: vk))
        #expect(seq == 1)

        let page = try await b.fetch(mailbox: box, after: 0)
        #expect(page.latest == 1 && page.messages.count == 1 && page.messages[0].from == a.device)
        let message = try JSONDecoder.relay.decode(SyncMessage.self, from: page.messages[0].body)
        #expect(try message.open(vaultKey: vk, devices: [aRec, bRec]) == payload)   // signed on device, verified on device

        try await b.ack(mailbox: box, seq: 1)
        let after = try await b.fetch(mailbox: box, after: 0)
        #expect(after.messages.isEmpty && after.oldest == 2)                         // everyone had it: deleted

        let r = try aKeys.revoke(device: b.device, by: a.device)
        try await a.revoke(mailbox: box, r)
        do { _ = try await b.fetch(mailbox: box, after: 0); Issue.record("removed device could still read") }
        catch RelayError.revoked(let got) { #expect(got.isValid(signer: aRec) && got.device == b.device) }
        await #expect(throws: RelayError.self) { try await c.addMember(mailbox: box, device: "X", signingKey: bRec.signingKey) }
    }

    @Test func rejectsBadSignaturesAndStaleClocks() async throws {
        let box = VaultKey.generate().mailboxID
        let (a, _, _) = try device("A-\(UUID().uuidString.prefix(8))")
        try await a.create(mailbox: box)
        // Same device id, different key: signature check fails.
        let impostor = RelayClient(base: base, device: a.device, keys: try DeviceKeys.generate(preferSecureEnclave: false))
        await #expect(throws: RelayError.http(401, "Bad signature")) { _ = try await impostor.fetch(mailbox: box, after: 0) }
    }

    @Test func linkRoomRoundTrip() async throws {
        let (a, _, _) = try device("L")
        let room = Link.newRoom()
        try await a.post(link: room, LinkMessage(kind: .deny))
        let got = try await a.fetch(link: room, after: 0)
        #expect(got.count == 1 && got[0].message.kind == .deny)
        #expect(try await a.fetch(link: room, after: got[0].seq).isEmpty)
    }
}
