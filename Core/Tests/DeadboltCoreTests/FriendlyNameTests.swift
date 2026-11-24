import Foundation
import Testing
@testable import DeadboltCore

/// The owner's own name for a login (LoginItem.title), versus the one derived from its website.
@Suite struct FriendlyNameTests {
    @Test func aNewLoginUsesTheWebsiteNameAndHasNoCustomName() throws {
        var v = Vault()
        let id = try v.save(host: "https://www.github.com/login", username: "alex", password: "pw")
        let item = try #require(v.login(id))
        #expect(item.title == "Github" && item.customName == nil)
        #expect(LoginItem.defaultTitle(for: ["accounts.google.com"]) == "Google")
        #expect(LoginItem.defaultTitle(for: []) == "Login")
    }

    @Test func aChosenNameIsReportedAndClearingItGoesBackToTheWebsite() throws {
        var v = Vault()
        let id = try v.save(host: "github.com", username: "alex", password: "pw")
        var item = try #require(v.login(id))
        item.title = "Work GitHub"
        #expect(item.customName == "Work GitHub")
        item.title = "   "                                   // blank counts as no name
        #expect(item.customName == nil)
        item.title = LoginItem.defaultTitle(for: item.sites)
        #expect(item.customName == nil)
    }

    @Test func theNameSyncsLikeAnyOtherField() throws {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var a = Vault(); var before = a
        let id = try a.save(host: "github.com", username: "alex", password: "pw", now: t)
        a.stamp(changesFrom: before, node: "A", now: t)
        var b = Vault(); b.merge(a.delta(since: nil))
        before = a
        var item = try #require(a.login(id)); item.title = "Personal GitHub"; a.upsert(item)
        a.stamp(changesFrom: before, node: "A", now: t.addingTimeInterval(60))
        b.merge(a.delta(since: nil))
        #expect(b.login(id)?.customName == "Personal GitHub")
    }
}
