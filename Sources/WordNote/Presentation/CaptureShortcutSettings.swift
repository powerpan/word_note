import SwiftUI
import WordNoteCore

private struct CaptureShortcutEnvironmentKey: EnvironmentKey {
    static let defaultValue: CaptureShortcutController? = nil
}

extension EnvironmentValues {
    var captureShortcut: CaptureShortcutController? {
        get { self[CaptureShortcutEnvironmentKey.self] }
        set { self[CaptureShortcutEnvironmentKey.self] = newValue }
    }
}

struct CaptureShortcutSettings: View {
    let controller: CaptureShortcutController
    @State private var draft: CaptureShortcutConfiguration

    init(controller: CaptureShortcutController) {
        self.controller = controller
        _draft = State(initialValue: controller.configuration)
    }

    var body: some View {
        GroupBox("Global Capture Shortcut") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enabled", isOn: $draft.enabled)
                HStack {
                    Picker("Key", selection: $draft.shortcut.key) {
                        ForEach(CaptureShortcut.Key.allCases) { Text(AppLocalization.text($0.title)).tag($0) }
                    }.frame(maxWidth: 180)
                    Spacer()
                }
                HStack(spacing: 16) {
                    modifier("Control", .control)
                    modifier("Option", .option)
                    modifier("Shift", .shift)
                    modifier("Command", .command)
                }
                HStack {
                    Button("Apply", systemImage: "checkmark") { controller.apply(draft) }
                        .disabled(!draft.isValid || !controller.isAvailable)
                    Button("Reset", systemImage: "arrow.counterclockwise") { draft = .init() }
                        .labelStyle(.iconOnly).help("Reset shortcut draft")
                    if controller.errorMessage != nil, controller.configuration.enabled {
                        Button("Retry Registration", systemImage: "arrow.clockwise") { controller.start() }
                            .labelStyle(.iconOnly).help("Retry saved shortcut").disabled(!controller.isAvailable)
                    }
                }
                if !draft.isValid { Text(CaptureShortcutError.invalidCombination.localizedDescription).foregroundStyle(.secondary) }
                if !controller.isAvailable {
                    Label("Unavailable during data maintenance", systemImage: "pause.circle")
                } else if let active = controller.activeShortcut {
                    Label("Registered: \(active.title)", systemImage: "keyboard")
                } else {
                    Label(controller.configuration.enabled ? "Not registered" : "Disabled", systemImage: "keyboard")
                }
                if let error = controller.errorMessage { StatusBanner(message: error, kind: .warning) }
            }.padding(.vertical, 4)
        }
        .groupBoxStyle(WordNoteGroupBoxStyle())
        .onChange(of: controller.configuration) { draft = controller.configuration }
    }

    private func modifier(_ title: String, _ value: CaptureShortcut.Modifiers) -> some View {
        Toggle(title, isOn: Binding(get: { draft.shortcut.modifiers.contains(value) }, set: { enabled in
            if enabled { draft.shortcut.modifiers.insert(value) } else { draft.shortcut.modifiers.remove(value) }
        })).toggleStyle(.checkbox)
    }
}
