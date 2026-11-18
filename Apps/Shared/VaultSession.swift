import DeadboltCore
import Foundation
import Observation

/// The one place that holds the unlocked vault key. Used by the app and the AutoFill extension.
/// The key lives only in memory here and in the biometric Keychain item; it is dropped on lock.
@MainActor @Observable
final class VaultSession {
    enum State: Equatable { case loading, noVault, locked, unlocked }

    private(set) var state: State = .loading
    private(set) var vault = Vault()
    private(set) var busy = false
    var toast: Toast?
    /// False between creating the vault and finishing onboarding (words + Face ID), so Root keeps showing onboarding.
    var onboardingFinished = !Prefs.onboardingPending {
        didSet { Prefs.onboardingPending = !onboardingFinished }
    }

    private var key: VaultKey?
    private var backgroundedAt: Date?
    let store: VaultStore

    init(store: VaultStore = AppConfig.store) {
        self.store = store
        state = store.exists ? .locked : .noVault
    }

    var biometricsEnabled: Bool { Prefs.biometricsEnabled && KeychainKey.biometryAvailable }

    /// Face ID alone is fine until the periodic master-password check is due.
    var biometricUnlockAllowed: Bool {
        guard biometricsEnabled, let last = Prefs.lastPasswordUnlock else { return false }
        return Date().timeIntervalSince(last) < Prefs.passwordReprompt
    }

    // MARK: create

    /// Creates the vault. Returns the recovery key so onboarding can show the 24 words.
    func create(password: String) async throws -> RecoveryKey {
        busy = true
        defer { busy = false }
        let store = self.store
        let (key, recovery, vault) = try await Task.detached(priority: .userInitiated) {
            let key = VaultKey.generate()
            let recovery = RecoveryKey.generate()
            var vault = Vault()
            vault.recoveryPhrase = recovery.phrase
            try store.write(VaultFile.create(vault: vault, key: key, password: password, recoveryKey: recovery))
            return (key, recovery, vault)
        }.value
        self.key = key
        self.vault = vault
        Prefs.lastPasswordUnlock = Date()
        onboardingFinished = false
        state = .unlocked
        return recovery
    }

    // MARK: unlock / lock

    /// Argon2id runs off the main thread so the UI keeps animating.
    func unlock(password: String) async throws {
        busy = true
        defer { busy = false }
        let store = self.store
        let (key, vault) = try await Task.detached(priority: .userInitiated) {
            try store.read().unlock(password: password)
        }.value
        Prefs.lastPasswordUnlock = Date()
        if Prefs.biometricsEnabled { try? KeychainKey.store(key) } // refresh after re-enrolment
        finishUnlock(key: key, vault: vault)
    }

    /// Returns false if the person cancelled Face ID.
    @discardableResult
    func unlockWithBiometrics(reason: String = "Unlock your vault") async throws -> Bool {
        guard biometricUnlockAllowed else { return false }
        guard let key = try await KeychainKey.read(reason: reason) else { return false }
        let vault = try store.read().open(key: key)
        finishUnlock(key: key, vault: vault)
        return true
    }

    func unlock(recoveryPhrase: String, newPassword: String) async throws {
        busy = true
        defer { busy = false }
        let store = self.store
        let (key, vault) = try await Task.detached(priority: .userInitiated) {
            var file = try store.read()
            let (key, vault) = try file.unlock(recoveryKey: RecoveryKey(phrase: recoveryPhrase))
            try file.changeMasterPassword(to: newPassword, key: key)
            try store.write(file)
            return (key, vault)
        }.value
        Prefs.lastPasswordUnlock = Date()
        finishUnlock(key: key, vault: vault)
    }

    private func finishUnlock(key: VaultKey, vault: Vault) {
        self.key = key
        self.vault = vault
        state = .unlocked
        Task { await IdentitySync.update(from: vault) }
    }

    func lock() {
        key = nil
        vault = Vault()
        if store.exists { state = .locked }
    }

    func didEnterBackground() { backgroundedAt = Date() }

    /// Locks if the app was away longer than the setting; otherwise picks up changes the extension made.
    func didBecomeActive() {
        defer { backgroundedAt = nil }
        if let at = backgroundedAt, Date().timeIntervalSince(at) >= Prefs.lockAfter { lock(); return }
        reload()
    }

    func reload() {
        guard let key, let fresh = try? store.read().open(key: key) else { return }
        vault = fresh
    }

    // MARK: biometrics

    func setBiometrics(_ on: Bool) throws {
        if on {
            guard let key else { throw VaultError.locked }
            try KeychainKey.store(key)
        } else {
            KeychainKey.delete()
        }
        Prefs.biometricsEnabled = on
    }

    // MARK: changes

    /// Every change goes through the store's coordinated read-modify-write.
    @discardableResult
    func mutate<T>(_ change: (inout Vault) throws -> T) throws -> T {
        guard let key else { throw VaultError.locked }
        let (vault, value) = try store.mutate(key: key, change)
        self.vault = vault
        Task { await IdentitySync.update(from: vault) }
        return value
    }

    func changeMasterPassword(to password: String) async throws {
        guard let key else { throw VaultError.locked }
        busy = true
        defer { busy = false }
        let store = self.store
        try await Task.detached(priority: .userInitiated) {
            var file = try store.read()
            try file.changeMasterPassword(to: password, key: key)
            try store.write(file)
        }.value
        Prefs.lastPasswordUnlock = Date()
    }

    func show(_ title: String, _ detail: String? = nil, style: Toast.Style = .success) {
        toast = Toast(title: title, detail: detail, style: style)
        if style == .error { Haptics.error() } else { Haptics.success() }
    }
}

struct Toast: Equatable, Identifiable {
    enum Style { case success, error }
    let id = UUID()
    let title: String
    let detail: String?
    let style: Style
}

extension Error {
    /// Plain-language message for the person, never key material.
    var friendly: String {
        switch self as Error {
        case DeadboltError.authenticationFailed: "That password doesn’t open this vault."
        case DeadboltError.invalidRecoveryPhrase(let why): why
        case VaultError.invalidSite: "That doesn’t look like a website address."
        case VaultError.locked: "Unlock Deadbolt first."
        default: "Something went wrong: \(localizedDescription)"
        }
    }
}
