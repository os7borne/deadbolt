import CoreImage
import CoreImage.CIFilterBuiltins
import DeadboltCore
import Foundation
import Security
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum SyncConfig {
    static let relay = URL(string: "https://deadbolt-relay.osborne.vc")!
}

/// This installation's id, name and keys. The id lives in the shared defaults so the AutoFill extension stamps
/// its changes with the same id; the private keys live in the Keychain (Secure Enclave handles where available).
enum DeviceIdentity {
    /// This installation's id. Kept in the Keychain as ThisDeviceOnly, so a new phone restored from an iCloud backup
    /// gets a NEW id instead of cloning the old phone's identity (preferences are restored by backups; this isn't).
    static var id: String {
        if let cached { return cached }
        if let stored = readID() { cached = stored; return stored }
        // Migration from versions that kept the id in preferences: adopt it only if its keys exist in this
        // device's Keychain (they can't have come from a backup), otherwise start fresh.
        if let legacy = AppConfig.defaults.string(forKey: "deviceID"), keysExist(for: legacy) {
            writeID(legacy); cached = legacy; return legacy
        }
        AppConfig.defaults.removeObject(forKey: "deviceID")
        let fresh = UUID().uuidString.lowercased()
        writeID(fresh)
        cached = fresh
        return fresh
    }

    nonisolated(unsafe) private static var cached: String?

    private static func idQuery() -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "deadbolt.device-id",
                                  kSecAttrAccount: "id", kSecAttrAccessGroup: KeychainKey.accessGroup]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        return q
    }

    private static func readID() -> String? {
        var q = idQuery(); q[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private static func writeID(_ id: String) {
        SecItemDelete(idQuery() as CFDictionary)
        var q = idQuery()
        q[kSecValueData] = Data(id.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func keysExist(for id: String) -> Bool {
        var q = query(account: id); q[kSecReturnAttributes] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static var name: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    static var model: String {
        #if os(iOS)
        var sys = utsname(); uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return UIDevice.current.model + " (\(id))"
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return "Mac (\(String(cString: buf)))"
        #endif
    }

    static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    private static let service = "deadbolt.device-keys"

    private static func query(account: String? = nil) -> [CFString: Any] {
        var q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account ?? id,
                                  kSecAttrAccessGroup: KeychainKey.accessGroup]
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = true
        #endif
        return q
    }

    /// Loads this device's keys, creating them on first use.
    static func keys() throws -> DeviceKeys {
        var q = query()
        q[kSecReturnData] = true
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return try JSONDecoder().decode(DeviceKeys.self, from: data)
        }
        let keys = try DeviceKeys.generate()
        var add = query()
        add[kSecValueData] = try JSONEncoder().encode(keys)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return keys
    }

    static func record(keys: DeviceKeys) throws -> DeviceRecord {
        DeviceRecord(id: id, name: name, model: model, platform: platform,
                     signingKey: try keys.signingPublicKey, agreementKey: try keys.agreementPublicKey)
    }

    /// Forget this device entirely (erase / removed): keys, id and sync position.
    static func reset() {
        SecItemDelete(query() as CFDictionary)
        SecItemDelete(idQuery() as CFDictionary)
        cached = nil
        for k in AppConfig.defaults.dictionaryRepresentation().keys
        where k == "deviceID" || k == "syncLastSent" || k.hasPrefix("syncLastSeq") || k.hasPrefix("mailboxReady-") {
            AppConfig.defaults.removeObject(forKey: k)
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> Image? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return Image(decorative: cg, scale: 1).interpolation(.none)
    }
}

// MARK: friendly device names

/// "iPhone (iPhone12,1)" → "iPhone 11". Apple's identifiers are unreadable; unknown ones fall back to the family name.
enum DeviceModel {
    static func friendly(_ raw: String) -> String {
        guard let open = raw.lastIndex(of: "("), raw.hasSuffix(")") else { return raw }
        let id = String(raw[raw.index(after: open)..<raw.index(before: raw.endIndex)])
        if let name = names[id] { return name }
        if id.hasPrefix("iPhone") { return "iPhone" }
        if id.hasPrefix("iPad") { return "iPad" }
        return id.hasPrefix("Mac") || raw.hasPrefix("Mac") ? "Mac" : raw
    }

    private static let names: [String: String] = [
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X", "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max",
        "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR", "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max", "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        "MacBookAir10,1": "MacBook Air", "MacBookPro17,1": "MacBook Pro", "MacBookPro18,1": "MacBook Pro", "MacBookPro18,2": "MacBook Pro",
        "MacBookPro18,3": "MacBook Pro", "MacBookPro18,4": "MacBook Pro", "Macmini9,1": "Mac mini", "iMac21,1": "iMac", "iMac21,2": "iMac",
        "Mac13,1": "Mac Studio", "Mac13,2": "Mac Studio", "Mac14,2": "MacBook Air", "Mac14,15": "MacBook Air 15\"",
        "Mac14,7": "MacBook Pro", "Mac14,3": "Mac mini", "Mac14,12": "Mac mini",
        "Mac15,12": "MacBook Air", "Mac15,13": "MacBook Air 15\"",
    ]
}

extension DeviceRecord {
    /// The name to show: Apple hides the owner's device name from apps on iPhone ("iPhone"), so that falls back to the model.
    var shownName: String {
        let generic = ["iPhone", "iPad", "Mac", ""]
        return generic.contains(name) ? DeviceModel.friendly(model) : name
    }
    /// "iPhone 11 · linked 18 Nov", leaving out the model when the name already says it.
    var shownDetail: String {
        let m = DeviceModel.friendly(model)
        let linked = "linked \(linkedAt.formatted(.dateTime.day().month(.abbreviated)))"
        return m == shownName ? linked : "\(m) · \(linked)"
    }
}
