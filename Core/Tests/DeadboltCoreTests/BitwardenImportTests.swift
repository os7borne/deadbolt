import Foundation
import Testing
@testable import DeadboltCore

@Suite struct BitwardenJSONTests {
    static let export = """
    {"encrypted": false, "folders": [{"id": "f1", "name": "Banking"}], "items": [
      {"id": "1", "folderId": "f1", "type": 1, "name": "Notion", "notes": "work", "favorite": false,
       "fields": [{"name": "Security answer", "value": "blue", "type": 1}, {"name": "Account ID", "value": "42", "type": 0}, {"name": "link", "value": null, "type": 3}],
       "login": {"uris": [{"uri": "https://notion.so"}, {"uri": "https://www.notion.com/login"}], "username": "alex", "password": "pw1", "totp": "JBSWY3DPEHPK3PXP"}},
      {"id": "2", "type": 3, "name": "Travel card", "notes": "limit 5k",
       "card": {"cardholderName": "Alex Doe", "brand": "Visa", "number": "4111 1111 1111 1111", "expMonth": "4", "expYear": "27", "code": "737"}},
      {"id": "3", "type": 3, "name": "Old card", "card": {"cardholderName": null, "brand": null, "number": "378282246310005", "expMonth": "13", "expYear": "2031", "code": null}},
      {"id": "4", "type": 4, "name": "Home",
       "identity": {"title": "Mr", "firstName": "Alex", "middleName": null, "lastName": "Doe", "address1": "1 Main St", "city": "Panaji", "state": "Goa", "postalCode": "403001", "country": "IN",
                    "email": "alex@example.com", "phone": "555", "ssn": "123-45-6789", "passportNumber": "P1234567", "licenseNumber": null}},
      {"id": "5", "type": 2, "name": "Wi-Fi", "notes": "ssid: home\\npass: hunter2", "secureNote": {"type": 0}},
      {"id": "6", "type": 1, "name": "Wi-Fi router", "login": {"uris": [], "username": "admin", "password": "x"}},
      {"id": "7", "type": 5, "name": "ssh key"}
    ]}
    """

    @Test func readsEveryKind() throws {
        let f = try PasswordImporter.parse(Self.export)
        #expect(f.source == .bitwarden)
        #expect(f.logins.count == 1 && f.cards.count == 2 && f.identities.count == 1 && f.notes.count == 1)

        let l = f.logins[0]
        #expect(l.url == "https://notion.so" && l.extraURLs == ["https://www.notion.com/login"] && l.totp == "JBSWY3DPEHPK3PXP")
        #expect(l.customFields.map(\.name) == ["Security answer", "Account ID"])      // linked field dropped
        #expect(l.customFields.map(\.hidden) == [true, false])

        let c = f.cards[0]
        #expect(c.title == "Travel card" && c.number == "4111111111111111" && c.cardholderName == "Alex Doe")
        #expect(c.expMonth == 4 && c.expYear == 2027 && c.securityCode == "737" && c.brand == .visa && c.notes == "limit 5k")
        let amex = f.cards[1]
        #expect(amex.expMonth == nil && amex.expYear == 2031)          // month 13 is not a month
        #expect(amex.resolvedBrand == .amex)                           // no brand given: detected

        let i = f.identities[0]
        #expect(i.fullName == "Alex Doe" && i.salutation == "Mr" && i.city == "Panaji" && i.ssn == "123-45-6789" && i.licenseNumber == "")
        #expect(f.notes[0].body == "ssid: home\npass: hunter2")

        #expect(f.skipped.map(\.row) == [6, 7])
        #expect(f.skipped[0].reason.contains("no website") && f.skipped[1].reason.contains("unsupported"))
        #expect(f.itemCount == 5)
    }

    @Test func refusesEncryptedAndForeignJSON() {
        #expect(throws: ImportError.encryptedExport) { try PasswordImporter.parse(#"{"encrypted": true, "encKeyValidation_DO_NOT_EDIT": "x", "data": "y"}"#) }
        #expect(throws: ImportError.notBitwardenJSON) { try PasswordImporter.parse(#"{"hello": "world"}"#) }
        #expect(throws: ImportError.notBitwardenJSON) { try PasswordImporter.parse("{ not json") }
        #expect(throws: ImportError.empty) { try PasswordImporter.parse(#"{"items": []}"#) }
    }

    @Test func csvStillWorksAndBOMJSONIsRecognised() throws {
        #expect(try PasswordImporter.parse("name,url,username,password\nA,https://a.com,u,p\n").logins.count == 1)
        #expect(try PasswordImporter.parse("\u{FEFF}\n  " + Self.export).cards.count == 2)
    }

    @Test func planAndApplyAddEverythingOnceAndNeverDuplicate() throws {
        var v = Vault()
        let f = try PasswordImporter.parse(Self.export)
        let plan = v.plan(f)
        #expect(plan.added == 1 && plan.newCards == 2 && plan.newIdentities == 1 && plan.newNotes == 1 && plan.writes == 5)
        #expect(v.cards.isEmpty)                                       // planning writes nothing

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        v.apply(f, now: now)
        #expect(v.logins.count == 1 && v.cards.count == 2 && v.identities.count == 1 && v.notes.count == 1)
        #expect(v.logins[0].sites == ["notion.so", "notion.com"])
        #expect(v.logins[0].customFields?.count == 2)
        #expect(v.cards.allSatisfy { $0.createdAt == now })

        // the same export again: nothing new
        let again = v.plan(f)
        #expect(again.newCards == 0 && again.duplicateCards == 2 && again.duplicateIdentities == 1 && again.duplicateNotes == 1)
        v.apply(f, now: now.addingTimeInterval(60))
        #expect(v.cards.count == 2 && v.identities.count == 1 && v.notes.count == 1 && v.logins.count == 1)
    }

    @Test func duplicatesInsideOneFileCollapse() throws {
        let twice = #"{"items": [{"type": 3, "name": "A", "card": {"number": "4111111111111111"}}, {"type": 3, "name": "B", "card": {"number": "4111 1111 1111 1111"}}]}"#
        var v = Vault()
        let f = try PasswordImporter.parse(twice)
        #expect(v.plan(f).newCards == 1 && v.plan(f).duplicateCards == 1)
        v.apply(f)
        #expect(v.cards.count == 1)
    }

    @Test func importedItemsSyncLikeAnyOther() throws {
        var a = Vault()
        let before = a
        a.apply(try PasswordImporter.parse(Self.export))
        a.stamp(changesFrom: before, node: "A")
        var b = Vault()
        b.merge(a.delta(since: nil))
        #expect(b.cards.count == 2 && b.identities.count == 1 && b.notes.count == 1)
        #expect(b.cards.first { $0.title == "Travel card" }?.securityCode == "737")
    }
}
