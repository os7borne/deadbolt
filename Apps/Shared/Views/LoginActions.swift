import DeadboltCore
import SwiftUI

/// Copy-username / copy-password / copy-code icon buttons, used in list rows on iPhone and in the Mac menu bar.
struct CopyButtons: View {
    @Environment(VaultSession.self) private var session
    let login: LoginItem
    var size: CGFloat = 34
    /// Only the password button (iPhone lists: codes have their own tab, the rest is in the detail or the swipe menu).
    var passwordOnly = false

    var body: some View {
        HStack(spacing: 2) {
            if !passwordOnly, let s = login.totpSecret, let t = try? TOTP(s) {
                small("clock", "Copy one-time code", prominent: false) { copy(t.code(), "Code copied") }
            }
            if !passwordOnly && !login.username.isEmpty {
                small("person", "Copy username", prominent: false) { copy(login.username, "Username copied") }
            }
            if !login.password.isEmpty {
                small("key.horizontal", "Copy password", prominent: true) {
                    copy(login.password, "Password copied")
                    try? session.mutate { $0.markUsed(login.id) }
                }
            }
        }
    }

    private func copy(_ text: String, _ title: String) {
        Clipboard.copySecret(text)   // the button swaps to a checkmark as the confirmation
    }

    private func small(_ icon: String, _ label: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        TickButton(action: action) { done in
            Image.tick(icon, done: done).font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(done ? DB.good : (prominent ? DB.brass : Color(hex: 0xC9CCD2)))
                .frame(width: size, height: size)
                .background(done ? DB.goodWash : (prominent ? DB.brassWash : DB.control.opacity(0.6)), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                .frame(minWidth: 44, minHeight: 44)   // comfortable tap target
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)                     // inside a list row: don't trigger the row's navigation
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Long-press (iPhone) / right-click (Mac) menu for a login.
struct LoginContextMenu: View {
    @Environment(VaultSession.self) private var session
    @Environment(\.openURL) private var openURL
    let login: LoginItem
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        if !login.password.isEmpty {
            Button { copy(login.password, "Password copied"); try? session.mutate { $0.markUsed(login.id) } } label: {
                Label("Copy Password", systemImage: "key.horizontal")
            }
            .keyboardShortcut("c", modifiers: .command)
        }
        if !login.username.isEmpty {
            Button { copy(login.username, "Username copied") } label: { Label("Copy Username", systemImage: "person") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        if let s = login.totpSecret, let t = try? TOTP(s) {
            Button { copy(t.code(), "Code copied") } label: { Label("Copy One-Time Code", systemImage: "clock") }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
        Divider()
        if let site = login.sites.first, let url = URL(string: "https://\(site)") {
            Button { openURL(url) } label: { Label("Open \(site)", systemImage: "safari") }
                .keyboardShortcut("o", modifiers: .command)
        }
        Divider()
        Button(action: edit) { Label("Edit…", systemImage: "pencil") }
            .keyboardShortcut("e", modifiers: .command)
        Button(role: .destructive, action: delete) { Label("Delete…", systemImage: "trash") }
    }

    private func copy(_ text: String, _ title: String) {
        Clipboard.copySecret(text)
        session.show(title, "Clipboard clears in 60 seconds")
    }
}
