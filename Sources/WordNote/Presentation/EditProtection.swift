import SwiftUI
import WordNoteCore

private struct EditProtectionKey: EnvironmentKey {
    static let defaultValue: WordNoteEditProtection? = nil
}

extension EnvironmentValues {
    var editProtection: WordNoteEditProtection? {
        get { self[EditProtectionKey.self] }
        set { self[EditProtectionKey.self] = newValue }
    }
}

@MainActor
func protectingEdits(_ protection: WordNoteEditProtection?, perform action: @escaping () -> Void) {
    if let protection { protection.request(proceed: action) } else { action() }
}

extension View {
    func protectEdits<Value: Equatable>(
        id: UUID, value: Value, isDirty: @escaping () -> Bool, title: String, preview: @escaping () -> String,
        save: @escaping () throws -> Void, discard: @escaping () -> Void
    ) -> some View {
        modifier(EditDraftRegistration(id: id, value: value, isDirty: isDirty, title: title, preview: preview, save: save, discard: discard))
    }
}

private struct EditDraftRegistration<Value: Equatable>: ViewModifier {
    @Environment(\.editProtection) private var protection
    let id: UUID
    let value: Value
    let isDirty: () -> Bool
    let title: String
    let preview: () -> String
    let save: () throws -> Void
    let discard: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: register)
            .onChange(of: value) { register() }
            .onDisappear { protection?.detach(id) }
        // A dirty draft remains reachable in the window if another window removes its model.
    }

    private func register() {
        protection?.track(id: id, title: title, preview: preview, isDirty: isDirty, save: save, discard: discard)
    }
}

#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
struct EditProtectionHost<Content: View>: View {
    @State private var protection = WordNoteEditProtection()
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.editProtection, protection)
            .background(EditProtectionWindowBridge(protection: protection))
            .toolbar {
                if protection.hasUnsavedChanges {
                    Button("Unsaved Changes", systemImage: "pencil.circle") { protection.request {} }
                        .help("Review unsaved changes")
                }
            }
            .sheet(isPresented: Binding(get: { protection.isPresented }, set: { _ in }), onDismiss: {
                protection.completeTransition()
            }) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Save changes before continuing?").font(.title3.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(protection.drafts) { draft in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.title).font(.headline)
                                    Text(draft.preview).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    if let message = protection.errorMessage { StatusBanner(message: message, kind: .warning) }
                    HStack {
                        Button("Discard", role: .destructive) { protection.resolve(.discard) }
                        Spacer()
                        Button("Cancel") { protection.resolve(.cancel) }.keyboardShortcut(.cancelAction)
                        Button("Save") { protection.resolve(.save) }.keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(width: 520)
                .interactiveDismissDisabled()
            }
    }
}
#endif
