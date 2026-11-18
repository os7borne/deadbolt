import AuthenticationServices
import DeadboltCore
@preconcurrency import LocalAuthentication
import SwiftUI

/// SPIKE: exercises every provider entry point we rely on and logs what iOS actually calls.
final class CredentialProviderViewController: ASCredentialProviderViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // First thing on every launch: proves iOS started the extension at all.
        SpikeLog.write("extension launched, footprint \(Argon2Bench.footprintMiB()) MiB, log at \(SpikeLog.url.path().suffix(40))")
    }

    // MARK: passwords + passkeys: list

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        SpikeLog.write("prepareCredentialList(services: \(serviceIdentifiers.map(\.identifier)))")
        showList(services: serviceIdentifiers, passkeyRequest: nil)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        SpikeLog.write("prepareCredentialList(services: \(serviceIdentifiers.map(\.identifier)), passkey rp: \(requestParameters.relyingPartyIdentifier), allowed: \(requestParameters.allowedCredentials.count))")
        showList(services: serviceIdentifiers, passkeyRequest: requestParameters)
    }

    // MARK: QuickType bar taps

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        SpikeLog.write("provideCredentialWithoutUserInteraction(type: \(credentialRequest.type.rawValue)) → asking for UI (we always require Face ID)")
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        SpikeLog.write("prepareInterfaceToProvideCredential(type: \(credentialRequest.type.rawValue))")
        switch credentialRequest {
        case let request as ASPasswordCredentialRequest:
            guard let identity = request.credentialIdentity as? ASPasswordCredentialIdentity,
                  let login = SpikeStore.logins().first(where: { $0.id == identity.recordIdentifier }) else { return fail("login not found") }
            show(SpikePanel(title: "Fill password", detail: "\(login.user) @ \(login.site)", actions: [
                ("Fill with Face ID", { self.fill(login) }), ("Cancel", { self.cancel() }),
            ]))
        case let request as ASPasskeyCredentialRequest:
            guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity,
                  let passkey = SpikeStore.passkeys().first(where: { $0.credentialID == identity.credentialID }) else { return fail("passkey not found") }
            show(SpikePanel(title: "Sign in with passkey", detail: "\(passkey.userName) @ \(passkey.relyingPartyID)", actions: [
                ("Sign in with Face ID", { self.signIn(passkey, clientDataHash: request.clientDataHash) }), ("Cancel", { self.cancel() }),
            ]))
        default:
            fail("unsupported request type \(credentialRequest.type.rawValue)")
        }
    }

    // MARK: passkey registration

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else { return fail("registration: not a passkey request") }
        let algs = request.supportedAlgorithms.map { $0.rawValue }
        SpikeLog.write("prepareInterface(forPasskeyRegistration rp: \(identity.relyingPartyIdentifier), user: \(identity.userName), algs: \(algs), excluded: \(request.excludedCredentials?.count ?? 0))")
        show(SpikePanel(title: "Create passkey", detail: "\(identity.userName) @ \(identity.relyingPartyIdentifier)", actions: [
            ("Create with Face ID", { self.register(identity: identity, clientDataHash: request.clientDataHash, algorithms: algs) }),
            ("Cancel", { self.cancel() }),
        ]))
    }

    // MARK: save password (iOS 26.2+)

    @available(iOS 26.2, *)
    override func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        SpikeLog.write("performWithoutUserInteraction(save: \(savePasswordRequest.serviceIdentifier.identifier), event: \(savePasswordRequest.event.rawValue)) → asking for UI")
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    @available(iOS 26.2, *)
    override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        let r = savePasswordRequest
        SpikeLog.write("prepareInterface(save: \(r.serviceIdentifier.identifier) type \(r.serviceIdentifier.type.rawValue), user: \(r.credential.user), title: \(r.title ?? "-"), event: \(r.event.rawValue))")
        show(SpikePanel(title: "Save password?", detail: "\(r.credential.user) @ \(r.serviceIdentifier.identifier)", actions: [
            ("Save", {
                let site = URL(string: r.serviceIdentifier.identifier)?.host() ?? r.serviceIdentifier.identifier
                do {
                    try SpikeStore.save(.init(site: site, user: r.credential.user, password: r.credential.password))
                    Task {
                        await SpikeStore.syncIdentities()
                        SpikeLog.write("saved login for \(site)")
                        await self.extensionContext.completeSavePasswordRequest()
                    }
                } catch { self.fail("save failed: \(error)") }
            }),
            ("Not now", { self.cancel() }),
        ]))
    }

    // MARK: configuration UI — shown when the provider is turned on in Settings. Runs the Argon2 bench *inside the extension*.

    override func prepareInterfaceForExtensionConfiguration() {
        SpikeLog.write("prepareInterfaceForExtensionConfiguration")
        show(SpikePanel(title: "Deadbolt Spike", detail: "Run Argon2id inside the AutoFill extension. If it vanishes mid-run, iOS killed it for memory — the log says which size.", actions: [
            ("Run Argon2 32/64/128 MiB", { Task.detached { _ = Argon2Bench.run() } }),
            ("Test Face ID → shared Keychain item", { self.testBiometricItem() }),
            ("Done", { self.extensionContext.completeExtensionConfigurationRequest() }),
        ]))
    }

    // MARK: actions

    private func showList(services: [ASCredentialServiceIdentifier], passkeyRequest: ASPasskeyCredentialRequestParameters?) {
        let hosts = Set(services.map { URL(string: $0.identifier)?.host() ?? $0.identifier })
        var actions: [(String, () -> Void)] = []
        if let p = passkeyRequest {
            let allowed = Set(p.allowedCredentials)
            for pk in SpikeStore.passkeys() where pk.relyingPartyID == p.relyingPartyIdentifier && (allowed.isEmpty || allowed.contains(pk.credentialID)) {
                actions.append(("🔑 \(pk.userName)", { self.signIn(pk, clientDataHash: p.clientDataHash) }))
            }
        }
        for login in SpikeStore.logins() where hosts.isEmpty || hosts.contains(where: { $0 == login.site || $0.hasSuffix("." + login.site) }) {
            actions.append(("🔒 \(login.user) — \(login.site)", { self.fill(login) }))
        }
        actions.append(("Cancel", { self.cancel() }))
        show(SpikePanel(title: "Deadbolt Spike", detail: actions.count == 1 ? "Nothing saved for \(hosts.sorted().joined(separator: ", "))" : "Choose", actions: actions))
    }

    private func fill(_ login: SpikeStore.Login) {
        verifyUser("Fill \(login.site)") {
            SpikeLog.write("filled password for \(login.site)")
            self.extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: login.user, password: login.password))
        }
    }

    private func register(identity: ASPasskeyCredentialIdentity, clientDataHash: Data, algorithms: [Int]) {
        verifyUser("Create a passkey for \(identity.relyingPartyIdentifier)") {
            do {
                let passkey = Passkey.create(relyingPartyID: identity.relyingPartyIdentifier, userName: identity.userName, userHandle: identity.userHandle)
                let reg = try WebAuthn.register(passkey, supportedAlgorithms: algorithms)
                try SpikeStore.save(passkey)
                Task {
                    await SpikeStore.syncIdentities()
                    SpikeLog.write("passkey registered for \(passkey.relyingPartyID), attestationObject \(reg.attestationObject.count) bytes")
                    await self.extensionContext.completeRegistrationRequest(using: ASPasskeyRegistrationCredential(
                        relyingParty: passkey.relyingPartyID, clientDataHash: clientDataHash,
                        credentialID: reg.credentialID, attestationObject: reg.attestationObject))
                }
            } catch { self.fail("register failed: \(error)") }
        }
    }

    private func signIn(_ passkey: Passkey, clientDataHash: Data) {
        verifyUser("Sign in to \(passkey.relyingPartyID)") {
            do {
                let a = try WebAuthn.assert(passkey, clientDataHash: clientDataHash)
                SpikeLog.write("passkey assertion for \(passkey.relyingPartyID)")
                self.extensionContext.completeAssertionRequest(using: ASPasskeyAssertionCredential(
                    userHandle: a.userHandle, relyingParty: passkey.relyingPartyID, signature: a.signature,
                    clientDataHash: clientDataHash, authenticatorData: a.authenticatorData, credentialID: a.credentialID))
            } catch { self.fail("assert failed: \(error)") }
        }
    }

    private func testBiometricItem() {
        Task {
            do {
                let secret = try await SpikeStore.readBiometricSecret(reason: "Read the test vault key")
                SpikeLog.write("ext read bio secret OK, fingerprint \(SpikeStore.fingerprint(secret))")
            } catch { SpikeLog.write("ext read bio secret FAILED: \(error)") }
        }
    }

    /// Face ID before releasing any credential. That's what lets us set the WebAuthn UV flag honestly.
    private func verifyUser(_ reason: String, then action: @escaping @MainActor () -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
            Task { @MainActor in
                if ok { action() } else { SpikeLog.write("Face ID failed: \(error?.localizedDescription ?? "?")") }
            }
        }
    }

    private func cancel() {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
    }

    private func fail(_ message: String) {
        SpikeLog.write("ERROR \(message)")
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.failed.rawValue))
    }

    private func show(_ panel: SpikePanel) {
        children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        let host = UIHostingController(rootView: panel)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct SpikePanel: View {
    let title: String
    let detail: String
    let actions: [(String, () -> Void)]

    var body: some View {
        NavigationStack {
            List {
                Section { Text(detail).foregroundStyle(.secondary) }
                Section {
                    ForEach(actions.indices, id: \.self) { i in
                        Button(actions[i].0, action: actions[i].1)
                            .foregroundStyle(actions[i].0 == "Cancel" || actions[i].0 == "Not now" ? .red : .accentColor)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
