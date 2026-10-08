import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class LearningOverviewTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testCourseAndGlobalCountsUseTheSameCardsAsReviewSelection() throws {
        let container = try Support.container(count: 6)
        let before = try Support.snapshot(container)
        let service = try WordNoteV3ReviewService(container: container)
        for courseID in [UUID?.none] + before.content.content.courses.map({ Optional($0.id) }) {
            let value = try service.learningOverview(courseID: courseID, mode: .englishToChinese,
                studyTimeZoneID: Support.zone, at: Support.now)
            let expected = try service.statistics(courseID: courseID, mode: .englishToChinese,
                studyTimeZoneID: Support.zone, at: Support.now)
            XCTAssertEqual(value.statistics, expected)
            XCTAssertEqual(value.terms.count, Set(value.cards.map { $0.term.id }).count)
            XCTAssertEqual(value.statistics.workload.readyCards, value.cards.filter { $0.state == .ready }.count)
        }
        XCTAssertEqual(try Support.snapshot(container), before)
        let course = before.content.content.courses[0]
        let overview = try service.learningOverview(courseID: course.id, mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: Support.now)
        let session = try service.startSession(scope: Support.scope(courseID: course.id), at: Support.now)
        XCTAssertEqual(Set(session.items.compactMap(\.cardID)), Set(overview.cards.filter { $0.state == .ready }.map(\.id)))
    }

    func testCardFiltersConjoinOnOneCardAndIgnoreLegacyMastery() throws {
        let container = try Support.container(count: 1)
        var payload = try Support.snapshot(container)
        let original = payload.cards[0]
        payload.content.content.terms[0].masteryLevelRaw = MasteryLevel.mastered.rawValue
        payload.cards[0].schedule.masteryLevel = .vague
        var second = original
        second.id = UUID()
        second.mode = .chineseToEnglish
        second.schedule.masteryLevel = .familiar
        payload.cards.append(second)
        let index = try ReviewCardLearningIndex(payload: payload, studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(index.matching(query: .init(mode: .englishToChinese, mastery: .vague, state: .ready)).map(\.id), [original.id])
        XCTAssertTrue(index.matching(query: .init(mode: .englishToChinese, mastery: .familiar)).isEmpty)
        XCTAssertTrue(index.matching(query: .init(mastery: .mastered)).isEmpty)
        let result = try LearningOverviewBuilder(payload: payload).overview(mode: .chineseToEnglish,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(result.terms.count, 1)
        XCTAssertEqual(result.cards.map(\.id), [second.id])
    }

    func testCardlessVocabularyStillAppearsInCourseReading() throws {
        let container = try Support.container(count: 2)
        var payload = try Support.snapshot(container)
        let removed = payload.cards.removeFirst()
        let value = try LearningOverviewBuilder(payload: payload).overview(mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertEqual(value.terms.count, 2)
        XCTAssertEqual(value.cards.count, 1)
        XCTAssertTrue(value.terms.contains { $0.id == removed.termID })
    }

    func testWeaknessUsesValidAgainOrPendingPriorityNotLegacyCounters() throws {
        let container = try Support.container(count: 2)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease, feedback: .again)
        var payload = try Support.snapshot(container)
        let builder = try LearningOverviewBuilder(payload: payload)
        XCTAssertEqual(try builder.overview(mode: .englishToChinese, studyTimeZoneID: Support.zone,
            at: Support.now).weakTermIDs, [source.term.id])
        for index in payload.eventStates.indices { payload.eventStates[index].invalidatedAt = Support.now }
        for index in payload.content.content.terms.indices { payload.content.content.terms[index].wrongCount = 100 }
        for index in payload.termHistories.indices {
            payload.termHistories[index].legacySnapshotAt = Support.now
            payload.termHistories[index].legacyWrongCount = 100
            payload.termHistories[index].legacyReviewCount = 0
            payload.termHistories[index].legacyDuplicateHitCount = 0
        }
        XCTAssertTrue(try LearningOverviewBuilder(payload: payload).overview(mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: Support.now).weakTermIDs.isEmpty)
        let other = try XCTUnwrap(payload.cards.firstIndex { $0.termID != source.term.id })
        payload.cards[other].schedule.priorityRequestedAt = Support.now
        XCTAssertEqual(try LearningOverviewBuilder(payload: payload).overview(mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: Support.now).weakTermIDs, [payload.cards[other].termID])
    }

    func testWaitingChangesAtDueBoundaryWithoutMutatingData() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease, feedback: .again)
        let before = try Support.snapshot(container)
        let first = try service.learningOverview(mode: .englishToChinese, studyTimeZoneID: Support.zone, at: Support.now)
        let due = try XCTUnwrap(first.cards.first?.waitingUntil)
        XCTAssertEqual(first.cards.first?.state, .waiting)
        XCTAssertEqual(first.statistics.workload.nextRelearningAt, due)
        XCTAssertEqual(try service.learningOverview(mode: .englishToChinese, studyTimeZoneID: Support.zone,
            at: due.addingTimeInterval(-1)).cards.first?.state, .waiting)
        XCTAssertEqual(try service.learningOverview(mode: .englishToChinese, studyTimeZoneID: Support.zone,
            at: due).cards.first?.state, .ready)
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testRecentEncountersKeepFrozenCourseAfterMembershipRemoval() throws {
        var payload = try V3TestSupport.payload()
        let occurrence = try XCTUnwrap(payload.content.occurrences.first { $0.courseID != nil })
        payload.content.courseLinks.removeAll { $0.courseID == occurrence.courseID }
        let value = try LearningOverviewBuilder(payload: payload).overview(courseID: occurrence.courseID,
            mode: .englishToChinese, studyTimeZoneID: Support.zone, at: V3TestSupport.date)
        XCTAssertTrue(value.terms.isEmpty)
        XCTAssertTrue(value.cards.isEmpty)
        XCTAssertTrue(value.recentOccurrences.contains { $0.id == occurrence.id })
        XCTAssertTrue(value.recentOccurrences.allSatisfy { $0.courseID == occurrence.courseID })
        let earlier = try LearningOverviewBuilder(payload: payload).overview(mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: .distantPast)
        XCTAssertTrue(earlier.recentOccurrences.isEmpty)
    }

    func testPendingListUsesTheInboxProjectionAndCourseFilter() throws {
        let container = try WordNoteV3ServiceTestSupport.container()
        let payload = try Support.snapshot(container)
        let records = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>())
        let candidates = try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.CandidateTermModel>())
        let index = InboxBrowseIndex(items: records.map { .init(record: $0, candidates: candidates) })
        for courseID in [UUID?.none] + payload.content.content.courses.map({ Optional($0.id) }) {
            var query = InboxBrowseQuery()
            query.courseID = courseID
            let expected = index.matching(query).active
            let result = try LearningOverviewBuilder(payload: payload).overview(courseID: courseID,
                mode: .englishToChinese, studyTimeZoneID: Support.zone, at: Support.now).pendingRecords
            XCTAssertEqual(result.map(\.id), expected.map(\.id))
            XCTAssertEqual(result.map(\.preview), expected.map(\.preview))
            XCTAssertEqual(result.map(\.canConfirm), expected.map(\.canConfirm))
        }
    }

    func testOverviewPreservesTheActiveFixedGroupAcrossDifferentScope() throws {
        let container = try Support.container(count: 6)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        let before = try Support.snapshot(container)
        let course = before.content.content.courses[0]
        let result = try service.learningOverview(courseID: course.id, mode: .chineseToEnglish,
            studyTimeZoneID: Support.zone, at: Support.now)
        XCTAssertTrue(result.cards.isEmpty)
        XCTAssertEqual(result.resumableSession?.session.id, lease.sessionID)
        XCTAssertEqual(result.resumableSession?.items.map(\.id), try service.reviewSession(lease.sessionID).items.map(\.id))
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testInvalidScopeAndTimeNeverReturnUnscopedFallback() throws {
        let builder = try LearningOverviewBuilder(payload: Support.snapshot(Support.container(count: 1)))
        XCTAssertThrowsError(try builder.overview(courseID: UUID(), mode: .englishToChinese,
            studyTimeZoneID: Support.zone, at: Support.now))
        XCTAssertThrowsError(try builder.overview(mode: .englishToChinese, studyTimeZoneID: "Invalid/Zone", at: Support.now))
        XCTAssertThrowsError(try builder.overview(mode: .englishToChinese, studyTimeZoneID: Support.zone,
            at: Date(timeIntervalSince1970: .nan)))
    }
}
