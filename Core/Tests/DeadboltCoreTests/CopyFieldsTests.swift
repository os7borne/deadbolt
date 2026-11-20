import Foundation
import Testing
@testable import DeadboltCore

@Suite struct CopyFieldsTests {
    @Test func cardSecretsAreMarkedAndEmptyFieldsAreLeftOut() {
        let c = CardItem(title: "Travel", cardholderName: "Alex Doe", number: "4111 1111 1111 1111", expMonth: 4, expYear: 2027, securityCode: "737")
        let byKey = Dictionary(uniqueKeysWithValues: c.copyFields.map { ($0.key, $0) })
        #expect(byKey["number"]?.secret == true && byKey["number"]?.value == "4111111111111111")
        #expect(byKey["code"]?.secret == true)
        #expect(byKey["pin"] == nil)                                   // no PIN saved: not offered
        #expect(byKey["holder"]?.secret == false)
        #expect(byKey["expiry"]?.value == "04/27" && byKey["expiryLong"]?.value == "04/2027")
        #expect(byKey["month"]?.value == "04" && byKey["year"]?.value == "2027")
        #expect(CardItem(title: "x").copyFields.isEmpty)
    }

    @Test func identityIdNumbersAreSecretContactDetailsAreNot() {
        var i = IdentityItem(title: "Home", firstName: "Alex", lastName: "Doe")
        i.email = "alex@example.com"; i.address1 = "1 Main St"; i.city = "Panaji"; i.ssn = "123-45-6789"; i.passportNumber = "P1234567"
        let byKey = Dictionary(uniqueKeysWithValues: i.copyFields.map { ($0.key, $0) })
        #expect(byKey["name"]?.value == "Alex Doe" && byKey["name"]?.secret == false)
        #expect(byKey["email"]?.secret == false && byKey["address"]?.value == "1 Main St\nPanaji")
        #expect(byKey["ssn"]?.secret == true && byKey["passport"]?.secret == true)
        #expect(byKey["license"] == nil && byKey["phone"] == nil)
        #expect(i.primaryCopyKey == "email")
        i.email = ""
        #expect(i.primaryCopyKey == "name")
        #expect(IdentityItem().primaryCopyKey == nil)
    }

    @Test func noteTextIsSecret() {
        #expect(NoteItem(title: "Wi-Fi", body: "hunter2").copyFields == [CopyField("body", "Note text", "hunter2", secret: true)])
        #expect(NoteItem(title: "empty").copyFields.isEmpty)
    }

    @Test func lookupFindsOnlyWhatExistsAndNeverLogins() throws {
        var v = Vault()
        let card = CardItem(title: "Travel", number: "4111111111111111", securityCode: "737")
        let who = IdentityItem(title: "Home", firstName: "Alex")
        let note = NoteItem(title: "n", body: "secret")
        v.upsert(card); v.upsert(who); v.upsert(note)
        let login = try v.save(host: "github.com", username: "alex", password: "pw")

        #expect(v.copyField(item: card.id, key: "number")?.field.value == "4111111111111111")
        #expect(v.copyField(item: card.id, key: "number")?.itemTitle == "Travel")
        #expect(v.copyField(item: who.id, key: "name")?.field.value == "Alex")
        #expect(v.copyField(item: note.id, key: "body")?.field.secret == true)
        #expect(v.copyField(item: card.id, key: "ssn") == nil)          // a key from another kind
        #expect(v.copyField(item: card.id, key: "pin") == nil)          // exists as a kind of field but empty
        #expect(v.copyField(item: UUID(), key: "number") == nil)
        #expect(v.copyField(item: login, key: "password") == nil)       // logins are not reachable through this path
        #expect(v.copyField(item: login, key: "username") == nil)
    }
}

@Suite struct RecencyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func loginsMostRecentFirstStarOnlyBreaksTies() throws {
        var v = Vault()
        let a = try v.save(host: "x.com", username: "amy", password: "1", now: t0)                          // ★ (first saved)
        let b = try v.save(host: "x.com", username: "ben", password: "2", asNewAccount: true, now: t0)
        let c = try v.save(host: "x.com", username: "cat", password: "3", asNewAccount: true, now: t0)
        #expect(v.accounts(for: "x.com").map(\.id) == [a, b, c])                                          // nothing used: ★, then A–Z
        v.markUsed(c, now: t0.addingTimeInterval(10))
        v.markUsed(b, now: t0.addingTimeInterval(20))
        #expect(v.accounts(for: "x.com").map(\.id) == [b, c, a])                                          // newest use first; the unused ★ is last
        v.markUsed(a, now: t0.addingTimeInterval(30))
        #expect(v.accounts(for: "x.com").map(\.id) == [a, b, c])
    }

    @Test func cardsAndIdentitiesByRecencyThenName() {
        var v = Vault()
        let x = CardItem(title: "Zed card", number: "4111111111111111"), y = CardItem(title: "Amex", number: "378282246310005"), z = CardItem(title: "Visa", number: "4111111111111111")
        v.upsert(x); v.upsert(y); v.upsert(z)
        #expect(v.cardsByRecency.map(\.title) == ["Amex", "Visa", "Zed card"])                            // never used: by name
        v.markItemUsed(x.id, now: t0)
        v.markItemUsed(z.id, now: t0.addingTimeInterval(5))
        #expect(v.cardsByRecency.map(\.title) == ["Visa", "Zed card", "Amex"])
        let h = IdentityItem(title: "Home", firstName: "A"), w = IdentityItem(title: "Work", firstName: "A")
        v.upsert(h); v.upsert(w)
        v.markItemUsed(w.id, now: t0)
        #expect(v.identitiesByRecency.map(\.title) == ["Work", "Home"])
        v.markItemUsed(UUID(), now: t0)                                                                    // unknown id: nothing happens
    }

    @Test func useIsNotAnEditAndItSyncs() {
        var a = Vault(), b = Vault()
        let card = CardItem(title: "Travel", number: "4111111111111111")
        let before = a
        a.upsert(card)
        a.stamp(changesFrom: before, node: "A", now: t0)
        b.merge(a.delta(since: nil))
        let edited = b.card(card.id)!.updatedAt

        let beforeUse = a
        a.markItemUsed(card.id, now: t0.addingTimeInterval(60))
        a.stamp(changesFrom: beforeUse, node: "A", now: t0.addingTimeInterval(60))
        #expect(a.card(card.id)?.updatedAt == edited)                                                      // using a card is not editing it
        #expect(a.card(card.id)?.clocks?["lastUsedAt"] != a.card(card.id)?.clocks?["number"])               // only that field was restamped
        b.merge(a.delta(since: nil))
        #expect(b.card(card.id)?.lastUsedAt == t0.addingTimeInterval(60))
    }

    @Test func oldCardsWithoutLastUsedStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"x","cardholderName":"","number":"4111111111111111","securityCode":"","pin":"","createdAt":0,"updatedAt":0}"#
        let c = try JSONDecoder.deadbolt.decode(CardItem.self, from: Data(json.utf8))
        #expect(c.lastUsedAt == nil)
    }
}
