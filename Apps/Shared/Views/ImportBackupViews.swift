import DeadboltCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: one-time code card

struct CodeCard: View {
    @Environment(VaultSession.self) private var session
    let secret: String

    var body: some View {
        if let totp = try? TOTP(secret) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = totp.secondsRemaining(at: ctx.date)
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(DB.line, lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(left) / CGFloat(totp.period))
                            .stroke(left <= 5 ? DB.danger : DB.brass, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: left)
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("One-time code · \(left) s").font(.db(13)).foregroundStyle(DB.text3)
                        Text(TOTP.grouped(totp.code(at: ctx.date))).font(.dbMono(24)).tracking(1.5)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    IconButton(systemName: "doc.on.doc", label: "Copy one-time code") {
                        Clipboard.copySecret(totp.code())
                    }
                }
                .padding(16)
                .accessibilityElement(children: .combine)
            }
            .background(DB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DB.line))
        }
    }
}

/// Small inline code for list rows.
struct InlineCode: View {
    let secret: String
    var body: some View {
        if let totp = try? TOTP(secret) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(TOTP.grouped(totp.code(at: ctx.date))).font(.dbMono(15)).foregroundStyle(DB.text).tracking(0.6)
            }
        }
    }
}

// MARK: import

struct ImportView: View {
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if done { doneView } else if let file, let plan { preview(file, plan) } else { intro }
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .navigationTitle("Import passwords")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(done ? "Done" : "Cancel") { cleanup(); dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
                load(result)
            }
        }
        .presentationBackground(DB.ground)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring your logins from another password manager as a CSV file. From Bitwarden, a JSON export also brings cards, identities and notes.")
                .font(.db(15)).foregroundStyle(DB.text2)
            Card {
                howTo("Apple Passwords", "Passwords app › File › Export All Passwords (Mac), or ••• › Export Data to Another App (iPhone)")
                CardDivider()
                howTo("Chrome", "chrome://password-manager/settings › Export passwords")
                CardDivider()
                howTo("1Password", "File › Export › CSV")
                CardDivider()
                howTo("Bitwarden", "Tools › Export vault › .json (cards, identities, notes too) or .csv")
            }
            Label("The export file isn’t encrypted. Delete it as soon as the import is done — Deadbolt will offer to.", systemImage: "exclamationmark.triangle")
                .font(.db(13)).foregroundStyle(DB.brass)
            if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
            Button("Choose file") { picking = true }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func howTo(_ app: String, _ steps: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app).font(.db(15, .semibold))
            Text(steps).font(.db(13)).foregroundStyle(DB.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
    }

    private func preview(_ file: ImportFile, _ plan: ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("From \(file.source.rawValue)").font(.db(24, .bold))
            Card {
                stat("New logins", plan.added, DB.good)
                CardDivider()
                stat("Updates to existing logins", plan.updated, DB.brass)
                CardDivider()
                stat("Already saved, no change", plan.unchanged, DB.text2)
                if plan.newCards > 0 { CardDivider(); stat("New cards", plan.newCards, DB.good) }
                if plan.newIdentities > 0 { CardDivider(); stat("New identities", plan.newIdentities, DB.good) }
                if plan.newNotes > 0 { CardDivider(); stat("New secure notes", plan.newNotes, DB.good) }
                let dupes = plan.duplicateCards + plan.duplicateIdentities + plan.duplicateNotes
                if dupes > 0 { CardDivider(); stat("Cards, identities, notes already saved", dupes, DB.text2) }
                if !file.skipped.isEmpty { CardDivider(); stat("Skipped", file.skipped.count, DB.danger) }
            }
            if plan.updated > 0 {
                Text("Updates keep the old password in history, so nothing is lost.").font(.db(13)).foregroundStyle(DB.text3)
            }
            if !file.skipped.isEmpty {
                DisclosureGroup("Why some rows were skipped") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(file.skipped.prefix(50).enumerated()), id: \.offset) { _, s in
                            Text("Row \(s.row): \(s.reason)").font(.db(13)).foregroundStyle(DB.text2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(.db(14)).tint(DB.text2)
            }
            Button("Import \(plan.writes) items") { apply(file) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(plan.writes == 0 || session.busy)
            Button("Choose a different file") { self.file = nil; self.plan = nil; picking = true }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func stat(_ label: String, _ n: Int, _ color: Color) -> some View {
        HStack { Text(label).font(.db(16)); Spacer(); Text("\(n)").font(.dbMono(17)).foregroundStyle(color) }
            .padding(.horizontal, 16).frame(minHeight: 52)
    }

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(DB.good)
                .frame(width: 64, height: 64).background(DB.goodWash, in: Circle()).padding(.top, 30)
            Text("Import finished").font(.db(22, .bold))
            Text("Your items are in the vault.").font(.db(15)).foregroundStyle(DB.text2)
            if deletedExport {
                Label("Export file deleted", systemImage: "checkmark.circle.fill").foregroundStyle(DB.good).font(.db(15, .semibold))
            } else {
                Text("Now delete the unencrypted export file.").font(.db(14)).foregroundStyle(DB.brass)
                Button("Delete the export file") { deleteExport() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
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
            session.show("Couldn’t delete it from here", "Delete “\(url.lastPathComponent)” in Files or Finder", style: .error)
        }
    }

    private func cleanup() { file = nil; plan = nil }
}

// MARK: backup settings

struct BackupSettingsView: View {
    @Environment(VaultSession.self) private var session
    @State private var picking = false
    @State private var folder = Backups.folderName
    @State private var last = Backups.lastBackup
    @State private var working = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Deadbolt saves an encrypted copy of your vault to a folder you choose, every week and after big changes like an import. Only your 24 recovery words can open it.")
                    .font(.db(15)).foregroundStyle(DB.text2)
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Folder").font(.db(16))
                            Text(folder ?? "Not chosen yet").font(.db(13)).foregroundStyle(folder == nil ? DB.danger : DB.text2)
                        }
                        Spacer()
                        Button(folder == nil ? "Choose" : "Change") { picking = true }
                            .buttonStyle(.plain).font(.db(15, .semibold)).foregroundStyle(DB.brass).frame(minHeight: 44)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 60)
                    CardDivider()
                    HStack {
                        Text("Last backup").font(.db(16))
                        Spacer()
                        Text(last.map { $0.formatted(.relative(presentation: .named)) } ?? "Never").font(.db(15)).foregroundStyle(DB.text2)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 52)
                }
                Button {
                    working = true
                    do { try Backups.write(session.vault); last = Backups.lastBackup; session.show("Backup saved", folder.map { "In \($0)" }) }
                    catch { session.show("Backup failed", error.friendly, style: .error) }
                    working = false
                } label: { if working { ProgressView().tint(DB.onBrass) } else { Text("Back up now") } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(folder == nil || working)
                Text("Tip: iCloud Drive keeps the file off this device, but Apple only ever sees encrypted data. A USB drive kept somewhere safe works too. Deadbolt keeps the newest \(Backups.keep) backups in the folder.")
                    .font(.db(13)).foregroundStyle(DB.text3)
            }
            .padding(20)
        }
        .background(DB.ground).foregroundStyle(DB.text)
        .navigationTitle("Backups")
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

// MARK: restore (first run)

struct RestoreView: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onRestored: () -> Void
    @State private var picking = false
    @State private var backup: BackupFile?
    @State private var phrase = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let backup {
                        Card {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.badge.clock").foregroundStyle(DB.brass)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Backup from \(backup.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.db(15, .semibold))
                                    Text("\(backup.items) logins").font(.db(13)).foregroundStyle(DB.text2)
                                }
                                Spacer()
                                Button("Change") { picking = true }.buttonStyle(.plain).foregroundStyle(DB.brass)
                            }
                            .padding(14)
                        }
                        Text("Your 24 recovery words").font(.db(13)).foregroundStyle(DB.text3).padding(.top, 6)
                        TextEditor(text: $phrase)
                            .font(.dbMono(15)).scrollContentBackground(.hidden).padding(10).frame(height: 130)
                            .background(DB.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(DB.lineStrong))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Text("New master password").font(.db(13)).foregroundStyle(DB.text3).padding(.top, 6)
                        SecureField("At least 10 characters", text: $password).textContentType(.newPassword).fieldStyle()
                        SecureField("Type it again", text: $confirm).textContentType(.newPassword).fieldStyle()
                        if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                        Button {
                            Task {
                                do {
                                    try await session.restore(backup, phrase: phrase, password: password)
                                    session.show("Vault restored", "\(session.vault.logins.count) logins")
                                    dismiss()
                                    onRestored()
                                } catch { self.error = error.friendly; Haptics.error() }
                            }
                        } label: { if session.busy { ProgressView().tint(DB.onBrass) } else { Text("Restore") } }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(password.count < 10 || password != confirm || session.busy)
                    } else {
                        Text("Pick your most recent backup file — it’s named “Deadbolt Backup” followed by a date.")
                            .font(.db(15)).foregroundStyle(DB.text2)
                        if let error { Text(error).font(.db(14)).foregroundStyle(DB.danger) }
                        Button("Choose backup file") { picking = true }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(20)
            }
            .background(DB.ground).foregroundStyle(DB.text)
            .navigationTitle("Restore from a backup")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .json]) { result in
                do { backup = try Backups.read(try result.get()); error = nil }
                catch { self.error = "That isn’t a Deadbolt backup file." }
            }
        }
        .presentationBackground(DB.ground)
    }
}
