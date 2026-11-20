import DeadboltCore
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// "Is this still the owner?" before a secret leaves the vault: a card number, security code, PIN, ID number or note text
/// is shown or copied only after a fresh Touch ID / Face ID check, every time. Without biometrics (Touch ID unavailable with the lid
/// closed, turned off in Settings, or cancelled) the **master password** is asked instead. The device passcode is never accepted.
struct OwnerPrompt: Identifiable, Equatable {
    let id = UUID()
    let reason: String
}

extension VaultSession {
    /// True when the owner passed the check. Never throws; "no" simply means don't release the secret.
    func confirmOwner(_ reason: String) async -> Bool {
        guard state == .unlocked else { return false }
        touch()
        #if os(macOS)
        // Deadbolt is a menu-bar app: after the system Touch ID dialog closes, macOS may not hand keyboard focus back to the
        // window the person was in, so the next sheet would open but not accept typing. Put focus back when the check ends.
        // Only when Deadbolt was the active app: a check started from the browser must not pull Deadbolt in front of Chrome.
        let window = NSApp.keyWindow
        let wasActive = NSApp.isActive
        defer { if wasActive { NSApp.activate(); window?.makeKeyAndOrderFront(nil) } }
        #endif
        if Prefs.biometricsEnabled, KeychainKey.biometryAvailable, await KeychainKey.confirmOwner(reason: reason) {
            touch()
            return true
        }
        guard ownerContinuation == nil else { return false }   // one question at a time
        let prompt = OwnerPrompt(reason: reason)
        // If nothing is showing the password sheet (its window was closed), give up after two minutes instead of waiting forever.
        Task { try? await Task.sleep(for: .seconds(120)); if ownerPrompt?.id == prompt.id { finishOwnerPrompt(false) } }
        return await withCheckedContinuation { c in
            ownerContinuation = c
            ownerPrompt = prompt
        }
    }

    func finishOwnerPrompt(_ ok: Bool) {
        ownerPrompt = nil
        let c = ownerContinuation
        ownerContinuation = nil
        c?.resume(returning: ok)
        if ok { touch() }
    }

    /// Checks, then copies with the short clipboard timeout. For menus and shortcuts, which confirm with a toast.
    func copyProtected(_ value: String, what: String, used: UUID? = nil) {
        Task {
            guard await confirmOwner("Copy \(what)") else { return }
            Clipboard.copySecret(value, clearAfter: Clipboard.sensitiveClearAfter)
            if let used { try? mutate { $0.markItemUsed(used) } }   // recent use orders the suggestions
            show("\(what.prefix(1).uppercased() + what.dropFirst()) copied", "Clears from the clipboard in \(Int(Clipboard.sensitiveClearAfter)) s")
        }
    }
}

/// The master-password fallback for `confirmOwner`.
struct OwnerPasswordSheet: View {
    @Environment(VaultSession.self) private var session
    let prompt: OwnerPrompt
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Confirm it’s you").font(.db(15, .semibold))
                Text("\(prompt.reason). Enter your master password.").font(.db(12)).foregroundStyle(DB.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("Master password", text: $password)
                .textFieldStyle(.plain).padding(.horizontal, 10).frame(height: 32)
                .background(Color(hex: 0x0F1014), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DB.lineStrong))
                .focused($focused)
                .onSubmit { confirm() }
            if let error { Text(error).font(.db(12)).foregroundStyle(DB.danger) }
            HStack {
                Spacer()
                Button("Cancel") { session.finishOwnerPrompt(false) }.keyboardShortcut(.cancelAction)
                Button("Confirm") { confirm() }.keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || session.busy)
            }
        }
        .padding(20).frame(maxWidth: 380)
        .background(DB.surface).foregroundStyle(DB.text)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }

    private func confirm() {
        guard !password.isEmpty, !session.busy else { return }
        Task {
            do {
                try await session.verify(password: password)
                session.finishOwnerPrompt(true)
            } catch {
                self.error = error.friendly
                password = ""
            }
        }
    }
}

extension View {
    /// Presents the master-password fallback when `confirmOwner` needs it. Put on the window that shows vault items.
    func ownerCheckSheet(_ session: VaultSession) -> some View {
        sheet(item: Binding(get: { session.ownerPrompt }, set: { if $0 == nil, session.ownerPrompt != nil { session.finishOwnerPrompt(false) } })) {
            OwnerPasswordSheet(prompt: $0)
                #if os(iOS)
                .presentationDetents([.height(300)]).presentationBackground(DB.surface)
                #endif
        }
    }
}
