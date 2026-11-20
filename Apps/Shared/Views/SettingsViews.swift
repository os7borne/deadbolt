import DeadboltCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct GeneratorView: View {
    @Environment(VaultSession.self) private var session
    @State private var model = GeneratorModel()

    var body: some View {
        @Bindable var m = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Kind", selection: $m.settings.passphrase) { Text("Password").tag(false); Text("Passphrase").tag(true) }
                    .pickerStyle(.segmented)
                Text(m.value).font(.dbMono(22)).foregroundStyle(DB.text).multilineTextAlignment(.leading)
                    .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                    .padding(18).background(DB.surface, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(DB.line))
                if m.settings.passphrase {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(m.settings.words) words").font(.db(15))
                            Slider(value: Binding(get: { Double(m.settings.words) }, set: { m.settings.words = Int($0) }), in: 4...8, step: 1).tint(DB.brass)
                        }
                        .padding(16)
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Length \(m.settings.options.length)").font(.db(15))
                            Slider(value: Binding(get: { Double(m.settings.options.length) }, set: { m.settings.options.length = Int($0) }), in: 8...64, step: 1).tint(DB.brass)
                        }
                        .padding(16)
                        CardDivider()
                        kindToggle("Capital letters  A–Z", $m.settings.options.upper)
                        CardDivider()
                        kindToggle("Lowercase letters  a–z", $m.settings.options.lower)
                        CardDivider()
                        kindToggle("Numbers  0–9", $m.settings.options.digits)
                        CardDivider()
                        kindToggle("Symbols  !@#$%^&*", $m.settings.options.symbols)
                        CardDivider()
                        Stepper("Minimum numbers: \(m.settings.options.minDigits)", value: $m.settings.options.minDigits, in: 1...10)
                            .disabled(!m.settings.options.digits).padding(.horizontal, 16).frame(minHeight: 52)
                        CardDivider()
                        Stepper("Minimum symbols: \(m.settings.options.minSymbols)", value: $m.settings.options.minSymbols, in: 1...10)
                            .disabled(!m.settings.options.symbols).padding(.horizontal, 16).frame(minHeight: 52)
                        CardDivider()
                        Toggle(isOn: $m.settings.options.avoidAmbiguous) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Avoid look-alike characters").font(.db(16))
                                Text("Leaves out 0 O 1 l I").font(.db(13)).foregroundStyle(DB.text2)
                            }
                        }
                        .tint(DB.brass).padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    Text("These choices sync to your other devices and are used by every Generate button, including in Chrome.")
                        .font(.db(13)).foregroundStyle(DB.text3)
                }
                HStack(spacing: 10) {
                    Button { m.regenerate(); Haptics.tap() } label: { Label("New", systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle(height: 54))
                    TickButton(action: { Clipboard.copySecret(m.value) }) { done in
                        Label(done ? "Copied" : "Copy", systemImage: done ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PrimaryButtonStyle(height: 54))
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Generator")
        .onAppear { model.load(session) }
        .onChange(of: model.settings) { model.changed(session) }
    }

    private func kindToggle(_ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(title, isOn: on).tint(DB.brass).disabled(model.isLastKind(on.wrappedValue))
            .padding(.horizontal, 16).frame(minHeight: 52)
    }
}

struct SettingsView: View {
    @Environment(VaultSession.self) private var session
    @State private var biometrics = Prefs.biometricsEnabled
    @State private var lockAfter = Prefs.lockAfter
    @State private var offerToSave = Prefs.offerToSave
    @State private var showAbout = false
    @State private var changingPassword = false
    @State private var erasing = false
    @State private var importing = false
    @State private var showIcons = IconStore.enabled
    @State private var autofillOn: Bool?
    #if os(macOS)
    @State private var atLogin = SystemSetup.opensAtLogin
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Button { session.lock() } label: {
                    Label("Lock Deadbolt now", systemImage: "lock.fill")
                }
                .buttonStyle(PrimaryButtonStyle(height: 52))

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
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AutoFill").font(.db(16))
                                Text(autofillOn == true ? "Deadbolt fills in Safari and apps" : "Turned off in System Settings")
                                    .font(.db(13)).foregroundStyle(DB.text2)
                            }
                            Spacer()
                            if autofillOn == true {
                                Label("On", systemImage: "checkmark.circle.fill").font(.db(14, .semibold)).foregroundStyle(DB.good)
                            } else if autofillOn == false {
                                Button("Turn on") {
                                    Task {
                                        autofillOn = await SystemSetup.requestAutofill()
                                        if autofillOn != true { SystemSetup.openAutofillSettings() }
                                    }
                                }
                                .buttonStyle(.plain).font(.db(15, .semibold)).foregroundStyle(DB.brass).frame(minHeight: 44)
                            }
                        }
                        .padding(.horizontal, 16).frame(minHeight: 56)
                        CardDivider()
                        #if os(macOS)
                        Toggle("Open Deadbolt at login", isOn: $atLogin).tint(DB.brass).padding(.horizontal, 16).frame(minHeight: 52)
                        CardDivider()
                        #endif
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
                            rowLabel("Recovery Kit", detail: "Your 24 words · print or save as PDF", icon: "doc.text", tint: DB.brass)
                        }.buttonStyle(.plain)
                        CardDivider()
                        NavigationLink { BackupSettingsView() } label: {
                            rowLabel("Backups", detail: Backups.folderName.map { "To \($0)" } ?? "Not set up — tap to choose a folder",
                                     icon: "externaldrive.badge.timemachine", tint: Backups.folderName == nil ? DB.danger : DB.good)
                        }.buttonStyle(.plain)
                    }
                }
                VStack(spacing: 8) {
                    SectionLabel("Import")
                    Card {
                        Button { importing = true } label: {
                            rowLabel("Import passwords", detail: "From Apple Passwords, Chrome, 1Password, Bitwarden", icon: "square.and.arrow.down", tint: DB.brass)
                        }.buttonStyle(.plain)
                    }
                }
                VStack(spacing: 8) {
                    SectionLabel("Privacy")
                    Card {
                        Toggle(isOn: $showIcons) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show website icons").font(.db(16))
                                Text("Fetched through Deadbolt’s own server, never a third party. Off means no requests.")
                                    .font(.db(13)).foregroundStyle(DB.text2)
                            }
                        }
                        .tint(DB.brass).padding(.horizontal, 16).padding(.vertical, 10)
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
                VStack(spacing: 8) {
                    SectionLabel("This device")
                    Card {
                        Button { erasing = true } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Erase Deadbolt from this device").font(.db(16)).foregroundStyle(DB.danger)
                                    Text("Removes the vault, \(KeychainKey.biometryName) key and suggestions here").font(.db(13)).foregroundStyle(DB.text2)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
        .sheet(isPresented: $erasing) { EraseDeviceView() }
        .sheet(isPresented: $importing) { ImportView() }
        .onChange(of: showIcons) { _, on in
            IconStore.enabled = on
            if !on { IconStore.shared.clear() }
            session.show(on ? "Website icons on" : "Website icons off", on ? nil : "Cached icons deleted")
        }
        .task { autofillOn = await SystemSetup.autofillEnabled() }
        #if os(macOS)
        .onChange(of: atLogin) { _, on in
            do { try SystemSetup.setOpensAtLogin(on); session.show(on ? "Deadbolt will open at login" : "Deadbolt won’t open at login") }
            catch { atLogin = SystemSetup.opensAtLogin; session.show("Couldn’t change that", error.friendly, style: .error) }
        }
        #endif
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

/// The closest thing to "sign out": there's no account, so this removes Deadbolt's data from this device.
struct EraseDeviceView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?

    private var linked: Bool { session.vault.activeDevices.contains { $0.id != DeviceIdentity.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(DB.danger)
            Text("Erase Deadbolt from this device?").font(.db(26, .bold))
            Text("This deletes the vault on this device, its \(KeychainKey.biometryName) key and the AutoFill suggestions. It can’t be undone.")
                .font(.db(15)).foregroundStyle(DB.text2)
            if linked {
                Label("Your other devices keep everything. This device is removed from the device list first, so it can’t sync again.",
                      systemImage: "laptopcomputer.and.iphone")
                    .font(.db(14)).foregroundStyle(DB.text2)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DB.surface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This is your only device: every password stored here will be gone.", systemImage: "xmark.octagon")
                    Label("Your Recovery Kit can’t bring them back without a backup file.", systemImage: "doc.text")
                }
                .font(.db(14)).foregroundStyle(DB.danger)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(DB.dangerWash, in: RoundedRectangle(cornerRadius: 14))
            }
            SecureField("Master password to confirm", text: $password).textContentType(.password).fieldStyle()
            if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
            Spacer()
            Button {
                Task {
                    do {
                        try await session.verify(password: password)
                        if linked, let me = session.vault.device(DeviceIdentity.id) {
                            try await session.remove(me, password: password)   // retire: tell the others, then erase
                        } else {
                            try session.eraseThisDevice()
                        }
                        session.show("Deadbolt erased from this device")
                        dismiss()
                    } catch { self.error = error.friendly; Haptics.error() }
                }
            } label: {
                Group { if session.busy { ProgressView() } else { Text("Erase this device") } }
                    .font(.db(17, .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(Color(hex: 0xC2412F), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(password.isEmpty || session.busy)
            Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(20).background(DB.ground).foregroundStyle(DB.text).presentationBackground(DB.ground)
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
    @State private var pdf: URL?
    @State private var password = ""
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("These 24 words open your vault if every device is lost. Keep them on paper, away from your devices.")
                    .font(.db(15)).foregroundStyle(DB.text2)
                if shown, let phrase = session.vault.recoveryPhrase {
                    RecoveryWordsGrid(words: phrase.split(separator: " ").map(String.init))
                    if let pdf {
                        #if os(iOS)
                        ShareLink(item: pdf) { Label("Print or save the Recovery Kit", systemImage: "printer") }
                            .buttonStyle(PrimaryButtonStyle())
                        #else
                        Button { NSWorkspace.shared.open(pdf) } label: { Label("Open Recovery Kit PDF to print", systemImage: "printer") }
                            .buttonStyle(PrimaryButtonStyle())
                        #endif
                        Text("Print it, then keep the paper somewhere safe. Avoid saving the PDF to cloud storage.")
                            .font(.db(13)).foregroundStyle(DB.text3)
                    }
                } else if KeychainKey.biometryAvailable {
                    Button {
                        Task { shown = await KeychainKey.confirmOwner(reason: "Show your recovery words") }
                    } label: { Label("Show words", systemImage: KeychainKey.biometryName == "Touch ID" ? "touchid" : "faceid") }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    // No Face ID / Touch ID on this device: the master password unlocks the words instead.
                    SecureField("Master password", text: $password).textContentType(.password).fieldStyle()
                    if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                    Button {
                        Task {
                            do { try await session.verify(password: password); password = ""; shown = true }
                            catch { self.error = error.friendly }
                        }
                    } label: { if session.busy { ProgressView().tint(DB.onBrass) } else { Text("Show words") } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(password.isEmpty || session.busy)
                }
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Recovery Kit")
        .onChange(of: shown) { _, on in
            if on, let phrase = session.vault.recoveryPhrase { pdf = try? RecoveryKitPDF.make(phrase: phrase) }
        }
        .onDisappear {
            shown = false
            if let pdf { try? FileManager.default.removeItem(at: pdf) } // don't leave the words lying around
            pdf = nil
        }
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
                ack("Public Suffix List", "MPL-2.0 · publicsuffix.org (Mozilla). Decides which sites may use which passkeys, the same rule browsers use.")
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
        ("Website icons without a third party", "Icons come through Deadbolt’s own server, straight from each site, cached for a week. Switch them off in Settings and no requests are made.", true),
        ("What the relay can see", "A random mailbox ID, the size and time of encrypted messages, your IP address and, for an iPhone, the push token Apple uses to wake Deadbolt. Never their contents.", false),
        ("Wake-up pushes carry nothing", "When another device changes something, your iPhone gets a silent push with no content, just a nudge to fetch. Apple sees that a push was sent, nothing more.", true),
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
