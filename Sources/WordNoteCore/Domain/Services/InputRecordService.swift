import Foundation
import SwiftData

public enum InputRecordValidationError: LocalizedError, Equatable {
    case blankRawText

    public var errorDescription: String? {
        switch self {
        case .blankRawText:
            return "Raw text cannot be empty."
        }
    }
}

@MainActor
public struct InputRecordService {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func createDraft(
        rawText: String,
        courseID: UUID?,
        sourceType: SourceType,
        note: String?
    ) throws -> InputRecordModel {
        let trimmedRawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedRawText) else {
            throw InputRecordValidationError.blankRawText
        }

        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = InputRecordModel(
            rawText: trimmedRawText,
            courseID: courseID,
            sourceType: sourceType,
            note: normalizedNote?.isEmpty == true ? nil : normalizedNote
        )

        modelContext.insert(record)
        try modelContext.save()
        return record
    }

    public func ignore(_ record: InputRecordModel) throws {
        record.status = .ignored
        record.touch()
        try modelContext.save()
    }

    public func delete(_ record: InputRecordModel) throws {
        modelContext.delete(record)
        try modelContext.save()
    }
}
