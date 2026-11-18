import SwiftUI

@main
struct DeadboltApp: App {
    @State private var session = VaultSession()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                // Hide contents in the app switcher.
                .overlay { if phase != .active && session.state == .unlocked { PrivacyCover() } }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background: session.didEnterBackground()
            case .active: session.didBecomeActive()
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
