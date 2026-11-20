import Foundation

/// The Public Suffix List (publicsuffix.org, MPL-2.0, bundled unmodified), used to decide which passkey
/// "relying party IDs" a site may use — the same rule browsers apply. Includes the private section, so
/// `evil.github.io` can't claim the rpId `github.io`.
public enum PublicSuffix {
    private static let rules: (normal: Set<String>, wildcard: Set<String>, exception: Set<String>) = {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("public_suffix_list.dat missing from DeadboltCore resources")
        }
        var normal = Set<String>(), wildcard = Set<String>(), exception = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("!") { exception.insert(String(line.dropFirst())) }
            else if line.hasPrefix("*.") { wildcard.insert(String(line.dropFirst(2))) }
            else { normal.insert(line) }
        }
        return (normal, wildcard, exception)
    }()

    /// True for "com", "co.uk", "github.io", "anything.ck" (wildcard) — but not "www.ck" (exception).
    public static func isPublicSuffix(_ domain: String) -> Bool {
        let d = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !d.isEmpty else { return true }
        if rules.exception.contains(d) { return false }
        if rules.normal.contains(d) { return true }
        if let dot = d.firstIndex(of: "."), rules.wildcard.contains(String(d[d.index(after: dot)...])) { return true }
        return !d.contains(".") // the implicit "*" rule: every single-label TLD
    }

    /// The registrable domain ("eTLD+1"): accounts.google.com → google.com, a.b.example.co.uk → example.co.uk,
    /// alex.github.io → alex.github.io. nil for a bare public suffix or an empty host.
    public static func registrableDomain(_ host: String) -> String? {
        let labels = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return nil }
        if labels == ["localhost"] { return "localhost" }
        // Walk from the full host toward the TLD; the first public suffix found is the longest one.
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            if isPublicSuffix(candidate) {
                return i == 0 ? nil : labels[(i - 1)...].joined(separator: ".")
            }
        }
        return nil
    }

    /// Same site for "save this sign-in?": login.example.com and app.example.com yes; example.com.evil.net no.
    public static func sameSite(_ a: String, _ b: String) -> Bool {
        guard let ra = registrableDomain(a), let rb = registrableDomain(b) else { return false }
        return ra == rb
    }

    /// WebAuthn: a page on `host` may use `rpID` only if rpID is host itself or a parent of it, and isn't a public suffix.
    public static func isValidRelyingParty(_ rpID: String, for host: String) -> Bool {
        let rp = rpID.lowercased(), h = host.lowercased()
        guard h == rp || h.hasSuffix("." + rp) else { return false }
        if rp == "localhost" { return true }
        return !isPublicSuffix(rp)
    }
}
