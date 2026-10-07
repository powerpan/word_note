import Foundation
import SwiftData

public struct DataIntegrityInspectionReport: Equatable, Sendable {
    public let orphanCandidateIDs: [UUID]
    public let orphanReviewEventIDs: [UUID]
    public let missingSourceTermIDs: [UUID]
    public let missingCourseRecordIDs: [UUID]
    public let missingCourseTermIDs: [UUID]

    public var issueCount: Int {
        orphanCandidateIDs.count + orphanReviewEventIDs.count + missingSourceTermIDs.count
            + missingCourseRecordIDs.count + missingCourseTermIDs.count
    }
}

public enum DataIntegrityStartupError: LocalizedError, Equatable {
    case unresolvedReferences(DataIntegrityInspectionReport)
    case unsavedChanges

    public var errorDescription: String? {
        switch self {
        case .unresolvedReferences(let report):
            "The database contains \(report.issueCount) broken references. Automatic cleanup was stopped to preserve your data."
        case .unsavedChanges:
            "Save or discard the current edit before inspecting stored data."
        }
    }
}

public struct DataIntegrityRepairReport: Equatable {
    public let deletedOrphanCandidates: Int
    public let deletedOrphanReviewEvents: Int
    public let clearedSourceRecordReferences: Int
    public let clearedCourseReferences: Int

    public var repairedItemCount: Int {
        deletedOrphanCandidates
            + deletedOrphanReviewEvents
            + clearedSourceRecordReferences
            + clearedCourseReferences
    }
}

@MainActor
public struct DataIntegrityService {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func inspectDanglingReferences() throws -> DataIntegrityInspectionReport {
        try danglingReferences().report
    }

    public func validateBeforeOpening() throws {
        let report = try inspectDanglingReferences()
        guard report.issueCount == 0 else { throw DataIntegrityStartupError.unresolvedReferences(report) }
    }

    /// Legacy explicit maintenance only. Startup must inspect, not silently delete recoverable rows.
    @discardableResult
    public func repairDanglingReferences() throws -> DataIntegrityRepairReport {
        try WordNoteWriteGate.check(modelContext)
        let references = try danglingReferences()
        references.orphanCandidates.forEach(modelContext.delete)
        references.orphanReviewEvents.forEach(modelContext.delete)
        references.termsWithMissingSource.forEach { $0.sourceRecordID = nil }
        references.recordsWithMissingCourse.forEach { $0.courseID = nil }
        references.termsWithMissingCourse.forEach { $0.courseID = nil }

        let report = DataIntegrityRepairReport(
            deletedOrphanCandidates: references.orphanCandidates.count,
            deletedOrphanReviewEvents: references.orphanReviewEvents.count,
            clearedSourceRecordReferences: references.termsWithMissingSource.count,
            clearedCourseReferences: references.recordsWithMissingCourse.count + references.termsWithMissingCourse.count
        )
        guard report.repairedItemCount > 0 else { return report }
        do {
            try modelContext.save()
            return report
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private struct DanglingReferences {
        let orphanCandidates: [CandidateTermModel]
        let orphanReviewEvents: [ReviewEventModel]
        let termsWithMissingSource: [TermModel]
        let recordsWithMissingCourse: [InputRecordModel]
        let termsWithMissingCourse: [TermModel]

        var report: DataIntegrityInspectionReport {
            DataIntegrityInspectionReport(
                orphanCandidateIDs: orphanCandidates.map(\.id).sorted { $0.uuidString < $1.uuidString },
                orphanReviewEventIDs: orphanReviewEvents.map(\.id).sorted { $0.uuidString < $1.uuidString },
                missingSourceTermIDs: termsWithMissingSource.map(\.id).sorted { $0.uuidString < $1.uuidString },
                missingCourseRecordIDs: recordsWithMissingCourse.map(\.id).sorted { $0.uuidString < $1.uuidString },
                missingCourseTermIDs: termsWithMissingCourse.map(\.id).sorted { $0.uuidString < $1.uuidString }
            )
        }
    }

    private func danglingReferences() throws -> DanglingReferences {
        guard modelContext.container.schema.version == WordNoteSchemaV1.versionIdentifier else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        guard !modelContext.hasChanges else { throw DataIntegrityStartupError.unsavedChanges }
        let records = try modelContext.fetch(FetchDescriptor<InputRecordModel>())
        let candidates = try modelContext.fetch(FetchDescriptor<CandidateTermModel>())
        let terms = try modelContext.fetch(FetchDescriptor<TermModel>())
        let reviewEvents = try modelContext.fetch(FetchDescriptor<ReviewEventModel>())
        let courses = try modelContext.fetch(FetchDescriptor<CourseModel>())

        let recordIDs = Set(records.map(\.id))
        let termIDs = Set(terms.map(\.id))
        let courseIDs = Set(courses.map(\.id))

        let orphanCandidates = candidates.filter { !recordIDs.contains($0.inputRecordID) }
        let orphanReviewEvents = reviewEvents.filter { !termIDs.contains($0.termID) }
        let termsWithMissingSource = terms.filter {
            guard let sourceRecordID = $0.sourceRecordID else { return false }
            return !recordIDs.contains(sourceRecordID)
        }
        let recordsWithMissingCourse = records.filter {
            guard let courseID = $0.courseID else { return false }
            return !courseIDs.contains(courseID)
        }
        let termsWithMissingCourse = terms.filter {
            guard let courseID = $0.courseID else { return false }
            return !courseIDs.contains(courseID)
        }

        return DanglingReferences(
            orphanCandidates: orphanCandidates, orphanReviewEvents: orphanReviewEvents,
            termsWithMissingSource: termsWithMissingSource, recordsWithMissingCourse: recordsWithMissingCourse,
            termsWithMissingCourse: termsWithMissingCourse
        )
    }
}
