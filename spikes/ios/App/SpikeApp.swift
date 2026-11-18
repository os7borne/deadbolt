import AuthenticationServices
import SwiftUI

@main
struct SpikeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var log = SpikeLog.read()
    @State private var providerEnabled: Bool?
    @State private var site = "webauthn.io"
    @State private var user = "osborne"
    @State private var password = "test-password-123"
    @State private var counts = (logins: 0, passkeys: 0)

    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Turn on the provider") {
                    LabeledContent("AutoFill provider", value: providerEnabled.map { $0 ? "On" : "Off" } ?? "…")
                    Button("Ask iOS to turn it on") {
                        ASSettingsHelper.requestToTurnOnCredentialProviderExtension { on in
                            SpikeLog.write("requestToTurnOn → \(on)")
                            Task { await refresh() }
                        }
                    }
                    Button("Open AutoFill settings") { Task { try? await ASSettingsHelper.openCredentialProviderAppSettings() } }
                }

                Section("2 · Shared Keychain + Face ID") {
                    Button("Store test vault key behind Face ID (once)") { run { try SpikeStore.storeBiometricSecret() } }
                    Button("Read it here (Face ID)") {
                        Task {
                            do { SpikeLog.write("app read bio secret OK, fingerprint \(SpikeStore.fingerprint(try await SpikeStore.readBiometricSecret(reason: "Read the test vault key")))") }
                            catch { SpikeLog.write("app read bio secret FAILED: \(error)") }
                            await refresh()
                        }
                    }
                    Text("Then read it from the extension: Settings → General → AutoFill & Passwords → Deadbolt Spike → “Test Face ID”.").font(.footnote).foregroundStyle(.secondary)
                }

                Section("3 · Test login") {
                    TextField("site (domain)", text: $site).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("user", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("password", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save login + update QuickType") {
                        run { try SpikeStore.save(.init(site: site, user: user, password: password)) }
                        Task { await SpikeStore.syncIdentities(); await refresh() }
                    }
                    LabeledContent("Stored", value: "\(counts.logins) logins, \(counts.passkeys) passkeys")
                }

                Section("4 · Argon2id in the app (compare with the extension)") {
                    Button("Run 32 / 64 / 128 MiB") { Task.detached { _ = Argon2Bench.run(); await refresh() } }
                }

                Section {
                    Text(log.isEmpty ? "No entries yet" : log).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Refresh") { Task { await refresh() } }
                    ShareLink("Share log", item: log)
                    Button("Clear log", role: .destructive) { SpikeLog.clear(); Task { await refresh() } }
                    Button("Delete all spike data", role: .destructive) { SpikeStore.deleteAll(); Task { await refresh() } }
                } header: { Text("Results log (app + extension)") }
            }
            .navigationTitle("Deadbolt Spike")
            .task { await refresh() }
            .refreshable { await refresh() }
        }
    }

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { SpikeLog.write("ERROR \(error)") }
        Task { await refresh() }
    }

    @MainActor private func refresh() async {
        providerEnabled = await ASCredentialIdentityStore.shared.state().isEnabled
        counts = (SpikeStore.logins().count, SpikeStore.passkeys().count)
        log = SpikeLog.read()
    }
}
