import Foundation

/// The vault file shared by the app and its AutoFill extension (different processes, same App Group file).
/// Every change is read-modify-write under an NSFileCoordinator, so a save from the extension can't
/// overwrite a change the app made a moment earlier.
public final class VaultStore: @unchecked Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The App Group location used by the app and the extension.
    public static func shared(appGroup: String) -> VaultStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            .map { VaultStore(url: $0.appendingPathComponent("Vault/vault.json")) }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func read() throws -> VaultFile {
        var result: Result<VaultFile, Error> = .failure(DeadboltError.malformed)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try VaultFile.read(from: u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    public func write(_ file: VaultFile) throws {
        try coordinatedWrite { _ in file }
    }

    /// Re-reads the latest file, decrypts, applies `change`, re-seals and writes — all under one write lock.
    @discardableResult
    public func mutate<T>(key: VaultKey, _ change: (inout Vault) throws -> T) throws -> (Vault, T) {
        var output: (Vault, T)?
        try coordinatedWrite { current in
            guard var file = current else { throw DeadboltError.malformed }
            var vault = try file.open(key: key)
            let value = try change(&vault)
            try file.update(vault, key: key)
            output = (vault, value)
            return file
        }
        return output!
    }

    private func coordinatedWrite(_ body: (VaultFile?) throws -> VaultFile) throws {
        var thrown: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            do {
                let current = FileManager.default.fileExists(atPath: u.path) ? try VaultFile.read(from: u) : nil
                try body(current).write(to: u)
            } catch { thrown = error }
        }
        if let coordError { throw coordError }
        if let thrown { throw thrown }
    }
}
