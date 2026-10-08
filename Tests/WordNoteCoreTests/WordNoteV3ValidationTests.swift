import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ValidationTests: XCTestCase {
    func testMissingExtraAndDuplicateMetadataAreRejected() throws {
        let payload = try V3TestSupport.payload()
        let changes: [(inout WordNoteSnapshotV3Payload) -> Void] = [
            { $0.termHistories.removeLast() }, { $0.eventStates.removeLast() },
            { $0.termHistories[0].id = UUID() }, { $0.eventStates[0].id = UUID() },
            { $0.termHistories.append($0.termHistories[0]) }, { $0.eventStates.append($0.eventStates[0]) }
        ]
        try reject(payload, mutations: changes)
    }

    func testCardIDAndBusinessKeyMustBothBeUnique() throws {
        let payload = try V3TestSupport.payload()
        try reject(payload, mutations: [
            { $0.cards.append($0.cards[0]) },
            { var copy = $0.cards[0]; copy.id = UUID(); $0.cards.append(copy) }
        ])
    }

    func testInvalidCardReferencesSchedulesAndUnsupportedScopesFailClosed() throws {
        let payload = try V3TestSupport.payload()
        try reject(payload, mutations: [
            { $0.cards[0].termID = UUID() }, { $0.cards[0].contentScopeKey = "sense:future" },
            { $0.cards[0].revision = -1 }, { $0.cards[0].schedule.intervalDays = -1 },
            { $0.cards[0].schedule.confidentStreak = Int.max }, { $0.cards[0].schedule.nextReviewAt = nil },
            { $0.cards[0].schedule.relearningRepeatCount = 3 }, { $0.cards[0].schedulerVersion = "unknown" },
            { $0.cards[0].schedule.lapseCount = 1 },
            { $0.cards[0].schedule.buriedUntil = Date(timeIntervalSince1970: .infinity) },
            { $0.cards[0].createdAt = Date(timeIntervalSince1970: 100_000_000_001) }
        ])
    }

    func testNewCardsCannotInheritReviewAbilityOrAnOldDueDate() throws {
        var payload = try V3TestSupport.payload()
        payload.cards[0].schedule = .init()
        payload.cards[0].schedulerVersion = ReviewSchedulerVersion.current
        XCTAssertNoThrow(try payload.validate())
        try reject(payload, mutations: [
            { $0.cards[0].schedule.lapseCount = 1 }, { $0.cards[0].schedule.confidentStreak = 1 },
            { $0.cards[0].schedule.masteryLevel = .mastered }, { $0.cards[0].schedule.intervalDays = 7 },
            { $0.cards[0].schedule.nextReviewAt = V3TestSupport.date },
            { $0.cards[0].schedule.lastReviewedAt = V3TestSupport.date }
        ])
    }

    func testFrozenMixedCountersCannotBeChangedOrPartiallyRemoved() throws {
        let payload = try V3TestSupport.payload()
        try reject(payload, mutations: [
            { $0.termHistories[0].legacyWrongCount = -1 }, { $0.termHistories[0].legacyReviewCount = nil },
            { $0.termHistories[0].legacySnapshotAt = nil },
            { $0.content.content.terms[0].reviewCount += 1 },
            { $0.termHistories[0].legacyWrongCount = 100_000 }
        ])
    }

    func testLegacyEventsCannotBeRelabeledWithInventedAnswersOrSessions() throws {
        let payload = try V3TestSupport.payload()
        try reject(payload, mutations: [
            { $0.eventStates[0].actionID = UUID() }, { $0.eventStates[0].sessionID = UUID() },
            { $0.eventStates[0].originalCardID = UUID() }, { $0.eventStates[0].beforeSchedule = .init() },
            { $0.eventStates[0].studyDayKey = "2026-09-21" },
            { $0.eventStates[0].schedulerVersion = ReviewSchedulerVersion.current },
            { $0.eventStates[0].cardID = UUID() }
        ])
    }

    func testNewEventsRequireActionSessionCardIdentityAndCompleteScheduleValues() throws {
        let payload = try V3TestSupport.reviewedPayload()
        let i = try XCTUnwrap(payload.eventStates.firstIndex { $0.feedbackSemanticsVersion == 2 })
        try reject(payload, mutations: [
            { $0.eventStates[i].actionID = nil }, { $0.eventStates[i].sessionID = nil },
            { $0.eventStates[i].sessionID = UUID() }, { $0.eventStates[i].originalCardID = nil },
            { $0.eventStates[i].originalCardID = UUID() }, { $0.eventStates[i].cardID = nil },
            { $0.eventStates[i].beforeSchedule = nil }, { $0.eventStates[i].afterSchedule = nil },
            { $0.eventStates[i].feedbackSemanticsVersion = 3 },
            { $0.eventStates[i].afterSchedule?.masteryLevel = .mastered },
            { $0.eventStates[i].afterSchedule?.nextReviewAt = V3TestSupport.date },
            { $0.eventStates[i].afterSchedule?.lastReviewedAt = nil }
        ])
    }

    func testRepeatedActionIDIsRejectedEvenWhenEventIDsDiffer() throws {
        var payload = try V3TestSupport.reviewedPayload()
        let state = try XCTUnwrap(payload.eventStates.first { $0.feedbackSemanticsVersion == 2 })
        var event = try XCTUnwrap(payload.content.content.reviewEvents.first { $0.id == state.id })
        var repeated = state
        event.id = UUID()
        repeated.id = event.id
        payload.content.content.reviewEvents.append(event)
        payload.eventStates.append(repeated)
        XCTAssertThrowsError(try payload.validate()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .duplicateID) }
    }

    func testOnlyAgainIncrementsNewLapseCount() throws {
        var payload = try V3TestSupport.reviewedPayload()
        let stateIndex = try XCTUnwrap(payload.eventStates.firstIndex { $0.feedbackSemanticsVersion == 2 })
        let eventIndex = try XCTUnwrap(payload.content.content.reviewEvents.firstIndex { $0.id == payload.eventStates[stateIndex].id })
        payload.content.content.reviewEvents[eventIndex].feedbackRaw = ReviewFeedback.hard.rawValue
        XCTAssertThrowsError(try payload.validate())
        payload.eventStates[stateIndex].afterSchedule?.lapseCount = 0
        XCTAssertNoThrow(try payload.validate())
        payload.content.content.reviewEvents[eventIndex].feedbackRaw = ReviewFeedback.again.rawValue
        XCTAssertThrowsError(try payload.validate())
    }

    func testDayBucketsRequireValidDateTimeZoneAndBoundedRepeatCount() throws {
        let payload = try V3TestSupport.reviewedPayload()
        let i = try XCTUnwrap(payload.eventStates.firstIndex { $0.feedbackSemanticsVersion == 2 })
        try reject(payload, mutations: [
            { $0.eventStates[i].studyDayKey = "2026-02-30" }, { $0.eventStates[i].studyDayKey = "2026-2-01" },
            { $0.eventStates[i].studyTimeZoneID = "Unknown/Zone" }, { $0.eventStates[i].studyDayKey = nil },
            { $0.cards[0].schedule.relearningTimeZoneID = nil },
            { $0.cards[0].schedule.relearningDayKey = "2026-13-01" },
            { $0.cards[0].schedule.relearningRepeatCount = 3 }
        ])
    }

    func testSessionStatusCursorBoundsAndSingleResumableSessionAreEnforced() throws {
        let payload = try V3TestSupport.reviewedPayload()
        try reject(payload, mutations: [
            { $0.sessions[0].targetCardCount = 4 }, { $0.sessions[0].targetCardCount = 101 },
            { $0.sessions[0].newCardLimitSnapshot = 51 }, { $0.sessions[0].status = .active },
            { $0.sessions[0].currentItemID = UUID() }, { $0.sessions[0].currentItemID = $0.sessionItems[0].id },
            { $0.sessions[0].endedAt = V3TestSupport.date }, { $0.sessions[0].status = .completed },
            { $0.sessions[0].scope.studyTimeZoneID = "Unknown/Zone" },
            { var second = $0.sessions[0]; second.id = UUID(); $0.sessions.append(second) }
        ])
    }

    func testSessionItemsRejectDuplicateTargetsPositionsAndForgedAttemptCounts() throws {
        let payload = try V3TestSupport.reviewedPayload()
        try reject(payload, mutations: [
            { var duplicate = $0.sessionItems[0]; duplicate.id = UUID(); $0.sessionItems.append(duplicate) },
            {
                var duplicate = $0.sessionItems[0]
                duplicate.id = UUID()
                duplicate.cardID = $0.cards[1].id
                duplicate.originalCardID = $0.cards[1].id
                duplicate.status = .pending
                duplicate.attemptCount = 0
                duplicate.availableAt = nil
                duplicate.lastActionID = nil
                $0.sessionItems.append(duplicate)
            },
            { $0.sessionItems[0].cardID = UUID() }, { $0.sessionItems[0].sessionID = UUID() },
            { $0.sessionItems[0].originalCardID = UUID() }, { $0.sessionItems[0].position = -1 },
            { $0.sessionItems[0].attemptCount = 2 }, { $0.sessionItems[0].lastActionID = UUID() },
            { $0.sessionItems[0].availableAt = nil }, { $0.sessionItems[0].completionOutcome = .reviewed }
        ])
    }

    func testDeletedCardKeepsOriginalIdentityAndHistoricalSchedulesWithoutResurrection() throws {
        var payload = try V3TestSupport.reviewedPayload()
        let originalID = payload.sessionItems[0].originalCardID
        payload.cards.removeAll { $0.id == originalID }
        for i in payload.eventStates.indices where payload.eventStates[i].cardID == originalID { payload.eventStates[i].cardID = nil }
        payload.sessionItems[0].cardID = nil
        payload.sessionItems[0].status = .unavailable
        payload.sessionItems[0].completionOutcome = .unavailable
        payload.sessionItems[0].availableAt = nil
        payload.sessions[0].status = .completed
        payload.sessions[0].endedAt = V3TestSupport.date
        let data = try WordNoteSnapshotV3Codec.encode(payload, kind: .manual)
        let restored = try WordNoteSnapshotV3Codec.decode(data).payload
        XCTAssertFalse(restored.cards.contains { $0.id == originalID })
        XCTAssertEqual(restored.sessionItems[0].originalCardID, originalID)
        let event = try XCTUnwrap(restored.eventStates.first { $0.feedbackSemanticsVersion == 2 })
        XCTAssertEqual(event.originalCardID, originalID)
        XCTAssertNil(event.cardID)
        XCTAssertNotNil(event.beforeSchedule)
        XCTAssertNotNil(event.afterSchedule)
    }

    func testHistoricalCourseScopeIsNotInvalidatedByCurrentCourseMembership() throws {
        var payload = try V3TestSupport.reviewedPayload()
        payload.sessions[0].scope.courseID = UUID()
        XCTAssertNoThrow(try payload.validate())
        XCTAssertEqual(payload.sessions[0].scope.courseName, "Original course")
    }

    func testClozeRequiresExactUnicodeRangeHashAndSourceOwnership() throws {
        let payload = try V3TestSupport.clozePayload()
        let i = try XCTUnwrap(payload.cards.firstIndex { $0.mode == .contextCloze })
        try reject(payload, mutations: [
            { $0.cards[i].clozeTarget = nil }, { $0.cards[i].contentScopeKey = "wholeTerm" },
            { $0.cards[i].clozeTarget?.occurrenceID = UUID() }, { $0.cards[i].clozeTarget?.sourceHash = "wrong" },
            { $0.cards[i].clozeTarget?.startCharacterOffset = Int.max },
            { $0.cards[i].clozeTarget?.characterCount = Int.max },
            { $0.cards[i].clozeTarget?.characterCount = 4 }, { $0.cards[i].clozeTarget?.answer = "Quick" },
            { $0.cards[i].clozeTarget?.acceptedAnswers = [" "] },
            { $0.content.occurrences[0].rawTextSnapshot = $0.content.occurrences[0].rawTextSnapshot.precomposedStringWithCanonicalMapping }
        ])
    }

    func testNewCardFieldChangesDoNotWriteCompatibilityTermSchedule() throws {
        var payload = try V3TestSupport.payload()
        let terms = payload.content.content.terms
        payload.cards[0].schedulerVersion = ReviewSchedulerVersion.current
        payload.cards[0].schedule.masteryLevel = .mastered
        payload.cards[0].schedule.intervalDays = 14
        payload.cards[0].schedule.nextReviewAt = V3TestSupport.date.addingTimeInterval(1_209_600)
        XCTAssertNoThrow(try payload.validate())
        XCTAssertEqual(payload.content.content.terms, terms)
    }

    private func reject(_ original: WordNoteSnapshotV3Payload,
                        mutations: [(inout WordNoteSnapshotV3Payload) -> Void], file: StaticString = #filePath, line: UInt = #line) throws {
        try original.validate()
        for (index, mutation) in mutations.enumerated() {
            var value = original
            mutation(&value)
            XCTAssertThrowsError(try value.validate(), "Mutation \(index) unexpectedly accepted", file: file, line: line)
        }
    }
}
