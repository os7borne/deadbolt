import AppKit
import DeadboltCore
import Foundation

/// The one vault session for the whole Mac app — menu bar, window and Chrome bridge all share it,
/// so they can never disagree about locked/unlocked. Also owns everything that locks the vault.
@MainActor
final class MacRuntime {
    static let shared = MacRuntime()

    /// Opens (or reopens) the main window. Set by the SwiftUI scene at launch; the browser bridge calls it for "Open Deadbolt".
    static var openMainWindow: (@MainActor () -> Void)?

    let session: VaultSession
    private(set) var bridge: BridgeServer!
    private var idleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?

    private init() {
        AppConfig.migrateMacStorageIfNeeded()   // before anything opens the vault
        session = VaultSession()
        bridge = BridgeServer(session: session)
        bridge.start()
        watchSystem()
        startIdleTimer()
        watchActivity()
        AppUpdater.shared.start()   // Sparkle: checks hourly, installs at a quiet moment (no-op in builds without an updater)
    }

    /// Typing and clicking in Deadbolt's own windows count as use. Without this, filling in a long form never reset the idle timer,
    /// and the vault locked (closing the form) while the person was still typing.
    private func watchActivity() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { if self?.session.state == .unlocked { self?.session.touch() } }
            return event
        }
    }

    /// Sleep, screen lock, display sleep and fast user switching all lock the vault — window open or not.
    private func watchSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.lock() }
            })
        }
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.lock() }
        })
    }

    /// Locks after "Lock after" (Settings) with no use from the menu bar, window or Chrome. At least a minute on Mac.
    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let s = self?.session, s.state == .unlocked else { return }
                if LockPolicy.shouldLock(lastActivity: s.lastActivity, now: Date(), lockAfter: Prefs.lockAfter) { s.lock() }
            }
        }
    }
}
