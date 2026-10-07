import SwiftUI
import WordNoteCore

private struct SavedChangeHistoryKey: EnvironmentKey {
    static let defaultValue: WordNoteV2UndoHistory? = nil
}

extension EnvironmentValues {
    var savedChangeHistory: WordNoteV2UndoHistory? {
        get { self[SavedChangeHistoryKey.self] }
        set { self[SavedChangeHistoryKey.self] = newValue }
    }
}

#if WORDNOTE_V2_VALIDATION
private struct SavedChangeUndoAction {
    let title: String
    let isEnabled: Bool
    let perform: () -> Void
}

private struct SavedChangeUndoActionKey: FocusedValueKey {
    typealias Value = SavedChangeUndoAction
}

private extension FocusedValues {
    var savedChangeUndoAction: SavedChangeUndoAction? {
        get { self[SavedChangeUndoActionKey.self] }
        set { self[SavedChangeUndoActionKey.self] = newValue }
    }
}

struct SavedChangeUndoControls: ViewModifier {
    @Environment(\.editProtection) private var editProtection
    @Environment(WordNoteDataProtection.self) private var dataProtection
    let history: WordNoteV2UndoHistory
    @State private var errorMessage: String?

    private var title: String { history.title.map { "Undo \($0)" } ?? "Undo Saved Change" }
    private var enabled: Bool { history.canUndo && !dataProtection.isRestoring }

    func body(content: Content) -> some View {
        content
            .toolbar {
                Button(title, systemImage: "arrow.uturn.backward", action: undo)
                    .labelStyle(.iconOnly)
                    .help(title)
                    .disabled(!enabled)
            }
            .focusedSceneValue(\.savedChangeUndoAction, SavedChangeUndoAction(title: title, isEnabled: enabled, perform: undo))
            .alert("Cannot Undo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
    }

    private func undo() {
        guard let operationID = history.operationID, enabled else { return }
        protectingEdits(editProtection) {
            do { try history.undo(expectedOperationID: operationID) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct SavedChangeUndoCommand: View {
    @FocusedValue(\.savedChangeUndoAction) private var action
    var body: some View {
        Button(action?.title ?? "Undo Saved Change", systemImage: "arrow.uturn.backward") { action?.perform() }
            .disabled(action?.isEnabled != true)
    }
}
#endif
