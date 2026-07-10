import Foundation
import SwiftData

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

    @discardableResult
    public func repairDanglingReferences() throws -> DataIntegrityRepairReport {
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

        orphanCandidates.forEach(modelContext.delete)
        orphanReviewEvents.forEach(modelContext.delete)
        termsWithMissingSource.forEach { $0.sourceRecordID = nil }
        recordsWithMissingCourse.forEach { $0.courseID = nil }
        termsWithMissingCourse.forEach { $0.courseID = nil }

        let report = DataIntegrityRepairReport(
            deletedOrphanCandidates: orphanCandidates.count,
            deletedOrphanReviewEvents: orphanReviewEvents.count,
            clearedSourceRecordReferences: termsWithMissingSource.count,
            clearedCourseReferences: recordsWithMissingCourse.count + termsWithMissingCourse.count
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
}
