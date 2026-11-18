import DeadboltCore
import SwiftUI

struct GeneratorView: View {
    @Environment(VaultSession.self) private var session
    @State private var mode = 0
    @State private var length = 20.0
    @State private var symbols = true
    @State private var words = 5.0
    @State private var value = PasswordGenerator.password()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Kind", selection: $mode) { Text("Password").tag(0); Text("Passphrase").tag(1) }
                    .pickerStyle(.segmented)
                Text(value).font(.dbMono(22)).foregroundStyle(DB.text).multilineTextAlignment(.leading)
                    .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                    .padding(18).background(DB.surface, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(DB.line))
                Card {
                    if mode == 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Length \(Int(length))").font(.db(15))
                            Slider(value: $length, in: 12...40, step: 1).tint(DB.brass)
                        }
                        .padding(16)
                        CardDivider()
                        Toggle("Symbols", isOn: $symbols).tint(DB.brass).padding(.horizontal, 16).frame(minHeight: 52)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(Int(words)) words").font(.db(15))
                            Slider(value: $words, in: 4...8, step: 1).tint(DB.brass)
                        }
                        .padding(16)
                    }
                }
                HStack(spacing: 10) {
                    Button { regenerate(); Haptics.tap() } label: { Label("New", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(height: 54))
                    Button { Clipboard.copySecret(value); session.show("Copied", "Clipboard clears in 60 seconds") } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(PrimaryButtonStyle(height: 54))
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Generator")
        .onChange(of: mode) { regenerate() }
        .onChange(of: length) { regenerate() }
        .onChange(of: symbols) { regenerate() }
        .onChange(of: words) { regenerate() }
    }

    private func regenerate() {
        value = mode == 0 ? PasswordGenerator.password(.init(length: Int(length), symbols: symbols)) : PasswordGenerator.passphrase(words: Int(words))
    }
}

struct SettingsView: View {
    @Environment(VaultSession.self) private var session
    @State private var biometrics = Prefs.biometricsEnabled
    @State private var lockAfter = Prefs.lockAfter
    @State private var offerToSave = Prefs.offerToSave
    @State private var showAbout = false
    @State private var changingPassword = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    SectionLabel("Unlock")
                    Card {
                        Toggle(KeychainKey.biometryName, isOn: $biometrics).tint(DB.brass)
                            .disabled(!KeychainKey.biometryAvailable)
                            .padding(.horizontal, 16).frame(minHeight: 52)
                        CardDivider()
                        HStack {
                            Text("Lock after").font(.db(16))
                            Spacer()
                            Picker("Lock after", selection: $lockAfter) {
                                Text("Immediately").tag(TimeInterval(0)); Text("1 minute").tag(TimeInterval(60))
                                Text("5 minutes").tag(TimeInterval(300)); Text("15 minutes").tag(TimeInterval(900))
                            }
                            .labelsHidden().tint(DB.text2)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        CardDivider()
                        navRow("Change master password") { changingPassword = true }
                    }
                }
                VStack(spacing: 8) {
                    SectionLabel("Autofill")
                    Card {
                        Toggle("Offer to save passwords", isOn: $offerToSave).tint(DB.brass).padding(.horizontal, 16).frame(minHeight: 52)
                        CardDivider()
                        HStack { Text("Clear clipboard after").font(.db(16)); Spacer(); Text("60 seconds").font(.db(15)).foregroundStyle(DB.text2) }
                            .padding(.horizontal, 16).frame(minHeight: 52)
                    }
                }
                VStack(spacing: 8) {
                    SectionLabel("If you lose everything")
                    Card {
                        NavigationLink { RecoveryKitView() } label: {
                            rowLabel("Recovery Kit", detail: "Your 24 words", icon: "doc.text", tint: DB.brass)
                        }.buttonStyle(.plain)
                    }
                }
                VStack(spacing: 8) {
                    SectionLabel("Deadbolt")
                    Card {
                        NavigationLink { PrivacyView() } label: {
                            rowLabel("Privacy", detail: "No account, no server copy", icon: "checkmark.shield", tint: DB.good)
                        }.buttonStyle(.plain)
                        CardDivider()
                        Button { showAbout = true } label: {
                            rowLabel("About Deadbolt", detail: "Version \(AppConfig.version)", icon: "info.circle", tint: DB.brass)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Settings")
        .onChange(of: biometrics) { _, on in
            do {
                try session.setBiometrics(on)
                session.show(on ? "\(KeychainKey.biometryName) is on" : "\(KeychainKey.biometryName) is off")
            } catch {
                biometrics = !on
                session.show("Couldn’t change \(KeychainKey.biometryName)", error.friendly, style: .error)
            }
        }
        .onChange(of: lockAfter) { _, v in Prefs.lockAfter = v; session.show("Saved") }
        .onChange(of: offerToSave) { _, v in Prefs.offerToSave = v; session.show(v ? "Deadbolt will offer to save" : "Deadbolt won’t offer to save") }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $changingPassword) { ChangePasswordView() }
    }

    private func navRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title).font(.db(16)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3) }
                .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, detail: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 30, height: 30).background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.db(16))
                Text(detail).font(.db(13)).foregroundStyle(DB.text2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
        }
        .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
    }
}

struct ChangePasswordView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New master password").font(.db(26, .bold))
            Text("Your vault stays the same; only the password that unlocks it changes.").font(.db(15)).foregroundStyle(DB.text2)
            SecureField("New master password", text: $password).textContentType(.newPassword).fieldStyle()
            SecureField("Type it again", text: $confirm).textContentType(.newPassword).fieldStyle()
            Spacer()
            Button {
                Task {
                    do { try await session.changeMasterPassword(to: password); session.show("Master password changed"); dismiss() }
                    catch { session.show("Couldn’t change it", error.friendly, style: .error) }
                }
            } label: { if session.busy { ProgressView().tint(DB.onBrass) } else { Text("Change password") } }
                .buttonStyle(PrimaryButtonStyle()).disabled(password.count < 10 || password != confirm || session.busy)
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(20).background(DB.ground).foregroundStyle(DB.text).presentationBackground(DB.ground)
    }
}

struct RecoveryKitView: View {
    @Environment(VaultSession.self) private var session
    @State private var shown = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("These 24 words open your vault if every device is lost. Keep them on paper, away from your devices.")
                    .font(.db(15)).foregroundStyle(DB.text2)
                if shown, let phrase = session.vault.recoveryPhrase {
                    RecoveryWordsGrid(words: phrase.split(separator: " ").map(String.init))
                } else {
                    Button {
                        Task { shown = await KeychainKey.confirmOwner(reason: "Show your recovery words") }
                    } label: { Label("Show words", systemImage: KeychainKey.biometryName == "Touch ID" ? "touchid" : "faceid") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Recovery Kit")
        .onDisappear { shown = false }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        DeadboltMark(size: 96)
                        Text("Deadbolt").font(.db(26, .bold)).padding(.top, 8)
                        Text("A private password and passkey manager for your own devices.")
                            .font(.db(15)).foregroundStyle(DB.text2).multilineTextAlignment(.center).frame(maxWidth: 280)
                        Text("Version \(AppConfig.version)").font(.dbMono(13)).foregroundStyle(DB.text3)
                    }
                    .padding(.top, 12)
                    Card {
                        Link(destination: DB.projectURL) {
                            HStack(spacing: 14) {
                                Image(systemName: "globe").foregroundStyle(DB.brass)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Project page").font(.db(16))
                                    Text("deadbolt.osborne.vc").font(.db(13)).foregroundStyle(DB.text2)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 56)
                        }
                        CardDivider()
                        NavigationLink { PrivacyView() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "checkmark.shield").foregroundStyle(DB.good)
                                Text("How your data is protected").font(.db(16))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 56)
                        }
                        .buttonStyle(.plain)
                        CardDivider()
                        NavigationLink { AcknowledgementsView() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "doc.text").foregroundStyle(Color(hex: 0xC9CCD2))
                                Text("Open-source acknowledgements").font(.db(16))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DB.text3)
                            }
                            .padding(.horizontal, 16).frame(minHeight: 56)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Built on Apple CryptoKit and libsodium (Argon2id).\nRecovery words use the BIP39 English list.")
                        .font(.db(13)).foregroundStyle(DB.text3).multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(DB.ground)
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ack("libsodium / swift-sodium", "ISC License · Frank Denis. Used for Argon2id key stretching.")
                ack("BIP39 English word list", "From the Bitcoin BIP39 specification. Used for recovery words and passphrases.")
                ack("Apple CryptoKit", "AES-256-GCM, HKDF, P-256 signatures for passkeys.")
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Acknowledgements")
    }
    private func ack(_ title: String, _ body: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.db(16, .semibold))
                Text(body).font(.db(14)).foregroundStyle(DB.text2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
}

struct PrivacyView: View {
    private let points: [(String, String, Bool)] = [
        ("No sign-up, no login", "There is no Deadbolt account. Devices trust each other directly after you approve them.", true),
        ("Encrypted before it’s stored", "AES-256-GCM on your vault. Your master password is stretched with Argon2id and never leaves the device.", true),
        ("Sync without a server copy", "Changes travel end-to-end encrypted. The relay holds them only until your other devices pick them up — 7 days at most.", true),
        ("No analytics, ads or tracking", "Deadbolt sends nothing about how you use it.", true),
        ("Backups you control", "Encrypted with your Recovery Kit and saved only where you choose.", true),
        ("What the relay can see", "A random mailbox ID, the size and time of encrypted messages, and your IP address. Never their contents.", false),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("No account.\nNo server copy.").font(.db(30, .bold)).lineSpacing(2)
                Text("Your vault lives only on your devices, encrypted with keys only they hold.")
                    .font(.db(15)).foregroundStyle(DB.text2).padding(.bottom, 10)
                ForEach(points, id: \.0) { title, body, ok in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: ok ? "checkmark" : "info").font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(ok ? DB.good : DB.brass)
                            .frame(width: 30, height: 30).background(ok ? DB.goodWash : DB.brassWash, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.db(15, .semibold))
                            Text(body).font(.db(13)).foregroundStyle(DB.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(DB.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(DB.line))
                }
                Text("Because nobody else holds your keys, nobody can reset your master password. Keep your Recovery Kit safe.")
                    .font(.db(12)).foregroundStyle(DB.text3).padding(.top, 8)
                Link("More at deadbolt.osborne.vc", destination: DB.projectURL).font(.db(14, .semibold)).foregroundStyle(DB.brass)
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Privacy")
    }
}
