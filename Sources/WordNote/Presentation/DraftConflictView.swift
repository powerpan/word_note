import SwiftUI
import WordNoteCore

/// Inline so a comparison cannot compete with the window's unsaved-changes sheet.
struct DraftConflictView<Value: Equatable>: View {
    let draft: WordNoteEditDraft<Value>
    let fields: [WordNoteEditField<Value>]
    let loadCurrent: () throws -> WordNoteDraftVersion<Value>
    var applyTitle = "Apply to Draft"
    var onApplied: () -> Void = {}
    @State private var comparison: WordNoteEditComparison<Value>?
    @State private var choices: [String: WordNoteEditChoice] = [:]
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Stored content changed", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                if comparison != nil {
                    Button("Refresh Comparison", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly).help("Refresh comparison")
                    Button("Close Comparison", systemImage: "xmark") { comparison = nil; errorMessage = nil }
                        .labelStyle(.iconOnly).help("Close comparison")
                } else {
                    Button("Compare Changes", systemImage: "arrow.left.arrow.right", action: refresh)
                }
            }
            if let comparison {
                Text("Original v\(comparison.baselineRevision) / Stored v\(comparison.current.revision)")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = comparison.current.blockingMessage { StatusBanner(message: message, kind: .warning) }
                if comparison.differences.isEmpty { Text("No editable fields changed.").foregroundStyle(.secondary) }
                ForEach(comparison.differences) { row in
                    DraftDifferenceRow(row: row, choice: Binding(get: { choices[row.id] }, set: { choices[row.id] = $0 }))
                }
                HStack {
                    let remaining = comparison.unresolvedCount(choices: choices)
                    if remaining > 0 { Text("\(remaining) unresolved").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(AppLocalization.text(applyTitle), systemImage: "checkmark", action: apply)
                        .disabled(remaining > 0 || comparison.current.blockingMessage != nil)
                }
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func refresh() {
        do {
            comparison = try WordNoteEditComparison(draft: draft, current: loadCurrent(), fields: fields)
            choices = [:]
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply() {
        guard let comparison else { return }
        do {
            try comparison.apply(to: draft, latest: loadCurrent(), choices: choices)
            self.comparison = nil
            errorMessage = nil
            onApplied()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct DraftDifferenceRow: View {
    let row: WordNoteEditDifference
    @Binding var choice: WordNoteEditChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.comparisonTitle(row)).font(.subheadline.bold())
                Spacer()
                if row.requiresChoice {
                    Picker("Use value", selection: $choice) {
                        Text("Choose").tag(WordNoteEditChoice?.none)
                        Text("Mine").tag(Optional(WordNoteEditChoice.mine))
                        Text("Stored").tag(Optional(WordNoteEditChoice.stored))
                    }.labelsHidden().frame(width: 160)
                } else {
                    Text(row.isEditable && row.localChanged && !row.storedChanged ? "Keep mine" : "Keep stored")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    column("Original", row.baseline).frame(minWidth: 155)
                    column("Mine", row.mine).frame(minWidth: 155)
                    column("Stored", row.stored).frame(minWidth: 155)
                }
                VStack(alignment: .leading, spacing: 10) {
                    column("Original", row.baseline)
                    column("Mine", row.mine)
                    column("Stored", row.stored)
                }
            }
            Divider()
        }
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(AppLocalization.comparisonValue(value, in: row)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
