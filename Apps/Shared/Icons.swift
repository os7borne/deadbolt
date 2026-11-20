import CryptoKit
import Foundation
import Observation
import SwiftUI
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// Website icons, fetched through Deadbolt's own relay (`/v1/icon/<domain>`), never a third-party service.
/// Cached on disk for 30 days (in the App Group on iOS, so the AutoFill sheet shares them); misses retried after 3.
/// Off in Settings › Privacy means no requests at all.
@MainActor @Observable
final class IconStore {
    static let shared = IconStore()

    private(set) var images: [String: PlatformImage] = [:]
    @ObservationIgnored private var inflight = Set<String>()
    @ObservationIgnored private var misses = Set<String>()
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let missAge: TimeInterval = 3 * 24 * 3600

    static var enabled: Bool {
        get { AppConfig.defaults.object(forKey: "showIcons") as? Bool ?? true }
        set { AppConfig.defaults.set(newValue, forKey: "showIcons") }
    }

    private var dir: URL {
        let base = AppConfig.store.url.deletingLastPathComponent().deletingLastPathComponent()
        return base.appendingPathComponent("Icons", isDirectory: true)
    }

    private func file(_ site: String, miss: Bool = false) -> URL {
        let name = SHA256.hash(data: Data(site.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name + (miss ? ".none" : ".img"))
    }

    func image(for site: String) -> PlatformImage? { images[site] }

    /// Loads from disk or the relay. Safe to call repeatedly.
    func load(_ site: String) async {
        guard Self.enabled, images[site] == nil, !inflight.contains(site), !misses.contains(site) else { return }
        let fm = FileManager.default
        let hit = file(site), miss = file(site, miss: true)
        if let attrs = try? fm.attributesOfItem(atPath: hit.path), let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < Self.maxAge, let data = try? Data(contentsOf: hit), let img = PlatformImage(data: data) {
            images[site] = img
            return
        }
        if let attrs = try? fm.attributesOfItem(atPath: miss.path), let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < Self.missAge {
            misses.insert(site)
            return
        }
        inflight.insert(site)
        defer { inflight.remove(site) }
        guard let url = URL(string: "/v1/icon/\(site)", relativeTo: SyncConfig.relay) else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var d = dir; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? d.setResourceValues(rv) // reveals your sites
            if (response as? HTTPURLResponse)?.statusCode == 200, let img = PlatformImage(data: data) {
                try? data.write(to: hit, options: .atomic)
                images[site] = img
            } else if (response as? HTTPURLResponse)?.statusCode == 404 {
                try? Data().write(to: miss, options: .atomic)
                misses.insert(site)
            }
        } catch {
            // Offline: the letter tile stays; try again next time.
        }
    }

    /// Turning icons off forgets everything fetched so far.
    func clear() {
        images = [:]
        misses = []
        try? FileManager.default.removeItem(at: dir)
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}
