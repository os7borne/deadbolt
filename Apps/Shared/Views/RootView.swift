import SwiftUI

struct RootView: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .loading: Color.clear
            case .locked: UnlockView()
            case .noVault, .unlocked:
                if session.state == .noVault || !session.onboardingFinished { OnboardingView() } else { MainView() }
            }
        }
        .background(DB.ground)
        .preferredColorScheme(.dark)
        .tint(DB.brass)
        .modifier(ToastOverlay())
    }
}

struct MainView: View {
    var body: some View {
        TabView {
            NavigationStack { VaultListView() }
                .tabItem { Label("Vault", systemImage: "lock.rectangle.stack") }
            NavigationStack { GeneratorView() }
                .tabItem { Label("Generator", systemImage: "wand.and.stars") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
