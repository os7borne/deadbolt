import CoreImage
import DeadboltCore
import SwiftUI
#if os(iOS)
import PhotosUI
import VisionKit
#else
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - form model (shared by the iPhone and Mac login forms)

/// Fields, validation and saving for "New login" / "Edit login". Views only lay it out.
@MainActor @Observable
final class LoginFormModel {
    let original: LoginItem?
    var site: String
    /// Other websites this login works on (each its own row in the form).
    var extraSites: [String]
    var customFields: [CustomField]
    /// The owner's own name for this login. Empty means "use the website's name".
    var name: String
    var username: String
    var password: String
    var totp: String
    var label: String
    var notes: String
    var error: String?
    /// Name shown for a code entry (the issuer from the QR code, e.g. "GitHub"). Only used for code-only entries.
    var codeTitle: String
    /// True for the "Add code" flow and for editing a code-only entry: no password needed, website optional.
    let allowsCodeOnly: Bool

    init(original: LoginItem?, site: String = "", codeOnly: Bool = false) {
        self.allowsCodeOnly = codeOnly || original?.isCodeOnly == true
        self.codeTitle = original?.isCodeOnly == true ? original?.title ?? "" : ""
        self.original = original
        self.site = original?.sites.first ?? site
        self.extraSites = Array(original?.sites.dropFirst() ?? [])
        self.customFields = original?.customFields ?? []
        self.name = original?.customName ?? ""
        self.username = original?.username ?? ""
        self.password = original?.password ?? ""
        self.totp = original?.totpSecret ?? ""
        self.label = original?.label ?? ""
        self.notes = original?.notes ?? ""
    }

    var isNew: Bool { original == nil }
    /// What the login is called when no name is typed, shown as the Name box's placeholder.
    var namePlaceholder: String { primarySite.map(Site.displayName) ?? "Name" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var primarySite: String? { Site.normalize(site) }
    var sites: [String] {
        var out: [String] = []
        for s in [site] + extraSites {
            if let n = Site.normalize(s), !out.contains(n) { out.append(n) }
        }
        return out
    }
    var code: TOTP? { totp.isEmpty ? nil : try? TOTP(totp) }
    var hasMore: Bool { !extraSites.isEmpty || !customFields.isEmpty || !label.isEmpty || !notes.isEmpty }

    /// Custom fields worth keeping: a field with neither a name nor a value is just an empty row.
    var cleanedFields: [CustomField]? {
        let kept = customFields.compactMap { f -> CustomField? in
            let name = f.name.trimmingCharacters(in: .whitespaces)
            guard !(name.isEmpty && f.value.isEmpty) else { return nil }
            var c = f; c.name = name.isEmpty ? "Field" : name; return c
        }
        return kept.isEmpty ? nil : kept
    }

    /// Extra website rows that aren't usable yet, said plainly (they'd be dropped on save otherwise).
    var extraSiteProblem: String? {
        extraSites.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty && Site.normalize($0) == nil }
            ? "One of the other websites isn’t a web address like github.com" : nil
    }
    /// Only a real password being replaced goes to history; adding one to a login that had none doesn't.
    var passwordChanged: Bool { original != nil && !(original?.password.isEmpty ?? true) && password != original?.password }

    /// Said under an empty password box: leaving it empty is fine (sign-in by emailed link or code).
    var noPasswordHint: String? {
        guard password.isEmpty, !allowsCodeOnly, original?.passkeyIDs.isEmpty ?? true else { return nil }
        return "Optional. Leave empty for sites that email you a sign-in link or code"
    }

    /// Where the login will be offered, or why the website isn't usable yet.
    var siteHint: (text: String, ok: Bool)? {
        let t = site.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard let host = primarySite else { return ("Enter a website like github.com", false) }
        return ("Fills on \(host) and its subdomains", true)
    }

    /// The first thing still missing, said plainly; nil when it can be saved.
    var missing: String? {
        if isCodeOnly {
            if !site.trimmingCharacters(in: .whitespaces).isEmpty && primarySite == nil { return "Enter a website like github.com, or clear it" }
            return nil
        }
        if allowsCodeOnly && code == nil { return "Add the one-time code" }
        if let p = extraSiteProblem, !isCodeOnly { return p }
        if primarySite == nil { return "Add the website" }
        if username.trimmingCharacters(in: .whitespaces).isEmpty { return "Add a username or email" }
        return nil   // the password is optional: sites that sign you in by emailed link or code have none
    }

    /// A code with nothing else: no password to save. Only in the code flows.
    var isCodeOnly: Bool { allowsCodeOnly && code != nil && password.isEmpty && (original?.passkeyIDs.isEmpty ?? true) }

    /// A website guessed from the code's issuer, offered (never applied silently): "GitHub" → github.com.
    var siteSuggestion: String? {
        guard isCodeOnly, site.trimmingCharacters(in: .whitespaces).isEmpty, let issuer = code?.issuer?.trimmingCharacters(in: .whitespaces),
              !issuer.isEmpty else { return nil }
        if issuer.contains("."), let s = Site.normalize(issuer) { return s }
        let word = issuer.lowercased()
        guard word.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return Site.normalize(word + ".com")
    }

    /// A code from the setup screen. Fills an empty username from the authenticator link's account name,
    /// and an empty name from its issuer.
    func useCode(_ raw: String, _ t: TOTP) {
        totp = raw
        if username.isEmpty, let account = t.account, !account.isEmpty { username = account }
        if codeTitle.isEmpty, let issuer = t.issuer, !issuer.isEmpty { codeTitle = issuer }
    }

    /// Saves and returns the toast to show.
    func save(in session: VaultSession) throws -> (String, String?) {
        let user = username.trimmingCharacters(in: .whitespaces)
        let secret = totp.trimmingCharacters(in: .whitespacesAndNewlines)
        if original == nil && isCodeOnly {
            let typedSite = site.trimmingCharacters(in: .whitespaces)
            try session.mutate { v in
                let id = try v.saveCode(host: typedSite.isEmpty ? nil : typedSite, title: codeTitle,
                                        username: user.isEmpty ? (code?.account ?? "") : user, secret: secret)
                guard var item = v.login(id) else { return }
                for s in sites where !item.sites.contains(s) { item.sites.append(s) }
                if !notes.isEmpty { item.notes = notes }
                v.upsert(item)
            }
            return ("Code saved", nil)
        }
        if var item = original {
            if isCodeOnly, !codeTitle.trimmingCharacters(in: .whitespaces).isEmpty { item.title = codeTitle.trimmingCharacters(in: .whitespaces) }
            item.sites = sites
            // Empty name: back to the website's name (also follows a changed website).
            if !isCodeOnly { item.title = trimmedName.isEmpty ? LoginItem.defaultTitle(for: sites) : trimmedName }
            item.username = user
            item.changePassword(to: password)
            item.totpSecret = secret.isEmpty ? nil : secret
            item.label = label.isEmpty ? nil : label
            item.notes = notes.isEmpty ? nil : notes
            item.customFields = cleanedFields
            try session.mutate { $0.upsert(item) }
            return ("Saved", passwordChanged ? "The old password is in history" : nil)
        }
        let host = sites[0]
        let proposal = session.vault.proposeSave(host: host, username: user, password: password)
        let id = try session.mutate { v in try v.save(host: host, username: user, password: password) }
        try session.mutate { v in
            guard var item = v.login(id) else { return }
            for s in sites where !item.sites.contains(s) { item.sites.append(s) }
            if !trimmedName.isEmpty { item.title = trimmedName }
            if !secret.isEmpty { item.totpSecret = secret }
            if !label.isEmpty { item.label = label }
            if !notes.isEmpty { item.notes = notes }
            if let f = cleanedFields { item.customFields = f }
            v.upsert(item)
        }
        switch proposal {
        case .update: return ("Updated your existing login", "The old password is in history")
        case .unchanged: return (secret.isEmpty ? "Already saved" : "Saved", nil)
        case .new: return ("Login saved", nil)
        }
    }
}

/// Rough strength for a hint under the password field (not a security guarantee).
enum PasswordStrength {
    static func describe(_ p: String) -> (text: String, level: Int)? {
        guard !p.isEmpty else { return nil }
        let classes = [p.contains { $0.isLowercase }, p.contains { $0.isUppercase }, p.contains { $0.isNumber },
                       p.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        let score = p.count + classes * 3
        if p.count < 8 || score < 16 { return ("Weak", 0) }
        if score < 24 { return ("Fair", 1) }
        return ("Strong", 2)
    }
    static func color(_ level: Int) -> Color { [DB.danger, DB.brass, DB.good][level] }
}

// MARK: - one-time code setup

/// "Add one-time code": scan or pick the QR code a website shows when you turn on two-factor authentication,
/// or type its setup key. Shows the live code so the person can finish setup on the website.
struct OneTimeCodeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var site: String?
    /// False when the caller shows its next step in the same sheet (see `AddCodeFlow`).
    var dismissOnUse = true
    let onUse: (String, TOTP) -> Void

    @State private var key = ""
    @State private var found: (raw: String, totp: TOTP)?
    @State private var problem: String?
    @State private var typing = false
    #if os(iOS)
    @State private var scanning = false
    @State private var photo: PhotosPickerItem?
    #else
    @State private var choosingFile = false
    @State private var dropping = false
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView { content.padding(20) }
                .background(DB.ground).foregroundStyle(DB.text)
                .navigationTitle("One-time code").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .fullScreenCover(isPresented: $scanning) { scanner }
                .onChange(of: photo) { _, item in Task { await read(item) } }
        }
        .presentationBackground(DB.ground)
        #else
        VStack(alignment: .leading, spacing: 0) {
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
                if let found {
                    Button("Add Code") { onUse(found.raw, found.totp); if dismissOnUse { dismiss() } }
                        .buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 16)
        }
        .padding(20).frame(width: 460)
        .font(.db(13)).foregroundStyle(DB.text).background(DB.surface)
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { readFile(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.first.map(readFile); return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).stroke(DB.brass, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(6)
            }
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let found { preview(found.totp) } else { setup }
    }

    // Step 1: get the QR code or key.
    private var setup: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            Text("On \(site ?? "the website"), turn on two-factor authentication and choose **authenticator app**. It shows a QR code.")
                .font(.db(compact ? 13 : 15)).foregroundStyle(DB.text2).fixedSize(horizontal: false, vertical: true)

            #if os(iOS)
            if DataScannerViewController.isSupported {
                Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(PrimaryButtonStyle(height: 52))
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label("Choose a screenshot", systemImage: "photo").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            #else
            HStack(spacing: 8) {
                Button { pasteImage() } label: { Label("Paste Screenshot", systemImage: "doc.on.clipboard") }
                    .buttonStyle(MacButtonStyle(prominent: true))
                Button { choosingFile = true } label: { Label("Choose Image…", systemImage: "photo") }
                    .buttonStyle(MacButtonStyle())
            }
            Text("Tip: press ⌃⇧⌘4 and drag over the QR code to copy it, then Paste Screenshot. You can also drop an image here.")
                .font(.db(12)).foregroundStyle(DB.text3).fixedSize(horizontal: false, vertical: true)
            #endif

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.db(compact ? 12.5 : 14)).foregroundStyle(DB.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if typing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Setup key").font(.db(compact ? 12 : 13)).foregroundStyle(DB.text3)
                    HStack(spacing: 8) {
                        #if os(iOS)
                        TextField("e.g. JBSW Y3DP EHPK 3PXP", text: $key).font(.dbMono(15)).fieldStyle()
                            .submitLabel(.done).onSubmit { tryKey() }
                        PasteButton(payloadType: String.self) { s in if let s = s.first { key = s; tryKey() } }
                            .labelStyle(.iconOnly).buttonBorderShape(.roundedRectangle).tint(DB.control)
                        #else
                        TextField("e.g. JBSW Y3DP EHPK 3PXP", text: $key).font(.dbMono(12.5)).macField().onSubmit { tryKey() }
                        #endif
                    }
                    Text("The letters and numbers shown under the QR code (“can’t scan?”). Spaces don’t matter.")
                        .font(.db(compact ? 12 : 13)).foregroundStyle(DB.text3)
                }
                .onChange(of: key) { tryKey(quiet: true) }
            } else {
                Button("Can’t scan? Enter the setup key instead") { typing = true }
                    .buttonStyle(.plain).font(.db(compact ? 12.5 : 15)).foregroundStyle(DB.brass)
            }
        }
    }

    // Step 2: show the live code to finish setup on the website.
    private func preview(_ t: TOTP) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            if let who = [t.issuer, t.account].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                Label(who, systemImage: "checkmark.seal.fill").font(.db(compact ? 13 : 15, .semibold)).foregroundStyle(DB.good)
            } else {
                Label("Code found", systemImage: "checkmark.seal.fill").font(.db(compact ? 13 : 15, .semibold)).foregroundStyle(DB.good)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = t.secondsRemaining(at: ctx.date)
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(DB.line, lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(left) / CGFloat(t.period))
                            .stroke(left <= 5 ? DB.danger : DB.brass, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: compact ? 22 : 30, height: compact ? 22 : 30)
                    Text(TOTP.grouped(t.code(at: ctx.date))).font(.dbMono(compact ? 24 : 30)).tracking(1.5)
                        .textSelection(.enabled)
                    Spacer()
                    Text("\(left) s").font(.db(compact ? 12 : 14)).foregroundStyle(DB.text3)
                }
                .padding(compact ? 12 : 16)
                .background(DB.ground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DB.line))
            }
            Text("If the website asks for a code to finish turning on two-factor, enter this one. Deadbolt keeps it with the login from now on.")
                .font(.db(compact ? 12.5 : 14)).foregroundStyle(DB.text2).fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            Button("Add code") { onUse(found!.raw, t); if dismissOnUse { dismiss() } }.buttonStyle(PrimaryButtonStyle(height: 52))
            #endif
            Button("Use a different code") { found = nil; key = ""; problem = nil }
                .buttonStyle(.plain).font(.db(compact ? 12.5 : 15)).foregroundStyle(DB.brass)
        }
    }

    private var compact: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    // MARK: reading codes

    private func accept(_ raw: String, quiet: Bool = false) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let t = try TOTP(s)
            found = (s, t); problem = nil
            Haptics.tap()
        } catch let e as TOTPError {
            guard !quiet else { return }
            switch e {
            case .unsupportedType: problem = "That code counts sign-ins (HOTP). Deadbolt supports time-based codes, which almost every website uses."
            case .invalidURI: problem = "That QR code isn’t for an authenticator app."
            case .invalidSecret: problem = s.lowercased().hasPrefix("otpauth") ? "That QR code is damaged or incomplete."
                                                                              : "That doesn’t look like a setup key. It’s usually 16–32 letters and numbers."
            }
        } catch { if !quiet { problem = error.friendly } }
    }

    private func tryKey(quiet: Bool = false) {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { problem = nil; return }
        // Typing: only switch to the preview once it's long enough to be a real key, and stay quiet until then.
        let letters = key.filter { $0.isLetter || $0.isNumber }.count
        if quiet && letters < 16 && !key.lowercased().hasPrefix("otpauth") { return }
        accept(key, quiet: quiet)
    }

    private func decoded(_ image: CGImage?) {
        guard let image else { problem = "Couldn’t open that image."; return }
        let codes = QRDecoder.strings(in: image)
        if let otp = codes.first(where: { $0.lowercased().hasPrefix("otpauth") }) { accept(otp) }
        else if let any = codes.first { accept(any) }
        else { problem = "No QR code found in that image. Make sure the whole code is in the picture." }
    }

    #if os(iOS)
    private var scanner: some View {
        ZStack(alignment: .top) {
            QRScanner(accept: { $0.lowercased().hasPrefix("otpauth") }) { s in scanning = false; accept(s) }
                .ignoresSafeArea()
            HStack {
                Text("Point at the QR code on the website").font(.db(15, .semibold))
                Spacer()
                Button("Cancel") { scanning = false }.font(.db(16, .semibold))
            }
            .padding(16).background(.ultraThinMaterial)
        }
        .preferredColorScheme(.dark)
    }

    private func read(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        let data = try? await item.loadTransferable(type: Data.self)
        decoded(data.flatMap { UIImage(data: $0)?.cgImage })
        photo = nil
    }
    #else
    private func pasteImage() {
        guard let img = NSImage(pasteboard: .general) else {
            if let s = NSPasteboard.general.string(forType: .string) { typing = true; key = s; accept(s); return }
            problem = "There’s no image on the clipboard. Press ⌃⇧⌘4 and drag over the QR code first."
            return
        }
        decoded(img.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func readFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        decoded(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
    #endif
}

/// QR codes in a still image (screenshots of 2FA setup pages). On-device Core Image, nothing leaves the device.
enum QRDecoder {
    static func strings(in image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}

#if os(iOS)
/// Live camera QR scanner that reports the first code `accept` likes.
struct QRScanner: UIViewControllerRepresentable {
    let accept: (String) -> Bool
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(accept: accept, found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let accept: (String) -> Bool
        let found: (String) -> Void
        var done = false
        init(accept: @escaping (String) -> Bool, found: @escaping (String) -> Void) { self.accept = accept; self.found = found }
        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let b) in items {
                guard !done, let s = b.payloadStringValue, accept(s) else { continue }
                done = true
                scanner.stopScanning()
                found(s)
            }
        }
    }
}
#endif

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
