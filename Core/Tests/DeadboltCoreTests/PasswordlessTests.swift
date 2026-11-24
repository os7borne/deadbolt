import Foundation
import Testing
@testable import DeadboltCore

/// Accounts saved on purpose without a password (sign-in by emailed link or code).
@Suite struct PasswordlessTests {
    @Test func savingWithoutAPasswordMakesAPasswordlessLogin() throws {
        var v = Vault()
        let id = try v.save(host: "https://workfromacafe.com/login", username: "me@mail.example", password: "")
        let item = try #require(v.login(id))
        #expect(item.isPasswordless && !item.isCodeOnly && item.passwordless == true)
        #expect(item.sites == ["workfromacafe.com"] && item.history.isEmpty)
        #expect(v.accounts(for: "workfromacafe.com").map(\.id) == [id])      // listed like any login
    }

    @Test func anEmptyPasswordNeverOverwritesARealOne() throws {
        var v = Vault()
        let id = try v.save(host: "github.com", username: "Alex", password: "real-pw")
        #expect(v.proposeSave(host: "github.com", username: "alex ", password: "") == .unchanged(existing: id))
        let again = try v.save(host: "github.com", username: "alex", password: "")
        #expect(again == id && v.login(id)?.password == "real-pw" && v.login(id)?.history.isEmpty == true)
        #expect(v.logins.count == 1)
    }

    @Test func savingTheSameEmailTwiceDoesNotDuplicate() throws {
        var v = Vault()
        let a = try v.save(host: "workfromacafe.com", username: "me@mail.example", password: "")
        #expect(v.proposeSave(host: "workfromacafe.com", username: "ME@mail.example", password: "") == .unchanged(existing: a))
        #expect(try v.save(host: "workfromacafe.com", username: "me@mail.example", password: "") == a)
        #expect(v.logins.count == 1)
    }

    @Test func addingAPasswordLaterClearsTheFlagWithoutAnEmptyHistoryEntry() throws {
        var v = Vault()
        let id = try v.save(host: "workfromacafe.com", username: "me@mail.example", password: "")
        #expect(v.proposeSave(host: "workfromacafe.com", username: "me@mail.example", password: "now-a-pw") == .update(existing: id))
        _ = try v.save(host: "workfromacafe.com", username: "me@mail.example", password: "now-a-pw")
        let item = try #require(v.login(id))
        #expect(item.password == "now-a-pw" && item.passwordless == nil && !item.isPasswordless && item.history.isEmpty)
    }

    @Test func clearingAPasswordOnPurposeMakesItPasswordlessAndKeepsTheOldOneInHistory() throws {
        var v = Vault()
        let id = try v.save(host: "github.com", username: "alex", password: "old")
        var item = try #require(v.login(id))
        item.changePassword(to: "")
        #expect(item.isPasswordless && item.history.map(\.password) == ["old"])
    }

    @Test func aCodeOnAPasswordlessLoginDoesNotTurnItIntoACodeOnlyEntry() throws {
        var v = Vault()
        let id = try v.save(host: "workfromacafe.com", username: "me@mail.example", password: "")
        var item = try #require(v.login(id))
        item.totpSecret = "JBSWY3DPEHPK3PXP"
        #expect(!item.isCodeOnly && item.isPasswordless)
        // A login that was never flagged and has only a code is still a code-only entry.
        let code = try v.saveCode(host: nil, title: "X", username: "u", secret: "JBSWY3DPEHPK3PXP")
        #expect(v.login(code)?.isCodeOnly == true && v.login(code)?.isPasswordless == false)
    }

    @Test func passkeyOnlyAccountsAreNotPasswordless() {
        var item = LoginItem(sites: ["example.com"], username: "u", password: "", passkeyIDs: [Data([1])])
        #expect(!item.isPasswordless && !item.isCodeOnly)
        item.passkeyIDs = []
        #expect(item.isPasswordless)
    }

    @Test func theFlagSyncsAndOldLoginsStillDecode() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var a = Vault(); let before = a
        let id = try a.save(host: "workfromacafe.com", username: "me@mail.example", password: "", now: t)
        a.stamp(changesFrom: before, node: "A", now: t)
        var b = Vault()
        b.merge(a.delta(since: nil))
        #expect(b.login(id)?.passwordless == true && b.login(id)?.isPasswordless == true)

        // A login saved by an older build has no `passwordless` key.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(a.login(id)))) as! [String: Any]
        old.removeValue(forKey: "passwordless")
        let decoded = try JSONDecoder().decode(LoginItem.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.passwordless == nil && decoded.isPasswordless)   // still listed as a login, never a code-only entry
    }
}
