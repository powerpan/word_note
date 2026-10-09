import SwiftUI
import WordNoteCore

extension View {
    func commandShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        modifier(CommandShortcutModifier(key: key, modifiers: modifiers))
    }
}

private struct CommandShortcutModifier: ViewModifier {
    @AppStorage(CommandShortcutPreference.storageKey) private var enabled = CommandShortcutPreference.defaultValue
    let key: KeyEquivalent
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        content.keyboardShortcut(enabled ? KeyboardShortcut(key, modifiers: modifiers) : nil)
    }
}

struct CommandShortcutToggle: View {
    @AppStorage(CommandShortcutPreference.storageKey) private var enabled = CommandShortcutPreference.defaultValue

    var body: some View {
        Toggle("Enable Command Shortcuts", isOn: $enabled)
            .accessibilityIdentifier("command-shortcuts-enabled")
    }
}

struct CaptureShortcutPreferenceSync: ViewModifier {
    @AppStorage(CommandShortcutPreference.storageKey) private var enabled = CommandShortcutPreference.defaultValue
    let controller: CaptureShortcutController

    func body(content: Content) -> some View {
        content.onChange(of: enabled, initial: true) { controller.setCommandShortcutsEnabled(enabled) }
    }
}
