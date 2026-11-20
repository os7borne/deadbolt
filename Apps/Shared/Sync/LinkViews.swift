import CryptoKit
import DeadboltCore
import SwiftUI

/// Network work for linking runs in tasks owned by these models, never by a view: a sheet re-presenting
/// (e.g. right after the QR scanner closes) must not cancel a request half-way.

// MARK: new device: "I already use Deadbolt"

@MainActor @Observable
final class JoinModel {
    enum Phase: Equatable { case waiting, confirm(code: String, by: String), receiving, done, declined, failed(String) }

    var phase: Phase = .waiting
    var useAccountNumber = false
    var accountNumber = ""
    private(set) var invite: LinkInvite?
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private var hello: LinkMessage.Hello?
    private var room: String?
    private var secret = Data()
    private var work: Task<Void, Never>?
    private var linkKey: SymmetricKey?

    func start() {
        guard invite == nil else { return }
        let inv = LinkInvite(room: Link.newRoom(), ephemeral: ephemeral.publicKey.x963Representation, secret: Random32.bytes())
        invite = inv
        begin(room: inv.room, secret: inv.secret)
    }

    func submitAccountNumber() {
        guard let n = try? AccountNumber(accountNumber) else { phase = .failed("That account number has a typo — check the 16 digits."); return }
        phase = .waiting
        begin(room: Link.room(forAccountNumber: n.digits), secret: Data())
    }

    func retry() {
        phase = .waiting
        if let room { begin(room: room, secret: secret) }
    }

    private func begin(room: String, secret: Data) {
        work?.cancel()
        work = Task { [weak self] in await self?.run(room: room, secret: secret) }
    }

    private func run(room: String, secret: Data) async {
        do {
            let keys = try DeviceIdentity.keys()
            let relay = RelayClient(base: SyncConfig.relay, device: DeviceIdentity.id, keys: keys)
            let h = LinkMessage.Hello(device: DeviceIdentity.id, signingKey: try keys.signingPublicKey,
                                      agreementKey: try keys.agreementPublicKey, ephemeral: ephemeral.publicKey.x963Representation)
            hello = h; self.room = room; self.secret = secret
            try await relay.post(link: room, LinkMessage(kind: .hello, hello: h))

            var after = 0
            while !Task.isCancelled {
                for (seq, m) in (try? await relay.fetch(link: room, after: after)) ?? [] {
                    after = max(after, seq)
                    switch m.kind {
                    case .accept:
                        guard let eph = m.ephemeral,
                              let d = try? Link.derive(myEphemeral: ephemeral, peerEphemeral: eph, hello: h, approverEphemeral: eph, secret: secret)
                        else { continue }
                        linkKey = d.key
                        let approver = m.sealed.flatMap { try? Link.openDetails($0, key: d.key, from: "approver") }
                        // Our name and model go only to the device that accepted, sealed with the link key.
                        let mine = LinkMessage.Details(name: DeviceIdentity.name, model: DeviceIdentity.model, platform: DeviceIdentity.platform)
                        try await relay.post(link: room, LinkMessage(kind: .details, sealed: try Link.seal(mine, key: d.key, from: "new")))
                        phase = .confirm(code: d.code, by: approver?.name ?? "your other device")
                    case .vault:
                        guard let key = linkKey, let sealed = m.sealed else { continue }
                        phase = .receiving
                        do {
                            try AppConfig.store.write(try Link.openVault(sealed, key: key))
                            AppConfig.defaults.set(true, forKey: "linkedFresh")
                            phase = .done
                        } catch { phase = .failed("The vault didn’t arrive intact. Try linking again.") }
                        return
                    case .deny:
                        phase = .declined
                        return
                    case .hello, .details: continue
                    }
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            phase = .failed(SyncEngine.describe(error))
        }
    }

    func cancel() { work?.cancel() }
}

enum Random32 { static func bytes() -> Data { SecureRandom.bytes(32) } }

struct JoinView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = JoinModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.phase {
                    case .waiting: waiting
                    case .confirm(let code, let by): confirm(code, by: by)
                    case .receiving: progress("Receiving your vault…")
                    case .done: progress("Vault received")
                    case .declined: message("Request declined", "The other device said no. Nothing was shared.", retry: false)
                    case .failed(let why): message("Couldn’t link", why, retry: true)
                    }
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .navigationTitle("Link this device")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel(); dismiss() } } }
        }
        .presentationBackground(DB.ground)
        .onAppear { model.start() }
        .onChange(of: model.phase) { _, p in
            if p == .done {
                session.reloadAfterLink()
                session.show("Vault received", "Enter your master password to unlock")
                dismiss()
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        if !model.useAccountNumber, let inv = model.invite {
            Text("On your iPhone with Deadbolt, open **Devices › Link a new device** and scan this code.")
                .font(.db(15)).foregroundStyle(DB.text2)
            if let qr = QRCode.image(inv.uri) {
                qr.resizable().scaledToFit().frame(maxWidth: 260)
                    .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Link code")
            }
            HStack(spacing: 10) { ProgressView(); Text("Waiting for your other device…").font(.db(14)).foregroundStyle(DB.text2) }
                .frame(maxWidth: .infinity)
            Button("Use my account number instead") { model.useAccountNumber = true }
                .buttonStyle(.plain).font(.db(15, .semibold)).foregroundStyle(DB.brass).frame(maxWidth: .infinity, minHeight: 44)
        } else {
            Text("Type your 16-digit account number. Your other device will show a request to approve (in Devices, or the Mac menu bar).")
                .font(.db(15)).foregroundStyle(DB.text2)
            TextField("4821 0937 1156 2204", text: $model.accountNumber)
                .font(.dbMono(20)).fieldStyle()
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Send request") { model.submitAccountNumber() }.buttonStyle(PrimaryButtonStyle())
                .disabled(model.accountNumber.filter(\.isNumber).count != 16)
            Text("The number is in Devices on any linked device, and on your Recovery Kit.").font(.db(13)).foregroundStyle(DB.text3)
            Button("Show a code to scan instead") { model.useAccountNumber = false }
                .buttonStyle(.plain).font(.db(15, .semibold)).foregroundStyle(DB.brass).frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private func confirm(_ code: String, by: String) -> some View {
        VStack(spacing: 16) {
            Text("Check \(by)").font(.db(24, .bold)).multilineTextAlignment(.center)
            Text("It should show the same code. If it does, approve there.").font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
            CodeDigits(code: code)
            HStack(spacing: 10) { ProgressView(); Text("Waiting for approval…").font(.db(14)).foregroundStyle(DB.text2) }
            Text("If the codes are different, cancel: someone else may be trying to link.").font(.db(13)).foregroundStyle(DB.danger).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 14) { ProgressView(); Text(text).font(.db(17, .semibold)) }.frame(maxWidth: .infinity).padding(.top, 60)
    }

    private func message(_ title: String, _ body: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.db(24, .bold))
            Text(body).font(.db(15)).foregroundStyle(DB.text2)
            if retry { Button("Try again") { model.retry() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 10) }
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
    }
}

struct CodeDigits: View {
    let code: String
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, d in
                Text(String(d)).font(.dbMono(34, .semibold)).foregroundStyle(DB.brass)
                    .frame(width: 64, height: 72)
                    .background(DB.control, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DB.lineStrong))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}

// MARK: existing device: approve a link

@MainActor @Observable
final class ApproveModel: Identifiable {
    enum Phase: Equatable { case review, approving, linked, denied, failed(String) }
    let id = UUID()
    let room: String
    let hello: LinkMessage.Hello
    let secret: Data
    var phase: Phase = .review
    private(set) var code = ""
    private(set) var details: LinkMessage.Details?
    private var key: SymmetricKey?
    private let ephemeral = P256.KeyAgreement.PrivateKey()
    private var work: Task<Void, Never>?

    init(room: String, hello: LinkMessage.Hello, secret: Data) {
        self.room = room; self.hello = hello; self.secret = secret
    }

    var name: String { details?.name ?? "New device" }

    /// Answers the new device (so both screens can show the code) and waits for its sealed name. Idempotent.
    func begin() {
        guard work == nil, phase == .review else { return }
        work = Task { [weak self] in await self?.accept() }
    }

    func retry() {
        work?.cancel(); work = nil
        code = ""; key = nil; details = nil
        phase = .review
        begin()
    }

    private func relay() throws -> RelayClient { RelayClient(base: SyncConfig.relay, device: DeviceIdentity.id, keys: try DeviceIdentity.keys()) }

    private func accept() async {
        do {
            let d = try Link.derive(myEphemeral: ephemeral, peerEphemeral: hello.ephemeral, hello: hello,
                                    approverEphemeral: ephemeral.publicKey.x963Representation, secret: secret)
            key = d.key
            let mine = LinkMessage.Details(name: DeviceIdentity.name, model: DeviceIdentity.model, platform: DeviceIdentity.platform)
            let r = try relay()
            try await r.post(link: room, LinkMessage(kind: .accept, ephemeral: ephemeral.publicKey.x963Representation,
                                                     sealed: try Link.seal(mine, key: d.key, from: "approver")))
            code = d.code
            var after = 0
            while details == nil, !Task.isCancelled {
                for (seq, m) in (try? await r.fetch(link: room, after: after)) ?? [] {
                    after = max(after, seq)
                    if m.kind == .details, let s = m.sealed, let got = try? Link.openDetails(s, key: d.key, from: "new") { details = got }
                }
                if details == nil { try? await Task.sleep(for: .milliseconds(1200)) }
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch { phase = .failed(SyncEngine.describe(error)) }
    }

    func approve(session: VaultSession) {
        guard let key, phase == .review else { return }
        let details = self.details ?? LinkMessage.Details(name: "New device", model: "", platform: "")
        Task {
            guard await KeychainKey.confirmOwner(reason: "Link \(details.name) to your vault") else { return }
            phase = .approving
            do {
                try await session.link(hello, details: details, linkKey: key, room: room)
                phase = .linked
                session.show("\(details.name) is linked", "It’s receiving your vault now")
            } catch {
                phase = .failed(SyncEngine.describe(error))
            }
        }
    }

    func deny() {
        work?.cancel()
        phase = .denied
        Task { try? await relay().post(link: room, LinkMessage(kind: .deny)) }
    }
}

struct ApproveLinkView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let model: ApproveModel

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .review, .approving:
                Image(systemName: model.details?.platform == "macOS" ? "laptopcomputer" : "iphone")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(DB.text2)
                    .frame(width: 72, height: 72).background(DB.surface, in: RoundedRectangle(cornerRadius: 22))
                Text("Link “\(model.name)”?").font(.db(26, .bold)).multilineTextAlignment(.center)
                Text("\(model.details.map { $0.model.isEmpty ? "A device" : $0.model } ?? "A device") asked to join your vault. Only approve if you started this.")
                    .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
                if model.code.isEmpty { ProgressView().padding(.top, 8) } else {
                    Text("Does \(model.name) show the same code?").font(.db(14)).foregroundStyle(DB.text2).padding(.top, 8)
                    CodeDigits(code: model.code)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button("Deny") { model.deny(); dismiss() }.buttonStyle(SecondaryButtonStyle(height: 56))
                    Button { model.approve(session: session) } label: {
                        if model.phase == .approving { ProgressView().tint(DB.onBrass) } else { Text("Codes match") }
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(model.code.isEmpty || model.phase == .approving)
                }
                Text("\(KeychainKey.biometryName) is required to approve.").font(.db(13)).foregroundStyle(DB.text3)
            case .linked:
                done("\(model.name) is linked", "It’s receiving your vault. You can remove it any time in Devices.", retry: false)
            case .denied:
                done("Request denied", "Nothing was shared.", retry: false)
            case .failed(let why):
                done("Couldn’t link", why, retry: true)
            }
        }
        .padding(20).frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DB.ground).foregroundStyle(DB.text).presentationBackground(DB.ground)
        .onAppear { model.begin() }
    }

    private func done(_ title: String, _ body: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(title).font(.db(22, .bold))
            Text(body).font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
            Spacer()
            if retry { Button("Try again") { model.retry() }.buttonStyle(PrimaryButtonStyle()) }
            Button("Done") { dismiss() }.buttonStyle(retry ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
        }
    }
}

/// Lets one button pick primary or secondary styling at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
