import AuthenticationServices
import DeadboltCore
import SwiftUI

/// The iOS AutoFill extension: fill passwords, save/update passwords (iOS 26.2+), create and use passkeys.
/// Every credential is released only after Face ID or the master password.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let session = VaultSession()
    private let model = AutoFillModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: AutoFillRoot(model: model).environment(session))
        host.view.backgroundColor = UIColor(DB.ground)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    // MARK: entry points

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.mode = .list(hosts: serviceIdentifiers.compactMap(Self.host), passkey: nil)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier],
                                        requestParameters: ASPasskeyCredentialRequestParameters) {
        model.mode = .list(hosts: serviceIdentifiers.compactMap(Self.host),
                           passkey: .init(rpID: requestParameters.relyingPartyIdentifier,
                                          clientDataHash: requestParameters.clientDataHash,
                                          allowed: requestParameters.allowedCredentials))
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.mode = .codes(hosts: serviceIdentifiers.compactMap(Self.host))
    }

    /// Tapping a QuickType suggestion: we always want Face ID first, so ask for the UI.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        cancel(.userInteractionRequired)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        switch credentialRequest {
        case let r as ASPasswordCredentialRequest:
            guard let identity = r.credentialIdentity as? ASPasswordCredentialIdentity,
                  let id = identity.recordIdentifier.flatMap(UUID.init(uuidString:)) else { return cancel(.credentialIdentityNotFound) }
            model.mode = .provideLogin(id)
        case let r as ASPasskeyCredentialRequest:
            guard let identity = r.credentialIdentity as? ASPasskeyCredentialIdentity else { return cancel(.credentialIdentityNotFound) }
            model.mode = .providePasskey(credentialID: identity.credentialID, clientDataHash: r.clientDataHash)
        case let r as ASOneTimeCodeCredentialRequest:
            guard let identity = r.credentialIdentity as? ASOneTimeCodeCredentialIdentity,
                  let id = identity.recordIdentifier.flatMap(UUID.init(uuidString:)) else { return cancel(.credentialIdentityNotFound) }
            model.mode = .provideCode(id)
        default:
            cancel(.failed)
        }
    }

    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let r = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = r.credentialIdentity as? ASPasskeyCredentialIdentity else { return cancel(.failed) }
        model.mode = .register(.init(rpID: identity.relyingPartyIdentifier, userName: identity.userName,
                                     userHandle: identity.userHandle, clientDataHash: r.clientDataHash,
                                     algorithms: r.supportedAlgorithms.map(\.rawValue),
                                     excluded: (r.excludedCredentials ?? []).map(\.credentialID)))
    }

    @available(iOS 26.2, *)
    override func performWithoutUserInteractionIfPossible(savePasswordRequest: ASSavePasswordRequest) {
        cancel(Prefs.offerToSave ? .userInteractionRequired : .userCanceled)
    }

    @available(iOS 26.2, *)
    override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        guard Prefs.offerToSave, let host = Self.host(savePasswordRequest.serviceIdentifier) else { return cancel(.userCanceled) }
        model.mode = .save(.init(host: host, username: savePasswordRequest.credential.user,
                                 password: savePasswordRequest.credential.password,
                                 formDisappeared: savePasswordRequest.event == .formDidDisappear))
    }

    override func prepareInterfaceForExtensionConfiguration() {
        model.mode = .configure
    }

    // MARK: completions (called by the SwiftUI side)

    func complete(login: LoginItem) {
        extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: login.username, password: login.password))
    }

    func complete(assertion a: WebAuthn.Assertion, rpID: String, clientDataHash: Data) {
        extensionContext.completeAssertionRequest(using: ASPasskeyAssertionCredential(
            userHandle: a.userHandle, relyingParty: rpID, signature: a.signature,
            clientDataHash: clientDataHash, authenticatorData: a.authenticatorData, credentialID: a.credentialID))
    }

    func complete(registration r: WebAuthn.Registration, rpID: String, clientDataHash: Data) {
        extensionContext.completeRegistrationRequest(using: ASPasskeyRegistrationCredential(
            relyingParty: rpID, clientDataHash: clientDataHash, credentialID: r.credentialID, attestationObject: r.attestationObject))
    }

    func complete(code: String) {
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
    }

    func completeSave() {
        if #available(iOS 26.2, *) { extensionContext.completeSavePasswordRequest() }
    }

    func completeConfiguration() { extensionContext.completeExtensionConfigurationRequest() }

    func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }

    static func host(_ s: ASCredentialServiceIdentifier) -> String? { Site.normalize(s.identifier) }
}
