import AppKit
import CryptoKit
import DeadboltCore
import Foundation
@preconcurrency import LocalAuthentication
import Security

/// Answers the Chrome extension, via `deadbolt-bridge`, over a Unix socket in the app-group container.
///
/// Who can ask: only a process whose code signature is Deadbolt's bridge, signed by this team — checked per
/// connection from the socket's audit token. Chrome itself only lets the Deadbolt extension start the bridge.
/// What it gives out: never the vault. Fill returns one login, and only if that login's site matches the page.
@MainActor
final class BridgeServer {
    static let groupID = "4CMN2DUGUL.com.osborne.deadbolt"
    /// The Chrome extensions allowed to start the native-messaging host: the one loaded from the repo (fixed key) and the
    /// one published on the Chrome Web Store (ID assigned by the store when the item was created, 2026-11-23).
    static let extensionIDs = ["lhalfpljkecpmpgcfibbaeldddnekdfa", "geldeaijmgdlfnkgkjdgmlmcadomfhch"]
    /// Exactly two callers: the Chrome native-messaging host and the Safari extension, both signed by this team.
    static let requirement = #"(identifier "com.osborne.deadbolt.bridge" or identifier "com.osborne.deadbolt.safari") and anchor apple generic and certificate leaf[subject.OU] = "4CMN2DUGUL""#

    private let session: VaultSession
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    init(session: VaultSession) { self.session = session }

    // MARK: setup

    func start() {
        installChromeManifest()
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupID) else { return }
        let path = dir.appendingPathComponent("bridge.sock").path
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in p.copyBytes(from: bytes); p[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); return }
        chmod(path, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    /// Where each Chromium-based browser looks for native-messaging hosts (relative to ~/Library/Application Support).
    /// Must match the sandbox exception list in project.yml.
    static let browserHostDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data", "Yab/Chromium",
        "Aside", "com.ardia.browser/Chromium",   // Aside (aside.com / ardia.dev)
    ]

    /// Browsers find native hosts through this file. Written for every installed Chromium browser on each launch,
    /// so the path follows the app. Browsers that aren't installed are skipped (no folders created for them).
    private func installChromeManifest() {
        guard let pw = getpwuid(getuid()), let homeC = pw.pointee.pw_dir else { return }
        let home = String(cString: homeC) // the real home, not the sandbox container
        for browser in Self.browserHostDirs {
            let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/\(browser)")
            installManifest(in: root.appendingPathComponent("NativeMessagingHosts"))
        }
    }

    private func installManifest(in dir: URL) {
        let manifest: [String: Any] = [
            "name": "com.osborne.deadbolt",
            "description": "Deadbolt password manager",
            "path": Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/deadbolt-bridge").path,
            "type": "stdio",
            "allowed_origins": Self.extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        // Only create the NativeMessagingHosts folder itself; if the browser's own folder is missing, it isn't installed.
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false) }
        catch CocoaError.fileWriteFileExists {} catch where (error as NSError).code == NSFileWriteFileExistsError {} catch {
            if !FileManager.default.fileExists(atPath: dir.path) { return }
        }
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("com.osborne.deadbolt.json"), options: .atomic)
        }
    }

    // MARK: connections

    private func acceptOne() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        guard Self.peerIsOurBridge(fd) else { close(fd); return }
        Task { @MainActor in
            defer { close(fd) }
            guard let line = Self.readLine(fd) else { return }
            let reply = await self.handle(line)
            var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
            out.append(0x0a)
            _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        }
    }

    /// The connecting process must be our signed bridge (identifier + team), checked from the kernel's audit token.
    static func peerIsOurBridge(_ fd: Int32) -> Bool {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while out.count < 4 << 20 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
            if out.last == 0x0a { out.removeLast(); return out }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: requests

    private func handle(_ data: Data) async -> [String: Any] {
        guard let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = req["type"] as? String else {
            return ["ok": false, "error": "badRequest"]
        }
        let host = (req["url"] as? String).flatMap(Site.normalize)
        // Using Deadbolt from the browser counts as activity; status checks and the toolbar badge's counts don't,
        // or just browsing would keep the vault unlocked forever.
        if type != "status" && (req["passive"] as? Bool) != true { session.touch() }

        switch type {
        case "status":
            return ["ok": true, "locked": session.state != .unlocked, "hasVault": session.state != .noVault]

        case "unlock":
            if session.state == .locked, session.biometricUnlockAllowed {
                _ = try? await session.unlockWithBiometrics(reason: "Unlock Deadbolt for Chrome")
            }
            if session.state != .unlocked { open() } // master password needed: show the window
            return ["ok": true, "locked": session.state != .unlocked]

        case "open":
            open()
            return ["ok": true]

        case "generate":
            // Uses the synced preferences when the vault is open; sensible defaults while locked.
            return ["ok": true, "password": session.state == .unlocked ? session.newPassword() : PasswordGenerator.password()]

        default:
            break
        }

        if type == "passkeyCreate" || type == "passkeyGet" { return await passkey(type, req) }

        guard session.state == .unlocked else { return ["ok": false, "error": "locked"] }

        // Cards, identities and notes aren't tied to a website, so they never go through a site check. The extension only
        // forwards these from its own popup (never from a page), and the values never leave this app: the extension is told which
        // fields exist and asks Deadbolt to copy one. Secret fields need a fresh Touch ID check here first.
        switch type {
        case "items": return itemList()
        case "copyItem": return await copyItem(req)
        case "fillItem": return await fillItem(req)
        default: break
        }

        guard let host else { return ["ok": false, "error": "badSite"] }

        switch type {
        case "accounts":
            let list = session.vault.accounts(for: host).map { l -> [String: Any] in
                ["id": l.id.uuidString, "title": l.title, "name": l.customName ?? "", "username": l.username, "label": l.label ?? "",
                 "hasPassword": !l.password.isEmpty, "hasCode": l.totpSecret != nil, "hasPasskey": !l.passkeyIDs.isEmpty,
                 "codeOnly": l.isCodeOnly, "passwordless": l.isPasswordless, "preferred": l.preferred]
            }
            return ["ok": true, "site": host, "accounts": list]

        case "fill", "code":
            // The login must belong to the page's site: a compromised page can't ask for another site's password.
            guard let id = (req["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let login = session.vault.login(id, for: host) else {
                return ["ok": false, "error": "notForThisSite"]
            }
            if type == "code" {
                guard let s = login.totpSecret, let t = try? TOTP(s) else { return ["ok": false, "error": "noCode"] }
                return ["ok": true, "code": t.code(), "remaining": t.secondsRemaining(at: Date()), "period": t.period]
            }
            try? session.mutate { $0.markUsed(login.id) }
            return ["ok": true, "username": login.username, "password": login.password]

        case "propose":
            // A password may be empty (sign-in by emailed link or code), but then the username is all there is to save.
            guard let user = req["username"] as? String, let pass = req["password"] as? String,
                  !(pass.isEmpty && user.trimmingCharacters(in: .whitespaces).isEmpty) else {
                return ["ok": false, "error": "badRequest"]
            }
            // The page now showing may be another subdomain after a redirect (login.x.com → app.x.com): same registrable
            // domain counts as the same site. Anything else waits (the person may come back), never prompts here.
            if let page = (req["pageUrl"] as? String).flatMap(Site.normalize), !PublicSuffix.sameSite(host, page) {
                return ["ok": true, "action": "none", "reason": "otherSite"]
            }
            switch session.vault.proposeSave(host: host, username: user, password: pass) {
            case .new: return ["ok": true, "action": "save"]
            case .update(let id): return ["ok": true, "action": "update", "addsPassword": session.vault.login(id)?.password.isEmpty ?? false]
            case .unchanged: return ["ok": true, "action": "none"]
            }

        case "save":
            guard Prefs.offerToSave, let user = req["username"] as? String, let pass = req["password"] as? String,
                  !(pass.isEmpty && user.trimmingCharacters(in: .whitespaces).isEmpty) else {
                return ["ok": false, "error": "badRequest"]
            }
            let separate = (req["separate"] as? Bool) ?? false
            do {
                try session.mutate { v in try v.save(host: host, username: user, password: pass, asNewAccount: separate) }
                return ["ok": true]
            } catch { return ["ok": false, "error": "saveFailed"] }

        case "add":
            // "Add login" in the extension's popup: an explicit action by the owner, so it doesn't depend on the
            // "offer to save" preference. Only the popup sends this (the extension refuses it from pages). The password
            // may be empty (sign-in by emailed link or code); an existing login's password is never erased by that.
            guard let user = (req["username"] as? String)?.trimmingCharacters(in: .whitespaces), !user.isEmpty,
                  let pass = req["password"] as? String else { return ["ok": false, "error": "badRequest"] }
            let outcome: String
            switch session.vault.proposeSave(host: host, username: user, password: pass) {
            case .new: outcome = "added"
            case .update: outcome = "updated"
            case .unchanged: outcome = "exists"
            }
            do {
                try session.mutate { v in try v.save(host: host, username: user, password: pass) }
                return ["ok": true, "result": outcome, "site": host]
            } catch { return ["ok": false, "error": "saveFailed"] }

        case "site":
            // The site a login added from this page should cover: its main (registrable) domain, as a suggestion.
            return ["ok": true, "site": host, "suggested": PublicSuffix.registrableDomain(host) ?? host]

        default:
            return ["ok": false, "error": "unknown"]
        }
    }

    // MARK: cards, identities, notes for the popup

    private func field(_ f: CopyField) -> [String: Any] { ["key": f.key, "label": f.label, "secret": f.secret] }

    /// Names and last four digits only. No card number, code, PIN, ID number or note text is in this answer.
    private func itemList() -> [String: Any] {
        let v = session.vault
        func byTitle(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
        let cards = v.cardsByRecency.map { c -> [String: Any] in
            ["id": c.id.uuidString, "title": c.title, "brand": c.resolvedBrand.displayName, "last4": c.last4, "expiry": c.expiry ?? "",
             "expired": c.isExpired(), "primary": "number", "fields": c.copyFields.map(field)]
        }
        let identities = v.identitiesByRecency.map { i -> [String: Any] in
            ["id": i.id.uuidString, "title": i.title.isEmpty ? i.fullName : i.title, "name": i.fullName,
             "primary": i.primaryCopyKey ?? "", "fields": i.copyFields.map(field)]
        }
        let notes = v.notes.sorted { byTitle($0.title, $1.title) }.map { n -> [String: Any] in
            ["id": n.id.uuidString, "title": n.title, "label": n.label ?? "", "primary": "body", "fields": n.copyFields.map(field)]
        }
        return ["ok": true, "cards": cards, "identities": identities, "notes": notes]
    }

    private func copyItem(_ req: [String: Any]) async -> [String: Any] {
        guard let id = (req["id"] as? String).flatMap(UUID.init(uuidString:)), let key = req["field"] as? String,
              let found = session.vault.copyField(item: id, key: key) else { return ["ok": false, "error": "notFound"] }
        let f = found.field
        let secs = Int(f.secret ? Clipboard.sensitiveClearAfter : Clipboard.clearAfter)
        if f.secret {
            // The person is looking at the browser, so a small note says that Deadbolt is asking, and for what.
            let hud = PasskeyHUD.shared
            hud.show("Copy \(f.label.lowercased())", detail: "Confirm with \(KeychainKey.biometryName) · \(found.itemTitle)")
            guard await confirmOwnerForBrowser("Copy \(f.label.lowercased()) for \(found.itemTitle)") else {
                hud.finish(success: false, "Cancelled", detail: "Nothing was copied")
                return ["ok": false, "error": "cancelled"]
            }
            Clipboard.copySecret(f.value, clearAfter: Clipboard.sensitiveClearAfter)
            hud.finish(success: true, "\(f.label) copied", detail: "Clears from the clipboard in \(secs) s")
        } else {
            Clipboard.copySecret(f.value)
        }
        session.touch()
        try? session.mutate { $0.markItemUsed(id) }   // recent use orders the suggestions
        return ["ok": true, "clearsIn": secs]
    }

    /// Values for the fields a page's form really has. The extension passes the tab's real address (never the page's own claim);
    /// the Touch ID note names that site, so a card can't be released to a lookalike without the person seeing where it goes.
    /// Only a card number or security code needs Touch ID; names, addresses and the like fill on the pick alone.
    private func fillItem(_ req: [String: Any]) async -> [String: Any] {
        guard let id = (req["id"] as? String).flatMap(UUID.init(uuidString:)),
              let want = req["want"] as? [String], want.count <= 24, want.allSatisfy({ $0.count <= 16 }),
              let urlString = req["url"] as? String, let url = URL(string: urlString), let host = url.host()?.lowercased(),
              url.scheme == "https" || host == "localhost" || host == "127.0.0.1" else { return ["ok": false, "error": "badRequest"] }
        guard let filled = session.vault.fillValues(item: id, want: want) else { return ["ok": false, "error": "notFound"] }
        if filled.hasSecret {
            let hud = PasskeyHUD.shared
            hud.show("Fill \(filled.summary)", detail: "Confirm with \(KeychainKey.biometryName) · \(host)")
            guard await confirmOwnerForBrowser("Fill \(filled.summary) on \(host)") else {
                hud.finish(success: false, "Cancelled", detail: "Nothing was filled")
                return ["ok": false, "error": "cancelled"]
            }
            hud.finish(success: true, "Filled \(filled.summary)", detail: host)
        }
        session.touch()
        try? session.mutate { $0.markItemUsed(id) }   // recent use orders the suggestions
        return ["ok": true, "values": filled.values]
    }

    /// Touch ID, or the master password when Touch ID isn't available. The password sheet lives in Deadbolt's window, so bring
    /// that forward if it is needed (the check itself doesn't activate Deadbolt when the browser started it).
    private func confirmOwnerForBrowser(_ reason: String) async -> Bool {
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if session.ownerPrompt != nil { open(); break }
            }
        }
        defer { watcher.cancel() }
        return await session.confirmOwner(reason)
    }

    // MARK: passkeys for the browser
    //
    // The page's MAIN-world script only relays the site's request. Everything that matters is decided here:
    // the origin (from the browser's own tab URL), the rpId rule (Public Suffix List), clientDataJSON, user verification.

    private func passkey(_ type: String, _ req: [String: Any]) async -> [String: Any] {
        guard let urlString = req["url"] as? String, let url = URL(string: urlString), let host = url.host()?.lowercased(),
              url.scheme == "https" || host == "localhost" else { return ["ok": false, "error": "SecurityError"] }
        let origin = "\(url.scheme!)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        let rpID = ((req["rpId"] as? String)?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? host
        guard PublicSuffix.isValidRelyingParty(rpID, for: host) else { return ["ok": false, "error": "SecurityError"] }
        guard let challenge = req["challenge"] as? String, challenge.count <= 1024,
              challenge.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return ["ok": false, "error": "badRequest"]
        }

        if type == "passkeyGet" {
            // Nothing for this site: step aside so the browser's own passkey handling runs.
            if session.state == .unlocked {
                let allowed = Set(((req["allow"] as? [String]) ?? []).compactMap(Self.unb64))
                let candidates = session.vault.passkeys(for: rpID).filter { allowed.isEmpty || allowed.contains($0.credentialID) }
                if candidates.isEmpty { return ["ok": false, "error": "none"] }
                if candidates.count > 1, req["choose"] == nil {
                    return ["ok": true, "choices": candidates.map { ["id": Self.b64($0.credentialID), "name": $0.userName] }]
                }
            }
        }

        // User verification: unlocking with Touch ID counts; otherwise a fresh Touch ID for this operation.
        // A small floating note says who is asking and why, since the person is looking at the browser.
        let creating = type == "passkeyCreate"
        let reason = creating ? "Create a passkey for \(rpID)" : "Sign in to \(rpID) with a passkey"
        let hud = PasskeyHUD.shared
        hud.show(creating ? "Create a passkey" : "Sign in with a passkey", detail: "Confirm with \(KeychainKey.biometryName) · \(rpID)")
        let verified: Bool
        if session.state != .unlocked {
            guard session.biometricUnlockAllowed else { hud.hide(); open(); return ["ok": false, "error": "locked"] }
            verified = (try? await session.unlockWithBiometrics(reason: reason)) == true
        } else {
            verified = await Self.verifyUser(reason)
        }
        guard verified else {
            hud.finish(success: false, "Cancelled", detail: "No passkey was used")
            return ["ok": false, "error": "NotAllowedError"]
        }
        session.touch()

        let result = creating ? create(req, rpID: rpID, origin: origin, challenge: challenge)
                              : get(req, rpID: rpID, origin: origin, challenge: challenge)
        let ok = result["ok"] as? Bool == true
        hud.finish(success: ok, ok ? (creating ? "Passkey saved" : "Passkey used") : "Couldn’t finish", detail: rpID)
        return result
    }

    private func create(_ req: [String: Any], rpID: String, origin: String, challenge: String) -> [String: Any] {
        guard let userID = (req["userId"] as? String).flatMap(Self.unb64), !userID.isEmpty, userID.count <= 64 else {
            return ["ok": false, "error": "badRequest"]
        }
        let userName = (req["userName"] as? String) ?? ""
        let algs = (req["algs"] as? [Int]) ?? [-7]
        let excluded = Set(((req["exclude"] as? [String]) ?? []).compactMap(Self.unb64))
        if session.vault.passkeys(for: rpID).contains(where: { excluded.contains($0.credentialID) }) {
            return ["ok": false, "error": "InvalidStateError"]   // the site says you already have one here
        }
        let clientData = Data(#"{"type":"webauthn.create","challenge":"\#(challenge)","origin":"\#(origin)","crossOrigin":false}"#.utf8)
        do {
            let pk = Passkey.create(relyingPartyID: rpID, userName: userName, userHandle: userID)
            let reg = try WebAuthn.register(pk, supportedAlgorithms: algs)
            try session.mutate { v in
                let match = v.accounts(for: rpID).first { Vault.canonical($0.username) == Vault.canonical(userName) }
                let id = try match?.id ?? v.save(host: rpID, username: userName, password: "", asNewAccount: true)
                v.add(pk, linkTo: id)
            }
            return ["ok": true, "id": Self.b64(reg.credentialID), "clientDataJSON": Self.b64(clientData),
                    "attestationObject": Self.b64(reg.attestationObject), "authenticatorData": Self.b64(reg.authenticatorData),
                    "publicKey": Self.b64(reg.publicKeyDER), "publicKeyAlgorithm": WebAuthn.es256]
        } catch WebAuthnError.unsupportedAlgorithm {
            return ["ok": false, "error": "NotSupportedError"]
        } catch {
            return ["ok": false, "error": "UnknownError"]
        }
    }

    private func get(_ req: [String: Any], rpID: String, origin: String, challenge: String) -> [String: Any] {
        let allowed = Set(((req["allow"] as? [String]) ?? []).compactMap(Self.unb64))
        let chosen = (req["choose"] as? String).flatMap(Self.unb64)
        let candidates = session.vault.passkeys(for: rpID).filter { allowed.isEmpty || allowed.contains($0.credentialID) }
        guard let pk = chosen.flatMap({ c in candidates.first { $0.credentialID == c } }) ?? candidates.first else {
            return ["ok": false, "error": "none"]
        }
        let clientData = Data(#"{"type":"webauthn.get","challenge":"\#(challenge)","origin":"\#(origin)","crossOrigin":false}"#.utf8)
        guard let a = try? WebAuthn.assert(pk, clientDataHash: Data(SHA256.hash(data: clientData))) else {
            return ["ok": false, "error": "UnknownError"]
        }
        return ["ok": true, "id": Self.b64(a.credentialID), "clientDataJSON": Self.b64(clientData),
                "authenticatorData": Self.b64(a.authenticatorData), "signature": Self.b64(a.signature), "userHandle": Self.b64(a.userHandle)]
    }

    private static func verifyUser(_ reason: String) async -> Bool {
        let ctx = LAContext()
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        return (try? await ctx.evaluatePolicy(policy, localizedReason: reason)) ?? false
    }

    static func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func unb64(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }

    /// Brings Deadbolt's window to the front, creating it if it was closed (the Chrome popup's "Open Deadbolt", or a password prompt).
    /// Deadbolt is a menu-bar app, so an ordinary activate() from a background request is often ignored; asking LaunchServices to
    /// open the app is the route that works when another app (Chrome) was in front.
    private func open() {
        MacRuntime.openMainWindow?()
        NSApp.activate()
        for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true || w.title == "Deadbolt" { w.makeKeyAndOrderFront(nil) }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in }
    }
}
