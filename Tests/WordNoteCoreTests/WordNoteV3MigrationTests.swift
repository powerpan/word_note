import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3MigrationTests: XCTestCase {
    func testMigrationCreatesExactlyOneCardPerTermAndDoesNotIncreaseDueWork() throws {
        var source = try V3TestSupport.source()
        source.content.terms[0].nextReviewAt = nil
        source.content.terms[1].nextReviewAt = V3TestSupport.date.addingTimeInterval(864_000)
        let result = try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)
        XCTAssertEqual(result.cards.count, source.content.terms.count)
        XCTAssertEqual(Set(result.cards.map(\.termID)), Set(source.content.terms.map(\.id)))
        let cutoff = V3TestSupport.date.addingTimeInterval(3600)
        XCTAssertEqual(result.cards.filter { $0.schedule.nextReviewAt.map { $0 < cutoff } ?? false }.count,
                       source.content.terms.filter { $0.nextReviewAt.map { $0 < cutoff } ?? false }.count)
        let suspended = try XCTUnwrap(result.cards.first { $0.termID == source.content.terms[0].id })
        XCTAssertEqual(suspended.schedule.phase, .suspended)
        XCTAssertNil(suspended.schedule.nextReviewAt)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.sessionItems.isEmpty)
    }

    func testLatestValidEventChoosesDirectionWithoutSharingOtherDirectionHistory() throws {
        var source = try V3TestSupport.source()
        let term = source.content.terms[0]
        let earlier = event(term.id, mode: .englishToChinese, at: V3TestSupport.date)
        let latest = event(term.id, mode: .chineseToEnglish, at: V3TestSupport.date.addingTimeInterval(1))
        source.content.reviewEvents = [latest, earlier]
        let result = try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)
        let card = try XCTUnwrap(result.cards.first { $0.termID == term.id })
        XCTAssertEqual(card.mode, .chineseToEnglish)
        XCTAssertEqual(result.eventStates.first { $0.id == latest.id }?.cardID, card.id)
        XCTAssertNil(result.eventStates.first { $0.id == earlier.id }?.cardID)
        XCTAssertTrue(result.cards.filter { $0.termID != term.id }.allSatisfy { $0.mode == .englishToChinese })
        XCTAssertEqual(result.content, source.canonicalized)
    }

    func testEqualTimestampUsesStableEventIDTieBreakIndependentOfFetchOrder() throws {
        var source = try V3TestSupport.source()
        let termID = source.content.terms[0].id
        var low = event(termID, mode: .englishToChinese, at: V3TestSupport.date)
        var high = event(termID, mode: .chineseToEnglish, at: V3TestSupport.date)
        low.id = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        high.id = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        source.content.reviewEvents = [high, low]
        let first = try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)
        source.content.reviewEvents.reverse()
        source.content.terms.reverse()
        source.recordStates.reverse()
        XCTAssertEqual(try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date), first)
        XCTAssertEqual(first.cards.first { $0.termID == termID }?.mode, .chineseToEnglish)
    }

    func testAllLegacyScheduleValuesAndMixedCountersArePreservedNotInferred() throws {
        var source = try V3TestSupport.source()
        source.content.terms[0].wrongCount = 27
        source.content.terms[0].reviewCount = 31
        source.content.terms[0].duplicateHitCount = 19
        source.content.terms[0].correctStreak = 7
        source.content.terms[0].reviewIntervalDays = 42
        let result = try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)
        for term in source.content.terms {
            let card = try XCTUnwrap(result.cards.first { $0.termID == term.id })
            XCTAssertEqual(card.schedule.masteryLevel.rawValue, term.masteryLevelRaw)
            XCTAssertEqual(card.schedule.intervalDays, term.reviewIntervalDays)
            XCTAssertEqual(card.schedule.confidentStreak, term.correctStreak)
            XCTAssertEqual(card.schedule.nextReviewAt, term.nextReviewAt)
            XCTAssertEqual(card.schedule.lastReviewedAt, term.lastReviewedAt)
            XCTAssertEqual(card.schedule.lapseCount, 0)
            XCTAssertNil(card.schedule.introducedAt)
            XCTAssertNil(card.schedule.priorityRequestedAt)
            let history = try XCTUnwrap(result.termHistories.first { $0.id == term.id })
            XCTAssertEqual(history.legacyWrongCount, term.wrongCount)
            XCTAssertEqual(history.legacyReviewCount, term.reviewCount)
            XCTAssertEqual(history.legacyDuplicateHitCount, term.duplicateHitCount)
            XCTAssertEqual(history.legacySnapshotAt, V3TestSupport.date)
        }
        XCTAssertEqual(result.content.content.terms, source.content.terms)
    }

    func testOldEventValuesArePreservedWithoutFabricatedSessionActionOrDates() throws {
        let source = try V3TestSupport.source()
        let result = try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)
        XCTAssertEqual(result.content.content.reviewEvents, source.content.reviewEvents)
        for state in result.eventStates {
            XCTAssertEqual(state.feedbackSemanticsVersion, 1)
            XCTAssertEqual(state.schedulerVersion, ReviewSchedulerVersion.legacy)
            XCTAssertNil(state.originalCardID)
            XCTAssertNil(state.sessionID)
            XCTAssertNil(state.actionID)
            XCTAssertNil(state.studyDayKey)
            XCTAssertNil(state.studyTimeZoneID)
            XCTAssertNil(state.beforeSchedule)
            XCTAssertNil(state.afterSchedule)
            XCTAssertNil(state.clockAnomaly)
        }
    }

    func testLatestLegacyClozeFailsPreflightRatherThanInventingATargetOrDirection() throws {
        var source = try V3TestSupport.source()
        let value = event(source.content.terms[0].id, mode: .contextCloze, at: V3TestSupport.date)
        source.content.reviewEvents = [value]
        let before = source
        let issues = try WordNoteV2ToV3Migration.preflight(source)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].eventID, value.id)
        XCTAssertEqual(issues[0].kind, .legacyClozeNeedsTarget)
        XCTAssertThrowsError(try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)) {
            XCTAssertEqual($0 as? WordNoteV2ToV3Migration.MigrationError, .preflightFailed(issues))
        }
        XCTAssertEqual(source, before)
    }

    func testEarlierClozeHistoryRemainsUnassignedWhenTheLatestModeCanMigrate() throws {
        var source = try V3TestSupport.source()
        let id = source.content.terms[0].id
        let cloze = event(id, mode: .contextCloze, at: V3TestSupport.date)
        source.content.reviewEvents = [cloze, event(id, mode: .englishToChinese, at: V3TestSupport.date.addingTimeInterval(1))]
        let result = try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date)
        XCTAssertNil(result.eventStates.first { $0.id == cloze.id }?.cardID)
        XCTAssertEqual(result.content.content.reviewEvents, source.canonicalized.content.reviewEvents)
    }

    func testInvalidSourceAndMigrationDateAreRejectedWithoutChanges() throws {
        var source = try V3TestSupport.source()
        source.content.reviewEvents[0].termID = UUID()
        let before = source
        XCTAssertThrowsError(try WordNoteV2ToV3Migration.convert(source, at: V3TestSupport.date))
        XCTAssertEqual(source, before)
        XCTAssertThrowsError(try WordNoteV2ToV3Migration.convert(V3TestSupport.source(), at: Date(timeIntervalSince1970: .infinity)))
    }

    func testEmptyDatabaseDoesNotFabricateCardsOrEvents() throws {
        let empty = try V3TestSupport.container(WordNoteSchemaV1.self)
        let v2 = try WordNoteV1ToV2Migration.convert(WordNoteSnapshotPayload.capture(from: empty.mainContext)).payload
        let v3 = try WordNoteV2ToV3Migration.convert(v2, at: V3TestSupport.date)
        XCTAssertEqual(v3.counts.total, 0)
        XCTAssertTrue(v3.termHistories.isEmpty)
        XCTAssertTrue(v3.eventStates.isEmpty)
        XCTAssertThrowsError(try WordNoteV2ToV3Migration.convert(v2, at: Date(timeIntervalSince1970: .infinity)))
    }

    private func event(_ termID: UUID, mode: ReviewMode, at date: Date) -> WordNoteSnapshotPayload.ReviewEvent {
        .init(WordNoteSchemaV2.ReviewEventModel(termID: termID, mode: mode, feedback: .good,
            previousMasteryLevel: .new, newMasteryLevel: .familiar, reviewedAt: date))
    }
}
