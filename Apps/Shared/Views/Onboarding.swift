import DeadboltCore
import SwiftUI

/// First run: master password → vault created → 24 words → Face ID → done.
struct OnboardingView: View {
    @Environment(VaultSession.self) private var session
    @State private var step = Step.welcome
    @State private var password = ""
    @State private var confirm = ""
    @State private var recovery: RecoveryKey?
    @State private var error: String?
    @State private var restoring = false
    @State private var joining = false
    @State private var removedNotice = Prefs.removedNotice

    enum Step: Int { case welcome = 0, password, words, biometrics, system }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if step != .welcome { progress.padding(.bottom, 14) }
            switch step {
            case .welcome: welcome
            case .password: passwordStep
            case .words: wordsStep
            case .biometrics: biometricsStep
            case .system: systemStep
            }
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 32)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(DB.ground)
        .foregroundStyle(DB.text)
        .animation(.snappy, value: step)
        // Resuming an interrupted setup (vault exists and is unlocked): go straight to the words.
        .task {
            guard session.state == .unlocked, step.rawValue < Step.words.rawValue else { return }
            step = Prefs.joinedByLink ? .biometrics : .words // a linked device already has its Recovery Kit elsewhere
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { i in
                    Capsule().fill(i <= step.rawValue ? DB.brass : DB.lineStrong).frame(height: 4)
                }
            }
            Text("Step \(step.rawValue) of 4").font(.db(13)).foregroundStyle(DB.text3)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("Step \(step.rawValue) of 4")
    }

    // MARK: steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            DeadboltMark(size: 112)
            Text("Deadbolt").font(.db(34, .bold))
            Text("Your passwords and passkeys, encrypted on your own devices. No account. No server copy.")
                .font(.db(16)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            Spacer()
            if let removedNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill").foregroundStyle(DB.brass)
                    Text(removedNotice).font(.db(13)).foregroundStyle(DB.text2)
                    Spacer(minLength: 0)
                    Button { Prefs.removedNotice = nil; self.removedNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(DB.text3).accessibilityLabel("Dismiss")
                }
                .padding(14).background(DB.brassWash, in: RoundedRectangle(cornerRadius: 14))
            }
            Button("Create my vault") { step = .password }.buttonStyle(PrimaryButtonStyle())
            Button("I already use Deadbolt") { joining = true }.buttonStyle(SecondaryButtonStyle())
            Button("Restore from a backup") { restoring = true }
                .buttonStyle(.plain).font(.db(15)).foregroundStyle(DB.text2).frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $restoring) { RestoreView(onRestored: { step = .biometrics }) }
        .sheet(isPresented: $joining) { JoinView() }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a master password").font(.db(28, .bold))
            Text("It unlocks Deadbolt when Face ID can’t. Nobody can reset it, so pick something you’ll remember — a few random words work well.")
                .font(.db(15)).foregroundStyle(DB.text2).lineSpacing(2)
            SecureField("Master password", text: $password).textContentType(.newPassword).fieldStyle()
            SecureField("Type it again", text: $confirm).textContentType(.newPassword).fieldStyle()
            Button {
                let p = PasswordGenerator.passphrase()
                password = p; confirm = p
                Clipboard.copySecret(p)
                session.show("Passphrase suggested", "Copied for 60 s — write it down somewhere safe")
            } label: { Label("Suggest a passphrase", systemImage: "wand.and.stars") }
                .buttonStyle(.plain).font(.db(15, .semibold)).foregroundStyle(DB.brass)
            if !password.isEmpty { Text(passwordHint).font(.db(13)).foregroundStyle(passwordOK ? DB.good : DB.text3) }
            if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
            Spacer()
            Button {
                Task { await createVault() }
            } label: {
                if session.busy { ProgressView().tint(DB.onBrass) } else { Text("Create vault") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!passwordOK || session.busy)
            .opacity(passwordOK ? 1 : 0.5)
        }
    }

    private var wordsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save your Recovery Kit").font(.db(28, .bold))
            Text("These 24 words open your vault if every device is lost. Nobody else has them. Write them down and keep them away from your devices.")
                .font(.db(15)).foregroundStyle(DB.text2).lineSpacing(2)
            if let words = recovery?.words ?? session.vault.recoveryPhrase?.split(separator: " ").map(String.init) {
                RecoveryWordsGrid(words: words)
            }
            Spacer()
            Button("I’ve written them down") { step = .biometrics }.buttonStyle(PrimaryButtonStyle())
            Text("You can see them again any time in Settings › Recovery Kit.")
                .font(.db(13)).foregroundStyle(DB.text3).frame(maxWidth: .infinity)
        }
    }

    private var biometricsStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: KeychainKey.biometryName == "Touch ID" ? "touchid" : "faceid")
                .font(.system(size: 54, weight: .light)).foregroundStyle(DB.brass)
            Text("Unlock with \(KeychainKey.biometryName)?").font(.db(26, .bold))
            Text("Faster than typing your master password. Deadbolt will still ask for the password every 14 days.")
                .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            Spacer()
            if !KeychainKey.biometryAvailable {
                Text("\(KeychainKey.biometryName) isn’t set up on this device. You can turn it on later in Settings.")
                    .font(.db(13)).foregroundStyle(DB.text3).multilineTextAlignment(.center)
            }
            Button("Use \(KeychainKey.biometryName)") {
                Task {
                    // A real check: this is when the system asks for permission to use Face ID.
                    guard await KeychainKey.confirmOwner(reason: "Turn on \(KeychainKey.biometryName) for Deadbolt") else {
                        session.show("\(KeychainKey.biometryName) wasn’t turned on", "You can do it later in Settings", style: .error)
                        return
                    }
                    do { try session.setBiometrics(true); session.show("\(KeychainKey.biometryName) is on") }
                    catch { session.show("Couldn’t turn on \(KeychainKey.biometryName)", error.friendly, style: .error) }
                    step = .system
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!KeychainKey.biometryAvailable)
            Button("Not now") { step = .system }.buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }

    #if os(iOS)
    @State private var autofillOn = false

    private var systemStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "key.viewfinder").font(.system(size: 54, weight: .light)).foregroundStyle(DB.brass)
            Text("Turn on AutoFill").font(.db(26, .bold))
            Text("So Deadbolt can fill passwords and passkeys in Safari and apps, and offer to save new ones.")
                .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 300)
            if autofillOn {
                Label("AutoFill is on", systemImage: "checkmark.circle.fill").font(.db(15, .semibold)).foregroundStyle(DB.good)
            }
            Spacer()
            if autofillOn {
                Button("Finish") { finish() }.buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Turn on AutoFill") {
                    Task {
                        autofillOn = await SystemSetup.requestAutofill()
                        if autofillOn { session.show("AutoFill is on") }
                        else { session.show("AutoFill is still off", "Use Open Settings, or turn it on later", style: .error) }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                Button("Open Settings") { SystemSetup.openAutofillSettings() }.buttonStyle(SecondaryButtonStyle())
                Button("Later") { finish() }.buttonStyle(.plain).font(.db(15)).foregroundStyle(DB.text2).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .task { autofillOn = await SystemSetup.autofillEnabled() }
    }
    #else
    @State private var atLogin = SystemSetup.opensAtLogin

    private var systemStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "menubar.rectangle").font(.system(size: 54, weight: .light)).foregroundStyle(DB.brass)
            Text("Open Deadbolt at login?").font(.db(26, .bold))
            Text("Deadbolt lives in the menu bar. Starting it at login keeps your vault one click away.")
                .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
            Button("Open at login") {
                do { try SystemSetup.setOpensAtLogin(true); session.show("Deadbolt will open at login") }
                catch { session.show("Couldn’t turn that on", error.friendly, style: .error) }
                finish()
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Not now") { finish() }.buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
    #endif

    // MARK: logic

    private var passwordOK: Bool { password.count >= 10 && password == confirm }
    private var passwordHint: String {
        if password.count < 10 { return "At least 10 characters (\(password.count) so far)" }
        if password != confirm { return confirm.isEmpty ? "Now type it again" : "The two don’t match yet" }
        return "Looks good"
    }

    private func createVault() async {
        error = nil
        do {
            recovery = try await session.create(password: password)
            password = ""; confirm = ""
            session.show("Vault created", "Encrypted on this device")
            step = .words
        } catch {
            self.error = error.friendly
            Haptics.error()
        }
    }

    private func finish() {
        Prefs.joinedByLink = false
        session.onboardingFinished = true
    }
}

struct RecoveryWordsGrid: View {
    let words: [String]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1)").font(.dbMono(11)).foregroundStyle(DB.text3).frame(width: 18, alignment: .trailing)
                    Text(w).font(.dbMono(14)).foregroundStyle(DB.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(Color(hex: 0x1B1D23), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DB.line))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func fieldStyle() -> some View {
        self.font(.db(16)).foregroundStyle(DB.text)
            .padding(.horizontal, 16).frame(height: 52)
            .background(DB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DB.lineStrong))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(.plain)
    }
}
