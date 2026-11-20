import Foundation
import Testing
@testable import DeadboltCore

@Suite struct SecurityPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func bridgeOnlyReleasesLoginsForThePagesSite() throws {
        var v = Vault()
        let gh = try v.save(host: "github.com", username: "alex", password: "p")
        let bank = try v.save(host: "bank.example", username: "alex", password: "q")
        #expect(v.login(gh, for: "github.com")?.password == "p")
        #expect(v.login(gh, for: "gist.github.com") != nil)               // subdomain of the saved site
        #expect(v.login(gh, for: "github.com.evil.example") == nil)       // lookalike
        #expect(v.login(bank, for: "github.com") == nil)                  // another site's login, even with its id
        #expect(v.login(UUID(), for: "github.com") == nil)
    }

    @Test func idleLock() {
        #expect(!LockPolicy.shouldLock(lastActivity: t0, now: t0.addingTimeInterval(299), lockAfter: 300))
        #expect(LockPolicy.shouldLock(lastActivity: t0, now: t0.addingTimeInterval(300), lockAfter: 300))
        // "Immediately" still waits the Mac minimum, so the menu bar stays usable for a moment.
        #expect(!LockPolicy.shouldLock(lastActivity: t0, now: t0.addingTimeInterval(30), lockAfter: 0))
        #expect(LockPolicy.shouldLock(lastActivity: t0, now: t0.addingTimeInterval(60), lockAfter: 0))
    }

    @Test func biometricWindow() {
        let day: TimeInterval = 24 * 3600
        #expect(LockPolicy.biometricsAllowed(enabled: true, available: true, lastPasswordUnlock: t0, now: t0.addingTimeInterval(13 * day)))
        #expect(!LockPolicy.biometricsAllowed(enabled: true, available: true, lastPasswordUnlock: t0, now: t0.addingTimeInterval(14 * day)))
        #expect(!LockPolicy.biometricsAllowed(enabled: true, available: true, lastPasswordUnlock: nil, now: t0))
        #expect(!LockPolicy.biometricsAllowed(enabled: false, available: true, lastPasswordUnlock: t0, now: t0))
        #expect(!LockPolicy.biometricsAllowed(enabled: true, available: false, lastPasswordUnlock: t0, now: t0))
        // A "last unlock" in the future (edited preferences) must not grant biometric unlock for longer.
        #expect(!LockPolicy.biometricsAllowed(enabled: true, available: true, lastPasswordUnlock: t0.addingTimeInterval(30 * day), now: t0))
    }

    @Test func secureRandomIsRandom() {
        #expect(SecureRandom.bytes(32).count == 32)
        #expect(SecureRandom.bytes(32) != SecureRandom.bytes(32))
    }
}
