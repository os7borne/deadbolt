import Foundation
import Testing
@testable import DeadboltCore

@Suite struct TOTPTests {
    // RFC 6238 Appendix B (8 digits).
    static let sha1 = Data("12345678901234567890".utf8)
    static let sha256 = Data("12345678901234567890123456789012".utf8)
    static let sha512 = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

    @Test(arguments: [
        (59.0, "94287082", "46119246", "90693936"),
        (1111111109, "07081804", "68084774", "25091201"),
        (1111111111, "14050471", "67062674", "99943326"),
        (1234567890, "89005924", "91819424", "93441116"),
        (2000000000, "69279037", "90698825", "38618901"),
        (20000000000, "65353130", "77737706", "47863826"),
    ])
    func rfc6238(time: Double, s1: String, s256: String, s512: String) {
        let d = Date(timeIntervalSince1970: time)
        #expect(TOTP(secret: Self.sha1, algorithm: .sha1, digits: 8).code(at: d) == s1)
        #expect(TOTP(secret: Self.sha256, algorithm: .sha256, digits: 8).code(at: d) == s256)
        #expect(TOTP(secret: Self.sha512, algorithm: .sha512, digits: 8).code(at: d) == s512)
    }

    @Test func base32RFC4648() {
        #expect(Base32.decode("MZXW6YTBOI======") == Data("foobar".utf8))
        #expect(Base32.decode("mzxw 6ytb oi") == Data("foobar".utf8))
        #expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")
        #expect(Base32.decode("not base32!") == nil)
    }

    @Test func parsesSetupKeyAndURI() throws {
        let key = Base32.encode(Self.sha1)
        #expect(try TOTP(key).secret == Self.sha1)
        let t = try TOTP("otpauth://totp/GitHub:alex?secret=\(key)&issuer=GitHub&digits=8&period=60&algorithm=SHA256")
        #expect(t.issuer == "GitHub" && t.account == "alex" && t.digits == 8 && t.period == 60 && t.algorithm == .sha256)
        #expect(throws: TOTPError.unsupportedType) { try TOTP("otpauth://hotp/x?secret=\(key)&counter=1") }
        #expect(throws: TOTPError.invalidSecret) { try TOTP("ABC") }
        #expect(throws: TOTPError.invalidURI) { try TOTP("otpauth://totp/x?secret=\(key)&digits=12") }
    }

    @Test func countdownAndGrouping() {
        let t = TOTP(secret: Self.sha1)
        #expect(t.secondsRemaining(at: Date(timeIntervalSince1970: 59)) == 1)
        #expect(t.secondsRemaining(at: Date(timeIntervalSince1970: 60)) == 30)
        #expect(t.code(at: Date(timeIntervalSince1970: 59)).count == 6)
        #expect(TOTP.grouped("302718") == "302 718")
    }
}

@Suite struct CSVTests {
    @Test func quotesCommasNewlinesBOMAndCRLF() {
        let text = "\u{FEFF}a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"line1\nline2\"\r\n\nlast,,\n"
        #expect(CSV.parse(text) == [["a", "b", "c"], ["x, y", "say \"hi\"", "line1\nline2"], ["last", "", ""]])
    }
}

@Suite struct ImportTests {
    @Test func applePasswordsExport() throws {
        let csv = """
        Title,URL,Username,Password,Notes,OTPAuth
        github.com (alex),https://github.com/,alex,pw1,,otpauth://totp/GitHub:alex?secret=JBSWY3DPEHPK3PXP&issuer=GitHub
        Bank,https://www.examplebank.com/login,58204471,pw2,"PIN hint, not the PIN",
        """
        let f = try PasswordImporter.parse(csv)
        #expect(f.source == .applePasswords)
        #expect(f.logins.count == 2 && f.skipped.isEmpty)
        #expect(f.logins[0].totp?.hasPrefix("otpauth://") == true)
        #expect(f.logins[1].notes == "PIN hint, not the PIN")
    }

    @Test func chromeExport() throws {
        let f = try PasswordImporter.parse("name,url,username,password,note\ngithub.com,https://github.com/login,alex,pw,\n")
        #expect(f.source == .chrome && f.logins.first?.username == "alex")
    }

    @Test func onePasswordAndBitwardenByHeaders() throws {
        let op = try PasswordImporter.parse("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nStripe,stripe.com,alex@example.com,pw,,false,false,,\n")
        #expect(op.source == .onePassword && op.logins.count == 1)
        let bw = try PasswordImporter.parse("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,Notion,,,0,https://notion.so,alex,pw,\n")
        #expect(bw.source == .bitwarden && bw.logins.first?.url == "https://notion.so")
    }

    @Test func skipsRowsWithReasons() throws {
        let f = try PasswordImporter.parse("name,url,username,password\nA,,u,p\nB,https://b.com,u,\nC,android://com.app,u,p\nD,https://d.com,u,p\n")
        #expect(f.logins.map(\.url) == ["https://d.com"])
        #expect(f.skipped.map(\.row) == [2, 3, 4])
    }

    @Test func rejectsUnknownColumnsAndEmpty() {
        #expect(throws: ImportError.empty) { try PasswordImporter.parse("name,url,username,password\n") }
        #expect(throws: ImportError.unrecognizedColumns(found: ["foo", "bar"])) { try PasswordImporter.parse("foo,bar\n1,2\n") }
    }

    @Test func planAndApplyNeverDuplicate() throws {
        var v = Vault()
        let existing = try v.save(host: "github.com", username: "alex", password: "old")
        let same = try v.save(host: "stripe.com", username: "a@example.com", password: "same")
        let csv = """
        name,url,username,password
        GitHub,https://github.com,Alex,new
        Stripe,https://stripe.com,a@example.com,same
        Notion,https://notion.so,alex,n1
        Notion,https://www.notion.so,alex,n2
        """
        let f = try PasswordImporter.parse(csv)
        let plan = v.plan(f)
        let actions = plan.entries.map(\.action)
        #expect(actions[0] == .update(existing))
        #expect(actions[1] == .unchanged(same))
        #expect(actions[2] == .add)
        #expect(plan.entries[3].updateID != nil)   // the 2nd Notion row updates the 1st, not a duplicate
        #expect(plan.added == 1 && plan.updated == 2 && plan.unchanged == 1)
        #expect(v.logins.count == 2)                // planning writes nothing

        v.apply(f)
        #expect(v.logins.count == 3)
        #expect(v.login(existing)?.password == "new" && v.login(existing)?.history.first?.password == "old")
        #expect(v.accounts(for: "notion.so").first?.password == "n2")
        #expect(v.accounts(for: "notion.so").first?.title == "Notion")
    }

    @Test func importKeepsCodeKeys() throws {
        var v = Vault()
        v.apply(try PasswordImporter.parse("Title,URL,Username,Password,Notes,OTPAuth\nGH,https://github.com,alex,pw,,JBSWY3DPEHPK3PXP\n"))
        #expect(v.logins.first?.totpSecret == "JBSWY3DPEHPK3PXP")
    }
}

private extension ImportPlan.Entry {
    var updateID: ImportPlan.Action? { if case .update = action { return action } else { return nil } }
}

@Suite struct BackupTests {
    @Test func roundTripWithRecoveryWordsOnly() throws {
        var v = Vault()
        try v.save(host: "github.com", username: "alex", password: "s3cret")
        let rk = RecoveryKey.generate()
        let data = try BackupFile.make(v, recoveryKey: rk).encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("s3cret") == false)
        let file = try BackupFile.read(data)
        #expect(file.items == 1)
        #expect(try file.open(recoveryKey: RecoveryKey(phrase: rk.phrase)) == v)
        #expect(throws: DeadboltError.authenticationFailed) { try file.open(recoveryKey: .generate()) }
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: (any Error).self) { try BackupFile.read(Data("{}".utf8)) }
        let wrongKind = #"{"kind":"x","format":1,"createdAt":0,"items":0,"sealed":""}"#
        #expect(throws: DeadboltError.malformed) { try BackupFile.read(Data(wrongKind.utf8)) }
    }

    @Test func restoreKeepsRecoveryKeyAndSetsNewPassword() throws {
        var v = Vault()
        try v.save(host: "a.com", username: "u", password: "p")
        let rk = RecoveryKey.generate()
        let (file, key) = try VaultFile.restore(v, recoveryKey: rk, password: "new-master", kdf: .testing())
        #expect(try file.unlock(password: "new-master").1.logins.count == 1)
        #expect(try file.unlock(recoveryKey: rk).0.keychainRepresentation == key.keychainRepresentation)
        #expect(try file.open(key: key).recoveryPhrase == rk.phrase)
    }

    @Test func fileNameIsSortableAndHasExtension() {
        let name = BackupFile.fileName(for: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(name.hasPrefix("Deadbolt Backup 2027-") && name.hasSuffix(".deadbolt"))
    }
}
