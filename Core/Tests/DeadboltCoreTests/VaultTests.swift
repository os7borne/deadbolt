import Foundation
import Testing
@testable import DeadboltCore

@Suite struct SiteTests {
    @Test(arguments: [
        ("https://WWW.GitHub.com/login?x=1", "github.com"), ("github.com", "github.com"), ("gist.github.com", "gist.github.com"),
        ("http://localhost:8080", "localhost"), ("accounts.google.com.", "accounts.google.com"),
    ])
    func normalizes(input: String, expected: String) { #expect(Site.normalize(input) == expected) }

    @Test(arguments: ["", "   ", "not a host", "foo", "javascript:alert(1)"])
    func rejects(input: String) { #expect(Site.normalize(input) == nil) }

    @Test func coverageIsStrict() {
        #expect(Site.host("gist.github.com", isCoveredBy: "github.com"))
        #expect(Site.host("https://www.github.com/x", isCoveredBy: "github.com"))
        #expect(!Site.host("github.com.evil.example", isCoveredBy: "github.com"))  // lookalike
        #expect(!Site.host("notgithub.com", isCoveredBy: "github.com"))
        #expect(!Site.host("github.com", isCoveredBy: "gist.github.com"))         // parent isn't covered by child
    }
}

@Suite struct VaultTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func savingSameSiteAndUserUpdatesInsteadOfDuplicating() throws {
        var v = Vault()
        let id = try v.save(host: "https://github.com/login", username: "alex", password: "one", now: t0)
        #expect(v.proposeSave(host: "github.com", username: "Alex ", password: "two") == .update(existing: id))
        let again = try v.save(host: "github.com", username: "Alex ", password: "two", now: t0.addingTimeInterval(60))
        #expect(again == id)
        #expect(v.logins.count == 1)
        #expect(v.login(id)?.password == "two")
        #expect(v.login(id)?.history.map(\.password) == ["one"])
    }

    @Test func unchangedPasswordNeedsNoPrompt() throws {
        var v = Vault()
        let id = try v.save(host: "github.com", username: "alex", password: "same")
        #expect(v.proposeSave(host: "www.github.com", username: "alex", password: "same") == .unchanged(existing: id))
        try v.save(host: "github.com", username: "alex", password: "same")
        #expect(v.logins.count == 1 && v.login(id)?.history.isEmpty == true)
    }

    @Test func multipleAccountsPerSite() throws {
        var v = Vault()
        let personal = try v.save(host: "github.com", username: "alex", password: "a", now: t0)
        let work = try v.save(host: "github.com", username: "alex-work", password: "b", now: t0)
        let bot = try v.save(host: "github.com", username: "alex-bot", password: "c", now: t0)
        #expect(v.logins.count == 3)
        #expect(v.accounts(for: "github.com").first?.id == personal) // first saved becomes preferred
        #expect(v.login(work)?.preferred == false)

        v.setPreferred(bot)
        #expect(v.accounts(for: "gist.github.com").first?.id == bot)
        #expect(v.logins.filter(\.preferred).map(\.id) == [bot])
    }

    @Test func explicitSeparateLoginIsAllowed() throws {
        var v = Vault()
        try v.save(host: "github.com", username: "alex", password: "a")
        try v.save(host: "github.com", username: "alex", password: "b", asNewAccount: true)
        #expect(v.logins.count == 2)
    }

    @Test func orderingPreferredThenRecentThenName() throws {
        var v = Vault()
        let a = try v.save(host: "x.com", username: "zed", password: "1", now: t0)        // preferred (first)
        let b = try v.save(host: "x.com", username: "bea", password: "2", now: t0)
        let c = try v.save(host: "x.com", username: "amy", password: "3", now: t0)
        v.markUsed(c, now: t0.addingTimeInterval(100))
        #expect(v.accounts(for: "x.com").map(\.id) == [a, c, b])
        #expect(v.accounts(for: "y.com").isEmpty)
    }

    @Test func historyIsCappedAndRestorable() throws {
        var item = LoginItem(sites: ["a.com"], username: "u", password: "p0", now: t0)
        for n in 1...25 { item.changePassword(to: "p\(n)", now: t0.addingTimeInterval(Double(n))) }
        #expect(item.history.count == LoginItem.historyLimit)
        #expect(item.history.first?.password == "p24")
        item.restore(item.history[3])
        #expect(item.password == "p21")
        #expect(item.history.first?.password == "p25")
    }

    @Test func passkeysLinkAndUnlink() throws {
        var v = Vault()
        let id = try v.save(host: "stripe.com", username: "alex@example.com", password: "x")
        let pk = Passkey.create(relyingPartyID: "stripe.com", userName: "alex@example.com", userHandle: Data([1]))
        v.add(pk, linkTo: id)
        #expect(v.passkeys(for: "stripe.com").count == 1)
        #expect(v.login(id)?.passkeyIDs == [pk.credentialID])
        v.deletePasskey(pk.credentialID)
        #expect(v.passkeys.isEmpty && v.login(id)?.passkeyIDs.isEmpty == true)
    }

    @Test func rejectsInvalidSite() {
        var v = Vault()
        #expect(throws: VaultError.invalidSite) { try v.save(host: "not a host", username: "u", password: "p") }
    }
}

@Suite struct VaultFileTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deadbolt-tests-\(UUID().uuidString)")

    @Test func createWriteReadUnlockWithPasswordAndRecoveryKey() throws {
        var vault = Vault()
        try vault.save(host: "github.com", username: "alex", password: "s3cret")
        let key = VaultKey.generate()
        let rk = RecoveryKey.generate()
        let file = try VaultFile.create(vault: vault, key: key, password: "copper-lantern", recoveryKey: rk, kdf: .testing())
        let url = dir.appendingPathComponent("vault.json")
        try file.write(to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("s3cret") && !raw.contains("github.com") && !raw.contains("alex")) // nothing in clear

        let back = try VaultFile.read(from: url)
        #expect(try back.unlock(password: "copper-lantern").1 == vault)
        #expect(try back.unlock(recoveryKey: RecoveryKey(phrase: rk.phrase)).1 == vault)
        #expect(throws: DeadboltError.authenticationFailed) { try back.unlock(password: "wrong") }
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func updateAndChangeMasterPassword() throws {
        let key = VaultKey.generate()
        var file = try VaultFile.create(vault: Vault(), key: key, password: "old", recoveryKey: .generate(), kdf: .testing())
        var vault = try file.open(key: key)
        try vault.save(host: "a.com", username: "u", password: "p")
        try file.update(vault, key: key)
        try file.changeMasterPassword(to: "new", key: key, kdf: .testing())
        #expect(file.wrapped.filter { $0.wrapper == .masterPassword }.count == 1)
        #expect(try file.unlock(password: "new").1.logins.count == 1)
        #expect(throws: DeadboltError.authenticationFailed) { try file.unlock(password: "old") }
    }
}

@Suite struct GeneratorTests {
    @Test func passwordsHaveEveryClassAndNoLookalikes() {
        for _ in 0..<200 {
            let p = PasswordGenerator.password(.init(length: 16))
            #expect(p.count == 16)
            #expect(p.contains(where: { PasswordGenerator.lower.contains($0) }))
            #expect(p.contains(where: { PasswordGenerator.upper.contains($0) }))
            #expect(p.contains(where: { PasswordGenerator.digitSet.contains($0) }))
            #expect(p.contains(where: { PasswordGenerator.symbolSet.contains($0) }))
            #expect(!p.contains(where: { "0O1lI".contains($0) }))
        }
        #expect(PasswordGenerator.password(.init(length: 2)).count == 8)
        #expect(!PasswordGenerator.password(.init(symbols: false)).contains(where: { PasswordGenerator.symbolSet.contains($0) }))
    }

    @Test func passphraseShape() {
        let parts = PasswordGenerator.passphrase(words: 5).split(separator: "-")
        #expect(parts.count == 6)
        #expect(parts.dropLast().allSatisfy { Wordlist.english.contains(String($0)) })
        #expect(Int(parts.last!) != nil)
    }
}

@Suite struct VaultStoreTests {
    @Test func mutateReadsLatestAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deadbolt-store-\(UUID().uuidString)/vault.json")
        let key = VaultKey.generate()
        let store = VaultStore(url: url)
        try store.write(VaultFile.create(vault: Vault(), key: key, password: "pw", recoveryKey: .generate(), kdf: .testing()))

        // Two "processes" each save through the store: neither change is lost.
        let (_, first) = try store.mutate(key: key) { try $0.save(host: "a.com", username: "app", password: "1") }
        let (vault, _) = try store.mutate(key: key) { try $0.save(host: "a.com", username: "extension", password: "2") }
        #expect(vault.logins.count == 2)
        #expect(try store.read().open(key: key).login(first)?.username == "app")
    }
}
