import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3CaptureTests: XCTestCase {
    private typealias Payload = WordNoteSnapshotV3Payload
    private let now = V3TestSupport.date.addingTimeInterval(30)
    private enum Failure: Error { case save }

    func testNewCapturesPersistFrozenContextAndQueueWithoutAnalysis() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        for (text, intent, direction) in [("new expression", LookupIntent.auto, "englishToChinese"),
                                           ("新的表達", .chineseToEnglish, "chineseToEnglish")] {
            let request = WordNoteCaptureRequest(rawText: "  \(text)  ", courseID: before.content.content.courses[0].id,
                sourceType: .book, note: "  source note  ", intent: intent, capturedVia: .floatingQuickAdd)
            let result = try service.capture(request, at: now)
            let record = try inputRecord(result, container)
            XCTAssertFalse(result.isReplay)
            XCTAssertEqual(record.rawText, text)
            XCTAssertEqual(record.note, "source note")
            XCTAssertEqual(record.courseID, request.courseID)
            XCTAssertEqual(record.captureID, request.captureID)
            XCTAssertEqual(record.sourceTypeRaw, "book")
            XCTAssertEqual(record.capturedViaRaw, "floatingQuickAdd")
            XCTAssertEqual(record.lookupIntentRaw, intent.rawValue)
            XCTAssertEqual(record.resolvedLookupDirectionRaw, direction)
            XCTAssertEqual(record.directionDetectorVersion, intent == .auto ? LookupDirectionDetectorV1.version : "explicit-v1")
            XCTAssertEqual(record.statusRaw, "draft")
            XCTAssertEqual(record.queueStateRaw, "queued")
            XCTAssertEqual(record.analysisGeneration, 1)
            XCTAssertEqual(record.revision, 0)
            XCTAssertNil(record.attemptID)
            XCTAssertEqual(record.createdAt, now)
        }
        let after = try snapshot(container, before)
        XCTAssertEqual(after.content.content.candidates, before.content.content.candidates)
        XCTAssertEqual(after.cards, before.cards)
        XCTAssertEqual(after.content.lookupEvents, before.content.lookupEvents)
    }

    func testSaveOnlyExistingTextCreatesDraftWithoutLookupOrPriority() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let request = WordNoteCaptureRequest(rawText: "quick", note: "  ")
        let result = try WordNoteV3ContentService(container: container).capture(request, analyze: false, at: now)
        let record = try inputRecord(result, container)
        XCTAssertEqual(record.queueStateRaw, "none")
        XCTAssertEqual(record.analysisGeneration, 0)
        XCTAssertNil(record.note)
        let after = try snapshot(container, before)
        XCTAssertEqual(after.content.content.terms, before.content.content.terms)
        XCTAssertEqual(after.cards, before.cards)
        XCTAssertEqual(after.content.lookupEvents, before.content.lookupEvents)
        XCTAssertEqual(after.content.occurrences, before.content.occurrences)
    }

    func testExactEnglishHitAddsSourceEventMembershipAndPriorityButNoLegacyMutation() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        var saves = 0
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
        let term = try quick(before)
        let request = WordNoteCaptureRequest(rawText: " QUICK ", courseID: before.content.content.courses[1].id,
            sourceType: .paper, note: "read again", capturedVia: .floatingQuickAdd)
        let result = try service.capture(request, at: now)
        XCTAssertEqual(result.destination, .vocabulary(id: term.id, term: term.term,
            chineseMeaning: term.chineseMeaning, englishDefinition: term.englishDefinition))
        let after = try snapshot(container, before)
        XCTAssertEqual(after.content.content.inputRecords, before.content.content.inputRecords)
        XCTAssertEqual(after.content.content.candidates, before.content.content.candidates)
        XCTAssertEqual(after.content.recordStates, before.content.recordStates)
        XCTAssertEqual(after.content.content.reviewEvents, before.content.content.reviewEvents)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertEqual(after.termHistories, before.termHistories)
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.sessionItems, before.sessionItems)
        var expectedTerm = term
        expectedTerm.updatedAt = now
        XCTAssertEqual(after.content.content.terms.first { $0.id == term.id }, expectedTerm)
        var expectedState = try XCTUnwrap(before.content.termStates.first { $0.id == term.id })
        expectedState.revision += 1
        XCTAssertEqual(after.content.termStates.first { $0.id == term.id }, expectedState)
        var expectedCard = try XCTUnwrap(before.cards.first { $0.termID == term.id })
        expectedCard.schedule.priorityRequestedAt = now
        expectedCard.revision += 1
        expectedCard.updatedAt = now
        XCTAssertEqual(after.cards.first { $0.id == expectedCard.id }, expectedCard)
        let source = try XCTUnwrap(after.content.occurrences.first { $0.captureID == request.captureID })
        XCTAssertEqual(source.rawTextSnapshot, "QUICK")
        XCTAssertEqual(source.note, request.note)
        XCTAssertEqual(source.courseID, request.courseID)
        XCTAssertEqual(source.capturedViaRaw, "floatingQuickAdd")
        XCTAssertEqual(source.sourceTypeRaw, "paper")
        XCTAssertNil(source.sourceRecordID)
        XCTAssertEqual(after.content.lookupEvents.first { $0.captureID == request.captureID }?.occurrenceID, source.id)
        XCTAssertEqual(after.content.occurrences.count, before.content.occurrences.count + 1)
        XCTAssertEqual(after.content.lookupEvents.count, before.content.lookupEvents.count + 1)
        XCTAssertEqual(after.content.courseLinks.count, before.content.courseLinks.count + 1)
        XCTAssertEqual(saves, 1)
    }

    func testDistinctRepeatQueriesKeepFactsAndOneLatestPriorityWithoutCooldownCounters() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let term = try quick(before)
        for offset in [0.0, 30, 630] {
            _ = try service.capture(.init(rawText: "quick", courseID: before.content.content.courses[1].id), at: now.addingTimeInterval(offset))
        }
        let after = try snapshot(container, before)
        XCTAssertEqual(after.content.lookupEvents.count, before.content.lookupEvents.count + 3)
        XCTAssertEqual(after.content.occurrences.count, before.content.occurrences.count + 3)
        XCTAssertEqual(after.content.courseLinks.count, before.content.courseLinks.count + 1)
        XCTAssertEqual(after.cards.first { $0.termID == term.id }?.schedule.priorityRequestedAt, now.addingTimeInterval(630))
        XCTAssertEqual(after.termHistories, before.termHistories)
        var expected = term
        expected.updatedAt = now.addingTimeInterval(630)
        XCTAssertEqual(after.content.content.terms.first { $0.id == term.id }, expected)
    }

    func testLocalAndQueuedReplaysDoNotSaveOrRefreshPriorityAcrossServices() throws {
        for text in ["quick", "new expression"] {
            let before = try V3TestSupport.payload()
            let container = try seeded(before)
            var saves = 0
            let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
            let request = WordNoteCaptureRequest(rawText: text)
            let first = try service.capture(request, at: now)
            let saved = try snapshot(container, before)
            let replay = try service.capture(request, at: now.addingTimeInterval(30))
            let other = try WordNoteV3ContentService(container: container).capture(request, at: now.addingTimeInterval(900))
            XCTAssertTrue(replay.isReplay)
            XCTAssertTrue(other.isReplay)
            XCTAssertEqual(first.destination, replay.destination)
            XCTAssertEqual(first.destination, other.destination)
            XCTAssertEqual(try snapshot(container, before), saved)
            XCTAssertEqual(saves, 1)
        }
    }

    func testLocalHitReplaySurvivesFullBackupRestoreAndDiskReopen() async throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let request = WordNoteCaptureRequest(rawText: "quick")
        let first = try WordNoteV3ContentService(container: container).capture(request, at: now)
        let saved = try snapshot(container, before)
        let backup = try WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(saved, kind: .manual)).payload
        let h = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: h.directory) }
        _ = try await h.seed(.v3(backup))
        let reopened = try h.store.open()
        let replay = try WordNoteV3ContentService(container: reopened.container).capture(request, at: now.addingTimeInterval(900))
        XCTAssertTrue(replay.isReplay)
        XCTAssertEqual(replay.destination, first.destination)
        XCTAssertEqual(try h.capture(reopened), .v3(saved))
    }

    func testDeletedSourceCannotBeResurrectedByReplayingCapture() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let request = WordNoteCaptureRequest(rawText: "quick")
        _ = try service.capture(request, at: now)
        let saved = try snapshot(container, before)
        let source = try XCTUnwrap(saved.content.occurrences.first { $0.captureID == request.captureID })
        let revision = try XCTUnwrap(saved.content.termStates.first { $0.id == source.termID }).revision
        try service.deleteOccurrence(source.id, expectedTermRevision: revision, at: now)
        let deleted = try snapshot(container, before)
        XCTAssertThrowsError(try service.capture(request, at: now)) { XCTAssertEqual($0 as? WordNoteV3ContentError, .captureConflict) }
        XCTAssertEqual(try snapshot(container, before), deleted)
    }

    func testEnglishCardIsPreferredOverOtherEnabledWholeTermCards() throws {
        var before = try V3TestSupport.payload()
        let termID = try quick(before).id
        let english = try XCTUnwrap(before.cards.first { $0.termID == termID })
        var reverse = english
        reverse.id = UUID()
        reverse.mode = .chineseToEnglish
        reverse.createdAt = V3TestSupport.date.addingTimeInterval(-1)
        before.cards.append(reverse)
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)
        let after = try snapshot(container, before)
        XCTAssertEqual(after.cards.first { $0.id == english.id }?.schedule.priorityRequestedAt, now)
        XCTAssertEqual(after.cards.first { $0.id == reverse.id }, reverse)
    }

    func testDisabledEnglishFallsBackToEnabledWholeTermDirection() throws {
        var before = try V3TestSupport.payload()
        let termID = try quick(before).id
        let index = try XCTUnwrap(before.cards.firstIndex { $0.termID == termID })
        var reverse = before.cards[index]
        reverse.id = UUID()
        reverse.mode = .chineseToEnglish
        before.cards[index].schedule.phase = .suspended
        before.cards.append(reverse)
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)
        let after = try snapshot(container, before)
        XCTAssertEqual(after.cards.first { $0.id == reverse.id }?.schedule.priorityRequestedAt, now)
        XCTAssertEqual(after.cards.first { $0.id == before.cards[index].id }, before.cards[index])
    }

    func testOnlyClozeOrSuspendedCardsKeepLookupFactWithoutAutoEnablingOrAddingCards() throws {
        for onlyCloze in [false, true] {
            var before = try V3TestSupport.clozePayload()
            let termID = before.content.occurrences[0].termID
            let text = try XCTUnwrap(before.content.content.terms.first { $0.id == termID }).term
            if onlyCloze { removeCards(&before, where: { $0.termID == termID && $0.mode != .contextCloze }) }
            else {
                for i in before.cards.indices where before.cards[i].termID == termID { before.cards[i].schedule.phase = .suspended }
            }
            let container = try seeded(before)
            _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: text), at: now)
            let after = try snapshot(container, before)
            XCTAssertEqual(after.cards, before.canonicalized.cards)
            XCTAssertEqual(after.content.lookupEvents.count, before.content.lookupEvents.count + 1)
        }
    }

    func testNoCardsCreatesDefaultNewCardWithoutCopyingLegacyAbilityOrBypassingQuota() throws {
        var before = try V3TestSupport.payload()
        let termID = try quick(before).id
        removeCards(&before, where: { $0.termID == termID })
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)
        let after = try snapshot(container, before)
        let card = try XCTUnwrap(after.cards.first { $0.termID == termID })
        var expected = ReviewCardSchedule()
        expected.priorityRequestedAt = now
        XCTAssertEqual(card.schedule, expected)
        XCTAssertEqual(card.mode, .englishToChinese)
        XCTAssertEqual(card.contentScopeKey, "wholeTerm")
        XCTAssertEqual(card.schedulerVersion, ReviewSchedulerVersion.current)
        XCTAssertEqual(card.revision, 0)
        XCTAssertEqual(card.createdAt, now)
        XCTAssertEqual(try ReviewCardQueuePolicy().availability(of: card.schedule, at: now, studyTimeZoneID: "Asia/Hong_Kong"), .newCard)
        XCTAssertEqual(after.termHistories, before.termHistories)
    }

    func testQueryDuringRelearningPreservesWaitAndFixedSessionMembership() throws {
        let before = try V3TestSupport.reviewedPayload().canonicalized
        let card = try XCTUnwrap(before.cards.first { $0.schedule.phase == .relearning })
        let text = try XCTUnwrap(before.content.content.terms.first { $0.id == card.termID }).term
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: text), at: now)
        let after = try snapshot(container, before)
        let changed = try XCTUnwrap(after.cards.first { $0.id == card.id })
        var expected = card.schedule
        expected.priorityRequestedAt = now
        XCTAssertEqual(changed.schedule, expected)
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.sessionItems, before.sessionItems)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertEqual(try ReviewCardQueuePolicy().availability(of: changed.schedule, at: now, studyTimeZoneID: "Asia/Hong_Kong"),
            .relearningWaiting(until: try XCTUnwrap(card.schedule.nextReviewAt)))
    }

    func testBuriedCardReceivesPriorityButCannotBePresentedEarly() throws {
        var before = try V3TestSupport.payload()
        let termID = try quick(before).id
        let index = try XCTUnwrap(before.cards.firstIndex { $0.termID == termID })
        let until = now.addingTimeInterval(1000)
        before.cards[index].schedule.buriedUntil = until
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)
        let schedule = try XCTUnwrap(snapshot(container, before).cards.first { $0.termID == termID }).schedule
        XCTAssertEqual(schedule.priorityRequestedAt, now)
        XCTAssertEqual(schedule.buriedUntil, until)
        XCTAssertEqual(try ReviewCardQueuePolicy().availability(of: schedule, at: now, studyTimeZoneID: "Asia/Hong_Kong"), .buried(until: until))
    }

    func testChineseDirectionAndPrefixMissCreateQueuedRecordsNotLocalSignals() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let requests = [WordNoteCaptureRequest(rawText: "過擬合"), .init(rawText: "quick", intent: .chineseToEnglish), .init(rawText: "qui")]
        for request in requests {
            let result = try service.capture(request, at: now)
            XCTAssertEqual(try inputRecord(result, container).queueStateRaw, "queued")
        }
        let after = try snapshot(container, before)
        XCTAssertEqual(after.content.lookupEvents, before.content.lookupEvents)
        XCTAssertEqual(after.cards, before.cards)
    }

    func testInvalidCaptureInputDoesNotLeavePartialWork() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        for request in [WordNoteCaptureRequest(rawText: " \n "), .init(rawText: String(repeating: "a", count: 8_001)),
                        .init(rawText: "new", courseID: UUID()), .init(rawText: "new", capturedVia: .legacy),
                        .init(rawText: "new", note: String(repeating: "a", count: WordNoteSnapshotPayload.maximumTextCharacters + 1))] {
            XCTAssertThrowsError(try service.capture(request, at: now))
            XCTAssertEqual(try snapshot(container, before), before)
        }
        XCTAssertThrowsError(try service.capture(.init(rawText: "new"), at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(try snapshot(container, before), before)
    }

    func testCaptureIDCannotBeReusedForConflictingContext() throws {
        for text in ["quick", "new expression"] {
            let before = try V3TestSupport.payload()
            let container = try seeded(before)
            let service = try WordNoteV3ContentService(container: container)
            let request = WordNoteCaptureRequest(rawText: text, note: "note")
            _ = try service.capture(request, at: now)
            let saved = try snapshot(container, before)
            for collision in [WordNoteCaptureRequest(captureID: request.captureID, rawText: "changed", note: "note"),
                .init(captureID: request.captureID, rawText: text, note: "changed"),
                .init(captureID: request.captureID, rawText: text, note: "note", intent: .chineseToEnglish),
                .init(captureID: request.captureID, rawText: text, sourceType: .paper, note: "note"),
                .init(captureID: request.captureID, rawText: text, note: "note", capturedVia: .floatingQuickAdd)] {
                XCTAssertThrowsError(try service.capture(collision, at: now)) { XCTAssertEqual($0 as? WordNoteV3ContentError, .captureConflict) }
            }
            XCTAssertEqual(try snapshot(container, before), saved)
        }
    }

    func testAmbiguousExactHeadwordsDoNotChooseAnArbitraryTerm() throws {
        let original = try V3TestSupport.payload()
        let container = try seeded(original)
        container.mainContext.insert(WordNoteSchemaV3.TermModel(term: "quick", termType: .word, chineseMeaning: "another meaning"))
        try container.mainContext.save()
        let before = try snapshot(container, original)
        XCTAssertThrowsError(try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .ambiguousExactMatch)
        }
        XCTAssertEqual(try snapshot(container, original), before)
    }

    func testSaveFailureRollsBackNewRecordsAndAllLocalHitRelationsIncludingNewCards() throws {
        for withoutCard in [false, true] {
            var before = try V3TestSupport.payload()
            if withoutCard { let id = try quick(before).id; removeCards(&before, where: { $0.termID == id }) }
            let container = try seeded(before)
            let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in throw Failure.save })
            for text in ["new expression", "quick"] {
                XCTAssertThrowsError(try service.capture(.init(rawText: text, courseID: before.content.content.courses[1].id), at: now)) {
                    XCTAssertEqual($0 as? Failure, .save)
                }
                XCTAssertEqual(try snapshot(container, before), before.canonicalized)
                XCTAssertFalse(container.mainContext.hasChanges)
            }
        }
    }

    func testTermOrCardRevisionOverflowRollsBackSourcesSignalsAndMemberships() throws {
        for termOverflow in [false, true] {
            var before = try V3TestSupport.payload()
            let id = try quick(before).id
            if termOverflow {
                let index = try XCTUnwrap(before.content.termStates.firstIndex { $0.id == id })
                before.content.termStates[index].revision = 1_000_000_000
            } else {
                let index = try XCTUnwrap(before.cards.firstIndex { $0.termID == id })
                before.cards[index].revision = 1_000_000_000
            }
            let container = try seeded(before)
            XCTAssertThrowsError(try WordNoteV3ContentService(container: container).capture(
                .init(rawText: "quick", courseID: before.content.content.courses[1].id), at: now)) {
                XCTAssertEqual($0 as? WordNoteV3ContentError, .counterLimit)
            }
            XCTAssertEqual(try snapshot(container, before), before)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    func testMaximumLegacyCountersDoNotPreventNewLookupFacts() throws {
        var before = try V3TestSupport.payload()
        let id = try quick(before).id
        let termIndex = try XCTUnwrap(before.content.content.terms.firstIndex { $0.id == id })
        let historyIndex = try XCTUnwrap(before.termHistories.firstIndex { $0.id == id })
        before.content.content.terms[termIndex].wrongCount = 1_000_000_000
        before.content.content.terms[termIndex].duplicateHitCount = 1_000_000_000
        before.termHistories[historyIndex].legacyWrongCount = 1_000_000_000
        before.termHistories[historyIndex].legacyDuplicateHitCount = 1_000_000_000
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)
        let after = try snapshot(container, before)
        XCTAssertEqual(after.termHistories, before.termHistories)
        XCTAssertEqual(after.content.lookupEvents.count, before.content.lookupEvents.count + 1)
    }

    func testWriteGateAndDirtyDraftBlockCaptureWithoutDiscardingUserChanges() throws {
        let before = try V3TestSupport.payload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try service.capture(.init(rawText: "quick"), at: now)) { XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress) }
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        let draft = WordNoteSchemaV3.CourseModel(courseName: "Unsaved draft")
        container.mainContext.insert(draft)
        XCTAssertThrowsError(try service.capture(.init(rawText: "quick"), at: now)) { XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges) }
        XCTAssertEqual(draft.courseName, "Unsaved draft")
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
        XCTAssertEqual(try snapshot(container, before), before)
    }

    func testLookupDuringClockRollbackPreservesCardInteractionHighWater() throws {
        var before = try V3TestSupport.payload()
        let id = try quick(before).id
        let index = try XCTUnwrap(before.cards.firstIndex { $0.termID == id })
        let future = now.addingTimeInterval(600)
        before.cards[index].updatedAt = future
        let container = try seeded(before)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: "quick"), at: now)
        let card = try XCTUnwrap(snapshot(container, before).cards.first { $0.termID == id })
        XCTAssertEqual(card.updatedAt, future)
        XCTAssertEqual(card.schedule.priorityRequestedAt, now)
    }

    private func seeded(_ payload: Payload) throws -> ModelContainer {
        let container = try V3TestSupport.container()
        try payload.populateEmptyStore(container.mainContext)
        return container
    }

    private func snapshot(_ container: ModelContainer, _ original: Payload) throws -> Payload {
        try Payload.capture(from: container.mainContext, preferences: original.content.content.preferences)
    }

    private func quick(_ payload: Payload) throws -> WordNoteSnapshotPayload.Term {
        try XCTUnwrap(payload.content.content.terms.first { $0.term == "quick" })
    }

    private func inputRecord(_ result: WordNoteCaptureResult, _ container: ModelContainer) throws -> WordNoteSchemaV3.InputRecordModel {
        guard case .inputRecord(let id, _) = result.destination else { XCTFail("Expected queued or draft record"); throw Failure.save }
        return try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.InputRecordModel>()).first { $0.id == id })
    }

    private func removeCards(_ payload: inout Payload, where predicate: (Payload.Card) -> Bool) {
        let removed = Set(payload.cards.filter(predicate).map(\.id))
        payload.cards.removeAll(where: predicate)
        for i in payload.eventStates.indices {
            if let id = payload.eventStates[i].cardID, removed.contains(id) { payload.eventStates[i].cardID = nil }
        }
    }
}
