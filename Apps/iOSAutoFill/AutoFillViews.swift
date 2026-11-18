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
        case providePasskey(credentialID: Data, clientDataHash: Data)
        case register(Registration)
        case save(SaveRequest)
        case configure
    }

    var mode: Mode = .idle
    weak var controller: CredentialProviderViewController?
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("Cancel", action: cancel).foregroundStyle(DB.brass)
                Spacer()
            }
            DeadboltMark(size: 64).padding(.top, 20)
            Text("Unlock Deadbolt").font(.db(22, .bold))
            if session.biometricUnlockAllowed {
                Button { Task { await biometric() } } label: {
                    Label("Unlock with \(KeychainKey.biometryName)", systemImage: "faceid")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            HStack(spacing: 8) {
                SecureField("Master password", text: $password).textContentType(.password).focused($focused)
                    .onSubmit { Task { await unlock() } }.fieldStyle()
                Button { Task { await unlock() } } label: {
                    Group { if session.busy { ProgressView() } else { Image(systemName: "arrow.right") } }
                        .frame(width: 52, height: 52).background(DB.control, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain).accessibilityLabel("Unlock").disabled(password.isEmpty || session.busy)
            }
            if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
            Spacer()
        }
        .padding(20)
        .task { if session.biometricUnlockAllowed { await biometric() } else { focused = true } }
    }

    private func biometric() async {
        do { try await session.unlockWithBiometrics(reason: "Fill from Deadbolt") } catch { self.error = error.friendly }
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

    var body: some View {
        let site = hosts.first ?? passkey?.rpID ?? ""
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { model.controller?.cancel(.userCanceled) }.foregroundStyle(DB.brass)
                Spacer()
                Text("Deadbolt").font(.db(17, .semibold))
                Spacer()
                Color.clear.frame(width: 52)
            }
            .padding(.horizontal, 16).frame(height: 52)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search all logins", text: $query).fieldStyle()
                    if query.isEmpty {
                        SectionLabel(site.isEmpty ? "Suggestions" : "For \(site)").padding(.top, 12)
                        if suggestedPasskeys.isEmpty && suggestedLogins.isEmpty {
                            Text("Nothing saved for \(site) yet.").font(.db(15)).foregroundStyle(DB.text2).padding(.vertical, 8)
                        } else {
                            Card { rows(passkeys: suggestedPasskeys, logins: suggestedLogins) }
                        }
                    } else {
                        SectionLabel("All logins").padding(.top, 12)
                        Card { rows(passkeys: [], logins: searchResults) }
                    }
                    Text("Face ID confirmed before anything is filled. Only logins saved for this site are suggested.")
                        .font(.db(13)).foregroundStyle(DB.text3).padding(.top, 14)
                }
                .padding(20)
            }
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
            row(title: l.username, detail: l.label.map { "\($0) · \(l.sites.first ?? "")" } ?? "Password · \(l.sites.first ?? "")",
                passkey: false, best: passkeys.isEmpty && i == 0 && l.preferred) {
                try? session.mutate { $0.markUsed(l.id) }
                model.controller?.complete(login: l)
            }
        }
    }

    private func row(title: String, detail: String, passkey: Bool, best: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if passkey {
                    Image(systemName: "key.horizontal.fill").foregroundStyle(DB.brass)
                        .frame(width: 42, height: 42).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    SiteTile(title: title)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.db(16, .semibold))
                    Text(detail).font(.db(13)).foregroundStyle(DB.text2).lineLimit(1)
                }
                Spacer()
                if best {
                    Text("Best").font(.db(12, .bold)).foregroundStyle(DB.onBrass).padding(.horizontal, 10).frame(height: 26).background(DB.brass, in: Capsule())
                }
            }
            .padding(.horizontal, 16).frame(minHeight: 68).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: create passkey

private struct CreatePasskeyView: View {
    @Environment(VaultSession.self) private var session
    let model: AutoFillModel
    let request: AutoFillModel.Registration
    @State private var working = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "key.horizontal.fill").font(.system(size: 34)).foregroundStyle(DB.brass)
                .frame(width: 76, height: 76).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 24))
            Text("Create a passkey for \(request.rpID)?").font(.db(22, .bold)).multilineTextAlignment(.center)
            Text("Sign in with \(KeychainKey.biometryName) instead of a password. Saved in Deadbolt.")
                .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            HStack(spacing: 12) {
                SiteTile(title: request.userName, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.userName).font(.db(15))
                    Text("Account on \(request.rpID)").font(.db(13)).foregroundStyle(DB.text3)
                }
                Spacer()
            }
            .padding(14).background(DB.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(DB.line))
            Spacer()
            Button { create() } label: { if working { ProgressView().tint(DB.onBrass) } else { Text("Create passkey") } }
                .buttonStyle(PrimaryButtonStyle()).disabled(working)
            Button("Cancel") { model.controller?.cancel(.userCanceled) }.buttonStyle(SecondaryButtonStyle(height: 46))
        }
        .padding(20)
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
                    SiteTile(title: request.host, size: 48)
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
        VStack(spacing: 16) {
            Spacer()
            DeadboltMark(size: 56)
            Text("Deadbolt is ready").font(.db(24, .bold))
            Text("It will offer your passwords and passkeys when you sign in, and offer to save new ones.")
                .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            Spacer()
            Button("Done", action: done).buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }
}

private struct NoVaultView: View {
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            DeadboltMark(size: 56)
            Text("Set up Deadbolt first").font(.db(22, .bold))
            Text("Open the Deadbolt app to create your vault.").font(.db(15)).foregroundStyle(DB.text2)
            Spacer()
            Button("Close", action: cancel).buttonStyle(SecondaryButtonStyle())
        }
        .padding(20)
    }
}
