#if os(macOS)
import AppKit
import DeadboltCore
import SwiftUI
import UniformTypeIdentifiers

// Mac v2 versions of the bigger Settings screens: Devices, Backups, Recovery Kit, Import, link approval, remove device.
// Same logic as the iPhone screens, laid out like the rest of the Mac app: 13 pt text, 12 pt secondary, 44 px rows.

// MARK: - shared pieces

/// A bordered group of rows separated by hairlines.
private struct MacGroup<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(DB.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DB.line))
    }
}

private struct MacHairline: View {
    var body: some View { Rectangle().fill(DB.line).frame(height: 1) }
}

private struct MacSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.db(11, .semibold)).tracking(0.6).foregroundStyle(DB.text3) }
}

/// Sheet frame: title, optional subtitle, content, then a button row.
private struct MacSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 460
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.db(15, .semibold))
                if let subtitle { Text(subtitle).font(.db(12)).foregroundStyle(DB.text2).fixedSize(horizontal: false, vertical: true) }
            }
            content()
            HStack(spacing: 8) { Spacer(); footer() }.padding(.top, 2)
        }
        .padding(20)
        .frame(width: width)
        .font(.db(13)).foregroundStyle(DB.text)
        .background(DB.raised)
    }
}

private struct MacNotice: View {
    let text: String
    var color: Color = DB.brass
    var icon = "exclamationmark.triangle"
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
            .font(.db(12)).foregroundStyle(color)
    }
}

private struct MacDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.db(12.5, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 26)
            .background(Color(hex: 0xC2412F).opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Devices

struct MacDevicesPane: View {
    @Environment(VaultSession.self) private var session
    @State private var requests = LinkRequests()
    @State private var reviewing: ApproveModel?
    @State private var removing: DeviceRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                syncRow

                if requests.pending.count > 1 {
                    MacNotice(text: "\(requests.pending.count) devices are asking to link at once. Approve only the one whose screen shows the same code — someone who knows your account number may be trying too.",
                              color: DB.danger, icon: "exclamationmark.triangle.fill")
                }
                ForEach(requests.pending) { r in
                    HStack(spacing: 10) {
                        Image(systemName: "bell.badge.fill").foregroundStyle(DB.brass)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("A new device wants to link").font(.db(13, .semibold))
                            Text("Its name appears once you review").font(.db(12)).foregroundStyle(DB.text3)
                        }
                        Spacer()
                        Button("Review") { reviewing = r }.buttonStyle(MacButtonStyle(prominent: true))
                    }
                    .padding(.horizontal, 12).frame(height: 48)
                    .background(DB.brassWash, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x3A3220)))
                }

                VStack(alignment: .leading, spacing: 8) {
                    MacSectionTitle("Your devices")
                    MacGroup {
                        ForEach(Array(session.vault.activeDevices.enumerated()), id: \.element.id) { i, d in
                            if i > 0 { MacHairline() }
                            row(d)
                        }
                    }
                    Text("To add a device: on the new one choose “I already use Deadbolt” and type the account number below. Its request appears here and in the menu bar.")
                        .font(.db(12)).foregroundStyle(DB.text3).fixedSize(horizontal: false, vertical: true)
                }

                if let n = session.vault.accountNumber, let acct = try? AccountNumber(n) {
                    VStack(alignment: .leading, spacing: 8) {
                        MacSectionTitle("Account number")
                        MacGroup {
                            HStack {
                                Text(acct.description).font(.dbMono(15)).tracking(0.5).textSelection(.enabled)
                                Spacer()
                                TickButton(action: { Clipboard.copySecret(acct.digits) }) { done in
                                    Label(done ? "Copied" : "Copy", systemImage: done ? "checkmark" : "doc.on.doc")
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                .buttonStyle(MacButtonStyle())
                            }
                            .padding(.horizontal, 12).frame(height: 44)
                        }
                        Text("Not a secret: it only lets a new device ask to join. Nothing is shared until you approve on a device you already have.")
                            .font(.db(12)).foregroundStyle(DB.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(width: 600, alignment: .leading)
        }
        .frame(width: 600, height: 480)
        .task { await session.sync.syncNow() }
        .onAppear { requests.watch(accountNumber: session.vault.accountNumber) }
        .onDisappear { requests.stop() }
        .onChange(of: session.vault.accountNumber) { _, n in requests.watch(accountNumber: n) }
        .sheet(item: $reviewing, onDismiss: { requests.prune() }) { MacApproveSheet(model: $0) }
        .sheet(item: $removing) { MacRemoveDeviceSheet(device: $0) }
    }

    @ViewBuilder private var syncRow: some View {
        HStack(spacing: 8) {
            switch session.sync.status {
            case .upToDate(let at):
                Circle().fill(DB.good).frame(width: 7, height: 7)
                Text("Up to date · \(at.formatted(.relative(presentation: .named)))")
            case .syncing:
                ProgressView().controlSize(.small); Text("Syncing…")
            case .offline(let why):
                Circle().fill(DB.danger).frame(width: 7, height: 7); Text(why).lineLimit(2)
            case .off:
                Circle().fill(DB.text3).frame(width: 7, height: 7); Text("Sync starts when the vault is unlocked")
            }
            Spacer()
            Button("Sync Now") { Task { await session.sync.syncNow() } }.buttonStyle(MacButtonStyle())
        }
        .font(.db(12.5)).foregroundStyle(DB.text2)
    }

    private func row(_ d: DeviceRecord) -> some View {
        let me = d.id == DeviceIdentity.id
        return HStack(spacing: 10) {
            Image(systemName: d.platform == "macOS" ? "laptopcomputer" : "iphone")
                .font(.system(size: 12)).foregroundStyle(Color(hex: 0xC9CCD2))
                .frame(width: 26, height: 26).background(DB.control, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(d.shownName).font(.db(13, .semibold))
                Text(d.shownDetail).font(.db(12)).foregroundStyle(DB.text3)
            }
            Spacer()
            if me {
                Text("This device").font(.db(11)).foregroundStyle(DB.text2)
                    .padding(.horizontal, 7).frame(height: 18).background(DB.control, in: Capsule())
            }
            Menu {
                Button(me ? "Retire This Device…" : "Remove \(d.name)…", role: .destructive) { removing = d }
            } label: {
                Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).foregroundStyle(DB.text2)
            .accessibilityLabel("Options for \(d.name)")
        }
        .padding(.horizontal, 12).frame(height: 48)
    }
}

/// Approve a new device after comparing codes.
private struct MacApproveSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let model: ApproveModel

    var body: some View {
        Group {
            switch model.phase {
            case .review, .approving:
                MacSheet(title: "Link “\(model.name)”?",
                         subtitle: "\(model.details.map { $0.model.isEmpty ? "A device" : $0.model } ?? "A device") asked to join your vault. Only approve if you started this.") {
                    VStack(spacing: 10) {
                        if model.code.isEmpty { ProgressView().controlSize(.small).frame(height: 56) } else {
                            Text("Does \(model.name) show the same code?").font(.db(12)).foregroundStyle(DB.text2)
                            CodeDigits(code: model.code)
                        }
                        Text("\(KeychainKey.biometryName) is required to approve.").font(.db(12)).foregroundStyle(DB.text3)
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    Button("Deny") { model.deny(); dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
                    Button { model.approve(session: session) } label: {
                        if model.phase == .approving { ProgressView().controlSize(.small) } else { Text("Codes Match") }
                    }
                    .buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(model.code.isEmpty || model.phase == .approving)
                }
            case .linked:
                result("\(model.name) is linked", "It’s receiving your vault. You can remove it any time in Devices.", retry: false)
            case .denied:
                result("Request denied", "Nothing was shared.", retry: false)
            case .failed(let why):
                result("Couldn’t link", why, retry: true)
            }
        }
        .onAppear { model.begin() }
    }

    private func result(_ title: String, _ body: String, retry: Bool) -> some View {
        MacSheet(title: title, subtitle: body) { EmptyView() } footer: {
            if retry { Button("Try Again") { model.retry() }.buttonStyle(MacButtonStyle()) }
            Button("Done") { dismiss() }.buttonStyle(MacButtonStyle(prominent: !retry)).keyboardShortcut(.defaultAction)
        }
    }
}

/// Remove another device, or retire this one. Needs the master password.
private struct MacRemoveDeviceSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let device: DeviceRecord
    @State private var password = ""
    @State private var error: String?

    private var isMe: Bool { device.id == DeviceIdentity.id }
    private var isLast: Bool { session.vault.activeDevices.count <= 1 }

    var body: some View {
        if isMe && isLast {
            MacSheet(title: "Retire this device?",
                     subtitle: "This is your only device, so it can’t be retired — your vault would have nowhere to live. Use Security › Erase Deadbolt from this Mac if you really mean to delete everything.") {
                EmptyView()
            } footer: {
                Button("OK") { dismiss() }.buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        } else {
            MacSheet(title: isMe ? "Retire this device?" : "Remove \(device.name)?",
                     subtitle: isMe
                        ? "This device stops syncing, leaves the device list and erases its copy of the vault. Your other devices keep everything."
                        : "\(device.name) can no longer sync. If it comes online it’s told it was removed and erases its copy.") {
                VStack(alignment: .leading, spacing: 10) {
                    if !isMe {
                        MacNotice(text: "Passwords already on \(device.name) stay there, still encrypted behind its Face ID or your master password. If it was lost or stolen, change your most important passwords.")
                    }
                    SecureField("Master password to confirm", text: $password).macField()
                        .onSubmit { go() }
                    if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
                }
            } footer: {
                Button("Cancel") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
                Button { go() } label: {
                    if session.busy { ProgressView().controlSize(.small) } else { Text(isMe ? "Retire This Device" : "Remove \(device.name)") }
                }
                .buttonStyle(MacDangerButtonStyle()).disabled(password.isEmpty || session.busy)
            }
        }
    }

    private func go() {
        guard !password.isEmpty, !session.busy else { return }
        Task {
            do {
                try await session.verify(password: password)
                try await session.remove(device, password: password)
                session.show(isMe ? "This device was retired" : "\(device.name) removed")
                dismiss()
            } catch { self.error = error.friendly }
        }
    }
}

// MARK: - Backups

struct MacBackupsPane: View {
    @Environment(VaultSession.self) private var session
    @State private var picking = false
    @State private var folder = Backups.folderName
    @State private var last = Backups.lastBackup
    @State private var working = false

    var body: some View {
        MacForm {
            MacFormRow("Folder") {
                HStack(spacing: 8) {
                    Text(folder ?? "Not chosen yet").foregroundStyle(folder == nil ? DB.danger : DB.text)
                        .lineLimit(1).truncationMode(.middle)
                    Button(folder == nil ? "Choose…" : "Change…") { picking = true }.buttonStyle(MacButtonStyle())
                }
                MacFormNote("An encrypted copy of your vault goes here every week and after big changes like an import. Only your 24 recovery words can open it.")
            }
            MacFormRow("Last backup") {
                Text(last.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            }
            MacFormRow("") {
                Button {
                    working = true
                    do { try Backups.write(session.vault); last = Backups.lastBackup; session.show("Backup saved", folder.map { "In \($0)" }) }
                    catch { session.show("Backup failed", error.friendly, style: .error) }
                    working = false
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Back Up Now") }
                }
                .buttonStyle(MacButtonStyle(prominent: true)).disabled(folder == nil || working)
            }
            MacFormDivider()
            MacFormRow("Tip") {
                MacFormNote("iCloud Drive keeps the file off this Mac, and Apple only ever sees encrypted data. A USB drive kept somewhere safe works too. Deadbolt keeps the newest \(Backups.keep) backups in the folder.")
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                try Backups.choose(folder: try result.get())
                folder = Backups.folderName
                try Backups.write(session.vault)
                last = Backups.lastBackup
                session.show("Backups are on", "First backup saved")
            } catch { session.show("Couldn’t use that folder", error.friendly, style: .error) }
        }
    }
}

// MARK: - Recovery Kit

struct MacRecoveryKitSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false
    @State private var pdf: URL?
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        MacSheet(title: "Recovery Kit", subtitle: "These 24 words open your vault if every device is lost. Keep them on paper, away from your devices.", width: 520) {
            VStack(alignment: .leading, spacing: 12) {
                if shown, let phrase = session.vault.recoveryPhrase {
                    let words = phrase.split(separator: " ").map(String.init)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(i + 1)").font(.dbMono(10.5)).foregroundStyle(DB.text3).frame(width: 16, alignment: .trailing)
                                Text(w).font(.dbMono(12.5))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7).frame(height: 26)
                            .background(Color(hex: 0x1B1D23), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(10).background(DB.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DB.line))
                    .textSelection(.enabled)
                    MacFormNote("Print it, then keep the paper somewhere safe. Avoid saving the PDF to cloud storage.")
                } else if KeychainKey.biometryAvailable {
                    MacFormNote("\(KeychainKey.biometryName) is needed to show them.")
                } else {
                    // No Touch ID on this Mac: the master password unlocks the words instead.
                    SecureField("Master password", text: $password).macField().onSubmit { reveal() }
                    if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
                }
            }
        } footer: {
            Button("Done") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
            if shown {
                if let pdf {
                    Button { NSWorkspace.shared.open(pdf) } label: { Label("Open PDF to Print", systemImage: "printer") }
                        .buttonStyle(MacButtonStyle(prominent: true))
                }
            } else if KeychainKey.biometryAvailable {
                Button { Task { shown = await KeychainKey.confirmOwner(reason: "Show your recovery words") } } label: {
                    Label("Show Words", systemImage: "touchid")
                }
                .buttonStyle(MacButtonStyle(prominent: true))
            } else {
                Button { reveal() } label: { if session.busy { ProgressView().controlSize(.small) } else { Text("Show Words") } }
                    .buttonStyle(MacButtonStyle(prominent: true)).disabled(password.isEmpty || session.busy)
            }
        }
        .onChange(of: shown) { _, on in
            if on, let phrase = session.vault.recoveryPhrase { pdf = try? RecoveryKitPDF.make(phrase: phrase) }
        }
        .onDisappear {
            shown = false
            if let pdf { try? FileManager.default.removeItem(at: pdf) } // don't leave the words lying around
            pdf = nil
        }
    }

    private func reveal() {
        guard !password.isEmpty, !session.busy else { return }
        Task {
            do { try await session.verify(password: password); password = ""; shown = true }
            catch { self.error = error.friendly }
        }
    }
}

// MARK: - Import

struct MacImportSheet: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var picking = false
    @State private var file: ImportFile?
    @State private var plan: ImportPlan?
    @State private var sourceURL: URL?
    @State private var error: String?
    @State private var done = false
    @State private var deletedExport = false

    var body: some View {
        Group {
            if done { doneView } else if let file, let plan { preview(file, plan) } else { intro }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { load($0) }
    }

    private var intro: some View {
        MacSheet(title: "Import Passwords", subtitle: "Bring your logins from another password manager as a CSV file. From Bitwarden, a JSON export also brings cards, identities and notes.", width: 520) {
            VStack(alignment: .leading, spacing: 10) {
                MacGroup {
                    howTo("Apple Passwords", "Passwords app › File › Export All Passwords")
                    MacHairline()
                    howTo("Chrome", "chrome://password-manager/settings › Export passwords")
                    MacHairline()
                    howTo("1Password", "File › Export › CSV")
                    MacHairline()
                    howTo("Bitwarden", "Tools › Export vault › .json (cards, identities, notes too) or .csv")
                }
                MacNotice(text: "The export file isn’t encrypted. Delete it as soon as the import is done — Deadbolt will offer to.")
                if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
            }
        } footer: {
            Button("Cancel") { dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Choose File…") { picking = true }.buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
        }
    }

    private func howTo(_ app: String, _ steps: String) -> some View {
        HStack(spacing: 12) {
            Text(app).font(.db(13, .semibold)).frame(width: 110, alignment: .leading)
            Text(steps).font(.db(12)).foregroundStyle(DB.text2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(height: 38)
    }

    private func preview(_ file: ImportFile, _ plan: ImportPlan) -> some View {
        MacSheet(title: "From \(file.source.rawValue)", width: 520) {
            VStack(alignment: .leading, spacing: 10) {
                MacGroup {
                    stat("New logins", plan.added, DB.good)
                    MacHairline()
                    stat("Updates to existing logins", plan.updated, DB.brass)
                    MacHairline()
                    stat("Already saved, no change", plan.unchanged, DB.text2)
                    if plan.newCards > 0 { MacHairline(); stat("New cards", plan.newCards, DB.good) }
                    if plan.newIdentities > 0 { MacHairline(); stat("New identities", plan.newIdentities, DB.good) }
                    if plan.newNotes > 0 { MacHairline(); stat("New secure notes", plan.newNotes, DB.good) }
                    let dupes = plan.duplicateCards + plan.duplicateIdentities + plan.duplicateNotes
                    if dupes > 0 { MacHairline(); stat("Cards, identities, notes already saved", dupes, DB.text2) }
                    if !file.skipped.isEmpty { MacHairline(); stat("Skipped", file.skipped.count, DB.danger) }
                }
                if plan.updated > 0 { MacFormNote("Updates keep the old password in history, so nothing is lost.") }
                if !file.skipped.isEmpty {
                    DisclosureGroup("Why some rows were skipped") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(file.skipped.prefix(50).enumerated()), id: \.offset) { _, s in
                                    Text("Row \(s.row): \(s.reason)").font(.db(12)).foregroundStyle(DB.text2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110).padding(.top, 4)
                    }
                    .font(.db(12.5)).tint(DB.text2)
                }
                if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
            }
        } footer: {
            Button("Choose a Different File…") { self.file = nil; self.plan = nil; picking = true }.buttonStyle(MacButtonStyle())
            Button("Cancel") { cleanup(); dismiss() }.buttonStyle(MacButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Import \(plan.writes) Items") { apply(file) }
                .buttonStyle(MacButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                .disabled(plan.writes == 0 || session.busy)
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack { Text(label); Spacer(); Text("\(n)").font(.dbMono(13)).foregroundStyle(color) }
            .padding(.horizontal, 12).frame(height: 36)
    }

    private var doneView: some View {
        MacSheet(title: "Import finished", subtitle: "Your logins are in the vault and ready to fill.", width: 520) {
            if deletedExport {
                MacNotice(text: "Export file deleted", color: DB.good, icon: "checkmark.circle.fill")
            } else {
                MacNotice(text: "Now delete the unencrypted export file.")
            }
        } footer: {
            if !deletedExport { Button("Delete the Export File") { deleteExport() }.buttonStyle(MacButtonStyle(prominent: true)) }
            Button("Done") { cleanup(); dismiss() }.buttonStyle(MacButtonStyle(prominent: deletedExport)).keyboardShortcut(.defaultAction)
        }
    }

    private func load(_ result: Result<URL, Error>) {
        error = nil
        do {
            let url = try result.get()
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = try PasswordImporter.parse(text)
            sourceURL = url
            file = parsed
            plan = session.vault.plan(parsed)
        } catch ImportError.unrecognizedColumns(let found) {
            error = "That file doesn’t look like a password export (columns: \(found.prefix(6).joined(separator: ", ")))."
        } catch ImportError.empty {
            error = "That file has nothing to import."
        } catch ImportError.encryptedExport {
            error = "That Bitwarden export is encrypted. Export again as “.json” (not “.json (Encrypted)”)."
        } catch ImportError.notBitwardenJSON {
            error = "That JSON file isn’t a Bitwarden vault export."
        } catch {
            self.error = error.friendly
        }
    }

    private func apply(_ file: ImportFile) {
        do {
            let vault = try session.mutate { v -> Vault in v.apply(file); return v }
            Backups.runIfDue(vault, force: true, session: session) // a big change: back it up now
            done = true
            session.show("Imported \(plan?.writes ?? file.itemCount) items")
        } catch { self.error = error.friendly }
    }

    private func deleteExport() {
        guard let url = sourceURL else { return }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.removeItem(at: url)
            deletedExport = true
            session.show("Export file deleted")
        } catch {
            session.show("Couldn’t delete it from here", "Delete “\(url.lastPathComponent)” in Finder", style: .error)
        }
    }

    private func cleanup() { file = nil; plan = nil }
}
#endif
