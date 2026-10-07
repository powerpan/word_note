import Foundation

public struct WordNoteV2IntegrityIssue: Codable, Equatable, Sendable {
    public enum Entity: String, Codable, Sendable {
        case course, inputRecord, candidate, term, reviewEvent, occurrence, courseLink, lookupEvent
        case courseRevision, recordState, candidateState, termState
    }

    public enum Kind: String, Codable, Sendable {
        case missingReference, mismatchedReference, duplicateIdentifier, duplicateBusinessKey
        case metadataMismatch, invalidCandidateState, unresolvedSavedCandidate, legacySubjectNeedsReview
        case ambiguousHeadword
    }

    public enum Resolution: String, Codable, Sendable {
        case detachMissingOptionalReference
        case manualResolutionRequired
        case warning
    }

    public let entity: Entity
    public let entityID: UUID
    public let field: String
    public let kind: Kind
    public let relatedID: UUID?
    public let resolution: Resolution
}

public struct WordNoteV2IntegrityReport: Equatable, Sendable {
    public let issues: [WordNoteV2IntegrityIssue]
    /// Any validation error remaining after only the proposed optional-reference detachments.
    public let remainingValidationError: WordNoteSnapshotError?

    public var detachableReferenceCount: Int {
        issues.filter { $0.resolution == .detachMissingOptionalReference }.count
    }

    public var requiresManualResolution: Bool {
        remainingValidationError != nil || issues.contains { $0.resolution == .manualResolutionRequired }
    }

    public var isStructurallyValid: Bool {
        !requiresManualResolution && detachableReferenceCount == 0
    }

    public var canPrepareRepair: Bool {
        !requiresManualResolution && detachableReferenceCount > 0
    }
}

public enum WordNoteV2IntegrityError: LocalizedError, Equatable {
    case unresolvedIssues(WordNoteV2IntegrityReport)
    case staleRepairPlan

    public var errorDescription: String? {
        switch self {
        case .unresolvedIssues: "Some data relationships need manual resolution. No records were deleted or changed."
        case .staleRepairPlan: "The data changed after the repair preview. Inspect it again before continuing."
        }
    }
}

/// A value-only proposal for a separate staged store, never permission to edit the source store.
public struct WordNoteV2IntegrityRepairPlan: Sendable {
    public let report: WordNoteV2IntegrityReport
    public let repairedPayload: WordNoteSnapshotV2Payload
    private let source: WordNoteSnapshotV2Payload

    init(report: WordNoteV2IntegrityReport, source: WordNoteSnapshotV2Payload, repairedPayload: WordNoteSnapshotV2Payload) {
        self.report = report
        self.source = source
        self.repairedPayload = repairedPayload
    }

    public func validatedPayload(matching current: WordNoteSnapshotV2Payload) throws -> WordNoteSnapshotV2Payload {
        guard current.canonicalized == source else { throw WordNoteV2IntegrityError.staleRepairPlan }
        try repairedPayload.validate()
        return repairedPayload
    }
}
