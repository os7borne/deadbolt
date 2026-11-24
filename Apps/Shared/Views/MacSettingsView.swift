#if os(macOS)
import AppKit
import DeadboltCore
import SwiftUI

/// Mac v2 Settings, shown inside the main window (⌘, or the gear): a row of tabs on top, the pane below, Done to go back.
/// Devices, Backups, Recovery Kit and Import live in MacSettingsPanes.swift.
struct MacSettingsView: View {
    @Environment(VaultSession.self) private var session
    @AppStorage("macSettingsTab", store: AppConfig.defaults) private var tab = "general"

    private let tabs: [(id: String, title: String, icon: String)] = [
        ("general", "General", "gearshape"), ("security", "Security", "lock.shield"), ("autofill", "AutoFill", "keyboard"),
        ("devices", "Devices", "laptopcomputer.and.iphone"), ("backups", "Backups", "externaldrive.badge.timemachine"), ("about", "About", "info.circle"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.id) { t in
                    Button { tab = t.id } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 16, weight: .medium))
                            Text(t.title).font(.db(11, .medium))
                        }
                        .foregroundStyle(tab == t.id ? DB.brass : DB.text2)
                        .frame(width: 68, height: 46)
                        .background(tab == t.id ? DB.control : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel(t.title)
                }
                Spacer()
                Button("Done") { session.settingsOpen = false }
                    .buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(DB.raised)
            Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1)

            ScrollView {
                pane.frame(maxWidth: .infinity)
            }
        }
        .font(.db(13))
        .foregroundStyle(DB.text)
        .background(DB.ground)
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case "security": MacSecuritySettings()
        case "autofill": MacAutoFillSettings()
        case "devices": MacDevicesPane()
        case "backups": MacBackupsPane()
        case "about": MacAboutSettings()
        default: MacGeneralSettings()
        }
    }
}

/// One right-aligned label + control row, as in the design.
struct MacFormRow<C: View>: View {
    let label: String
    @ViewBuilder let content: () -> C
    init(_ label: String, @ViewBuilder content: @escaping () -> C) { self.label = label; self.content = content }
    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(DB.text2).frame(width: 170, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) { content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MacFormNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.db(12)).foregroundStyle(DB.text3).fixedSize(horizontal: false, vertical: true) }
}

struct MacForm<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) { content() }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(width: 600, alignment: .top)
    }
}

struct MacFormDivider: View {
    var body: some View { Rectangle().fill(Color(hex: 0x1C1F26)).frame(height: 1).gridCellColumns(2).padding(.vertical, 2) }
}

// MARK: General

private struct MacGeneralSettings: View {
    @Environment(VaultSession.self) private var session
    @State private var atLogin = SystemSetup.opensAtLogin
    @State private var showIcons = IconStore.enabled
    @State private var importing = false

    var body: some View {
        MacForm {
            MacFormRow("Startup") {
                Toggle("Open Deadbolt at login", isOn: $atLogin).toggleStyle(.checkbox)
                MacFormNote("Deadbolt lives in the menu bar so Chrome and AutoFill can reach it.")
            }
            MacFormRow("Website icons") {
                Toggle("Show website icons", isOn: $showIcons).toggleStyle(.checkbox)
                MacFormNote("Fetched through Deadbolt’s own server, never a third party. Off means no requests.")
            }
            UpdatesRows()
            MacFormDivider()
            MacFormRow("Import") {
                Button("Import Passwords…") { importing = true }.buttonStyle(MacButtonStyle())
                MacFormNote("From Apple Passwords, Chrome, 1Password or Bitwarden (CSV).")
            }
        }
        .sheet(isPresented: $importing) { MacImportSheet() }
        .onChange(of: atLogin) { _, on in
            do { try SystemSetup.setOpensAtLogin(on); session.show(on ? "Opens at login" : "Won’t open at login") }
            catch { atLogin = SystemSetup.opensAtLogin; session.show("Couldn’t change that", error.friendly, style: .error) }
        }
        .onChange(of: showIcons) { _, on in
            IconStore.enabled = on
            if !on { IconStore.shared.clear() }
            session.show(on ? "Website icons on" : "Website icons off", on ? nil : "Cached icons deleted")
        }
    }
}

// MARK: Security

private struct MacSecuritySettings: View {
    @Environment(VaultSession.self) private var session
    @State private var biometrics = Prefs.biometricsEnabled
    @State private var lockAfter = max(Prefs.lockAfter, LockPolicy.macMinimum)
    @State private var changingPassword = false
    @State private var recoveryKit = false
    @State private var erasing = false

    var body: some View {
        MacForm {
            MacFormRow("Unlock with") {
                Toggle(KeychainKey.biometryName, isOn: $biometrics).toggleStyle(.checkbox)
                    .disabled(!KeychainKey.biometryAvailable)
            }
            MacFormRow("Lock after") {
                Picker("", selection: $lockAfter) {
                    Text("1 minute").tag(TimeInterval(60)); Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900)); Text("1 hour").tag(TimeInterval(3600))
                }
                .labelsHidden().frame(width: 180)
                MacFormNote("Also locks when the Mac sleeps, the screen locks or you switch user.")
            }
            MacFormRow("Master password") {
                Button("Change…") { changingPassword = true }.buttonStyle(MacButtonStyle())
            }
            MacFormRow("Clipboard") { Text("Cleared 60 seconds after copying") }
            MacFormDivider()
            MacFormRow("Recovery Kit") {
                Button("Show Words…") { recoveryKit = true }.buttonStyle(MacButtonStyle())
                MacFormNote("Your 24 words and account number. Print them and keep them somewhere safe.")
            }
            MacFormDivider()
            MacFormRow("This Mac") {
                Button("Erase Deadbolt from this Mac…") { erasing = true }
                    .buttonStyle(.plain).foregroundStyle(DB.danger)
                    .padding(.horizontal, 12).frame(height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0x3A2A28)))
            }
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordView().frame(minWidth: 460, minHeight: 360) }
        .sheet(isPresented: $recoveryKit) { MacRecoveryKitSheet() }
        .sheet(isPresented: $erasing) { EraseDeviceView().frame(minWidth: 460, minHeight: 420) }
        .onChange(of: biometrics) { _, on in
            do { try session.setBiometrics(on); session.show(on ? "\(KeychainKey.biometryName) is on" : "\(KeychainKey.biometryName) is off") }
            catch { biometrics = !on; session.show("Couldn’t change \(KeychainKey.biometryName)", error.friendly, style: .error) }
        }
        .onChange(of: lockAfter) { _, v in Prefs.lockAfter = v; session.show("Saved") }
    }
}

// MARK: AutoFill

private struct MacAutoFillSettings: View {
    @Environment(VaultSession.self) private var session
    @State private var offerToSave = Prefs.offerToSave
    @State private var autofillOn: Bool?

    var body: some View {
        MacForm {
            MacFormRow("Safari and apps") {
                HStack(spacing: 10) {
                    switch autofillOn {
                    case true?: Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(DB.good)
                    case false?:
                        Text("Off").foregroundStyle(DB.danger)
                        Button("Turn On…") {
                            Task {
                                autofillOn = await SystemSetup.requestAutofill()
                                if autofillOn != true { SystemSetup.openAutofillSettings() }
                            }
                        }
                        .buttonStyle(MacButtonStyle())
                    case nil: ProgressView().controlSize(.small)
                    }
                }
                MacFormNote("System Settings › General › AutoFill & Passwords › Deadbolt.")
            }
            MacFormRow("Saving") {
                Toggle("Offer to save new passwords", isOn: $offerToSave).toggleStyle(.checkbox)
                MacFormNote("In Chrome-based browsers and Safari, after you sign in.")
            }
            MacFormDivider()
            MacFormRow("Browsers") {
                Text("Chrome, Aside, Arc, Brave, Edge and other Chromium browsers")
                MacFormNote("Load the Deadbolt extension in the browser; it talks to this app directly, never to a server.")
            }
        }
        .task { autofillOn = await SystemSetup.autofillEnabled() }
        .onChange(of: offerToSave) { _, v in Prefs.offerToSave = v; session.show(v ? "Deadbolt will offer to save" : "Deadbolt won’t offer to save") }
    }
}

// MARK: About

private struct MacAboutSettings: View {
    @State private var privacy = false
    @State private var acknowledgements = false

    var body: some View {
        VStack(spacing: 12) {
            DeadboltMark(size: 64)
            Text("Deadbolt").font(.db(17, .semibold))
            Text("Version \(AppConfig.version)").font(.db(12)).foregroundStyle(DB.text3)
            Text("A private password and passkey manager. No account, no server copy.")
                .font(.db(13)).foregroundStyle(DB.text2).multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Link("Project page", destination: DB.projectURL).buttonStyle(MacButtonStyle())
                Button("Privacy…") { privacy = true }.buttonStyle(MacButtonStyle())
                Button("Acknowledgements…") { acknowledgements = true }.buttonStyle(MacButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 600)
        .sheet(isPresented: $privacy) {
            NavigationStack { PrivacyView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { privacy = false } } } }
                .frame(minWidth: 520, minHeight: 560)
        }
        .sheet(isPresented: $acknowledgements) {
            NavigationStack { AcknowledgementsView().toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { acknowledgements = false } } } }
                .frame(minWidth: 520, minHeight: 480)
        }
    }
}
#endif
