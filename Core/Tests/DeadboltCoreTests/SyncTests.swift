import CryptoKit
import Foundation
import Testing
@testable import DeadboltCore

/// Two "devices" editing their own copy, then exchanging deltas.
private struct Device {
    let id: String
    var vault: Vault
    var lastSent: HLC? = nil
    init(_ id: String, _ vault: Vault = Vault()) { self.id = id; self.vault = vault }

    mutating func edit(at t: TimeInterval, _ change: (inout Vault) throws -> Void) rethrows {
        let before = vault
        try change(&vault)
        vault.stamp(changesFrom: before, node: id, now: Date(timeIntervalSince1970: t))
    }

    mutating func outgoing() -> Vault {
        let d = vault.delta(since: lastSent)
        lastSent = vault.newestClock
        return d
    }
}

@Suite struct MergeTests {
    @Test func hlcOrderingAndMonotonic() {
        let a = HLC(millis: 10, counter: 0, node: "a")
        #expect(a < HLC(millis: 10, counter: 1, node: "a"))
        #expect(HLC(millis: 10, counter: 0, node: "a") < HLC(millis: 10, counter: 0, node: "b"))
        // clock behind the newest seen stamp: still moves forward
        let n = HLC.next(after: HLC(millis: 5_000_000, counter: 3, node: "x"), node: "me", now: Date(timeIntervalSince1970: 1))
        #expect(n.millis == 5_000_000 && n.counter == 4)
    }

    @Test func editsOnDifferentFieldsBothSurvive() throws {
        var a = Device("A")
        var id = UUID()
        try a.edit(at: 100) { id = try $0.save(host: "github.com", username: "alex", password: "p1") }
        var b = Device("B"); b.vault.merge(a.outgoing())

        a.edit(at: 200) { v in var i = v.login(id)!; i.notes = "from A"; v.upsert(i) }
        b.edit(at: 210) { v in var i = v.login(id)!; i.label = "Work"; v.upsert(i) }
        a.vault.merge(b.outgoing()); b.vault.merge(a.outgoing())

        #expect(a.vault.login(id)?.notes == "from A" && a.vault.login(id)?.label == "Work")
        #expect(a.vault.logins == b.vault.logins)
    }

    @Test func customFieldsAndExtraWebsitesSyncAndOldLoginsStillDecode() throws {
        var a = Device("A")
        var id = UUID()
        try a.edit(at: 100) { id = try $0.save(host: "bank.example", username: "alex", password: "p1") }
        var b = Device("B"); b.vault.merge(a.outgoing())

        a.edit(at: 200) { v in
            var i = v.login(id)!
            i.sites.append("bank-login.example")
            i.customFields = [CustomField(name: "Account ID", value: "12345"), CustomField(name: "PIN", value: "9981", hidden: true)]
            v.upsert(i)
        }
        b.edit(at: 210) { v in var i = v.login(id)!; i.notes = "from B"; v.upsert(i) }   // a different field: both survive
        a.vault.merge(b.outgoing()); b.vault.merge(a.outgoing())
        #expect(a.vault.login(id)?.customFields?.count == 2 && a.vault.login(id)?.notes == "from B")
        #expect(a.vault.logins == b.vault.logins)
        #expect(b.vault.accounts(for: "bank-login.example").count == 1)   // the extra website matches too

        // A login saved before custom fields existed has no such key and still decodes.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"X","sites":["x.com"],"username":"u","password":"p","passkeyIDs":[],"preferred":false,"history":[],"createdAt":0,"updatedAt":0}"#
        let item = try JSONDecoder().decode(LoginItem.self, from: Data(old.utf8))
        #expect(item.customFields == nil)
    }

    @Test func generatorPreferencesSyncNewestWins() {
        var a = Device("A"); var b = Device("B")
        a.edit(at: 100) { $0.generator = .init(options: .init(length: 30, symbols: false)) }
        b.vault.merge(a.outgoing())
        #expect(b.vault.generator?.options.length == 30 && b.vault.generator?.options.symbols == false)

        // Both change it; the later change wins on both devices.
        a.edit(at: 200) { $0.generator = .init(options: .init(length: 16)) }
        b.edit(at: 210) { $0.generator = .init(options: .init(length: 24, avoidAmbiguous: false), words: 6, passphrase: true) }
        a.vault.merge(b.outgoing()); b.vault.merge(a.outgoing())
        #expect(a.vault.generator == b.vault.generator)
        #expect(a.vault.generator?.options.length == 24 && a.vault.generator?.words == 6)
        // A vault that never set it stays nil (older vaults decode fine).
        #expect(Vault().generator == nil)
    }

    @Test func concurrentPasswordChangesKeepTheLoserInHistory() throws {
        var a = Device("A")
        var id = UUID()
        try a.edit(at: 100) { id = try $0.save(host: "x.com", username: "u", password: "orig") }
        var b = Device("B"); b.vault.merge(a.outgoing())

        a.edit(at: 200) { v in var i = v.login(id)!; i.changePassword(to: "fromA", now: Date(timeIntervalSince1970: 200)); v.upsert(i) }
        b.edit(at: 300) { v in var i = v.login(id)!; i.changePassword(to: "fromB", now: Date(timeIntervalSince1970: 300)); v.upsert(i) }
        let da = a.outgoing(), db = b.outgoing()
        a.vault.merge(db); b.vault.merge(da)

        for v in [a.vault, b.vault] {
            let item = v.login(id)!
            #expect(item.password == "fromB")                           // newer wins
            #expect(Set(item.history.map(\.password)) == ["orig", "fromA"]) // nothing lost
        }
        #expect(a.vault.login(id) == b.vault.login(id))
    }

    @Test func mergeIsIdempotentAndOrderIndependent() throws {
        var a = Device("A"), b = Device("B"), c = Device("C")
        try a.edit(at: 100) { try $0.save(host: "a.com", username: "1", password: "x") }
        try b.edit(at: 110) { try $0.save(host: "b.com", username: "2", password: "y") }
        try c.edit(at: 120) { try $0.save(host: "c.com", username: "3", password: "z") }
        let (da, db, dc) = (a.outgoing(), b.outgoing(), c.outgoing())

        var v1 = Vault(); v1.merge(da); v1.merge(db); v1.merge(dc)
        var v2 = Vault(); v2.merge(dc); v2.merge(da); v2.merge(db); v2.merge(da); v2.merge(dc)
        #expect(v1 == v2)
        #expect(v1.logins.count == 3)
    }

    @Test func deleteReachesOtherDevicesButALaterEditWins() throws {
        var a = Device("A")
        var keep = UUID(), gone = UUID()
        try a.edit(at: 100) { v in
            keep = try v.save(host: "k.com", username: "u", password: "p")
            gone = try v.save(host: "g.com", username: "u", password: "p")
        }
        var b = Device("B"); b.vault.merge(a.outgoing())

        a.edit(at: 200) { $0.delete(gone); $0.delete(keep) }
        b.edit(at: 300) { v in var i = v.login(keep)!; i.notes = "edited after the delete"; v.upsert(i) }
        let da = a.outgoing(), db = b.outgoing()
        a.vault.merge(db); b.vault.merge(da)

        for v in [a.vault, b.vault] {
            #expect(v.login(gone) == nil)
            #expect(v.login(keep)?.notes == "edited after the delete")
        }
    }

    @Test func passkeysAndTheirDeletesSync() throws {
        var a = Device("A")
        let pk = Passkey.create(relyingPartyID: "stripe.com", userName: "a", userHandle: Data([1]))
        a.edit(at: 100) { $0.add(pk) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        #expect(b.vault.passkeys.count == 1)
        b.edit(at: 200) { $0.deletePasskey(pk.credentialID) }
        a.vault.merge(b.outgoing())
        #expect(a.vault.passkeys.isEmpty)
    }

    @Test func deltaOnlyCarriesNewChanges() throws {
        var a = Device("A")
        try a.edit(at: 100) { try $0.save(host: "a.com", username: "u", password: "p") }
        #expect(a.outgoing().logins.count == 1)
        #expect(a.outgoing().isEmptyDelta)
        try a.edit(at: 200) { try $0.save(host: "b.com", username: "u", password: "p") }
        #expect(a.outgoing().logins.map(\.sites) == [["b.com"]])
    }

    @Test func legacyVaultGetsStampedOnFirstChange() throws {
        var legacy = Vault()
        try legacy.save(host: "old.com", username: "u", password: "p") // no clocks: made before sync
        legacy.recoveryPhrase = "words"
        #expect(legacy.logins[0].clocks == nil)
        var d = Device("A", legacy)
        d.edit(at: 100) { $0.accountNumber = "4111111111111111" }
        #expect(d.vault.logins[0].clocks?.count == LoginItem.mergedFields.count)
        let out = d.outgoing()
        #expect(out.logins.count == 1 && out.recoveryPhrase == "words" && out.accountNumber == "4111111111111111")
    }

    @Test func removalIsNeverUndoneByAMerge() throws {
        let keys = try DeviceKeys.generate(preferSecureEnclave: false)
        let rec = DeviceRecord(id: "D", name: "Old phone", model: "iPhone", platform: "iOS",
                               signingKey: try keys.signingPublicKey, agreementKey: try keys.agreementPublicKey)
        var a = Device("A"); a.edit(at: 100) { $0.upsertDevice(rec) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        let revocation = try keys.revoke(device: "D", by: "A")
        a.edit(at: 200) { $0.revokeDevice(revocation) }
        b.edit(at: 300) { v in var d = v.device("D")!; d.name = "Renamed later"; v.upsertDevice(d) } // newer, but not revoked
        let da = a.outgoing(), db = b.outgoing()
        a.vault.merge(db); b.vault.merge(da)
        #expect(a.vault.device("D")?.revoked != nil && b.vault.device("D")?.revoked != nil)
        #expect(a.vault.activeDevices.isEmpty)
    }
}

@Suite struct SyncCryptoTests {
    let vk = VaultKey.generate(epoch: 3)

    func device(_ id: String) throws -> (DeviceKeys, DeviceRecord) {
        let k = try DeviceKeys.generate(preferSecureEnclave: false)
        return (k, DeviceRecord(id: id, name: id, model: "test", platform: "test", signingKey: try k.signingPublicKey, agreementKey: try k.agreementPublicKey))
    }

    @Test func signedSealedMessageRoundTrip() throws {
        let (keys, rec) = try device("A")
        var payload = Vault(); try payload.save(host: "a.com", username: "u", password: "secret")
        let m = try SyncMessage.make(.delta, payload: payload, from: "A", keys: keys, vaultKey: vk)
        #expect(!String(decoding: try JSONEncoder().encode(m), as: UTF8.self).contains("secret"))
        #expect(try m.open(vaultKey: vk, devices: [rec]) == payload)
    }

    @Test func rejectsForgedTamperedRevokedAndOldEpoch() throws {
        let (keys, rec) = try device("A")
        let (otherKeys, _) = try device("X")
        let m = try SyncMessage.make(.delta, payload: Vault(), from: "A", keys: keys, vaultKey: vk)

        #expect(throws: SyncError.unknownSender("A")) { try m.open(vaultKey: self.vk, devices: []) }
        let forged = try SyncMessage.make(.delta, payload: Vault(), from: "A", keys: otherKeys, vaultKey: vk)
        #expect(throws: SyncError.badSignature) { try forged.open(vaultKey: self.vk, devices: [rec]) }
        var sealed = m.sealed; sealed[sealed.count - 1] ^= 1
        let tampered = SyncMessage(v: 1, from: "A", kind: .delta, epoch: 3, sealed: sealed, signature: m.signature)
        #expect(throws: SyncError.badSignature) { try tampered.open(vaultKey: self.vk, devices: [rec]) }
        var revoked = rec; revoked.revoked = try keys.revoke(device: "A", by: "A")
        #expect(throws: SyncError.unknownSender("A")) { try m.open(vaultKey: self.vk, devices: [revoked]) }
        #expect(throws: SyncError.wrongEpoch(3)) { try m.open(vaultKey: VaultKey.generate(epoch: 4), devices: [rec]) }
    }

    @Test func revocationSignatureChecks() throws {
        let (keys, rec) = try device("A")
        let (_, other) = try device("B")
        let r = try keys.revoke(device: "Z", by: "A")
        #expect(r.isValid(signer: rec))
        #expect(!r.isValid(signer: other))
        let altered = Revocation(device: "B", by: "A", at: r.at, signature: r.signature)
        #expect(!altered.isValid(signer: rec))
    }

    @Test func mailboxDependsOnKeyAndEpoch() throws {
        let raw = Data(repeating: 7, count: 32)
        let a = try VaultKey(epoch: 1, rawBytes: raw), b = try VaultKey(epoch: 2, rawBytes: raw)
        #expect(a.mailboxID.count == 64 && a.mailboxID != b.mailboxID)
        #expect(a.mailboxID == (try VaultKey(epoch: 1, rawBytes: raw)).mailboxID)
    }

    @Test func secureEnclaveOrSoftwareKeysSign() throws {
        let keys = try DeviceKeys.generate() // Secure Enclave on Apple silicon, software otherwise
        let msg = Data("hello".utf8)
        let sig = try keys.sign(msg)
        #expect(sig.count == 64)
        #expect(DeviceKeys.verify(signature: sig, message: msg, publicKey: try keys.signingPublicKey))
    }
}

@Suite struct LinkTests {
    func hello(_ eph: P256.KeyAgreement.PrivateKey) throws -> LinkMessage.Hello {
        let k = try DeviceKeys.generate(preferSecureEnclave: false)
        return .init(device: "NEW", signingKey: try k.signingPublicKey, agreementKey: try k.agreementPublicKey, ephemeral: eph.publicKey.x963Representation)
    }

    @Test func bothSidesGetTheSameKeyAndCode() throws {
        let newEph = P256.KeyAgreement.PrivateKey(), appEph = P256.KeyAgreement.PrivateKey()
        let h = try hello(newEph), secret = Random.bytes(32)
        let a = try Link.derive(myEphemeral: newEph, peerEphemeral: appEph.publicKey.x963Representation, hello: h,
                                approverEphemeral: appEph.publicKey.x963Representation, secret: secret)
        let b = try Link.derive(myEphemeral: appEph, peerEphemeral: newEph.publicKey.x963Representation, hello: h,
                                approverEphemeral: appEph.publicKey.x963Representation, secret: secret)
        #expect(a.code == b.code && a.code.count == 4)
        let file = try VaultFile.create(vault: Vault(), key: .generate(), password: "pw", recoveryKey: .generate(), kdf: .testing())
        #expect(try Link.openVault(Link.sealVault(file, key: a.key), key: b.key) == file)
    }

    @Test func swappedIdentityKeysOrEphemeralsChangeTheCode() throws {
        let newEph = P256.KeyAgreement.PrivateKey(), appEph = P256.KeyAgreement.PrivateKey(), mitm = P256.KeyAgreement.PrivateKey()
        let h = try hello(newEph)
        let real = try Link.derive(myEphemeral: newEph, peerEphemeral: appEph.publicKey.x963Representation, hello: h,
                                   approverEphemeral: appEph.publicKey.x963Representation, secret: Data())
        // Relay replaces the new device's identity keys in the hello the approver sees.
        let swapped = try hello(newEph)
        let seen = try Link.derive(myEphemeral: appEph, peerEphemeral: newEph.publicKey.x963Representation, hello: swapped,
                                   approverEphemeral: appEph.publicKey.x963Representation, secret: Data())
        #expect(real.code != seen.code || real.key.withUnsafeBytes { Data($0) } != seen.key.withUnsafeBytes { Data($0) })
        // Relay puts its own ephemeral in front of the approver.
        let mitmSide = try Link.derive(myEphemeral: appEph, peerEphemeral: mitm.publicKey.x963Representation, hello: h,
                                       approverEphemeral: appEph.publicKey.x963Representation, secret: Data())
        #expect(mitmSide.key.withUnsafeBytes { Data($0) } != real.key.withUnsafeBytes { Data($0) })
    }

    @Test func inviteURIRoundTripAndRejectsJunk() throws {
        let inv = LinkInvite(room: Link.newRoom(), ephemeral: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, secret: Random.bytes(32))
        #expect(try LinkInvite(uri: inv.uri) == inv)
        #expect(throws: SyncError.self) { try LinkInvite(uri: "https://example.com") }
        #expect(throws: SyncError.self) { try LinkInvite(uri: "deadbolt://link?v=1&r=zz&k=aa&s=bb") }
    }

    @Test func accountNumberRoomIsStableAndHex() {
        #expect(Link.room(forAccountNumber: "4111111111111111") == Link.room(forAccountNumber: "4111111111111111"))
        #expect(Link.room(forAccountNumber: "4111111111111111").count == 32)
        #expect(Link.room(forAccountNumber: "4111111111111111") != Link.room(forAccountNumber: "4111111111111129"))
    }
}


@Suite struct LinkPrivacyTests {
    @Test func helloCarriesNoNamesAndDetailsAreSealedPerRole() throws {
        let k = try DeviceKeys.generate(preferSecureEnclave: false)
        let h = LinkMessage.Hello(device: "id", signingKey: try k.signingPublicKey, agreementKey: try k.agreementPublicKey,
                                  ephemeral: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        let wire = String(decoding: try JSONEncoder().encode(LinkMessage(kind: .hello, hello: h)), as: UTF8.self)
        #expect(!wire.contains("name") && !wire.contains("model"))

        let key = SymmetricKey(size: .bits256)
        let d = LinkMessage.Details(name: "Oz’s MacBook Air", model: "Mac (Mac14,2)", platform: "macOS")
        let sealed = try Link.seal(d, key: key, from: "new")
        #expect(!String(decoding: sealed, as: UTF8.self).contains("MacBook"))
        #expect(try Link.openDetails(sealed, key: key, from: "new") == d)
        #expect(throws: DeadboltError.authenticationFailed) { try Link.openDetails(sealed, key: key, from: "approver") } // roles can't be swapped
    }
}

@Suite struct RotationTests {
    func device(_ id: String) throws -> (DeviceKeys, DeviceRecord) {
        let k = try DeviceKeys.generate(preferSecureEnclave: false)
        return (k, DeviceRecord(id: id, name: id, model: "t", platform: "t", signingKey: try k.signingPublicKey, agreementKey: try k.agreementPublicKey))
    }

    @Test func eachGrantOpensOnlyForItsDevice() throws {
        let next = VaultKey.generate(epoch: 2)
        let (bKeys, b) = try device("B")
        let (cKeys, c) = try device("C")
        let (removedKeys, _) = try device("REMOVED")
        let gB = try KeyGrant.make(next, for: b), gC = try KeyGrant.make(next, for: c)
        #expect(try gB.open(with: bKeys).keychainRepresentation == next.keychainRepresentation)
        #expect(try gC.open(with: cKeys).epoch == 2)
        #expect(throws: (any Error).self) { try gB.open(with: cKeys) }       // C can't open B's
        #expect(throws: (any Error).self) { try gB.open(with: removedKeys) } // nor can the removed device
    }

    @Test func rotationMessageEndToEnd() throws {
        // A removes D; B (remaining) gets the new key through a signed .rotate message in the old mailbox.
        let old = VaultKey.generate(epoch: 1)
        let (aKeys, a) = try device("A")
        let (bKeys, b) = try device("B")
        var vault = Vault(); try vault.save(host: "x.com", username: "u", password: "p")
        let rk = RecoveryKey.generate(); vault.recoveryPhrase = rk.phrase
        let next = VaultKey.generate(epoch: 2)
        let file = try VaultFile.create(vault: vault, key: next, password: "master", recoveryKey: rk, kdf: .testing())
        let payload = RotatePayload(epoch: 2, removed: "D", grants: [try KeyGrant.make(next, for: b)], wrapped: file.wrapped)
        let msg = try SyncMessage.make(.rotate, data: JSONEncoder().encode(payload), from: "A", keys: aKeys, vaultKey: old)

        let got = try JSONDecoder().decode(RotatePayload.self, from: msg.openData(vaultKey: old, devices: [a, b]))
        let bNext = try got.grants.first { $0.device == "B" }!.open(with: bKeys)
        let rekeyed = try VaultFile.rekeyed(vault, key: bNext, wrapped: got.wrapped)
        #expect(try rekeyed.unlock(password: "master").1 == vault)           // master password still works
        #expect(try rekeyed.unlock(recoveryKey: rk).0.epoch == 2)            // and the Recovery Kit
        #expect(throws: (any Error).self) { try rekeyed.open(key: old) }     // the old key no longer opens it
        #expect(next.mailboxID != old.mailboxID)
    }

    @Test func rekeyRejectsMismatchedWraps() throws {
        let file = try VaultFile.create(vault: Vault(), key: .generate(epoch: 1), password: "p", recoveryKey: .generate(), kdf: .testing())
        #expect(throws: DeadboltError.malformed) { try VaultFile.rekeyed(Vault(), key: .generate(epoch: 2), wrapped: file.wrapped) }
    }
}
