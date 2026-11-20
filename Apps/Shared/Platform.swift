import AuthenticationServices
import DeadboltCore
import Foundation
import SwiftUI
#if os(macOS)
import ServiceManagement
#endif
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#else
import AppKit
#endif

enum AppConfig {
    /// Shared by the app and its AutoFill extension (and, on Mac, the browser bridge socket).
    #if os(iOS)
    static let appGroup = "group.com.osborne.deadbolt"
    #else
    static let appGroup = "4CMN2DUGUL.com.osborne.deadbolt"
    #endif

    static var store: VaultStore { VaultStore.shared(appGroup: appGroup, node: DeviceIdentity.id)! }

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    #if os(macOS)
    /// One-time move from the Mac app's private container (before the Mac AutoFill extension existed).
    /// The old file is left in place as a backup.
    static func migrateMacStorageIfNeeded() {
        let fm = FileManager.default
        let groupDefaults = UserDefaults(suiteName: appGroup)!
        if !groupDefaults.bool(forKey: "migratedFromAppContainer") {
            for (k, v) in UserDefaults.standard.dictionaryRepresentation() where !k.hasPrefix("NS") && !k.hasPrefix("Apple") && !k.hasPrefix("com.apple") {
                if groupDefaults.object(forKey: k) == nil { groupDefaults.set(v, forKey: k) }
            }
            groupDefaults.set(true, forKey: "migratedFromAppContainer")
        }
        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Deadbolt/vault.json")
        guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let new = group.appendingPathComponent("Vault/vault.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: old, to: new)
        }
    }
    #endif

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
    /// Shown once on the welcome screen after this device was removed from a vault by another device.
    static var removedNotice: String? {
        get { AppConfig.defaults.string(forKey: "removedNotice") }
        set { AppConfig.defaults.set(newValue, forKey: "removedNotice") }
    }
    /// This device joined an existing vault by linking: onboarding skips the recovery words.
    static var joinedByLink: Bool {
        get { AppConfig.defaults.bool(forKey: "joinedByLink") }
        set { AppConfig.defaults.set(newValue, forKey: "joinedByLink") }
    }
    static var offerToSave: Bool {
        get { AppConfig.defaults.object(forKey: "offerToSave") as? Bool ?? true }
        set { AppConfig.defaults.set(newValue, forKey: "offerToSave") }
    }
}

/// System permissions and switches Deadbolt asks for.
@MainActor
enum SystemSetup {
    /// Is Deadbolt turned on as an AutoFill provider (iOS)?
    static func autofillEnabled() async -> Bool {
        await ASCredentialIdentityStore.shared.state().isEnabled
    }

    /// Shows the system prompt to turn Deadbolt on for AutoFill. Returns the result.
    static func requestAutofill() async -> Bool {
        await withCheckedContinuation { c in
            ASSettingsHelper.requestToTurnOnCredentialProviderExtension { on in c.resume(returning: on) }
        }
    }

    static func openAutofillSettings() {
        Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() }
    }

    #if os(macOS)
    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
    #endif
}

enum Clipboard {
    static let clearAfter: TimeInterval = 60
    /// Card numbers, security codes, PINs and ID numbers leave the clipboard sooner.
    static let sensitiveClearAfter: TimeInterval = 30

    /// Copies locally only (no Universal Clipboard) and clears after 60 s (or `clearAfter`).
    static func copySecret(_ text: String, clearAfter: TimeInterval = Clipboard.clearAfter) {
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
        var identities: [any ASCredentialIdentity] = []
        for login in vault.logins where !login.password.isEmpty { // passkey-only accounts have no password to offer
            for site in login.sites {
                let identity = ASPasswordCredentialIdentity(serviceIdentifier: .init(identifier: site, type: .domain),
                                                            user: login.username, recordIdentifier: login.id.uuidString)
                identity.rank = login.preferred ? 1 : 0
                identities.append(identity)
            }
        }
        for login in vault.logins where login.totpSecret != nil {
            for site in login.sites {
                identities.append(ASOneTimeCodeCredentialIdentity(serviceIdentifier: .init(identifier: site, type: .domain),
                                                                  label: login.username, recordIdentifier: login.id.uuidString))
            }
        }
        for pk in vault.passkeys {
            identities.append(ASPasskeyCredentialIdentity(relyingPartyIdentifier: pk.relyingPartyID, userName: pk.userName,
                                                          credentialID: pk.credentialID, userHandle: pk.userHandle,
                                                          recordIdentifier: nil))
        }
        try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    static func clear() {
        ASCredentialIdentityStore.shared.removeAllCredentialIdentities(nil)
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
