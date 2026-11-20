import DeadboltCore
import Foundation
@preconcurrency import LocalAuthentication
import Security

/// The vault key behind Face ID / Touch ID: a Keychain item with `biometryCurrentSet` (re-enrolling a face
/// or finger invalidates it) and `WhenUnlockedThisDeviceOnly` (never leaves this device, never in backups).
/// The device passcode is deliberately NOT a fallback.
enum KeychainKey {
    static let service = "deadbolt.vault-key"

    static var accessGroup: String { Bundle.main.object(forInfoDictionaryKey: "DeadboltKeychainGroup") as! String }

    private static func baseQuery() -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: "vk", kSecAttrAccessGroup: accessGroup]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        return q
    }

    static func store(_ key: VaultKey) throws {
        SecItemDelete(baseQuery() as CFDictionary)
        var error: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        var epoch = key.epoch.bigEndian
        var data = Data(bytes: &epoch, count: 4)
        data.append(key.keychainRepresentation)
        var q = baseQuery()
        q[kSecAttrAccessControl] = acl
        q[kSecValueData] = data
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Shows Face ID / Touch ID, then reads the key with that approval. Returns nil if the person cancels.
    ///
    /// Face ID runs as its own step (evaluatePolicy) and the Keychain read then reuses the approved context
    /// with interaction disabled. Letting SecItemCopyMatching show Face ID itself fails with
    /// errSecInteractionNotAllowed in the AutoFill extension while its sheet is still being presented.
    static func read(reason: String) async throws -> VaultKey? {
        let context = LAContext()
        context.localizedFallbackTitle = "" // no "Enter Passcode" button: the passcode must not open the vault
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let e as LAError {
            switch e.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: return nil
            case .biometryLockout: throw KeychainError(biometry: "\(biometryName) is locked after too many tries. Use your master password.")
            case .biometryNotEnrolled, .biometryNotAvailable: throw KeychainError(biometry: "\(biometryName) isn’t available. Use your master password.")
            default: throw KeychainError(biometry: e.localizedDescription)
            }
        }
        context.interactionNotAllowed = true // already approved: never prompt a second time
        var q = baseQuery()
        q[kSecReturnData] = true
        q[kSecUseAuthenticationContext] = context
        let query = q
        let (status, data): (OSStatus, Data?) = await Task.detached {
            var out: CFTypeRef?
            let s = SecItemCopyMatching(query as CFDictionary, &out)
            return (s, out as? Data)
        }.value
        switch status {
        case errSecSuccess:
            guard let data, data.count == 36 else { throw KeychainError(status: errSecDecode) }
            let epoch = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return try VaultKey(epoch: epoch, rawBytes: data.suffix(32))
        case errSecUserCanceled:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    static func delete() { SecItemDelete(baseQuery() as CFDictionary) }

    /// Face ID / Touch ID is set up on this device at all.
    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var biometryName: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return c.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    /// A fresh biometric check before something sensitive (showing recovery words).
    static func confirmOwner(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}

struct KeychainError: LocalizedError, CustomStringConvertible {
    let status: OSStatus
    var biometryMessage: String?

    init(status: OSStatus) { self.status = status }
    init(biometry message: String) { self.status = errSecAuthFailed; self.biometryMessage = message }

    var isMissingKey: Bool { status == errSecItemNotFound }

    /// Plain words for the person, with the code kept at the end so a screenshot is enough to diagnose.
    var errorDescription: String? {
        if let biometryMessage { return biometryMessage }
        switch status {
        case errSecItemNotFound:
            return "\(KeychainKey.biometryName) needs setting up again on this device. Unlock with your master password and it’s restored. (\(status))"
        case errSecInteractionNotAllowed:
            return "\(KeychainKey.biometryName) wasn’t ready yet. Try again. (\(status))"
        case errSecAuthFailed:
            return "\(KeychainKey.biometryName) didn’t match. Try again or use your master password. (\(status))"
        case errSecMissingEntitlement:
            return "This build can’t reach the shared Keychain. (\(status))"
        default:
            return "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
    var description: String { errorDescription ?? "Keychain error \(status)" }
}
