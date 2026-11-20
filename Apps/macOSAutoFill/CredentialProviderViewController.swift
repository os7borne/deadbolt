import AppKit
import AuthenticationServices
import DeadboltCore
import SwiftUI

/// Mac AutoFill: passwords, passkeys and one-time codes in Safari and every Mac app, from the same vault as the
/// menu-bar app (shared App Group + Keychain group). Same screens as the iPhone extension (AutoFillViews.swift), laid out at the Mac app's compact scale.
/// macOS has no save-password API for providers: saving in Safari goes through the Safari extension instead.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let session = VaultSession()
    private let model = AutoFillModel()

    override func loadView() {
        model.controller = self
        let host = NSHostingView(rootView: AutoFillRoot(model: model).environment(session).frame(minWidth: 360, minHeight: 360))
        view = host
        preferredContentSize = NSSize(width: 380, height: 440)
    }

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

    /// Always ask for Touch ID first.
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

    override func prepareInterfaceForExtensionConfiguration() { model.mode = .configure }

    // MARK: completions (same API as the iOS controller, used by AutoFillViews)

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

    func completeSave() { cancel(.userCanceled) } // not offered by macOS

    func completeConfiguration() { extensionContext.completeExtensionConfigurationRequest() }

    func cancel(_ code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }

    static func host(_ s: ASCredentialServiceIdentifier) -> String? { Site.normalize(s.identifier) }
}
