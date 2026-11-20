import CryptoKit
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
    /// Last time the vault was used (copy, fill, edit, unlock). The Mac locks after "Lock after" of no use.
    @ObservationIgnored private(set) var lastActivity = Date()
    func touch() { lastActivity = Date() }
    /// A login to open in the edit sheet (set from the Mac menu bar's Edit…; shown by the main window).
    var editTarget: EditTarget?
    /// A master-password check waiting for the person (Touch ID isn't available, or was cancelled). Shown by the main window; see OwnerCheck.swift.
    var ownerPrompt: OwnerPrompt?
    /// An item editor the menu-bar panel wants the main window to open (cards, identities, notes). The window takes it.
    var pendingItemSheet: ItemSheet?
    @ObservationIgnored var ownerContinuation: CheckedContinuation<Bool, Never>?
    /// Mac: Settings is shown inside the main window (not a second window) while this is true.
    var settingsOpen = false
    /// False between creating the vault and finishing onboarding (words + Face ID), so Root keeps showing onboarding.
    var onboardingFinished = !Prefs.onboardingPending {
        didSet { Prefs.onboardingPending = !onboardingFinished }
    }

    private(set) var key: VaultKey?
    @ObservationIgnored private(set) var sync: SyncEngine!
    private var backgroundedAt: Date?
    let store: VaultStore

    init(store: VaultStore = AppConfig.store) {
        self.store = store
        state = store.exists ? .locked : .noVault
        sync = SyncEngine(session: self)
    }

    var biometricsEnabled: Bool { Prefs.biometricsEnabled && KeychainKey.biometryAvailable }

    /// Face ID alone is fine until the periodic master-password check is due.
    var biometricUnlockAllowed: Bool {
        LockPolicy.biometricsAllowed(enabled: Prefs.biometricsEnabled, available: KeychainKey.biometryAvailable,
                                     lastPasswordUnlock: Prefs.lastPasswordUnlock, now: Date())
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
        touch()
        self.key = key
        self.vault = vault
        state = .unlocked
        _ = applyPending(includeAppOnly: !isExtension)
        Task { await IdentitySync.update(from: vault) }
        backupIfDue()
        if !isExtension { sync.start() }
    }

    /// Merges messages queued by a push-woken background fetch. Returns true if the vault key was rotated.
    /// The AutoFill extension merges ordinary changes; key rotations and snapshot requests wait for the app.
    @discardableResult
    func applyPending(includeAppOnly: Bool) -> Bool {
        let queued = SyncEngine.loadPending()
        guard !queued.isEmpty, key != nil else { return false }
        var keep: [Data] = []
        var rotated = false
        for (i, body) in queued.enumerated() {
            guard let key, let m = try? JSONDecoder.relayDecoder.decode(SyncMessage.self, from: body) else { continue }
            switch m.kind {
            case .delta, .snapshot:
                if let delta = try? m.open(vaultKey: key, devices: vault.devices ?? []) { try? applyRemote(delta) }
            case .rotate:
                guard includeAppOnly else { keep.append(contentsOf: queued[i...]); SyncEngine.savePending(keep); return false }
                if let data = try? m.openData(vaultKey: key, devices: vault.devices ?? []),
                   let payload = try? JSONDecoder().decode(RotatePayload.self, from: data), payload.removed != DeviceIdentity.id,
                   (try? adoptRotation(payload)) != nil {
                    rotated = true
                    SyncEngine.savePending([])                    // anything after it was in the old mailbox
                    return true
                }
            case .snapshotRequest:
                if !includeAppOnly { keep.append(body) }         // the app answers these when it next syncs
            }
        }
        SyncEngine.savePending(keep)
        return rotated
    }

    /// The AutoFill extension can't reach the backup folder; only the app writes backups.
    private var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    private func backupIfDue(force: Bool = false) {
        guard !isExtension else { return }
        Backups.runIfDue(vault, force: force, session: self)
    }

    /// First run on a new device: backup file + recovery words → a new local vault with a new master password.
    func restore(_ backup: BackupFile, phrase: String, password: String) async throws {
        busy = true
        defer { busy = false }
        let store = self.store
        let (key, vault) = try await Task.detached(priority: .userInitiated) {
            let recovery = try RecoveryKey(phrase: phrase)
            let restored = try backup.open(recoveryKey: recovery)
            let (file, key) = try VaultFile.restore(restored, recoveryKey: recovery, password: password)
            try store.write(file)
            return (key, try file.open(key: key))
        }.value
        Prefs.lastPasswordUnlock = Date()
        onboardingFinished = false
        self.key = key
        self.vault = vault
        state = .unlocked
        Task { await IdentitySync.update(from: vault) }
    }

    func lock() {
        finishOwnerPrompt(false)
        sync.stop()
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
        if state == .unlocked { sync.soon() }
    }

    func reload() {
        guard let key, let fresh = try? store.read().open(key: key) else { return }
        vault = fresh
    }

    // MARK: erase

    /// Checks the master password (Argon2id) without changing any state. Used before destructive actions.
    func verify(password: String) async throws {
        busy = true
        defer { busy = false }
        let store = self.store
        _ = try await Task.detached(priority: .userInitiated) { try store.read().unlock(password: password) }.value
    }

    /// Removes Deadbolt's data from THIS device: vault file, Face ID key, system suggestions, preferences.
    func eraseThisDevice() throws {
        sync.stop()
        try store.delete()
        DeviceIdentity.reset()
        KeychainKey.delete()
        IdentitySync.clear()
        Prefs.biometricsEnabled = false
        Prefs.lastPasswordUnlock = nil
        onboardingFinished = true
        key = nil
        vault = Vault()
        state = .noVault
    }

    // MARK: sync

    /// Changes from another device, already verified and decrypted by the sync engine.
    func applyRemote(_ delta: Vault) throws {
        guard let key else { throw VaultError.locked }
        vault = try store.mergeRemote(key: key, delta)
        Task { await IdentitySync.update(from: vault) }
    }

    /// A vault just arrived through linking: it's locked until the master password is typed.
    func reloadAfterLink() {
        Prefs.joinedByLink = true
        onboardingFinished = false
        key = nil
        vault = Vault()
        state = store.exists ? .locked : .noVault
    }

    /// Approves a new device: relay membership, device record, then the vault file sealed to the link key.
    func link(_ hello: LinkMessage.Hello, details: LinkMessage.Details, linkKey: SymmetricKey, room: String) async throws {
        guard let key else { throw VaultError.locked }
        let relay = RelayClient(base: SyncConfig.relay, device: DeviceIdentity.id, keys: try DeviceIdentity.keys())
        try await relay.addMember(mailbox: key.mailboxID, device: hello.device, signingKey: hello.signingKey)
        let record = DeviceRecord(id: hello.device, name: details.name, model: details.model, platform: details.platform,
                                  signingKey: hello.signingKey, agreementKey: hello.agreementKey)
        try mutate { $0.upsertDevice(record) }
        var m = LinkMessage(kind: .vault)
        m.sealed = try Link.sealVault(try store.read(), key: linkKey) // still locked by the master password
        try await relay.post(link: room, m)
        await sync.syncNow()
    }

    /// Removes another device, or retires this one. The caller has already checked the master password,
    /// which is needed again here to wrap the new vault key.
    func remove(_ device: DeviceRecord, password: String) async throws {
        guard let key else { throw VaultError.locked }
        busy = true
        defer { busy = false }
        let keys = try DeviceIdentity.keys()
        let me = DeviceIdentity.id
        let relay = RelayClient(base: SyncConfig.relay, device: me, keys: keys)
        let revocation = try keys.revoke(device: device.id, by: me)
        if device.id == me {
            try mutate { $0.revokeDevice(revocation) }
            await sync.syncNow()                                  // tell the others before losing access
            try await relay.revoke(mailbox: key.mailboxID, revocation)
            try eraseThisDevice()
        } else {
            try await relay.revoke(mailbox: key.mailboxID, revocation)
            try mutate { $0.revokeDevice(revocation) }
            await sync.syncNow()                                  // the removal itself reaches the others first
            try await rotateKey(removed: device.id, password: password, relay: relay, keys: keys)
        }
    }

    /// After a removal: a new vault key the removed device never sees.
    /// 1) new key wrapped by the master password + recovery key, 2) sealed to each remaining device's agreement key,
    /// 3) new mailbox with only the remaining devices, 4) signed announcement in the old mailbox, 5) re-seal locally.
    private func rotateKey(removed: String, password: String, relay: RelayClient, keys: DeviceKeys) async throws {
        guard let old = key, let phrase = vault.recoveryPhrase else { throw VaultError.locked }
        let next = VaultKey.generate(epoch: old.epoch + 1)
        let current = vault
        let me = DeviceIdentity.id
        let others = current.activeDevices.filter { $0.id != me }
        let (file, grants) = try await Task.detached(priority: .userInitiated) {
            let file = try VaultFile.create(vault: current, key: next, password: password, recoveryKey: RecoveryKey(phrase: phrase))
            return (file, try others.map { try KeyGrant.make(next, for: $0) })
        }.value

        try await relay.create(mailbox: next.mailboxID)
        for d in others { try await relay.addMember(mailbox: next.mailboxID, device: d.id, signingKey: d.signingKey) }
        AppConfig.defaults.set(true, forKey: "mailboxReady-\(next.mailboxID.prefix(12))")

        let payload = RotatePayload(epoch: next.epoch, removed: removed, grants: grants, wrapped: file.wrapped)
        try await relay.send(mailbox: old.mailboxID, try SyncMessage.make(.rotate, data: JSONEncoder().encode(payload),
                                                                          from: me, keys: keys, vaultKey: old))
        try store.write(file)
        key = next
        if Prefs.biometricsEnabled { try? KeychainKey.store(next) }
        show("New vault key in use", "The removed device can’t read anything from now on")
    }

    /// Another device removed someone and sent the next key. Re-seal the local vault under it.
    func adoptRotation(_ payload: RotatePayload) throws {
        guard let old = key, payload.epoch == old.epoch + 1,
              let grant = payload.grants.first(where: { $0.device == DeviceIdentity.id }) else { throw SyncError.wrongEpoch(payload.epoch) }
        let next = try grant.open(with: try DeviceIdentity.keys())
        let current = try store.read().open(key: old)
        try store.write(try VaultFile.rekeyed(current, key: next, wrapped: payload.wrapped))
        key = next
        vault = current
        if Prefs.biometricsEnabled { try? KeychainKey.store(next) }
    }

    /// The relay says this device was removed. Erase only if the removal is signed by a device of this vault.
    func handleRemoval(_ r: Revocation) {
        guard r.device == DeviceIdentity.id,
              let signer = vault.device(r.by), r.isValid(signer: signer) else {
            show("Sync stopped", "The relay reported a removal that couldn’t be verified", style: .error)
            return
        }
        Prefs.removedNotice = "“\(signer.name)” removed this device from your vault on \(r.at.formatted(date: .abbreviated, time: .shortened)), so its copy was erased."
        try? eraseThisDevice()
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
        touch()
        let (vault, value) = try store.mutate(key: key, change)
        self.vault = vault
        Task { await IdentitySync.update(from: vault) }
        backupIfDue()
        if !isExtension { sync.soon() }
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
        touch()
        toast = Toast(title: title, detail: detail, style: style)
        if style == .error { Haptics.error() } else { Haptics.success() }
    }
}

struct EditTarget: Identifiable, Equatable { let id: UUID }

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
        case let e as LocalizedError where e.errorDescription != nil: e.errorDescription!
        default: "Something went wrong: \(localizedDescription)"
        }
    }
}
