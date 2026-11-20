import SwiftUI

struct RootView: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .loading: Color.clear
            case .locked: UnlockView()
            case .noVault, .unlocked:
                if session.state == .noVault || !session.onboardingFinished { OnboardingView() } else {
                    #if os(macOS)
                    MacMainView()
                    #else
                    MainView()
                    #endif
                }
            }
        }
        .background(DB.ground)
        .preferredColorScheme(.dark)
        .tint(DB.brass)
        .modifier(ToastOverlay())
        .sheet(item: Binding(get: { session.state == .unlocked ? session.editTarget : nil },
                             set: { session.editTarget = $0 })) { target in
            if let login = session.vault.login(target.id) {
                if login.isCodeOnly {
                    CodeEntrySheet(original: login)
                } else {
                #if os(macOS)
                MacEditSheet(original: login)
                #else
                EditLoginView(original: login)
                #endif
                }
            }
        }
    }
}

struct MainView: View {
    @Environment(VaultSession.self) private var session

    var body: some View {
        TabView {
            NavigationStack { VaultListView() }
                .tabItem { Label("Vault", systemImage: "lock.rectangle.stack") }
            #if os(iOS)
            NavigationStack { CodesView() }
                .tabItem { Label("Codes", systemImage: "clock.badge.checkmark") }
            #endif
            NavigationStack { DevicesView() }
                .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .ownerCheckSheet(session)   // master-password fallback for Face ID checks on cards, identities and notes
    }
}
