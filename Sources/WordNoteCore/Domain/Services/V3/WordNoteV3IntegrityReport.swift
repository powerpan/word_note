import Foundation

public struct WordNoteV3IntegrityIssue: Equatable, Sendable {
    public enum Entity: String, Sendable { case card, session, sessionItem, termHistory, eventState }
    public enum Kind: String, Sendable {
        case missingReference, mismatchedReference, duplicateIdentifier, duplicateBusinessKey, metadataMismatch, invalidState
    }
    public let entity: Entity
    public let entityID: UUID
    public let field: String
    public let kind: Kind
    public let relatedID: UUID?
}

public struct WordNoteV3IntegrityReport: Equatable, Sendable {
    public let content: WordNoteV2IntegrityReport
    public let issues: [WordNoteV3IntegrityIssue]
    public let remainingValidationError: WordNoteSnapshotError?

    public var detachableReferenceCount: Int { content.detachableReferenceCount }
    public var requiresManualResolution: Bool { content.requiresManualResolution || !issues.isEmpty || remainingValidationError != nil }
    public var canPrepareRepair: Bool { !requiresManualResolution && detachableReferenceCount > 0 }
    public var isStructurallyValid: Bool { !requiresManualResolution && detachableReferenceCount == 0 }
}

public enum WordNoteV3IntegrityError: LocalizedError, Equatable {
    case unresolvedIssues(WordNoteV3IntegrityReport)
    case staleRepairPlan

    public var errorDescription: String? {
        switch self {
        case .unresolvedIssues: "Some data relationships need manual resolution. No records, review cards, or sessions were deleted or changed."
        case .staleRepairPlan: "The data changed after the repair preview. Inspect it again before continuing."
        }
    }
}

public struct WordNoteV3IntegrityRepairPlan: Sendable {
    public let report: WordNoteV3IntegrityReport
    public let repairedPayload: WordNoteSnapshotV3Payload
    private let source: WordNoteSnapshotV3Payload

    init(report: WordNoteV3IntegrityReport, source: WordNoteSnapshotV3Payload, repairedPayload: WordNoteSnapshotV3Payload) {
        self.report = report
        self.source = source
        self.repairedPayload = repairedPayload
    }

    public func validatedPayload(matching current: WordNoteSnapshotV3Payload) throws -> WordNoteSnapshotV3Payload {
        guard current.canonicalized == source else { throw WordNoteV3IntegrityError.staleRepairPlan }
        try repairedPayload.validate()
        return repairedPayload
    }
}
