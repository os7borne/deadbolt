import AuthenticationServices
import DeadboltCore
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

enum AppConfig {
    static let appGroup = "group.com.osborne.deadbolt"

    /// iOS: the App Group, so the AutoFill extension reads the same file.
    /// macOS: the app's own sandbox container until the Mac extension/native host arrive.
    static var store: VaultStore {
        #if os(iOS)
        return VaultStore.shared(appGroup: appGroup)!
        #else
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return VaultStore(url: dir.appendingPathComponent("Deadbolt/vault.json"))
        #endif
    }

    static var defaults: UserDefaults {
        #if os(iOS)
        return UserDefaults(suiteName: appGroup)!
        #else
        return .standard
        #endif
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}

/// Non-secret preferences (shared with the extension on iOS).
enum Prefs {
    static var biometricsEnabled: Bool {
        get { AppConfig.defaults.bool(forKey: "biometricsEnabled") }
        set { AppConfig.defaults.set(newValue, forKey: "biometricsEnabled") }
    }
    /// Seconds in the background before locking.
    static var lockAfter: TimeInterval {
        get { AppConfig.defaults.object(forKey: "lockAfter") as? TimeInterval ?? 300 }
        set { AppConfig.defaults.set(newValue, forKey: "lockAfter") }
    }
    /// After this long, Face ID alone isn't enough: ask for the master password once.
    static let passwordReprompt: TimeInterval = 14 * 24 * 3600
    static var lastPasswordUnlock: Date? {
        get { AppConfig.defaults.object(forKey: "lastPasswordUnlock") as? Date }
        set { AppConfig.defaults.set(newValue, forKey: "lastPasswordUnlock") }
    }
    /// True from "vault created" until the person has seen the recovery words and the Face ID offer.
    /// Persisted so an app kill mid-setup resumes at the words instead of skipping them.
    static var onboardingPending: Bool {
        get { AppConfig.defaults.bool(forKey: "onboardingPending") }
        set { AppConfig.defaults.set(newValue, forKey: "onboardingPending") }
    }
    static var offerToSave: Bool {
        get { AppConfig.defaults.object(forKey: "offerToSave") as? Bool ?? true }
        set { AppConfig.defaults.set(newValue, forKey: "offerToSave") }
    }
}

enum Clipboard {
    static let clearAfter: TimeInterval = 60

    /// Copies locally only (no Universal Clipboard) and clears after 60 s.
    static func copySecret(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(clearAfter)])
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
        #endif
    }
}

/// Tells the system which logins and passkeys exist (no secrets) so it can suggest them above the keyboard.
enum IdentitySync {
    static func update(from vault: Vault) async {
        #if os(iOS)
        var identities: [any ASCredentialIdentity] = []
        for login in vault.logins where !login.password.isEmpty { // passkey-only accounts have no password to offer
            for site in login.sites {
                let identity = ASPasswordCredentialIdentity(serviceIdentifier: .init(identifier: site, type: .domain),
                                                            user: login.username, recordIdentifier: login.id.uuidString)
                identity.rank = login.preferred ? 1 : 0
                identities.append(identity)
            }
        }
        for pk in vault.passkeys {
            identities.append(ASPasskeyCredentialIdentity(relyingPartyIdentifier: pk.relyingPartyID, userName: pk.userName,
                                                          credentialID: pk.credentialID, userHandle: pk.userHandle,
                                                          recordIdentifier: nil))
        }
        try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
        #endif
    }

    static func clear() {
        #if os(iOS)
        ASCredentialIdentityStore.shared.removeAllCredentialIdentities(nil)
        #endif
    }
}

#if os(iOS)
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
#else
enum Haptics {
    static func success() {}
    static func error() {}
    static func tap() {}
}
#endif
