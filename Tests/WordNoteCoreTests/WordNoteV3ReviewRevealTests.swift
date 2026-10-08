import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ReviewRevealTests: XCTestCase {
    private typealias Support = V3ReviewTestSupport
    private typealias Payload = WordNoteSnapshotV3Payload

    func testRevealBuriesEnabledSiblingsAndDefersOnlyThisSessionsSiblingItems() throws {
        let original = try siblingPayload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let session = try XCTUnwrap(original.sessions.first { $0.status == .active })
        let lease = try service.acquireLease(sessionID: session.id, ownerID: UUID())
        let source = try service.currentAnswerSnapshot(sessionID: session.id)
        let revealed = try service.revealAnswer(source, lease: lease, at: Support.now)
        let after = try Support.snapshot(container, original: original)
        let until = try ReviewStudyDay(containing: Support.now, timeZoneID: session.scope.studyTimeZoneID).end
        for old in original.cards where old.termID == source.card.termID && old.id != source.card.id {
            var expected = old
            if old.schedule.phase != .suspended {
                expected.schedule.buriedUntil = until
                expected.revision += 1
                expected.updatedAt = Support.now
            }
            XCTAssertEqual(after.cards.first { $0.id == old.id }, expected)
        }
        XCTAssertEqual(revealed.card.schedule, source.card.schedule)
        XCTAssertEqual(revealed.card.revision, source.card.revision + 1)
        XCTAssertEqual(revealed.session.revision, session.revision + 1)
        let siblingItem = try XCTUnwrap(after.sessionItems.first { $0.sessionID == session.id && $0.id != source.item.id })
        XCTAssertEqual(siblingItem.status, .siblingDeferred)
        XCTAssertEqual(siblingItem.completionOutcome, .siblingDeferred)
        XCTAssertEqual(siblingItem.attemptCount, 0)
        XCTAssertNil(siblingItem.availableAt)
        let ended = try XCTUnwrap(original.sessions.first { $0.status == .ended })
        XCTAssertEqual(after.sessions.first { $0.id == ended.id }, ended)
        XCTAssertEqual(after.sessionItems.filter { $0.sessionID == ended.id }, original.sessionItems.filter { $0.sessionID == ended.id })
        XCTAssertEqual(after.content.content.terms, original.content.content.terms)
        XCTAssertEqual(after.content.termStates, original.content.termStates)
        XCTAssertEqual(after.content.content.reviewEvents, original.content.content.reviewEvents)
        XCTAssertEqual(after.eventStates, original.eventStates)
        XCTAssertEqual(after.termHistories, original.termHistories)
        XCTAssertNoThrow(try service.previewFeedback(.good, lease: lease, at: Support.now))
    }

    func testRevealIsIdempotentAndNeverShortensAnExistingBurial() throws {
        var original = try siblingPayload()
        let currentItem = try XCTUnwrap(original.sessions.first { $0.status == .active }).currentItemID
        let currentID = try XCTUnwrap(original.sessionItems.first { $0.id == currentItem }).cardID
        let index = try XCTUnwrap(original.cards.firstIndex { $0.id != currentID && $0.mode == .contextCloze })
        let later = Support.now.addingTimeInterval(172_800)
        original.cards[index].schedule.buriedUntil = later
        let container = try Support.seeded(original)
        var saves = 0
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in saves += 1 })
        let sessionID = try XCTUnwrap(original.sessions.first { $0.status == .active }).id
        let lease = try service.acquireLease(sessionID: sessionID, ownerID: UUID())
        let first = try service.revealAnswer(service.currentAnswerSnapshot(sessionID: sessionID), lease: lease, at: Support.now)
        let saved = try Support.snapshot(container, original: original)
        let again = try service.revealAnswer(first, lease: lease, at: Support.now.addingTimeInterval(1))
        XCTAssertEqual(first, again)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try Support.snapshot(container, original: original), saved)
        XCTAssertEqual(saved.cards.first { $0.id == original.cards[index].id }, original.cards[index])
    }

    func testRevealSaveFailureRollsBackSiblingsAndDoesNotGrantAnswerCapability() throws {
        let original = try siblingPayload()
        let container = try Support.seeded(original)
        var fail = true
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in if fail { throw Support.Failure.save } })
        let sessionID = try XCTUnwrap(original.sessions.first { $0.status == .active }).id
        let lease = try service.acquireLease(sessionID: sessionID, ownerID: UUID())
        let source = try service.currentAnswerSnapshot(sessionID: sessionID)
        XCTAssertThrowsError(try service.revealAnswer(source, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), original)
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
        fail = false
        XCTAssertNoThrow(try service.revealAnswer(source, lease: lease, at: Support.now))
    }

    func testRevealRejectsStaleDisplayedAnswerAndMissingOwnership() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try service.acquireLease(sessionID: original.sessions[0].id, ownerID: UUID())
        let source = try service.currentAnswerSnapshot(sessionID: lease.sessionID)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first { $0.id == source.term.id })
        term.chineseMeaning = "changed answer"
        try container.mainContext.save()
        let changed = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.revealAnswer(source, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .stalePreview)
        }
        service.releaseLease(lease)
        XCTAssertThrowsError(try service.revealAnswer(service.currentAnswerSnapshot(sessionID: lease.sessionID), lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .invalidLease)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), changed)
    }

    func testFreshContainerDoesNotRestoreInMemoryRevealedAnswer() throws {
        let original = try Support.payload()
        let first = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: first)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        _ = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let saved = try Support.snapshot(first, original: original)
        let reopened = try Support.seeded(saved)
        let fresh = try WordNoteV3ReviewService(container: reopened)
        let new = try fresh.acquireLease(sessionID: lease.sessionID, ownerID: lease.ownerID)
        XCTAssertThrowsError(try fresh.previewFeedback(.good, lease: new, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
        XCTAssertEqual(try Support.snapshot(reopened, original: original), saved)
    }

    func testRevealingAnAlreadyPresentedSecondRepeatDoesNotCountAnotherPresentation() throws {
        let original = try Support.payload(relearningRepeat: 2)
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.again, lease: lease, at: Support.now)
        XCTAssertEqual(preview.source.card.schedule.relearningRepeatCount, 2)
        XCTAssertEqual(preview.plan.disposition, .relearningLimitReached)
        XCTAssertEqual(preview.source.card.schedule, original.cards.first { $0.id == preview.source.card.id }?.schedule)
    }

    private func siblingPayload() throws -> Payload {
        var value = try V3TestSupport.clozePayload()
        let currentIndex = try XCTUnwrap(value.cards.firstIndex { $0.mode == .contextCloze })
        value.cards[currentIndex].schedule = try ReviewCardScheduler().presentation(for: value.cards[currentIndex].schedule,
            at: Support.now, studyTimeZoneID: "Asia/Hong_Kong").after
        value.cards[currentIndex].updatedAt = Support.now
        let current = value.cards[currentIndex]
        var sibling = current
        sibling.id = UUID()
        sibling.clozeTarget?.id = UUID()
        sibling.contentScopeKey = try XCTUnwrap(sibling.clozeTarget).contentScopeKey
        sibling.schedule = .init()
        sibling.updatedAt = V3TestSupport.date
        value.cards.append(sibling)
        var suspended = try XCTUnwrap(value.cards.first { $0.termID == current.termID && $0.mode == .englishToChinese })
        suspended.id = UUID()
        suspended.mode = .chineseToEnglish
        suspended.schedule.phase = .suspended
        suspended.schedule.nextReviewAt = nil
        value.cards.append(suspended)
        let sessionID = UUID(), currentItemID = UUID(), endedID = UUID()
        value.sessions = [.init(id: sessionID, scope: .init(mode: .contextCloze, studyTimeZoneID: "Asia/Hong_Kong"),
            targetCardCount: 20, newCardLimitSnapshot: 10, status: .active, currentItemID: currentItemID,
            createdAt: Support.now, updatedAt: Support.now, endedAt: nil, revision: 0),
            .init(id: endedID, scope: .init(mode: .contextCloze, studyTimeZoneID: "Asia/Hong_Kong"),
                targetCardCount: 20, newCardLimitSnapshot: 10, status: .ended, currentItemID: nil,
                createdAt: V3TestSupport.date, updatedAt: V3TestSupport.date, endedAt: V3TestSupport.date, revision: 0)]
        value.sessionItems = [.init(id: currentItemID, sessionID: sessionID, cardID: current.id, originalCardID: current.id,
            position: 0, status: .presented, attemptCount: 0, availableAt: nil, lastActionID: nil, completionOutcome: nil,
            createdAt: Support.now, updatedAt: Support.now),
            .init(id: UUID(), sessionID: sessionID, cardID: sibling.id, originalCardID: sibling.id,
                position: 1, status: .pending, attemptCount: 0, availableAt: nil, lastActionID: nil, completionOutcome: nil,
                createdAt: Support.now, updatedAt: Support.now),
            .init(id: UUID(), sessionID: endedID, cardID: sibling.id, originalCardID: sibling.id,
                position: 0, status: .pending, attemptCount: 0, availableAt: nil, lastActionID: nil, completionOutcome: nil,
                createdAt: V3TestSupport.date, updatedAt: V3TestSupport.date)]
        try value.validate()
        return value.canonicalized
    }
}
