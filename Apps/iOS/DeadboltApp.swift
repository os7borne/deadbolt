import SwiftUI
import UIKit

/// Owns the session so silent pushes (which arrive through the app delegate) and the UI share it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var session = VaultSession()

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        app.registerForRemoteNotifications()   // silent pushes need no permission prompt
        return true
    }

    func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        AppConfig.defaults.set(token.map { String(format: "%02x", $0) }.joined(), forKey: "pushToken")
    }

    func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// The relay says another device changed something. Unlocked: sync properly. Locked: fetch and queue the
    /// encrypted messages; they're merged at the next unlock (here or in the AutoFill sheet).
    @MainActor
    func application(_ app: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if session.state == .unlocked {
            await session.sync.syncNow()
            return .newData
        }
        return await SyncEngine.prefetch() ? .newData : .noData
    }
}

@main
struct DeadboltApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.session)
                // Hide contents in the app switcher.
                .overlay { if phase != .active && delegate.session.state == .unlocked { PrivacyCover() } }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background: delegate.session.didEnterBackground()
            case .active: delegate.session.didBecomeActive()
            default: break
            }
        }
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack { DB.ground.ignoresSafeArea(); DeadboltMark(size: 88) }
    }
}
