import AuthenticationServices
import DeadboltCore
import SwiftUI

@MainActor @Observable
final class AutoFillModel {
    struct PasskeyQuery { let rpID: String; let clientDataHash: Data; let allowed: [Data] }
    struct Registration { let rpID: String; let userName: String; let userHandle: Data; let clientDataHash: Data; let algorithms: [Int]; let excluded: [Data] }
    struct SaveRequest { let host: String; let username: String; let password: String; let formDisappeared: Bool }

    enum Mode {
        case idle
        case list(hosts: [String], passkey: PasskeyQuery?)
        case provideLogin(UUID)
        case provideCode(UUID)
        case codes(hosts: [String])
        case providePasskey(credentialID: Data, clientDataHash: Data)
        case register(Registration)
        case save(SaveRequest)
        case configure
    }

    var mode: Mode = .idle
    weak var controller: CredentialProviderViewController?
}

/// Sizes for the AutoFill screens: iPhone-sized by default, the Mac app's compact scale (13 pt text, 44 px rows) on the Mac.
private enum AF {
    #if os(macOS)
    static let mac = true
    static let headerFont: CGFloat = 13, h1: CGFloat = 17, rowTitle: CGFloat = 13, rowDetail: CGFloat = 12, body: CGFloat = 12.5, small: CGFloat = 11.5
    static let rowHeight: CGFloat = 44, tile: CGFloat = 28, pad: CGFloat = 16, headerHeight: CGFloat = 44
    #else
    static let mac = false
    static let headerFont: CGFloat = 17, h1: CGFloat = 22, rowTitle: CGFloat = 16, rowDetail: CGFloat = 13, body: CGFloat = 15, small: CGFloat = 13
    static let rowHeight: CGFloat = 68, tile: CGFloat = 42, pad: CGFloat = 20, headerHeight: CGFloat = 52
    #endif
}

private extension View {
    func afPrimary() -> some View {
        #if os(macOS)
        self.buttonStyle(MacButtonStyle(prominent: true))
        #else
        self.buttonStyle(PrimaryButtonStyle())
        #endif
    }
    func afSecondary() -> some View {
        #if os(macOS)
        self.buttonStyle(MacButtonStyle())
        #else
        self.buttonStyle(SecondaryButtonStyle(height: 46))
        #endif
    }
    func afField() -> some View {
        #if os(macOS)
        self.macField()
        #else
        self.fieldStyle()
        #endif
    }
}

private struct AFCard<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) { content() }
            .background(DB.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DB.line))
        #else
        Card { content() }
        #endif
    }
}

private struct AFLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        #if os(macOS)
        Text(text.uppercased()).font(.db(11, .semibold)).tracking(0.6).foregroundStyle(DB.text3)
        #else
        SectionLabel(text)
        #endif
    }
}

private struct AFHeader: View {
    let title: String
    let cancel: () -> Void
    var body: some View {
        HStack {
            #if os(macOS)
            Button("Cancel", action: cancel).buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
            #else
            Button("Cancel", action: cancel).foregroundStyle(DB.brass)
            #endif
            Spacer()
            Text(title).font(.db(AF.headerFont, .semibold))
            Spacer()
            Color.clear.frame(width: AF.mac ? 60 : 52)
        }
        .padding(.horizontal, 16).frame(height: AF.headerHeight)
    }
}

struct AutoFillRoot: View {
    @Environment(VaultSession.self) private var session
    let model: AutoFillModel

    var body: some View {
        Group {
            if case .configure = model.mode {
                ConfigureView(done: { model.controller?.completeConfiguration() })
            } else if session.state == .noVault {
                NoVaultView(cancel: { model.controller?.cancel(.userCanceled) })
            } else if session.state != .unlocked {
                ExtensionUnlock(cancel: { model.controller?.cancel(.userCanceled) })
            } else {
                content
            }
        }
        .background(DB.ground)
        .foregroundStyle(DB.text)
        .preferredColorScheme(.dark)
        .tint(DB.brass)
        .modifier(ToastOverlay())
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .idle, .configure: Color.clear
        case .list(let hosts, let passkey): ChooseLoginView(model: model, hosts: hosts, passkey: passkey)
        case .provideLogin(let id): AutoComplete { provide(id) }
        case .provideCode(let id): AutoComplete { provideCode(id) }
        case .codes(let hosts): ChooseCodeView(model: model, hosts: hosts)
        case .providePasskey(let cid, let hash): AutoComplete { signIn(cid, hash) }
        case .register(let r): CreatePasskeyView(model: model, request: r)
        case .save(let s): SaveSheet(model: model, request: s)
        }
    }

    /// QuickType tap: the unlock itself was the confirmation, so complete straight away.
    private func provide(_ id: UUID) {
        guard let login = session.vault.login(id) else { return model.controller?.cancel(.credentialIdentityNotFound) ?? () }
        try? session.mutate { $0.markUsed(id) }
        model.controller?.complete(login: login)
    }

    private func provideCode(_ id: UUID) {
        guard let secret = session.vault.login(id)?.totpSecret, let t = try? TOTP(secret) else {
            return model.controller?.cancel(.credentialIdentityNotFound) ?? ()
        }
        model.controller?.complete(code: t.code())
    }

    private func signIn(_ credentialID: Data, _ hash: Data) {
        guard let pk = session.vault.passkeys.first(where: { $0.credentialID == credentialID }),
              let a = try? WebAuthn.assert(pk, clientDataHash: hash) else { return model.controller?.cancel(.credentialIdentityNotFound) ?? () }
        model.controller?.complete(assertion: a, rpID: pk.relyingPartyID, clientDataHash: hash)
    }
}

private struct AutoComplete: View {
    let action: () -> Void
    var body: some View { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).task { action() } }
}

// MARK: unlock inside the extension

private struct ExtensionUnlock: View {
    @Environment(VaultSession.self) private var session
    let cancel: () -> Void
    @State private var password = ""
    @State private var error: String?
    @State private var prompting = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: AF.mac ? 12 : 16) {
            HStack {
                #if os(macOS)
                Button("Cancel", action: cancel).buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
                #else
                Button("Cancel", action: cancel).foregroundStyle(DB.brass)
                #endif
                Spacer()
            }
            Spacer(minLength: 0)
            DeadboltMark(size: AF.mac ? 44 : 64).padding(.top, AF.mac ? 0 : 20)
            Text("Unlock Deadbolt").font(.db(AF.h1, .bold))
            if session.biometricUnlockAllowed {
                Button { Task { await biometric() } } label: {
                    Label("Unlock with \(KeychainKey.biometryName)", systemImage: KeychainKey.biometryName == "Touch ID" ? "touchid" : "faceid")
                }
                .afPrimary()
            }
            HStack(spacing: 8) {
                SecureField("Master password", text: $password).textContentType(.password).focused($focused)
                    .onSubmit { Task { await unlock() } }.afField()
                Button { Task { await unlock() } } label: {
                    Group { if session.busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.right") } }
                        .frame(width: AF.mac ? 28 : 52, height: AF.mac ? 28 : 52)
                        .background(DB.control, in: RoundedRectangle(cornerRadius: AF.mac ? 6 : 16))
                }
                .buttonStyle(.plain).accessibilityLabel("Unlock").disabled(password.isEmpty || session.busy)
            }
            .frame(maxWidth: AF.mac ? 300 : .infinity)
            if let error { Text(error).font(.db(AF.mac ? 12 : 14)).foregroundStyle(DB.danger) }
            Spacer()
        }
        .padding(AF.mac ? 16 : 20)
        .task {
            guard session.biometricUnlockAllowed else { focused = true; return }
            try? await Task.sleep(for: .milliseconds(450)) // let the AutoFill sheet finish presenting
            await biometric()
        }
    }

    private func biometric() async {
        guard !prompting else { return }
        prompting = true
        defer { prompting = false }
        error = nil
        do {
            if try await !session.unlockWithBiometrics(reason: "Fill from Deadbolt") { focused = true }
        } catch { self.error = error.friendly; focused = true }
    }

    private func unlock() async {
        do { try await session.unlock(password: password) } catch { self.error = error.friendly; Haptics.error() }
    }
}

// MARK: choose a login (list)

private struct ChooseLoginView: View {
    @Environment(VaultSession.self) private var session
    let model: AutoFillModel
    let hosts: [String]
    let passkey: AutoFillModel.PasskeyQuery?
    @State private var query = ""
    @State private var mismatch: LoginItem?

    var body: some View {
        let site = hosts.first ?? passkey?.rpID ?? ""
        VStack(spacing: 0) {
            AFHeader(title: "Deadbolt") { model.controller?.cancel(.userCanceled) }

            ScrollView {
                VStack(alignment: .leading, spacing: AF.mac ? 8 : 10) {
                    TextField("Search all logins", text: $query).afField()
                    if query.isEmpty {
                        AFLabel(site.isEmpty ? "Suggestions" : "For \(site)").padding(.top, AF.mac ? 6 : 12)
                        if suggestedPasskeys.isEmpty && suggestedLogins.isEmpty {
                            Text("Nothing saved for \(site) yet.").font(.db(AF.body)).foregroundStyle(DB.text2).padding(.vertical, 8)
                        } else {
                            AFCard { rows(passkeys: suggestedPasskeys, logins: suggestedLogins) }
                        }
                    } else {
                        AFLabel("All logins").padding(.top, AF.mac ? 6 : 12)
                        AFCard { rows(passkeys: [], logins: searchResults) }
                    }
                    Text("\(KeychainKey.biometryName) is confirmed before anything is filled. Only logins saved for this site are suggested.")
                        .font(.db(AF.small)).foregroundStyle(DB.text3).padding(.top, AF.mac ? 8 : 14)
                }
                .padding(AF.pad)
            }
        }
        .alert("Fill a login for another site?", isPresented: Binding(get: { mismatch != nil }, set: { if !$0 { mismatch = nil } }),
               presenting: mismatch) { l in
            Button("Fill anyway", role: .destructive) { fill(l) }
            Button("Cancel", role: .cancel) {}
        } message: { l in
            Text("This login is saved for \(l.sites.first ?? "another site"), but you’re signing in to \(hosts.first ?? "a different site"). Fake sites often look like the real one — only continue if you’re sure.")
        }
    }

    private var suggestedLogins: [LoginItem] {
        var seen = Set<UUID>()
        return hosts.flatMap { session.vault.accounts(for: $0) }.filter { seen.insert($0.id).inserted }
    }

    private var suggestedPasskeys: [Passkey] {
        guard let p = passkey else { return [] }
        let allowed = Set(p.allowed)
        return session.vault.passkeys(for: p.rpID).filter { allowed.isEmpty || allowed.contains($0.credentialID) }
    }

    private var searchResults: [LoginItem] {
        let q = query.lowercased()
        return session.vault.logins.filter { $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q) || $0.sites.contains { $0.contains(q) } }
    }

    @ViewBuilder private func rows(passkeys: [Passkey], logins: [LoginItem]) -> some View {
        ForEach(Array(passkeys.enumerated()), id: \.element.credentialID) { i, pk in
            if i > 0 { CardDivider() }
            row(title: pk.userName, detail: "Passkey · sign in with \(KeychainKey.biometryName)", passkey: true, best: i == 0) {
                guard let p = passkey, let a = try? WebAuthn.assert(pk, clientDataHash: p.clientDataHash) else { return }
                model.controller?.complete(assertion: a, rpID: pk.relyingPartyID, clientDataHash: p.clientDataHash)
            }
        }
        ForEach(Array(logins.enumerated()), id: \.element.id) { i, l in
            if i > 0 || !passkeys.isEmpty { CardDivider() }
            row(title: l.customName ?? l.username,
                detail: l.customName != nil ? "\(l.username) · \(l.sites.first ?? "")"
                    : (l.label.map { "\($0) · \(l.sites.first ?? "")" } ?? "Password · \(l.sites.first ?? "")"),
                passkey: false, best: passkeys.isEmpty && i == 0 && l.preferred) {
                // Filling a login saved for another site is how phishing works: ask first, naming both sites.
                if !hosts.isEmpty, !hosts.contains(where: { h in l.sites.contains { Site.host(h, isCoveredBy: $0) } }) {
                    mismatch = l
                    return
                }
                fill(l)
            }
        }
    }

    private func fill(_ l: LoginItem) {
        try? session.mutate { $0.markUsed(l.id) }
        model.controller?.complete(login: l)
    }

    private func row(title: String, detail: String, passkey: Bool, best: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AF.mac ? 10 : 14) {
                if passkey {
                    Image(systemName: "person.badge.key").font(.system(size: AF.mac ? 12 : 16)).foregroundStyle(DB.brass)
                        .frame(width: AF.tile, height: AF.tile).background(DB.brassWash, in: RoundedRectangle(cornerRadius: AF.mac ? 8 : 12))
                } else {
                    SiteTile(title: title, size: AF.tile)
                }
                VStack(alignment: .leading, spacing: AF.mac ? 1 : 3) {
                    Text(title).font(.db(AF.rowTitle, .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.db(AF.rowDetail)).foregroundStyle(DB.text2).lineLimit(1)
                }
                Spacer()
                if best {
                    Text("Best").font(.db(AF.mac ? 11 : 12, .bold)).foregroundStyle(DB.onBrass)
                        .padding(.horizontal, AF.mac ? 8 : 10).frame(height: AF.mac ? 20 : 26).background(DB.brass, in: Capsule())
                }
            }
            .padding(.horizontal, AF.mac ? 10 : 16).frame(minHeight: AF.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: choose a one-time code

private struct ChooseCodeView: View {
    @Environment(VaultSession.self) private var session
    let model: AutoFillModel
    let hosts: [String]

    var body: some View {
        let withCodes = session.vault.logins.filter { $0.totpSecret != nil }
        var seen = Set<UUID>()
        let matching = hosts.flatMap { session.vault.accounts(for: $0) }.filter { $0.totpSecret != nil && seen.insert($0.id).inserted }
        let list = matching.isEmpty ? withCodes : matching
        return VStack(spacing: 0) {
            AFHeader(title: "One-time codes") { model.controller?.cancel(.userCanceled) }
            ScrollView {
                VStack(alignment: .leading, spacing: AF.mac ? 8 : 10) {
                    AFLabel(matching.isEmpty ? "All codes" : "For \(hosts.first ?? "")")
                    if list.isEmpty {
                        Text("No one-time codes saved yet. Add a setup key to a login in the Deadbolt app.").font(.db(AF.body)).foregroundStyle(DB.text2)
                    } else {
                        AFCard {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, l in
                                if i > 0 { CardDivider() }
                                Button {
                                    if let s = l.totpSecret, let t = try? TOTP(s) { model.controller?.complete(code: t.code()) }
                                } label: {
                                    HStack(spacing: AF.mac ? 10 : 14) {
                                        SiteTile(title: l.title, site: l.sites.first, size: AF.tile)
                                        VStack(alignment: .leading, spacing: AF.mac ? 1 : 3) {
                                            Text(l.title).font(.db(AF.rowTitle, .semibold)).lineLimit(1)
                                            Text(l.username).font(.db(AF.rowDetail)).foregroundStyle(DB.text2).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        if let s = l.totpSecret { InlineCode(secret: s) }
                                    }
                                    .padding(.horizontal, AF.mac ? 10 : 16).frame(minHeight: AF.mac ? 44 : 64).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(AF.pad)
            }
        }
    }
}

// MARK: create passkey

private struct CreatePasskeyView: View {
    @Environment(VaultSession.self) private var session
    let model: AutoFillModel
    let request: AutoFillModel.Registration
    @State private var working = false

    var body: some View {
        VStack(spacing: AF.mac ? 12 : 16) {
            Spacer()
            Image(systemName: "person.badge.key").font(.system(size: AF.mac ? 22 : 34)).foregroundStyle(DB.brass)
                .frame(width: AF.mac ? 48 : 76, height: AF.mac ? 48 : 76).background(DB.brassWash, in: RoundedRectangle(cornerRadius: AF.mac ? 14 : 24))
            Text("Create a passkey for \(request.rpID)?").font(.db(AF.h1, .bold)).multilineTextAlignment(.center)
            Text("Sign in with \(KeychainKey.biometryName) instead of a password. Saved in Deadbolt.")
                .font(.db(AF.body)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            HStack(spacing: AF.mac ? 10 : 12) {
                SiteTile(title: request.userName, size: AF.mac ? 28 : 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.userName).font(.db(AF.mac ? 13 : 15)).lineLimit(1).truncationMode(.middle)
                    Text("Account on \(request.rpID)").font(.db(AF.rowDetail)).foregroundStyle(DB.text3)
                }
                Spacer()
            }
            .padding(AF.mac ? 10 : 14).background(DB.surface, in: RoundedRectangle(cornerRadius: AF.mac ? 8 : 16))
            .overlay(RoundedRectangle(cornerRadius: AF.mac ? 8 : 16).stroke(DB.line))
            Spacer()
            HStack(spacing: 8) {
                #if os(macOS)
                Button("Cancel") { model.controller?.cancel(.userCanceled) }.afSecondary().keyboardShortcut(.cancelAction)
                Spacer()
                #endif
                Button { create() } label: { if working { ProgressView().controlSize(.small).tint(DB.onBrass) } else { Text("Create Passkey") } }
                    .afPrimary().disabled(working)
                #if os(macOS)
                    .keyboardShortcut(.defaultAction)
                #endif
            }
            #if os(iOS)
            Button("Cancel") { model.controller?.cancel(.userCanceled) }.afSecondary()
            #endif
        }
        .padding(AF.pad)
    }

    private func create() {
        working = true
        let existing = Set(session.vault.passkeys.map(\.credentialID))
        if request.excluded.contains(where: existing.contains) {
            session.show("You already have a passkey here", style: .error)
            return model.controller?.cancel(.matchedExcludedCredential) ?? ()
        }
        do {
            let pk = Passkey.create(relyingPartyID: request.rpID, userName: request.userName, userHandle: request.userHandle)
            let reg = try WebAuthn.register(pk, supportedAlgorithms: request.algorithms)
            let final = try session.mutate { v -> Vault in
                // Attach to the matching account, or create a passkey-only login for it.
                let match = v.accounts(for: request.rpID).first { Vault.canonical($0.username) == Vault.canonical(request.userName) }
                let id = try match?.id ?? v.save(host: request.rpID, username: request.userName, password: "", asNewAccount: true)
                v.add(pk, linkTo: id)
                return v
            }
            Task {
                await IdentitySync.update(from: final)
                model.controller?.complete(registration: reg, rpID: request.rpID, clientDataHash: request.clientDataHash)
            }
        } catch {
            working = false
            session.show("Couldn’t create the passkey", error.friendly, style: .error)
        }
    }
}

// MARK: save or update

private struct SaveSheet: View {
    @Environment(VaultSession.self) private var session
    let model: AutoFillModel
    let request: AutoFillModel.SaveRequest
    @State private var done: String?

    var body: some View {
        let proposal = session.vault.proposeSave(host: request.host, username: request.username, password: request.password)
        VStack(alignment: .leading, spacing: 18) {
            if let done {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(DB.good)
                        .frame(width: 64, height: 64).background(DB.goodWash, in: Circle())
                    Text(done).font(.db(20, .bold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                HStack(spacing: 14) {
                    SiteTile(title: request.host, site: request.host, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isUpdate(proposal) ? "Update saved password?" : "Save to Deadbolt?").font(.db(20, .bold))
                        Text("\(request.username) · \(request.host)").font(.db(14)).foregroundStyle(DB.text2)
                    }
                }
                if isUpdate(proposal) {
                    Text("The old password moves to history, so you can undo this.").font(.db(13)).foregroundStyle(DB.text3)
                }
                Button(isUpdate(proposal) ? "Update password" : "Save password") { save(asNew: false, update: isUpdate(proposal)) }
                    .buttonStyle(PrimaryButtonStyle(height: 54))
                if isUpdate(proposal) {
                    Button("Save as a separate login") { save(asNew: true, update: false) }.buttonStyle(SecondaryButtonStyle())
                }
                Button("Not now") { model.controller?.cancel(.userCanceled) }
                    .buttonStyle(.plain).font(.db(16)).foregroundStyle(DB.text2).frame(maxWidth: .infinity, minHeight: 46)
            }
        }
        .padding(20)
        .task {
            // Same password already saved: nothing to ask.
            if case .unchanged = proposal { model.controller?.completeSave() }
        }
    }

    private func isUpdate(_ p: Vault.SaveProposal) -> Bool { if case .update = p { return true } else { return false } }

    private func save(asNew: Bool, update: Bool) {
        do {
            let vault = try session.mutate { v -> Vault in
                try v.save(host: request.host, username: request.username, password: request.password, asNewAccount: asNew)
                return v
            }
            done = update ? "Password updated" : "Saved to Deadbolt"
            Haptics.success()
            Task {
                await IdentitySync.update(from: vault)
                try? await Task.sleep(for: .milliseconds(700))
                model.controller?.completeSave()
            }
        } catch {
            session.show("Couldn’t save", error.friendly, style: .error)
        }
    }
}

// MARK: misc

private struct ConfigureView: View {
    let done: () -> Void
    var body: some View {
        VStack(spacing: AF.mac ? 12 : 16) {
            Spacer()
            DeadboltMark(size: AF.mac ? 44 : 56)
            Text("Deadbolt is ready").font(.db(AF.mac ? 17 : 24, .bold))
            Text("It will offer your passwords and passkeys when you sign in, and offer to save new ones.")
                .font(.db(AF.body)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            Spacer()
            Button("Done", action: done).afPrimary()
        }
        .padding(AF.pad)
    }
}

private struct NoVaultView: View {
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: AF.mac ? 12 : 16) {
            Spacer()
            DeadboltMark(size: AF.mac ? 44 : 56)
            Text("Set up Deadbolt first").font(.db(AF.h1, .bold))
            Text("Open the Deadbolt app to create your vault.").font(.db(AF.body)).foregroundStyle(DB.text2)
            Spacer()
            Button("Close", action: cancel).afSecondary()
        }
        .padding(AF.pad)
    }
}
