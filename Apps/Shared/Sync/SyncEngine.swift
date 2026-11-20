import DeadboltCore
import Foundation
import Observation

/// Keeps this device's vault in step with the others through the relay mailbox.
/// Push: changes since the last send. Pull: everything after the last message seen. Both idempotent.
@MainActor @Observable
final class SyncEngine {
    enum Status: Equatable {
        case off
        case syncing
        case upToDate(Date)
        case offline(String)
    }

    private(set) var status: Status = .off
    private(set) var running = false
    private weak var session: VaultSession?
    private var pending: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(session: VaultSession) { self.session = session }

    private var lastSent: HLC? {
        get { AppConfig.defaults.data(forKey: "syncLastSent").flatMap { try? JSONDecoder().decode(HLC.self, from: $0) } }
        set { AppConfig.defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "syncLastSent") }
    }
    /// Sealed, signed messages fetched while the vault was locked (silent push). Merged at the next unlock.
    static var pendingURL: URL { AppConfig.store.url.deletingLastPathComponent().appendingPathComponent("pending.json") }

    static func loadPending() -> [Data] {
        (try? JSONDecoder().decode([Data].self, from: Data(contentsOf: pendingURL))) ?? []
    }

    static func savePending(_ items: [Data]) {
        if items.isEmpty { try? FileManager.default.removeItem(at: pendingURL); return }
        try? JSONEncoder().encode(items).write(to: pendingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var u = pendingURL; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? u.setResourceValues(rv)
    }

    /// Woken by a silent push while locked: fetch the new (still encrypted) messages and queue them.
    /// No key is needed or used; the queue is merged after the next unlock, in the app or the AutoFill sheet.
    static func prefetch() async -> Bool {
        guard let box = AppConfig.defaults.string(forKey: "currentMailbox"), let keys = try? DeviceIdentity.keys() else { return false }
        let me = DeviceIdentity.id
        let relay = RelayClient(base: SyncConfig.relay, device: me, keys: keys)
        let seqKey = "syncLastSeq-\(box.prefix(16))"
        var after = AppConfig.defaults.integer(forKey: seqKey)
        var queued = loadPending()
        let start = queued.count
        do {
            while true {
                let page = try await relay.fetch(mailbox: box, after: after)
                for e in page.messages {
                    after = max(after, e.seq)
                    if e.from != me { queued.append(e.body) }
                }
                if page.messages.count < 200 { break }
            }
            savePending(queued)                                   // durable first, then acknowledge
            if after != AppConfig.defaults.integer(forKey: seqKey) {
                try await relay.ack(mailbox: box, seq: after)
                AppConfig.defaults.set(after, forKey: seqKey)
            }
        } catch { return false }
        return queued.count > start
    }

    /// Registers this iPhone's push token with the current mailbox when it changes.
    private func registerPushIfNeeded(relay: RelayClient, mailbox: String) async {
        guard let token = AppConfig.defaults.string(forKey: "pushToken") else { return }
        let marker = "pushRegistered-\(mailbox.prefix(16))"
        guard AppConfig.defaults.string(forKey: marker) != token else { return }
        if (try? await relay.registerPush(mailbox: mailbox, token: token)) != nil { AppConfig.defaults.set(token, forKey: marker) }
    }

    /// Position in the current mailbox. Kept per mailbox, because a key rotation moves everyone to a new one.
    private func lastSeq(_ box: String) -> Int { AppConfig.defaults.integer(forKey: "syncLastSeq-\(box.prefix(16))") }
    private func setLastSeq(_ box: String, _ v: Int) { AppConfig.defaults.set(v, forKey: "syncLastSeq-\(box.prefix(16))") }

    // MARK: scheduling

    /// Starts periodic sync while unlocked. Safe to call repeatedly.
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stop() {
        timer?.cancel(); timer = nil
        pending?.cancel(); pending = nil
        status = .off
    }

    /// After a local change: wait a moment so a burst of edits goes out as one message.
    func soon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    // MARK: the sync pass

    func syncNow() async {
        guard !running, let session, let key = session.key, session.state == .unlocked else { return }
        running = true
        defer { running = false }
        if case .upToDate = status {} else { status = .syncing }
        do {
            let keys = try DeviceIdentity.keys()
            let me = DeviceIdentity.id
            let relay = RelayClient(base: SyncConfig.relay, device: me, keys: keys)
            try await bootstrapIfNeeded(session: session, relay: relay, keys: keys, key: key)
            let box = key.mailboxID
            AppConfig.defaults.set(box, forKey: "currentMailbox")     // so a locked, push-woken app knows where to fetch
            if session.applyPending(includeAppOnly: true) { running = false; await syncNow(); return } // a queued rotation moved us
            await registerPushIfNeeded(relay: relay, mailbox: box)

            if AppConfig.defaults.bool(forKey: "linkedFresh") {
                lastSent = session.vault.newestClock          // everything here came from the approver already
                AppConfig.defaults.removeObject(forKey: "linkedFresh")
            }

            // Push
            let out = session.vault.delta(since: lastSent)
            if !out.isEmptyDelta {
                try await relay.send(mailbox: box, try SyncMessage.make(.delta, payload: out, from: me, keys: keys, vaultKey: key))
                lastSent = session.vault.newestClock
            }

            // Pull
            var after = lastSeq(box)
            var rotated = false
            pull: while true {
                let page = try await relay.fetch(mailbox: box, after: after)
                if after > 0 && page.oldest > after + 1 && page.oldest <= page.latest || (after > page.latest) {
                    // Messages expired before we saw them (offline > 7 days) or the mailbox was reset: ask for everything.
                    try await relay.send(mailbox: box, try SyncMessage.make(.snapshotRequest, payload: Vault(), from: me, keys: keys, vaultKey: key))
                    after = max(0, page.oldest - 1)
                }
                for e in page.messages {
                    after = max(after, e.seq)
                    guard e.from != me else { continue }
                    if await handle(e, session: session, relay: relay, keys: keys, key: key, mailbox: box) {
                        rotated = true                     // new key, new mailbox: stop reading the old one
                        break pull
                    }
                }
                if page.messages.count < 200 { break }
            }
            if after != lastSeq(box) {
                try await relay.ack(mailbox: box, seq: after)
                setLastSeq(box, after)
            }
            if rotated {
                status = .syncing
                running = false
                await syncNow()                            // continue in the new mailbox right away
                return
            }
            status = .upToDate(Date())
        } catch RelayError.revoked(let r) {
            session.handleRemoval(r)
        } catch {
            status = .offline(Self.describe(error))
        }
    }

    /// Returns true if the vault key was rotated (the caller must switch mailbox).
    private func handle(_ e: RelayClient.Envelope, session: VaultSession, relay: RelayClient, keys: DeviceKeys, key: VaultKey, mailbox: String) async -> Bool {
        guard let m = try? JSONDecoder.relayDecoder.decode(SyncMessage.self, from: e.body) else { return false }
        do {
            switch m.kind {
            case .delta, .snapshot:
                let delta = try m.open(vaultKey: key, devices: session.vault.devices ?? [])
                try session.applyRemote(delta)
            case .snapshotRequest:
                _ = try m.open(vaultKey: key, devices: session.vault.devices ?? []) // only answer real members
                try await relay.send(mailbox: mailbox, try SyncMessage.make(.snapshot, payload: session.vault.delta(since: nil),
                                                                              from: DeviceIdentity.id, keys: keys, vaultKey: key))
            case .rotate:
                let data = try m.openData(vaultKey: key, devices: session.vault.devices ?? [])
                let payload = try JSONDecoder().decode(RotatePayload.self, from: data)
                guard payload.removed != DeviceIdentity.id else { return false } // we were the one removed: the relay says so next
                try session.adoptRotation(payload)
                return true
            }
        } catch {
            // A message we can't verify or open is ignored, never merged.
        }
        return false
    }

    /// First sync on this vault: give it an account number, register this device, create the mailbox.
    private func bootstrapIfNeeded(session: VaultSession, relay: RelayClient, keys: DeviceKeys, key: VaultKey) async throws {
        let me = DeviceIdentity.id
        if session.vault.accountNumber == nil || session.vault.device(me) == nil {
            let record = try DeviceIdentity.record(keys: keys)
            try session.mutate { v in
                if v.accountNumber == nil { v.accountNumber = AccountNumber.generate().digits }
                if v.device(me) == nil { v.upsertDevice(record) }
            }
        }
        if !AppConfig.defaults.bool(forKey: "mailboxReady-\(key.mailboxID.prefix(12))") {
            // Only the first device of a vault creates the mailbox; linked devices were added by their approver.
            if session.vault.activeDevices.count == 1 {
                do { try await relay.create(mailbox: key.mailboxID) }
                catch RelayError.http(409, _) {} // already exists
            }
            AppConfig.defaults.set(true, forKey: "mailboxReady-\(key.mailboxID.prefix(12))")
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case RelayError.http(let code, let msg): "Relay said \(code): \(msg)"
        case let e as URLError where e.code == .notConnectedToInternet: "No internet connection"
        case let e as URLError where e.code == .cannotFindHost: "Can’t reach the sync relay"
        default: error.localizedDescription
        }
    }
}

extension JSONDecoder {
    static var relayDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
