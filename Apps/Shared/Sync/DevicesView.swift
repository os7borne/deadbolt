import DeadboltCore
import SwiftUI
#if os(iOS)
import VisionKit
#endif

/// Watches the account-number link room for new devices asking to join (while this screen or the Mac panel is open).
@MainActor @Observable
final class LinkRequests {
    private(set) var pending: [ApproveModel] = []
    private var seen = Set<String>()
    private var task: Task<Void, Never>?

    func watch(accountNumber: String?) {
        guard task == nil, let n = accountNumber else { return }
        let room = Link.room(forAccountNumber: n)
        task = Task { [weak self] in
            var after = 0
            while !Task.isCancelled {
                if let keys = try? DeviceIdentity.keys(),
                   let msgs = try? await RelayClient(base: SyncConfig.relay, device: DeviceIdentity.id, keys: keys).fetch(link: room, after: after) {
                    for (seq, m) in msgs {
                        after = max(after, seq)
                        guard m.kind == .hello, let h = m.hello, h.device != DeviceIdentity.id else { continue }
                        guard let self, self.seen.insert(h.device).inserted else { continue }
                        self.pending.append(ApproveModel(room: room, hello: h, secret: Data()))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    /// Drop requests that were approved, denied or failed; keep ones the person just closed without deciding.
    func prune() { pending.removeAll { $0.phase != .review } }
}

struct DevicesView: View {
    @Environment(VaultSession.self) private var session
    @State private var requests = LinkRequests()
    @State private var reviewing: ApproveModel?
    @State private var scanning = false
    @State private var scannedURI: String?
    @State private var removing: DeviceRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                syncStatus

                if requests.pending.count > 1 {
                    Label("\(requests.pending.count) devices are asking to link at once. Approve only the one whose screen shows the same code — someone who knows your account number may be trying too.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.db(13)).foregroundStyle(DB.danger)
                        .padding(12).background(DB.dangerWash, in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(requests.pending) { r in
                    Button { reviewing = r } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bell.badge.fill").foregroundStyle(DB.brass)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("A new device wants to link").font(.db(14, .semibold))
                                Text("Its name appears once you review").font(.db(13)).foregroundStyle(DB.text2)
                            }
                            Spacer()
                            Text("Review").font(.db(14, .semibold)).foregroundStyle(DB.onBrass)
                                .padding(.horizontal, 12).frame(height: 32).background(DB.brass, in: Capsule())
                        }
                        .padding(14).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x3A3220)))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 8) {
                    SectionLabel("Your devices")
                    Card {
                        ForEach(Array(session.vault.activeDevices.enumerated()), id: \.element.id) { i, d in
                            if i > 0 { CardDivider() }
                            row(d)
                        }
                        CardDivider()
                        Button { link() } label: {
                            Label("Link a new device", systemImage: "plus").font(.db(14, .semibold)).foregroundStyle(DB.brass)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(minHeight: 46)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(linkHint).font(.db(12)).foregroundStyle(DB.text3).padding(.horizontal, 4)
                }

                if let n = session.vault.accountNumber, let acct = try? AccountNumber(n) {
                    VStack(spacing: 8) {
                        SectionLabel("Account number")
                        Card {
                            HStack {
                                Text(acct.description).font(.dbMono(15)).tracking(0.5).textSelection(.enabled)
                                Spacer()
                                IconButton(systemName: "doc.on.doc", label: "Copy account number") {
                                    Clipboard.copySecret(acct.digits)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                        Text("Not a secret: it only lets a new device ask to join. Nothing is shared until you approve on a device you already have.")
                            .font(.db(12)).foregroundStyle(DB.text3).padding(.horizontal, 4)
                    }
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Devices")
        .task { await session.sync.syncNow() }
        .onAppear { requests.watch(accountNumber: session.vault.accountNumber) }
        .onDisappear { requests.stop() }
        .onChange(of: session.vault.accountNumber) { _, n in requests.watch(accountNumber: n) }
        .sheet(item: $reviewing, onDismiss: { requests.prune() }) { ApproveLinkView(model: $0) }
        .sheet(item: $removing) { RemoveDeviceView(device: $0) }
        #if os(iOS)
        // Open the approval only once the scanner sheet has fully gone, so the two sheets never fight.
        .sheet(isPresented: $scanning, onDismiss: {
            if let uri = scannedURI { scannedURI = nil; Task { await openInvite(uri) } }
        }) {
            LinkScanner { uri in
                scannedURI = uri
                scanning = false
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private var linkHint: String {
        #if os(iOS)
        "On the new device choose “I already use Deadbolt”, then scan its code here — or type the account number below on it."
        #else
        "On the new device choose “I already use Deadbolt” and type the account number below. Its request appears here and in the menu bar."
        #endif
    }

    @ViewBuilder private var syncStatus: some View {
        HStack(spacing: 10) {
            switch session.sync.status {
            case .upToDate(let at):
                Circle().fill(DB.good).frame(width: 8, height: 8)
                Text("Up to date · \(at.formatted(.relative(presentation: .named)))")
            case .syncing:
                ProgressView().controlSize(.small); Text("Syncing…")
            case .offline(let why):
                Circle().fill(DB.danger).frame(width: 8, height: 8); Text(why).lineLimit(2)
            case .off:
                Circle().fill(DB.text3).frame(width: 8, height: 8); Text("Sync starts when the vault is unlocked")
            }
            Spacer()
            Button("Sync now") { Task { await session.sync.syncNow() } }.buttonStyle(.plain).foregroundStyle(DB.brass)
        }
        .font(.db(13)).foregroundStyle(DB.text2)
        .padding(.horizontal, 14).frame(minHeight: 42)
        .background(DB.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ d: DeviceRecord) -> some View {
        let me = d.id == DeviceIdentity.id
        return HStack(spacing: 12) {
            Image(systemName: d.platform == "macOS" ? "laptopcomputer" : "iphone").font(.system(size: 14))
                .foregroundStyle(Color(hex: 0xC9CCD2)).frame(width: 34, height: 34).background(DB.control, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(d.shownName).font(.db(15, .semibold)).lineLimit(1)
                    if me {
                        Text("This device").font(.db(11)).foregroundStyle(DB.text2)
                            .padding(.horizontal, 7).frame(height: 18).background(DB.control, in: Capsule())
                    }
                }
                Text(d.shownDetail).font(.db(12)).foregroundStyle(DB.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Menu {
                Button(me ? "Retire this device…" : "Remove \(d.name)…", role: .destructive) { removing = d }
            } label: {
                Image(systemName: "ellipsis").frame(width: 40, height: 40)
            }
            .menuStyle(.button).buttonStyle(.plain).foregroundStyle(DB.text2)
            .accessibilityLabel("Options for \(d.name)")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func link() {
        #if os(iOS)
        if DataScannerViewController.isSupported { scanning = true } else { session.show("Can’t scan here", "Type the account number on the new device instead", style: .error) }
        #else
        session.show("Waiting for the new device", "Type the account number there; its request appears here")
        #endif
    }

    private func openInvite(_ uri: String) async {
        do {
            let inv = try LinkInvite(uri: uri)
            let client = RelayClient(base: SyncConfig.relay, device: DeviceIdentity.id, keys: try DeviceIdentity.keys())
            for _ in 0..<10 {
                if let h = try await client.fetch(link: inv.room, after: 0).compactMap({ $0.message.hello }).first(where: { $0.ephemeral == inv.ephemeral }) {
                    reviewing = ApproveModel(room: inv.room, hello: h, secret: inv.secret)
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
            session.show("No request found", "Keep the code open on the new device and try again", style: .error)
        } catch { session.show("That code didn’t work", error.friendly, style: .error) }
    }
}

/// Remove another device, or retire this one. Needs the master password.
struct RemoveDeviceView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let device: DeviceRecord
    @State private var password = ""
    @State private var error: String?

    private var isMe: Bool { device.id == DeviceIdentity.id }
    private var isLast: Bool { session.vault.activeDevices.count <= 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isMe ? "Retire this device?" : "Remove \(device.name)?").font(.db(26, .bold))
            if isMe && isLast {
                Text("This is your only device, so it can’t be retired — your vault would have nowhere to live. Use Settings › Erase Deadbolt from this device if you really mean to delete everything.")
                    .font(.db(15)).foregroundStyle(DB.text2)
            } else {
                Text(isMe
                     ? "This device stops syncing, leaves the device list and erases its copy of the vault. Your other devices keep everything."
                     : "\(device.name) can no longer sync. If it comes online it’s told it was removed and erases its copy.")
                    .font(.db(15)).foregroundStyle(DB.text2)
                if !isMe {
                    Label("Passwords already on \(device.name) stay there, still encrypted behind its Face ID or your master password. If it was lost or stolen, change your most important passwords.",
                          systemImage: "exclamationmark.triangle")
                        .font(.db(13)).foregroundStyle(DB.brass)
                }
                SecureField("Master password to confirm", text: $password).textContentType(.password).fieldStyle()
                if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
            }
            Spacer()
            if !(isMe && isLast) {
                Button {
                    Task {
                        do {
                            try await session.verify(password: password)
                            try await session.remove(device, password: password)
                            session.show(isMe ? "This device was retired" : "\(device.name) removed")
                            dismiss()
                        } catch { self.error = error.friendly; Haptics.error() }
                    }
                } label: {
                    Group { if session.busy { ProgressView() } else { Text(isMe ? "Retire this device" : "Remove \(device.name)") } }
                        .font(.db(17, .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 56)
                        .background(Color(hex: 0xC2412F), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain).disabled(password.isEmpty || session.busy)
            }
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(20).background(DB.ground).foregroundStyle(DB.text).presentationBackground(DB.ground)
    }
}

#if os(iOS)
/// Camera QR scanner for link codes. The camera permission prompt appears the first time this opens.
struct LinkScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                guard !done, let s = b.payloadStringValue, s.hasPrefix("deadbolt://link") else { continue }
                done = true
                scanner.stopScanning()
                found(s)
            }
        }
    }
}
#endif
