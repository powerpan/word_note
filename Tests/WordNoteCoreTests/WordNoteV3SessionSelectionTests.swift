import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3SessionSelectionTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testDefaultsBuildTwentyDistinctPendingCardsWithoutPresentingOrCharging() throws {
        let container = try Support.container(count: 25)
        let before = try Support.snapshot(container)
        let service = try WordNoteV3ReviewService(container: container)
        let result = try service.startSession(scope: Support.scope(), at: Support.now)
        XCTAssertEqual(result.items.count, 20)
        XCTAssertEqual(Set(result.items.map(\.originalCardID)).count, 20)
        XCTAssertEqual(result.items.map(\.position), Array(0..<20))
        XCTAssertTrue(result.items.allSatisfy { $0.status == .pending && $0.attemptCount == 0 })
        XCTAssertEqual(result.session.status, .active)
        XCTAssertEqual(result.session.currentItemID, result.items.first?.id)
        XCTAssertEqual(result.session.introductions, [])
        XCTAssertEqual(try Support.snapshot(container).cards, before.cards)
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 0)
    }

    func testNewCardsRequireOptInAndOnlyFillRemainingDailyQuota() throws {
        let container = try Support.container(newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        for scope in [Support.scope(), Support.scope(newCards: true)] {
            XCTAssertThrowsError(try service.startSession(scope: scope, newCardLimit: 0, at: Support.now)) {
                XCTAssertEqual($0 as? WordNoteV3ReviewError, .noEligibleCards)
            }
        }
        XCTAssertNil(try service.resumableSession())
        let result = try service.startSession(scope: Support.scope(newCards: true), newCardLimit: 3, at: Support.now)
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.session.newCardLimitSnapshot, 3)
        XCTAssertEqual(try service.newCardQuota(limit: 3, studyTimeZoneID: Support.zone, at: Support.now).remaining, 3)
    }

    func testCourseMembershipAndDirectionFilterDoNotUseLegacyCourseField() throws {
        let container = try Support.container(count: 6)
        let before = try Support.snapshot(container)
        let a = try XCTUnwrap(before.content.content.courses.first { $0.courseName == "Course A" })
        let service = try WordNoteV3ReviewService(container: container)
        let result = try service.startSession(scope: Support.scope(courseID: a.id), at: Support.now)
        let members = Set(before.content.courseLinks.filter { $0.courseID == a.id }.map(\.termID))
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.session.scope.courseName, "Course A")
        XCTAssertTrue(result.items.allSatisfy { item in before.cards.contains { $0.id == item.cardID && members.contains($0.termID) } })
        XCTAssertTrue(before.content.content.terms.allSatisfy { $0.courseID == nil })
        let other = try Support.container(count: 1)
        XCTAssertThrowsError(try WordNoteV3ReviewService(container: other).startSession(scope: Support.scope(mode: .chineseToEnglish), at: Support.now))
    }

    func testMinuteDuePriorityDayDueAndNewOrderingExcludesWaitingBuriedAndSuspended() throws {
        let container = try Support.container(count: 8)
        var value = try Support.snapshot(container)
        value.cards[0].schedule.phase = .new
        value.cards[0].schedule.nextReviewAt = nil
        value.cards[1].schedule.priorityRequestedAt = Support.now
        value.cards[1].schedule.nextReviewAt = Support.now.addingTimeInterval(172800)
        for index in [2, 4] {
            value.cards[index].schedule.phase = .relearning
            value.cards[index].schedule.masteryLevel = .vague
            value.cards[index].schedule.relearningDayKey = "2026-09-21"
            value.cards[index].schedule.relearningTimeZoneID = Support.zone
        }
        value.cards[2].schedule.nextReviewAt = Support.now
        value.cards[4].schedule.nextReviewAt = Support.now.addingTimeInterval(1)
        value.cards[5].schedule.buriedUntil = Support.now.addingTimeInterval(3600)
        value.cards[6].schedule.phase = .suspended
        value.cards[7].schedule.nextReviewAt = try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end
        try value.validate()
        let selection = try ReviewSessionSelection(payload: value, scope: Support.scope(newCards: true), target: 20, newCardLimit: 10, at: Support.now)
        XCTAssertEqual(selection.cardIDs, [2, 1, 3, 0].map { value.cards[$0].id })
        value.cards.reverse()
        value.content.content.terms.reverse()
        XCTAssertEqual(try ReviewSessionSelection(payload: value, scope: Support.scope(newCards: true), target: 20, newCardLimit: 10,
            at: Support.now).cardIDs, selection.cardIDs)
    }

    func testWeakScopeDoesNotTurnLegacyCountsIntoFailures() throws {
        var legacy = try V3TestSupport.payload()
        legacy.content.content.terms[0].wrongCount = 7
        let history = try XCTUnwrap(legacy.termHistories.firstIndex { $0.id == legacy.content.content.terms[0].id })
        legacy.termHistories[history].legacyWrongCount = 7
        let card = try XCTUnwrap(legacy.cards.firstIndex { $0.termID == legacy.content.content.terms[0].id })
        legacy.cards[card].mode = .englishToChinese
        legacy.cards[card].schedule.phase = .review
        legacy.cards[card].schedule.nextReviewAt = Support.now
        try legacy.validate()
        XCTAssertTrue(legacy.content.content.terms.contains { $0.wrongCount > 0 })
        XCTAssertTrue(try ReviewSessionSelection(payload: legacy, scope: Support.scope(queue: .weakTerms), target: 20,
            newCardLimit: 10, at: Support.now).cardIDs.isEmpty)
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let initial = try service.startSession(scope: Support.scope(), at: Support.now)
        let lease = try service.acquireLease(sessionID: initial.session.id, ownerID: UUID())
        _ = try service.presentNextCard(lease: lease, expectedRevision: initial.session.revision, at: Support.now)
        _ = try Support.answer(service, lease: lease, feedback: .again)
        let current = try service.reviewSession(initial.session.id)
        _ = try service.endSession(lease: lease, expectedRevision: current.session.revision, at: Support.now)
        var snapshot = try Support.snapshot(container)
        let weak = Support.scope(queue: .weakTerms)
        XCTAssertTrue(try ReviewSessionSelection(payload: snapshot, scope: weak, target: 20, newCardLimit: 10, at: Support.now).cardIDs.isEmpty)
        XCTAssertEqual(try ReviewSessionSelection(payload: snapshot, scope: weak, target: 20, newCardLimit: 10,
            at: Support.now.addingTimeInterval(600)).cardIDs.count, 1)
        snapshot.eventStates[0].invalidatedAt = Support.now
        XCTAssertTrue(try ReviewSessionSelection(payload: snapshot, scope: weak, target: 20, newCardLimit: 10,
            at: Support.now.addingTimeInterval(600)).cardIDs.isEmpty)
        snapshot.cards[0].schedule.priorityRequestedAt = Support.now
        XCTAssertEqual(try ReviewSessionSelection(payload: snapshot, scope: weak, target: 20, newCardLimit: 10,
            at: Support.now.addingTimeInterval(600)).cardIDs.count, 1)
    }

    func testStartRetryIsReadOnlyAndASecondResumableGroupIsRejected() throws {
        let container = try Support.container()
        var saves = 0
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in saves += 1 })
        let id = UUID()
        let first = try service.startSession(id: id, scope: Support.scope(), at: Support.now)
        let retry = try WordNoteV3ReviewService(container: container).startSession(id: id, scope: Support.scope(), at: Support.now.addingTimeInterval(100))
        XCTAssertEqual(first, retry)
        XCTAssertEqual(saves, 1)
        XCTAssertThrowsError(try service.startSession(scope: Support.scope(), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .activeSessionExists(id))
        }
        XCTAssertThrowsError(try service.startSession(id: id, scope: Support.scope(newCards: true), at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .actionConflict)
        }
        XCTAssertEqual(try service.reviewSession(id), first)
    }

    func testCourseRenameMembershipRemovalAndNewCardsDoNotExtendFixedGroup() throws {
        let container = try Support.container(count: 4)
        let course = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.CourseModel>()).first)
        let service = try WordNoteV3ReviewService(container: container)
        let result = try service.startSession(scope: Support.scope(courseID: course.id), at: Support.now)
        course.courseName = "Renamed"
        let links = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermCourseLinkModel>())
        links.filter { $0.courseID == course.id }.forEach(container.mainContext.delete)
        let term = WordNoteSchemaV3.TermModel(term: "additional", termType: .word, chineseMeaning: "新增", nextReviewAt: nil)
        container.mainContext.insert(term)
        container.mainContext.insert(WordNoteSchemaV3.ReviewCardModel(termID: term.id))
        try container.mainContext.save()
        XCTAssertEqual(try service.reviewSession(result.session.id), result)
        XCTAssertEqual(try service.startSession(id: result.session.id, scope: Support.scope(courseID: course.id), at: Support.now), result)
    }

    func testInvalidOptionsEmptyScopeAndFailedSaveLeaveNoPartialSession() throws {
        let container = try Support.container()
        let before = try Support.snapshot(container)
        let service = try WordNoteV3ReviewService(container: container)
        for target in [4, 101] { XCTAssertThrowsError(try service.startSession(scope: Support.scope(), targetCardCount: target, at: Support.now)) }
        for limit in [-1, 51] { XCTAssertThrowsError(try service.startSession(scope: Support.scope(), newCardLimit: limit, at: Support.now)) }
        XCTAssertThrowsError(try service.startSession(scope: Support.scope(timeZone: "Not/AZone"), at: Support.now))
        XCTAssertThrowsError(try service.startSession(scope: Support.scope(courseID: UUID()), at: Support.now))
        XCTAssertThrowsError(try service.startSession(scope: Support.scope(), at: Date(timeIntervalSince1970: .nan)))
        let failing = try WordNoteV3ReviewService(container: container, beforeSave: { _ in throw V3ReviewTestSupport.Failure.save })
        XCTAssertThrowsError(try failing.startSession(scope: Support.scope(), at: Support.now))
        XCTAssertEqual(try Support.snapshot(container), before)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testManualImportanceThenCreationThenUUIDProvideStableTieBreaks() throws {
        let container = try Support.container(count: 4)
        var value = try Support.snapshot(container)
        for index in value.content.content.terms.indices { value.content.content.terms[index].importanceRaw = "low" }
        let important = try XCTUnwrap(value.content.content.terms.firstIndex { $0.id == value.cards[2].termID })
        value.content.content.terms[important].importanceRaw = "high"
        value.cards[3].createdAt = Support.now.addingTimeInterval(-1)
        let selected = try ReviewSessionSelection(payload: value, scope: Support.scope(), target: 20, newCardLimit: 10, at: Support.now)
        XCTAssertEqual(selected.cardIDs, [2, 3, 0, 1].map { value.cards[$0].id })
    }

    func testChineseRecallRequiresMeaningAndDoesNotSubstituteAnotherDirection() throws {
        let container = try Support.container(count: 2)
        var value = try Support.snapshot(container)
        for index in value.cards.indices { value.cards[index].mode = .chineseToEnglish }
        let empty = try XCTUnwrap(value.content.content.terms.firstIndex { $0.id == value.cards[0].termID })
        value.content.content.terms[empty].chineseMeaning = " \n "
        let selected = try ReviewSessionSelection(payload: value, scope: Support.scope(mode: .chineseToEnglish),
            target: 20, newCardLimit: 10, at: Support.now)
        XCTAssertEqual(selected.cardIDs, [value.cards[1].id])
    }
}
