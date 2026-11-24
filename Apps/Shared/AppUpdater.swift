import SwiftUI
#if DIRECT_DISTRIBUTION
import Sparkle
#endif

/// Self-updates for the Mac app people download from deadbolt.osborne.vc (target `DeadboltMac`, built with DIRECT_DISTRIBUTION).
/// Every other target compiles the stubs below: `isAvailable` is false and the Settings rows hide themselves.
///
/// How an update goes: Sparkle checks the appcast hourly, downloads a newer zip (EdDSA-signed, notarized) in the background and,
/// with "Install updates automatically" on, installs it by itself, but only at a quiet moment (`isQuiet`): no sheet open in
/// Deadbolt, and either another app in front or 2 minutes without a key or click. With the switch off, the update waits in
/// Settings › General › Updates until Install and restart is pressed. Updates are accepted only if signed with our EdDSA key.
@MainActor @Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private(set) var status = ""
    private(set) var lastChecked: Date?
    private(set) var updateVersion: String?
    private(set) var checking = false

    #if DIRECT_DISTRIBUTION
    static let isAvailable = true
    private var controller: SPUStandardUpdaterController!
    /// Sparkle hands us this when an update is downloaded and waiting; calling it installs and relaunches now.
    private var installNow: (() -> Void)?
    private var quietTimer: Timer?
    private var started = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
        lastChecked = controller.updater.lastUpdateCheckDate
        refreshStatus()
    }

    var automatic: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            controller.updater.automaticallyDownloadsUpdates = newValue
            controller.updater.automaticallyChecksForUpdates = true
            refreshStatus()
        }
    }

    func checkNow() {
        checking = true
        status = "Checking…"
        NSApp.activate(ignoringOtherApps: true)   // Deadbolt has no Dock icon; Sparkle's own alert must not open behind other apps
        controller.checkForUpdates(nil)
    }

    /// Install the downloaded update right now (the "Install and restart" button).
    func installPending() { installNow?() }
    var hasPending: Bool { installNow != nil }

    private func refreshStatus() {
        if let v = updateVersion {
            status = installNow != nil ? "Deadbolt \(v) is ready" : "Deadbolt \(v) is available"
        } else if checking {
            status = "Checking…"
        } else if let d = lastChecked {
            status = "Up to date · checked \(d.formatted(date: .abbreviated, time: .shortened))"
        } else {
            status = "Not checked yet"
        }
    }

    // MARK: quiet moments

    private func startQuietTimer() {
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.installIfQuiet() }
        }
    }

    private func installIfQuiet() {
        guard let installNow, automatic, isQuiet else { return }
        quietTimer?.invalidate()
        self.installNow = nil
        installNow()
    }

    /// Restarting would lose an unsaved edit, so never while a sheet (an edit form, a dialog) is open in Deadbolt.
    private var isBusy: Bool { NSApp.windows.contains { $0.attachedSheet != nil } }

    private var isQuiet: Bool {
        if isBusy { return false }
        if !NSApp.isActive { return true }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle >= 120
    }
    #else
    static let isAvailable = false
    func start() {}
    var automatic: Bool { get { false } set {} }
    func checkNow() {}
    func installPending() {}
    var hasPending: Bool { false }
    #endif
}

#if DIRECT_DISTRIBUTION
extension AppUpdater: SPUUpdaterDelegate {
    /// Testing only: a process started from a terminal with DEADBOLT_FEED_URL set reads that appcast instead of the real one
    /// (updates are still accepted only if signed with our EdDSA key). Launching the app normally never has it.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["DEADBOLT_FEED_URL"]
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            updateVersion = version
            checking = false
            refreshStatus()
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            updateVersion = nil
            checking = false
            lastChecked = Date()
            refreshStatus()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor in
            checking = false
            // "You're up to date" arrives as an error code on some paths; only show real failures.
            if (error as NSError).code != 1001 { status = "Couldn’t check: \(message)" }
        }
    }

    /// The update is downloaded and would install when Deadbolt quits. Keep the install block: we run it at a quiet moment.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        // Sparkle calls this and expects the block back on the main thread.
        nonisolated(unsafe) let block = immediateInstallationBlock
        Task { @MainActor in
            installNow = block
            updateVersion = item.displayVersionString
            refreshStatus()
            startQuietTimer()
            installIfQuiet()
        }
        return true
    }
}
#endif

#if os(macOS)
/// Settings › General › Updates (Mac, downloaded build only).
struct UpdatesRows: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        if AppUpdater.isAvailable {
            MacFormRow("Updates") {
                Toggle("Install updates automatically", isOn: Binding(get: { updater.automatic }, set: { updater.automatic = $0 }))
                    .toggleStyle(.checkbox)
                MacFormNote("Downloads in the background and installs when you’re not in the middle of something.")
                HStack(spacing: 10) {
                    Text(updater.status).font(.db(12)).foregroundStyle(DB.text2)
                    if updater.hasPending {
                        Button("Install and Restart") { updater.installPending() }.buttonStyle(MacButtonStyle(prominent: true))
                    } else {
                        Button("Check for Updates") { updater.checkNow() }.buttonStyle(MacButtonStyle()).disabled(updater.checking)
                    }
                }
            }
        }
    }
}
#endif
