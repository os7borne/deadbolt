import AppKit
import DeadboltCore
import SwiftUI

/// Menu-bar app: always running, quick search + copy from the menu bar, full vault in a window.
@main
struct DeadboltMacApp: App {
    @State private var session = VaultSession()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel().environment(session)
        } label: {
            Image("MenuBarIcon")
                .opacity(session.state == .unlocked ? 1 : 0.55)   // dimmed while locked
                .accessibilityLabel(session.state == .unlocked ? "Deadbolt, unlocked" : "Deadbolt, locked")
        }
        .menuBarExtraStyle(.window)

        Window("Deadbolt", id: "main") {
            RootView()
                .environment(session)
                .frame(minWidth: 760, minHeight: 560)
                .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in session.lock() }
                .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in session.lock() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 700)
    }
}

/// The menu-bar popover from the design: search, copy password / username, open the full window.
struct MenuBarPanel: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DeadboltMark(size: 22)
                Text("Deadbolt").font(.db(15, .bold))
                Spacer()
                if session.state == .unlocked {
                    Button { session.lock() } label: { Image(systemName: "lock") }
                        .buttonStyle(.plain).frame(width: 30, height: 30).background(DB.control, in: RoundedRectangle(cornerRadius: 8))
                        .help("Lock now")
                }
            }
            .padding(14)

            switch session.state {
            case .unlocked: unlocked
            case .noVault:
                prompt("Set up your vault in the Deadbolt window.") { open() }
            default: locked
            }

            Divider().overlay(DB.line)
            HStack {
                Button("Open Deadbolt") { open() }.buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(DB.text3)
            }
            .font(.db(13)).foregroundStyle(Color(hex: 0xC9CCD2)).padding(.horizontal, 14).frame(height: 40)
        }
        .frame(width: 380)
        .background(DB.raised).foregroundStyle(DB.text)
        .preferredColorScheme(.dark)
        .modifier(ToastOverlay())
    }

    private var unlocked: some View {
        VStack(spacing: 8) {
            TextField("Search", text: $query).focused($focused).textFieldStyle(.plain).font(.db(14))
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color(hex: 0x1A1C22), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? DB.brass : DB.lineStrong))
                .padding(.horizontal, 14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(results) { l in
                        HStack(spacing: 12) {
                            SiteTile(title: l.title, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.title).font(.db(14, .semibold))
                                Text(l.username).font(.db(12)).foregroundStyle(DB.text2).lineLimit(1)
                            }
                            Spacer()
                            Button("User") { Clipboard.copySecret(l.username); session.show("Username copied") }
                                .buttonStyle(.plain).font(.db(11)).padding(.horizontal, 6).frame(height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0x343843)))
                            if !l.password.isEmpty {
                                Button("Password") {
                                    Clipboard.copySecret(l.password)
                                    try? session.mutate { $0.markUsed(l.id) }
                                    session.show("Password copied", "Clipboard clears in 60 seconds")
                                }
                                .buttonStyle(.plain).font(.db(11, .semibold)).foregroundStyle(DB.onBrass)
                                .padding(.horizontal, 6).frame(height: 22).background(DB.brass, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        .padding(.horizontal, 10).frame(height: 54)
                    }
                    if results.isEmpty {
                        Text(query.isEmpty ? "No logins yet" : "Nothing matches").font(.db(13)).foregroundStyle(DB.text2).padding(20)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 340)
        }
        .onAppear { focused = true }
    }

    private var locked: some View {
        VStack(spacing: 10) {
            if session.biometricUnlockAllowed {
                Button { Task { try? await session.unlockWithBiometrics() } } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
                    .buttonStyle(PrimaryButtonStyle(height: 40))
            }
            SecureField("Master password", text: $password).textFieldStyle(.plain).font(.db(14))
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color(hex: 0x1A1C22), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit {
                    Task {
                        do { try await session.unlock(password: password); password = "" }
                        catch { self.error = error.friendly }
                    }
                }
            if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
        }
        .padding(.horizontal, 14).padding(.bottom, 14)
    }

    private func prompt(_ text: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Text(text).font(.db(13)).foregroundStyle(DB.text2)
            Button("Open Deadbolt", action: action).buttonStyle(PrimaryButtonStyle(height: 36))
        }
        .padding(14)
    }

    private var results: [LoginItem] {
        let q = query.lowercased()
        return session.vault.logins
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q) || $0.sites.contains { $0.contains(q) } }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            .prefix(30).map { $0 }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
