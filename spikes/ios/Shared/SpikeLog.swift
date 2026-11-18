import DeadboltCore
import Foundation

/// Results log in the App Group container, written by both the app and the extension,
/// so the app can show (and you can copy) what happened inside the extension.
/// Never logs secrets: fingerprints and timings only.
enum SpikeLog {
    static let url: URL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.osborne.deadbolt.spike")!
        .appendingPathComponent("spike-log.txt")

    static func write(_ message: String, file: String = #fileID) {
        let who = Bundle.main.bundleIdentifier?.hasSuffix(".autofill") == true ? "ext" : "app"
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(who)] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    static func clear() { try? FileManager.default.removeItem(at: url) }

    static var deviceSummary: String {
        var sys = utsname()
        uname(&sys)
        let model = withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "\(model), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}

/// Argon2id timing and memory at several sizes. Logs *before* each run, so if iOS kills the
/// extension for using too much memory the log shows which size did it.
enum Argon2Bench {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running = false

    /// One run at a time: overlapping runs make the memory numbers meaningless.
    static func run(sizesMiB: [Int] = [32, 64, 128]) -> [String] {
        lock.lock()
        if running { lock.unlock(); SpikeLog.write("argon2 bench already running, ignored tap"); return [] }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        SpikeLog.write("argon2 bench on \(SpikeLog.deviceSummary), footprint before \(footprintMiB()) MiB")
        var results: [String] = []
        for mib in sizesMiB {
            SpikeLog.write("argon2 starting \(mib) MiB × 3 passes…")
            let params = KDFParams.fresh(opsLimit: 3, memLimitBytes: mib << 20)
            let start = Date()
            do {
                _ = try PasswordKDF.deriveKEK(password: "copper-lantern-orbit-maple", params: params)
                let line = String(format: "argon2 %d MiB: %.0f ms, peak footprint %d MiB", mib, Date().timeIntervalSince(start) * 1000, footprintMiB(peak: true))
                SpikeLog.write(line)
                results.append(line)
            } catch {
                SpikeLog.write("argon2 \(mib) MiB FAILED: \(error)")
                results.append("\(mib) MiB failed")
            }
        }
        return results
    }

    /// The number iOS uses to decide whether to kill an extension.
    static func footprintMiB(peak: Bool = false) -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int((peak ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint) >> 20)
    }
}
