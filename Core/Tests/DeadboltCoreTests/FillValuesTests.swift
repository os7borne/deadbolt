import Foundation
import Testing
@testable import DeadboltCore

@Suite struct FillValuesTests {
    func vault() -> (Vault, CardItem, IdentityItem, UUID) {
        var v = Vault()
        let card = CardItem(title: "Travel", cardholderName: "Alex Q Doe", number: "4111 1111 1111 1111", expMonth: 4, expYear: 2027, securityCode: "737", pin: "5821")
        var who = IdentityItem(title: "Home", firstName: "Alex", lastName: "Doe")
        who.email = "alex@example.com"; who.address1 = "1 Main St"; who.address2 = "Flat 2"; who.city = "Panaji"; who.postalCode = "403001"
        who.country = "India"; who.ssn = "123-45-6789"
        v.upsert(card); v.upsert(who)
        let login = (try? v.save(host: "github.com", username: "alex", password: "pw"))!
        return (v, card, who, login)
    }

    @Test func cardValuesAreFormattedForWhateverTheFormAsksFor() {
        let (v, card, _, _) = vault()
        let f = v.fillValues(item: card.id, want: ["number", "holder", "holderFirst", "holderLast", "expMonth", "expYear", "expYear2", "expiry", "expiryLong", "expiryCompact", "code"])!
        #expect(f.values["number"] == "4111111111111111" && f.values["code"] == "737")
        #expect(f.values["holder"] == "Alex Q Doe" && f.values["holderFirst"] == "Alex Q" && f.values["holderLast"] == "Doe")
        #expect(f.values["expMonth"] == "04" && f.values["expYear"] == "2027" && f.values["expYear2"] == "27")
        #expect(f.values["expiry"] == "04/27" && f.values["expiryLong"] == "04/2027" && f.values["expiryCompact"] == "0427")
        #expect(f.summary == "Visa •••• 1111" && f.hasSecret)
    }

    @Test func onlyRequestedKeysAreReleased() {
        let (v, card, _, _) = vault()
        let f = v.fillValues(item: card.id, want: ["holder", "expiry"])!
        #expect(Set(f.values.keys) == ["holder", "expiry"])            // no number, no code
        #expect(!f.hasSecret)                                            // so no Touch ID is needed for this request
        #expect(v.fillValues(item: card.id, want: ["number"])!.hasSecret)
        #expect(v.fillValues(item: card.id, want: ["code"])!.hasSecret)
    }

    @Test func pinAndUnknownKeysAreNeverFillable() {
        let (v, card, who, _) = vault()
        let f = v.fillValues(item: card.id, want: ["pin", "password", "ssn", "bogus"])!
        #expect(f.values.isEmpty)
        let g = v.fillValues(item: who.id, want: ["ssn", "passport", "license", "pin"])!
        #expect(g.values.isEmpty && !g.hasSecret)                       // ID numbers are copy-only
    }

    @Test func identityValuesAndAddressJoin() {
        let (v, _, who, _) = vault()
        let f = v.fillValues(item: who.id, want: ["first", "last", "name", "email", "address", "address1", "address2", "city", "postal", "country", "phone"])!
        #expect(f.values["first"] == "Alex" && f.values["name"] == "Alex Doe" && f.values["email"] == "alex@example.com")
        #expect(f.values["address"] == "1 Main St, Flat 2, Panaji, 403001, India")
        #expect(f.values["postal"] == "403001" && f.values["country"] == "India")
        #expect(f.values["phone"] == nil)                                // empty values are left out
        #expect(!f.hasSecret && f.summary == "Alex Doe")
    }

    @Test func loginsAndUnknownIdsAreNotReachable() {
        let (v, _, _, login) = vault()
        #expect(v.fillValues(item: login, want: ["password", "username", "email"]) == nil)
        #expect(v.fillValues(item: UUID(), want: ["number"]) == nil)
    }

    @Test func singleWordHolderGoesToFirstOnly() {
        var v = Vault()
        let c = CardItem(title: "x", cardholderName: "Madonna", number: "4111111111111111")
        v.upsert(c)
        let f = v.fillValues(item: c.id, want: ["holderFirst", "holderLast"])!
        #expect(f.values["holderFirst"] == "Madonna" && f.values["holderLast"] == nil)
    }
}
