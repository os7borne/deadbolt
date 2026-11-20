import DeadboltCore
import SwiftUI

struct UnlockView: View {
    @Environment(VaultSession.self) private var session
    @State private var password = ""
    @State private var error: String?
    @State private var showRecovery = false
    @State private var attempts = 0
    @State private var prompting = false
    @State private var cancelled = false
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            DeadboltMark(size: 104)
            Text("Deadbolt is locked").font(.db(28, .bold)).padding(.top, 32).padding(.bottom, 8)
            Text(subtitle).font(.db(16)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            Spacer()

            if session.biometricUnlockAllowed {
                Button { Task { await biometric() } } label: {
                    Label(cancelled ? "Try \(KeychainKey.biometryName) again" : "Unlock with \(KeychainKey.biometryName)",
                          systemImage: KeychainKey.biometryName == "Touch ID" ? "touchid" : "faceid")
                }
                .disabled(prompting)
                .buttonStyle(PrimaryButtonStyle(height: 58))
                .padding(.bottom, 14)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(session.biometricUnlockAllowed ? "Or use your master password" : "Master password")
                    .font(.db(13)).foregroundStyle(DB.text3).padding(.leading, 4)
                HStack(spacing: 8) {
                    SecureField("Master password", text: $password)
                        .textContentType(.password).focused($focused).onSubmit { Task { await unlock() } }
                        .fieldStyle()
                    Button { Task { await unlock() } } label: {
                        Group {
                            if session.busy { ProgressView() } else { Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)) }
                        }
                        .frame(width: 52, height: 52)
                        .background(DB.control, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DB.lineStrong))
                    }
                    .buttonStyle(.plain).foregroundStyle(DB.text)
                    .disabled(password.isEmpty || session.busy)
                    .accessibilityLabel("Unlock with master password")
                }
                .modifier(Shake(amount: CGFloat(attempts)))
                if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger).padding(.leading, 4) }
            }

            HStack(spacing: 4) {
                Text("Forgot it?").foregroundStyle(DB.text3)
                Button("Use your Recovery Kit") { showRecovery = true }.buttonStyle(.plain).foregroundStyle(DB.brass)
            }
            .font(.db(13)).padding(.top, 22)
        }
        .padding(.horizontal, 28).padding(.bottom, 40)
        .frame(maxWidth: 480).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DB.ground).foregroundStyle(DB.text)
        // Biometrics is the default: start it on its own whenever this screen is shown or the app comes back.
        .task { await autoUnlock() }
        .onChange(of: phase) { _, new in if new == .active { Task { await autoUnlock() } } }
        .sheet(isPresented: $showRecovery) { RecoverView() }
    }

    private var subtitle: String {
        if session.biometricsEnabled && !session.biometricUnlockAllowed {
            return "It’s been a while — enter your master password once to keep \(KeychainKey.biometryName) working."
        }
        return "Your vault stays encrypted on this device until you unlock it."
    }

    private func unlock() async {
        guard !password.isEmpty else { return }
        error = nil
        do {
            try await session.unlock(password: password)
            password = ""
        } catch {
            self.error = error.friendly
            withAnimation(.default) { attempts += 1 }
            Haptics.error()
        }
    }

    private func autoUnlock() async {
        guard session.state == .locked, !prompting else { return }
        guard session.biometricUnlockAllowed else { focused = true; return } // master-password check is due
        cancelled = false
        try? await Task.sleep(for: .milliseconds(250)) // let the screen settle so the prompt isn't refused
        await biometric()
    }

    private func biometric() async {
        guard !prompting else { return }
        prompting = true
        defer { prompting = false }
        error = nil
        do {
            let unlocked = try await session.unlockWithBiometrics()
            if !unlocked { cancelled = true; focused = true } // cancelled: offer the password, don't nag
        } catch {
            self.error = error.friendly
            focused = true
        }
    }
}

/// Recovery words → new master password.
struct RecoverView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @State private var newPassword = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recover your vault").font(.db(26, .bold))
            Text("Type your 24 recovery words, then choose a new master password.").font(.db(15)).foregroundStyle(DB.text2)
            TextEditor(text: $phrase)
                .font(.dbMono(15)).scrollContentBackground(.hidden)
                .padding(10).frame(height: 140)
                .background(DB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DB.lineStrong))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField("New master password (10+ characters)", text: $newPassword).textContentType(.newPassword).fieldStyle()
            if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
            Spacer()
            Button {
                Task {
                    do {
                        try await session.unlock(recoveryPhrase: phrase, newPassword: newPassword)
                        session.show("Vault recovered", "Your new master password is set")
                        dismiss()
                    } catch { self.error = error.friendly; Haptics.error() }
                }
            } label: { if session.busy { ProgressView().tint(DB.onBrass) } else { Text("Recover") } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(newPassword.count < 10 || session.busy)
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(20).background(DB.ground).foregroundStyle(DB.text)
        .presentationBackground(DB.ground)
    }
}

struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}

struct ToastOverlay: ViewModifier {
    @Environment(VaultSession.self) private var session
    #if os(macOS)
    static let compact = true, alignment = Alignment.bottomTrailing   // Mac v2: small, above the status bar
    #else
    static let compact = false, alignment = Alignment.bottom
    #endif
    func body(content: Content) -> some View {
        content.overlay(alignment: Self.alignment) {
            if let toast = session.toast {
                HStack(spacing: 12) {
                    Image(systemName: toast.style == .success ? "checkmark" : "exclamationmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(toast.style == .success ? DB.good : DB.danger)
                        .frame(width: 26, height: 26).background(DB.ground, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title).font(.db(Self.compact ? 13 : 15, .semibold))
                        if let d = toast.detail { Text(d).font(.db(Self.compact ? 12 : 13)).foregroundStyle(Color(hex: 0x4A4E57)) }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DB.ground)
                .padding(.horizontal, Self.compact ? 12 : 16).padding(.vertical, Self.compact ? 9 : 14)
                .background(DB.text, in: RoundedRectangle(cornerRadius: Self.compact ? 10 : 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                .fixedSize(horizontal: Self.compact, vertical: false)
                .padding(.horizontal, Self.compact ? 18 : 20).padding(.bottom, Self.compact ? 40 : 24)
                .frame(maxWidth: Self.compact ? nil : 480)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2.4))
                    if session.toast?.id == toast.id { session.toast = nil }
                }
                .onTapGesture { session.toast = nil }
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.snappy, value: session.toast)
    }
}
