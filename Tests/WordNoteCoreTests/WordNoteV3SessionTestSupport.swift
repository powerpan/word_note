import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum V3SessionTestSupport {
    static let now = V3ReviewTestSupport.now
    static let zone = "Asia/Hong_Kong"
    static func scope(newCards: Bool = false, courseID: UUID? = nil, mode: ReviewMode = .englishToChinese,
                      queue: ReviewQueueScope = .dueToday, timeZone: String = zone) -> ReviewSessionScopeSnapshot {
        .init(courseID: courseID, mode: mode, queue: queue, includesNewCards: newCards, studyTimeZoneID: timeZone)
    }

    static func container(count: Int = 12, newCards: Bool = false, at date: Date = now) throws -> ModelContainer {
        let container = try V3TestSupport.container()
        let a = WordNoteSchemaV3.CourseModel(courseName: "Course A", createdAt: date, updatedAt: date)
        let b = WordNoteSchemaV3.CourseModel(courseName: "Course B", createdAt: date, updatedAt: date)
        container.mainContext.insert(a)
        container.mainContext.insert(b)
        for index in 0..<count {
            let term = WordNoteSchemaV3.TermModel(term: "sample\(index)", termType: .word, chineseMeaning: "測試釋義",
                nextReviewAt: nil, createdAt: date, updatedAt: date)
            let card = WordNoteSchemaV3.ReviewCardModel(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                termID: term.id, createdAt: date)
            if !newCards { card.phaseRaw = "review"; card.nextReviewAt = date }
            container.mainContext.insert(term)
            container.mainContext.insert(card)
            container.mainContext.insert(WordNoteSchemaV3.TermCourseLinkModel(termID: term.id,
                courseID: index.isMultiple(of: 2) ? a.id : b.id, createdAt: date))
            if index == 0 {
                container.mainContext.insert(WordNoteSchemaV3.TermCourseLinkModel(termID: term.id, courseID: b.id, createdAt: date))
            }
        }
        try container.mainContext.save()
        _ = try snapshot(container)
        return container
    }

    static func snapshot(_ container: ModelContainer) throws -> WordNoteSnapshotV3Payload {
        try .capture(from: container.mainContext)
    }

    static func startPresented(_ service: WordNoteV3ReviewService, newCards: Bool = false,
                               at date: Date = now) throws -> (WordNoteV3ReviewLease, WordNoteV3ReviewAnswerSnapshot) {
        let session = try service.startSession(scope: scope(newCards: newCards), at: date)
        let lease = try service.acquireLease(sessionID: session.session.id, ownerID: UUID())
        return try (lease, show(service, lease: lease, at: date))
    }

    static func show(_ service: WordNoteV3ReviewService, lease: WordNoteV3ReviewLease,
                     at date: Date = now) throws -> WordNoteV3ReviewAnswerSnapshot {
        let session = try service.reviewSession(lease.sessionID)
        return try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: date))
    }

    static func answer(_ service: WordNoteV3ReviewService, lease: WordNoteV3ReviewLease,
                       feedback: ReviewFeedback = .good, at date: Date = now) throws -> WordNoteV3FeedbackReceipt {
        let source = try service.currentAnswerSnapshot(sessionID: lease.sessionID)
        _ = try service.revealAnswer(source, lease: lease, at: date)
        return try service.recordFeedback(service.previewFeedback(feedback, lease: lease, at: date), actionID: UUID(), lease: lease, at: date)
    }

    @discardableResult
    static func introduce(_ service: WordNoteV3ReviewService, limit: Int = 10, at date: Date = now,
                           scope: ReviewSessionScopeSnapshot = scope(newCards: true)) throws -> WordNoteV3ReviewAnswerSnapshot {
        let session = try service.startSession(scope: scope, targetCardCount: 5, newCardLimit: limit, at: date)
        let lease = try service.acquireLease(sessionID: session.session.id, ownerID: UUID())
        let source = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: session.session.revision, at: date))
        _ = try answer(service, lease: lease, at: date)
        if let remaining = try service.resumableSession() {
            _ = try service.endSession(lease: lease, expectedRevision: remaining.session.revision, at: date)
        }
        return source
    }
}
