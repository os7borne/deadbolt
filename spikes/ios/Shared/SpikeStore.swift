import AuthenticationServices
import DeadboltCore
import Foundation
@preconcurrency import LocalAuthentication
import Security

/// SPIKE ONLY. Stores test logins and passkeys as plain Keychain items in the shared access group,
/// so the app and the AutoFill extension see the same data. The real app keeps them in the encrypted vault.
enum SpikeStore {
    static var accessGroup: String { Bundle.main.object(forInfoDictionaryKey: "DeadboltKeychainGroup") as! String }

    struct Login: Codable, Identifiable, Hashable {
        var id = UUID().uuidString
        var site: String       // e.g. "example.com"
        var user: String
        var password: String
    }

    // MARK: logins + passkeys (no biometric ACL: the extension asks for Face ID itself before using them)

    static func save(_ login: Login) throws { try put(service: "spike.login", account: login.id, data: JSONEncoder().encode(login)) }
    static func save(_ passkey: Passkey) throws {
        try put(service: "spike.passkey", account: passkey.credentialID.base64EncodedString(), data: JSONEncoder().encode(passkey))
    }
    static func logins() -> [Login] { all(service: "spike.login").compactMap { try? JSONDecoder().decode(Login.self, from: $0) } }
    static func passkeys() -> [Passkey] { all(service: "spike.passkey").compactMap { try? JSONDecoder().decode(Passkey.self, from: $0) } }

    static func deleteAll() {
        for service in ["spike.login", "spike.passkey", "spike.bio"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccessGroup: accessGroup] as CFDictionary)
        }
        ASCredentialIdentityStore.shared.removeAllCredentialIdentities(nil)
    }

    /// Pushes everything into the system QuickType store so iOS can suggest it above the keyboard.
    static func syncIdentities() async {
        var identities: [any ASCredentialIdentity] = logins().map {
            ASPasswordCredentialIdentity(serviceIdentifier: .init(identifier: $0.site, type: .domain), user: $0.user, recordIdentifier: $0.id)
        }
        identities += passkeys().map {
            ASPasskeyCredentialIdentity(relyingPartyIdentifier: $0.relyingPartyID, userName: $0.userName,
                                        credentialID: $0.credentialID, userHandle: $0.userHandle, recordIdentifier: nil)
        }
        do {
            try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
            SpikeLog.write("identity store: \(identities.count) identities saved")
        } catch {
            SpikeLog.write("identity store FAILED: \(error)")
        }
    }

    // MARK: biometric item — the "VK behind Face ID" test

    static func storeBiometricSecret() throws {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "spike.bio", kSecAttrAccessGroup: accessGroup] as CFDictionary)
        var error: Unmanaged<CFError>?
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw error!.takeRetainedValue()
        }
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword, kSecAttrService: "spike.bio", kSecAttrAccount: "vk",
            kSecAttrAccessGroup: accessGroup, kSecAttrAccessControl: acl, kSecValueData: secret,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpikeError.keychain(status) }
        SpikeLog.write("bio secret stored, fingerprint \(fingerprint(secret))")
    }

    /// Reads the biometric item. iOS shows Face ID; the passcode is NOT accepted (biometryCurrentSet).
    static func readBiometricSecret(reason: String) async throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var out: CFTypeRef?
                let status = SecItemCopyMatching([
                    kSecClass: kSecClassGenericPassword, kSecAttrService: "spike.bio", kSecAttrAccount: "vk",
                    kSecAttrAccessGroup: accessGroup, kSecReturnData: true, kSecUseAuthenticationContext: context,
                ] as CFDictionary, &out)
                if status == errSecSuccess, let data = out as? Data { cont.resume(returning: data) } else { cont.resume(throwing: SpikeError.keychain(status)) }
            }
        }
    }

    static func fingerprint(_ data: Data) -> String { String(data.base64EncodedString().prefix(6)) }

    // MARK: plumbing

    private static func put(service: String, account: String, data: Data) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecAttrAccessGroup: accessGroup]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData] = data
        attrs[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw SpikeError.keychain(status) }
    }

    private static func all(service: String) -> [Data] {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccessGroup: accessGroup,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &out)
        guard status == errSecSuccess else { return [] }
        return out as? [Data] ?? []
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    var description: String {
        switch self {
        case .keychain(let s): "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "?")"
        }
    }
}
