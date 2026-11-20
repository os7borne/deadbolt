import Foundation
import Testing
@testable import DeadboltCore

/// Two "devices" editing their own copy, then exchanging deltas (same shape as MergeTests).
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

@Suite struct CardTests {
    @Test(arguments: [
        ("4111 1111 1111 1111", CardBrand.visa), ("5500005555555559", .mastercard), ("2221000000000009", .mastercard),
        ("378282246310005", .amex), ("6011111111111117", .discover), ("3530111333300000", .jcb),
        ("30569309025904", .diners), ("6200000000000005", .unionpay), ("5081000000000000", .rupay),
    ])
    func detectsBrand(number: String, brand: CardBrand) {
        #expect(CardBrand.detect(number) == brand)
    }

    @Test func noBrandFromNothing() {
        #expect(CardBrand.detect("") == nil)
        #expect(CardItem(number: "9").resolvedBrand == .other)
    }

    @Test func luhn() {
        #expect(CardItem(number: "4111 1111 1111 1111").passesLuhn)
        #expect(CardItem(number: "378282246310005").passesLuhn)
        #expect(!CardItem(number: "4111111111111112").passesLuhn)
        #expect(!CardItem(number: "1234").passesLuhn)
    }

    @Test func numberIsNormalisedAndMasked() {
        let c = CardItem(title: "Travel", number: "4111-1111 1111 1111", expMonth: 4, expYear: 27)
        #expect(c.number == "4111111111111111")
        #expect(c.expYear == 2027)
        #expect(c.maskedSummary == "Visa •••• 1111")
        #expect(!c.maskedSummary.contains("4111111111"))
        #expect(c.formattedNumber == "4111 1111 1111 1111")
        #expect(c.expiry == "04/2027")
        #expect(CardItem(number: "378282246310005").formattedNumber == "3782 822463 10005")
    }

    @Test func expiresAtEndOfMonth() {
        let c = CardItem(expMonth: 6, expYear: 2026)
        func at(_ y: Int, _ m: Int, _ d: Int) -> Date { Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))! }
        #expect(!c.isExpired(now: at(2026, 6, 30)))
        #expect(c.isExpired(now: at(2026, 7, 1)))
        #expect(!CardItem().isExpired())
    }

    @Test func searchNeverSeesSecrets() {
        let c = CardItem(title: "Travel", cardholderName: "Alex Doe", number: "4111111111111111", securityCode: "737", pin: "5821")
        for secret in ["4111111111111111", "737", "5821", "4111 1111"] { #expect(!c.searchText.contains(secret)) }
        #expect(c.searchText.contains("1111"))   // last 4 is allowed
        #expect(c.searchText.contains("visa"))
        let i = { var i = IdentityItem(title: "Home", firstName: "Alex"); i.ssn = "123-45-6789"; i.passportNumber = "P1234567"; return i }()
        #expect(!i.searchText.contains("123-45") && !i.searchText.contains("p1234567"))
        #expect(!NoteItem(title: "Wi-Fi", body: "hunter2").searchText.contains("hunter2"))
    }
}

@Suite struct ItemSyncTests {
    @Test func cardsIdentitiesAndNotesReachAnotherDevice() {
        var a = Device("A")
        let card = CardItem(title: "Travel", number: "4111111111111111", expMonth: 4, expYear: 2030, securityCode: "737")
        let who = IdentityItem(title: "Home", firstName: "Alex", lastName: "Doe")
        let note = NoteItem(title: "Wi-Fi", body: "hunter2")
        a.edit(at: 100) { $0.upsert(card); $0.upsert(who); $0.upsert(note) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        #expect(b.vault.card(card.id)?.securityCode == "737")
        #expect(b.vault.identity(who.id)?.fullName == "Alex Doe")
        #expect(b.vault.note(note.id)?.body == "hunter2")
        #expect(b.vault.itemCount == 3)
    }

    @Test func editsToDifferentFieldsBothSurvive() {
        var a = Device("A")
        let card = CardItem(title: "Travel", number: "4111111111111111", expMonth: 4, expYear: 2027)
        a.edit(at: 100) { $0.upsert(card) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        a.edit(at: 200) { v in var c = v.card(card.id)!; c.expYear = 2031; v.upsert(c) }
        b.edit(at: 300) { v in var c = v.card(card.id)!; c.title = "Travel (new)"; v.upsert(c) }
        let da = a.outgoing(), db = b.outgoing()
        a.vault.merge(db); b.vault.merge(da)
        for d in [a, b] {
            #expect(d.vault.card(card.id)?.expYear == 2031)
            #expect(d.vault.card(card.id)?.title == "Travel (new)")
        }
    }

    @Test func newestEditWinsOnTheSameField() {
        var a = Device("A")
        let card = CardItem(title: "x", number: "4111111111111111")
        a.edit(at: 100) { $0.upsert(card) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        a.edit(at: 200) { v in var c = v.card(card.id)!; c.pin = "1111"; v.upsert(c) }
        b.edit(at: 300) { v in var c = v.card(card.id)!; c.pin = "2222"; v.upsert(c) }
        let da = a.outgoing(), db = b.outgoing()
        a.vault.merge(db); b.vault.merge(da)
        #expect(a.vault.card(card.id)?.pin == "2222" && b.vault.card(card.id)?.pin == "2222")
    }

    @Test func deleteReachesOtherDeviceAndLaterEditBringsItBack() {
        var a = Device("A")
        let card = CardItem(title: "Old", number: "4111111111111111")
        a.edit(at: 100) { $0.upsert(card) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        a.edit(at: 200) { $0.deleteCard(card.id) }
        b.vault.merge(a.outgoing())
        #expect(b.vault.cards.isEmpty)
        #expect(b.vault.tombstones?["card:\(card.id.uuidString)"] != nil)

        // B edits an old copy it still had, after the delete: the edit is newer, so the card returns.
        var c = Device("C"); c.vault = Vault(); c.vault.cards = [card]
        c.edit(at: 100) { v in var x = v.card(card.id)!; x.title = "Revived"; v.upsert(x) }   // stamped at t=100 < delete
        b.vault.merge(c.outgoing())
        #expect(b.vault.cards.isEmpty)           // older than the delete: stays deleted
        c.edit(at: 900) { v in var x = v.card(card.id)!; x.title = "Revived again"; v.upsert(x) }
        b.vault.merge(c.outgoing())
        #expect(b.vault.card(card.id)?.title == "Revived again")
    }

    @Test func orderAndRepeatsDontMatter() {
        var a = Device("A"), b = Device("B")
        let c1 = CardItem(title: "one", number: "4111111111111111"), c2 = CardItem(title: "two", number: "5500005555555559")
        a.edit(at: 100) { $0.upsert(c1) }
        b.edit(at: 150) { $0.upsert(c2) }
        let da = a.outgoing(), db = b.outgoing()
        var v1 = Vault(); v1.merge(da); v1.merge(db)
        var v2 = Vault(); v2.merge(db); v2.merge(da); v2.merge(db); v2.merge(da)
        #expect(v1.cards == v2.cards)
        #expect(v1.cards.count == 2)
    }

    @Test func onlyChangedFieldsAreRestamped() {
        var a = Device("A")
        let card = CardItem(title: "x", number: "4111111111111111")
        a.edit(at: 100) { $0.upsert(card) }
        let before = a.vault.card(card.id)!.clocks!["number"]!
        a.edit(at: 200) { v in var c = v.card(card.id)!; c.title = "y"; v.upsert(c) }
        let after = a.vault.card(card.id)!
        #expect(after.clocks!["number"] == before)
        #expect(after.clocks!["title"]! > before)
    }

    @Test func deletingAnIdentityUnlinksItsCards() {
        var a = Device("A")
        let who = IdentityItem(title: "Home", firstName: "Alex")
        let card = CardItem(title: "x", number: "4111111111111111", identityID: who.id)
        a.edit(at: 100) { $0.upsert(who); $0.upsert(card) }
        var b = Device("B"); b.vault.merge(a.outgoing())
        a.edit(at: 200) { $0.deleteIdentity(who.id) }
        b.vault.merge(a.outgoing())
        #expect(b.vault.identities.isEmpty)
        #expect(b.vault.card(card.id)?.identityID == nil)
        #expect(b.vault.card(card.id)?.number == "4111111111111111")   // the card itself is untouched
    }

    @Test func emptyDeltaIsEmptyOnlyWithoutItems() {
        var a = Device("A")
        #expect(a.outgoing().isEmptyDelta)
        a.edit(at: 100) { $0.upsert(NoteItem(title: "n")) }
        #expect(!a.outgoing().isEmptyDelta)     // a note alone is a real change
        #expect(a.outgoing().isEmptyDelta)      // and once sent, nothing is left to send
    }
}

@Suite struct SchemaTests {
    @Test func vaultsFromBeforeCardsStillOpen() throws {
        // What an older build wrote: no cards/identities/notes/schema keys at all.
        let v = Vault(logins: [LoginItem(sites: ["github.com"], username: "alex", password: "p")])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.deadbolt.encode(v)) as! [String: Any]
        for k in ["cards", "identities", "notes", "schema"] { json.removeValue(forKey: k) }
        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder.deadbolt.decode(Vault.self, from: old)
        #expect(decoded.logins.count == 1)
        #expect(decoded.cards.isEmpty && decoded.identities.isEmpty && decoded.notes.isEmpty)
        #expect(decoded.schema == nil)
    }

    @Test func aNewerSchemaIsRefusedNotDroppedAndResaved() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder.deadbolt.encode(Vault())) as! [String: Any]
        json["schema"] = Vault.currentSchema + 1
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DeadboltError.self) { try JSONDecoder.deadbolt.decode(Vault.self, from: data) }
    }

    @Test func stampMarksTheCurrentSchemaAndItemsSurviveTheFileRoundTrip() throws {
        var v = Vault()
        let before = v
        v.upsert(CardItem(title: "x", number: "4111111111111111", securityCode: "737"))
        v.upsert(IdentityItem(title: "Home", firstName: "Alex"))
        v.upsert(NoteItem(title: "n", body: "secret"))
        v.stamp(changesFrom: before, node: "A")
        #expect(v.schema == Vault.currentSchema)

        let key = VaultKey.generate()
        let recovery = RecoveryKey.generate()
        let file = try VaultFile.create(vault: v, key: key, password: "correct horse battery", recoveryKey: recovery, kdf: .fresh())
        let reopened = try file.open(key: key)
        #expect(reopened == v)
        #expect(reopened.cards.first?.securityCode == "737")
    }

    @Test func backupCountsEveryKindOfItem() throws {
        var v = Vault(logins: [LoginItem(sites: ["github.com"], username: "a", password: "p")])
        v.upsert(CardItem(title: "x", number: "4111111111111111"))
        v.upsert(NoteItem(title: "n"))
        let recovery = RecoveryKey.generate()
        let b = try BackupFile.make(v, recoveryKey: recovery)
        #expect(b.items == 3)
    }
}
