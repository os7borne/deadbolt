import DeadboltCore
import SwiftUI

extension VaultSession {
    /// The generator preferences shared by every device (inside the encrypted vault), or the defaults.
    var generatorSettings: PasswordGenerator.Settings { vault.generator ?? PasswordGenerator.Settings() }
    /// A new password using those preferences. Used by every "Generate" button and the Chrome bridge.
    func newPassword() -> String { PasswordGenerator.password(generatorSettings.options) }
}

/// State behind the generator screens: the preferences (synced), and the value currently shown.
@MainActor @Observable
final class GeneratorModel {
    var settings = PasswordGenerator.Settings()
    var value = ""
    private var saveTask: Task<Void, Never>?

    func load(_ session: VaultSession) {
        settings = session.generatorSettings
        regenerate()
    }

    func regenerate() { value = PasswordGenerator.generate(settings) }

    /// A changed option regenerates at once and is written to the vault shortly after (so dragging a slider is one write).
    func changed(_ session: VaultSession) {
        regenerate()
        saveTask?.cancel()
        let wanted = settings
        saveTask = Task { [weak session] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let session, session.generatorSettings != wanted else { return }
            try? session.mutate { $0.generator = wanted }
        }
    }

    /// At least one kind of character must stay on.
    func isLastKind(_ on: Bool) -> Bool {
        let o = settings.options
        return on && [o.upper, o.lower, o.digits, o.symbols].filter { $0 }.count == 1
    }
}
