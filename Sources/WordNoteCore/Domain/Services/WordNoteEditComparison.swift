import Foundation

public enum WordNoteEditComparisonError: LocalizedError, Equatable {
    case duplicateField
    case unresolvedFields
    case invalidChoice
    case draftChanged
    case storedChanged
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateField: "The comparison contains duplicate fields."
        case .unresolvedFields: "Choose a value for every conflicting field."
        case .invalidChoice: "The selected field is not part of this comparison."
        case .draftChanged: "Your draft changed after this comparison opened. Refresh the comparison."
        case .storedChanged: "The stored content changed again. Refresh the comparison before applying it."
        case .unavailable(let message): message
        }
    }
}

public enum WordNoteEditChoice: String, CaseIterable, Sendable {
    case mine
    case stored
}

public struct WordNoteEditDifference: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let baseline: String
    public let mine: String
    public let stored: String
    public let localChanged: Bool
    public let storedChanged: Bool
    public let isConflict: Bool
    public let isEditable: Bool
    public var requiresChoice: Bool { isEditable && isConflict }
}

/// Typed equality decides conflicts. Display text never determines whether values match.
public struct WordNoteEditField<Value> {
    public let id: String
    private let difference: (Value, Value, Value) -> WordNoteEditDifference
    private let copy: ((Value, inout Value) -> Void)?

    public init<Field: Equatable>(
        _ id: String, title: String, keyPath: WritableKeyPath<Value, Field>, display: @escaping (Field) -> String
    ) {
        self.init(id, title: title, value: { $0[keyPath: keyPath] },
                  update: { field, value in value[keyPath: keyPath] = field }, display: display)
    }

    public init<Field: Equatable>(
        _ id: String, title: String, value: @escaping (Value) -> Field,
        update: ((Field, inout Value) -> Void)? = nil, display: @escaping (Field) -> String
    ) {
        self.id = id
        difference = { baseline, local, current in
            let old = value(baseline), mine = value(local), stored = value(current)
            return WordNoteEditDifference(id: id, title: title, baseline: display(old), mine: display(mine), stored: display(stored),
                                          localChanged: mine != old, storedChanged: stored != old,
                                          isConflict: mine != old && stored != old && mine != stored, isEditable: update != nil)
        }
        copy = update.map { setter in { source, target in setter(value(source), &target) } }
    }

    fileprivate func row(_ baseline: Value, _ local: Value, _ current: Value) -> WordNoteEditDifference {
        difference(baseline, local, current)
    }
    fileprivate func copyValue(from source: Value, to target: inout Value) { copy?(source, &target) }
}

public struct WordNoteDraftVersion<Value: Equatable>: Equatable {
    public let value: Value
    public let revision: Int
    public let blockingMessage: String?

    public init(_ value: Value, revision: Int, blockingMessage: String? = nil) {
        self.value = value
        self.revision = revision
        self.blockingMessage = blockingMessage
    }
}

/// An immutable three-way preview. Applying it only rebases a value draft; it never writes a store.
public struct WordNoteEditComparison<Value: Equatable> {
    public let baseline: Value
    public let local: Value
    public let current: WordNoteDraftVersion<Value>
    public let baselineRevision: Int
    private let fields: [WordNoteEditField<Value>]

    @MainActor
    public init(draft: WordNoteEditDraft<Value>, current: WordNoteDraftVersion<Value>, fields: [WordNoteEditField<Value>]) throws {
        guard Set(fields.map(\.id)).count == fields.count else { throw WordNoteEditComparisonError.duplicateField }
        baseline = draft.baseline
        local = draft.value
        baselineRevision = draft.revision
        self.current = current
        self.fields = fields
    }

    public var differences: [WordNoteEditDifference] {
        fields.map { $0.row(baseline, local, current.value) }.filter { $0.localChanged || $0.storedChanged }
    }

    public func unresolvedCount(choices: [String: WordNoteEditChoice]) -> Int {
        differences.filter { $0.requiresChoice && choices[$0.id] == nil }.count
    }

    public func resolvedValue(choices: [String: WordNoteEditChoice]) throws -> Value {
        if let message = current.blockingMessage { throw WordNoteEditComparisonError.unavailable(message) }
        let editable = Set(differences.filter(\.requiresChoice).map(\.id))
        guard Set(choices.keys).isSubset(of: editable) else { throw WordNoteEditComparisonError.invalidChoice }
        guard unresolvedCount(choices: choices) == 0 else { throw WordNoteEditComparisonError.unresolvedFields }
        var resolved = current.value
        for field in fields {
            let row = field.row(baseline, local, current.value)
            if row.isEditable && ((row.localChanged && !row.storedChanged) || choices[row.id] == .mine) {
                field.copyValue(from: local, to: &resolved)
            }
        }
        return resolved
    }

    @MainActor
    public func apply(to draft: WordNoteEditDraft<Value>, latest: WordNoteDraftVersion<Value>, choices: [String: WordNoteEditChoice]) throws {
        guard draft.baseline == baseline, draft.value == local, draft.revision == baselineRevision else {
            throw WordNoteEditComparisonError.draftChanged
        }
        guard latest == current else { throw WordNoteEditComparisonError.storedChanged }
        let resolved = try resolvedValue(choices: choices)
        draft.baseline = current.value
        draft.revision = current.revision
        draft.value = resolved
    }
}
