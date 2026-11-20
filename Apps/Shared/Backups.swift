import DeadboltCore
import Foundation
import SwiftUI

/// Automatic encrypted backups to a folder the owner picks (iCloud Drive, a USB drive, a NAS…).
/// Backups are sealed with the recovery key, so they open only with the 24 words.
@MainActor
enum Backups {
    static let keep = 10                       // newest files kept in the folder
    static let interval: TimeInterval = 7 * 24 * 3600

    static var folderName: String? {
        resolveFolder().map { $0.lastPathComponent }
    }

    static var lastBackup: Date? {
        get { AppConfig.defaults.object(forKey: "lastBackupAt") as? Date }
        set { AppConfig.defaults.set(newValue, forKey: "lastBackupAt") }
    }

    /// Remembers a folder chosen in the system picker (security-scoped bookmark).
    static func choose(folder url: URL) throws {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        AppConfig.defaults.set(data, forKey: "backupFolderBookmark")
    }

    static func forgetFolder() { AppConfig.defaults.removeObject(forKey: "backupFolderBookmark") }

    private static func resolveFolder() -> URL? {
        guard let data = AppConfig.defaults.data(forKey: "backupFolderBookmark") else { return nil }
        var stale = false
        #if os(macOS)
        let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        if stale, let url { try? choose(folder: url) }
        return url
    }

    /// Writes a backup now. Returns the file written.
    @discardableResult
    static func write(_ vault: Vault) throws -> URL {
        guard let folder = resolveFolder() else { throw BackupError.noFolder }
        guard let phrase = vault.recoveryPhrase else { throw BackupError.noRecoveryKey }
        let data = try BackupFile.make(vault, recoveryKey: RecoveryKey(phrase: phrase)).encoded()
        let ok = folder.startAccessingSecurityScopedResource()
        defer { if ok { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(BackupFile.fileName(for: Date()))
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { thrown = error }
        }
        if let e = coordError ?? thrown { throw e }
        prune(folder)
        lastBackup = Date()
        return url
    }

    /// Backs up if a folder is set and the last backup is older than a week (or `force`).
    /// Failures are reported but never block what the person was doing.
    static func runIfDue(_ vault: Vault, force: Bool = false, session: VaultSession) {
        guard resolveFolder() != nil, !vault.logins.isEmpty else { return }
        if !force, let last = lastBackup, Date().timeIntervalSince(last) < interval { return }
        do { try write(vault) }
        catch { session.show("Backup didn’t run", error.friendly, style: .error) }
    }

    private static func prune(_ folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let ours = files.filter { $0.lastPathComponent.hasPrefix("Deadbolt Backup ") && $0.pathExtension == BackupFile.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // names sort by date
        for old in ours.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    /// Reads a backup file picked in the system file picker.
    static func read(_ url: URL) throws -> BackupFile {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try BackupFile.read(Data(contentsOf: url))
    }
}

enum BackupError: LocalizedError {
    case noFolder, noRecoveryKey
    var errorDescription: String? {
        switch self {
        case .noFolder: "Choose a backup folder first."
        case .noRecoveryKey: "This vault has no recovery words stored, so it can’t make backups."
        }
    }
}

// MARK: printable Recovery Kit

@MainActor
enum RecoveryKitPDF {
    /// Renders the kit to a temporary PDF (US Letter). The caller deletes it when done.
    static func make(phrase: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Deadbolt Recovery Kit.pdf")
        try? FileManager.default.removeItem(at: url)
        let renderer = ImageRenderer(content: RecoveryKitPage(words: phrase.split(separator: " ").map(String.init), date: Date()))
        renderer.proposedSize = ProposedViewSize(width: 612, height: 792)
        var failed = true
        renderer.render { size, draw in
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            failed = false
        }
        if failed { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// The printed page: black on white so it photocopies and survives a cheap printer.
struct RecoveryKitPage: View {
    let words: [String]
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image("Logo").resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Deadbolt Recovery Kit").font(.system(size: 22, weight: .bold))
                    Text("Created \(date.formatted(date: .long, time: .omitted))").font(.system(size: 11)).foregroundStyle(.gray)
                }
            }
            Text("These 24 words open your Deadbolt vault if you lose every device. Anyone who has them and one of your backup files can read your passwords. Keep this page somewhere safe, away from your devices. Never photograph it or store it online.")
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.gray).frame(width: 16, alignment: .trailing)
                        Text(w).font(.system(size: 14, weight: .medium, design: .monospaced))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.5)))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("To recover").font(.system(size: 13, weight: .semibold))
                Text("1. Install Deadbolt on a new device and choose “Restore from a backup”.\n2. Pick your most recent backup file (named “Deadbolt Backup …”).\n3. Type these 24 words, then choose a new master password.")
                    .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Master password (optional — only if this page is kept somewhere very safe)").font(.system(size: 10)).foregroundStyle(.gray)
                Rectangle().fill(.gray.opacity(0.6)).frame(height: 1).padding(.top, 22)
            }
            Spacer()
            Text("deadbolt.osborne.vc").font(.system(size: 10)).foregroundStyle(.gray)
        }
        .padding(48)
        .frame(width: 612, height: 792, alignment: .topLeading)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }
}
