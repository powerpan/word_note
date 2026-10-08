import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3DeletionTests: XCTestCase {
    private typealias Payload = WordNoteSnapshotV3Payload
    private let now = V3TestSupport.date.addingTimeInterval(30)

    func testInputDeletionPreservesSourcesCardsAndHistoryButDetachesLiveReferences() throws {
        let before = try V3TestSupport.clozePayload().canonicalized
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let record = before.content.content.inputRecords[0]
        let revision = try XCTUnwrap(before.content.recordStates.first { $0.id == record.id }).revision
        let affected = Set(before.content.occurrences.filter { $0.sourceRecordID == record.id }.map(\.termID)
            + before.content.content.terms.filter { $0.sourceRecordID == record.id }.map(\.id))
        try service.deleteInputRecord(record.id, expectedRevision: revision, at: now)
        let after = try capture(container, before)
        XCTAssertFalse(after.content.content.inputRecords.contains { $0.id == record.id })
        XCTAssertFalse(after.content.content.candidates.contains { $0.inputRecordID == record.id })
        XCTAssertFalse(after.content.content.terms.contains { $0.sourceRecordID == record.id })
        var expectedSources = before.content.occurrences
        for i in expectedSources.indices where expectedSources[i].sourceRecordID == record.id { expectedSources[i].sourceRecordID = nil }
        XCTAssertEqual(after.content.occurrences, expectedSources)
        XCTAssertEqual(after.cards, before.cards)
        XCTAssertEqual(after.content.courseLinks, before.content.courseLinks)
        XCTAssertEqual(after.content.lookupEvents, before.content.lookupEvents)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertEqual(after.termHistories, before.termHistories)
        for state in after.content.termStates {
            let old = try XCTUnwrap(before.content.termStates.first { $0.id == state.id })
            XCTAssertEqual(state.revision, old.revision + (affected.contains(state.id) ? 1 : 0))
        }
    }

    func testSourceDeletionCreatesExplicitClozeTombstoneAndInvalidatesSessionWithoutReviewCredit() throws {
        let before = try clozeSessionPayload()
        let container = try seeded(before)
        let source = before.content.occurrences[0]
        let card = try XCTUnwrap(before.cards.first { $0.mode == .contextCloze })
        let oldTerm = try XCTUnwrap(before.content.content.terms.first { $0.id == source.termID })
        let revision = try termRevision(source.termID, before)
        try WordNoteV3ContentService(container: container).deleteOccurrence(source.id, expectedTermRevision: revision, at: now)
        let after = try capture(container, before)
        let suspended = try XCTUnwrap(after.cards.first { $0.id == card.id })
        var expectedCard = card
        expectedCard.schedule.phase = .suspended
        expectedCard.schedule.nextReviewAt = nil
        expectedCard.schedule.priorityRequestedAt = nil
        expectedCard.revision += 1
        expectedCard.updatedAt = now
        expectedCard.clozeTarget?.sourceDeletedAt = now
        expectedCard.clozeTarget?.sourceHash = ""
        expectedCard.clozeTarget?.startCharacterOffset = 0
        expectedCard.clozeTarget?.characterCount = 0
        expectedCard.clozeTarget?.answer = ""
        expectedCard.clozeTarget?.acceptedAnswers = []
        XCTAssertEqual(suspended, expectedCard)
        XCTAssertFalse(after.content.occurrences.contains { $0.id == source.id })
        XCTAssertTrue(after.content.lookupEvents.filter { $0.termID == source.termID }.allSatisfy { $0.occurrenceID == nil })
        XCTAssertEqual(after.sessionItems[0].originalCardID, card.id)
        XCTAssertNil(after.sessionItems[0].cardID)
        XCTAssertEqual(after.sessionItems[0].status, .unavailable)
        XCTAssertEqual(after.sessionItems[0].completionOutcome, .unavailable)
        XCTAssertEqual(after.sessionItems[0].position, before.sessionItems[0].position)
        XCTAssertEqual(after.sessionItems[0].attemptCount, 0)
        XCTAssertEqual(after.sessions[0].status, .completed)
        XCTAssertEqual(after.sessions[0].endedAt, now)
        XCTAssertNil(after.sessions[0].currentItemID)
        XCTAssertEqual(after.sessions[0].scope, before.sessions[0].scope)
        XCTAssertEqual(after.content.content.reviewEvents, before.content.content.reviewEvents)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertEqual(after.termHistories, before.termHistories)
        var expectedTerm = oldTerm
        expectedTerm.updatedAt = now
        XCTAssertEqual(after.content.content.terms.first { $0.id == source.termID }, expectedTerm)
        XCTAssertEqual(try termRevision(source.termID, after), revision + 1)
    }

    func testCardDeletionPreservesEventSnapshotsAndOriginalIdentityButTermDeletionCascadesHistory() throws {
        let before = try V3TestSupport.reviewedPayload()
        let card = before.cards[0]
        for deleteTerm in [false, true] {
            let container = try seeded(before)
            let service = try WordNoteV3ContentService(container: container)
            if deleteTerm { try service.deleteTerm(card.termID, expectedRevision: termRevision(card.termID, before), at: now) }
            else { try service.deleteReviewCard(card.id, expectedRevision: card.revision, at: now) }
            let after = try capture(container, before)
            XCTAssertFalse(after.cards.contains { $0.id == card.id })
            var expectedItem = before.sessionItems[0]
            expectedItem.cardID = nil
            expectedItem.status = .unavailable
            expectedItem.completionOutcome = .unavailable
            expectedItem.availableAt = nil
            expectedItem.updatedAt = now
            XCTAssertEqual(after.sessionItems, [expectedItem])
            XCTAssertEqual(after.sessions[0].status, .completed)
            XCTAssertEqual(after.sessions[0].targetCardCount, before.sessions[0].targetCardCount)
            XCTAssertEqual(after.sessions[0].newCardLimitSnapshot, before.sessions[0].newCardLimitSnapshot)
            if deleteTerm {
                XCTAssertFalse(after.content.content.terms.contains { $0.id == card.termID })
                XCTAssertFalse(after.content.content.reviewEvents.contains { $0.termID == card.termID })
                XCTAssertFalse(after.termHistories.contains { $0.id == card.termID })
                XCTAssertFalse(after.content.occurrences.contains { $0.termID == card.termID })
                XCTAssertFalse(after.content.courseLinks.contains { $0.termID == card.termID })
                XCTAssertFalse(after.content.lookupEvents.contains { $0.termID == card.termID })
            } else {
                XCTAssertEqual(after.content.content.reviewEvents, before.content.content.reviewEvents)
                var expectedStates = before.eventStates
                for i in expectedStates.indices where expectedStates[i].cardID == card.id { expectedStates[i].cardID = nil }
                XCTAssertEqual(after.eventStates, expectedStates)
                XCTAssertEqual(after.termHistories, before.termHistories)
            }
        }
    }

    func testDeletingTermMarksSavedCandidateTargetDeletedWithoutForgettingConfirmation() throws {
        var before = try V3TestSupport.reviewedPayload()
        let termID = before.cards[0].termID
        let candidateID = before.content.content.candidates[0].id
        let index = try XCTUnwrap(before.content.candidateStates.firstIndex { $0.id == candidateID })
        let operation = UUID()
        before.content.content.candidates[0].statusRaw = "saved"
        before.content.candidateStates[index].savedLinkStateRaw = "resolved"
        before.content.candidateStates[index].savedTermID = termID
        before.content.candidateStates[index].confirmationOperationID = operation
        let container = try seeded(before)
        try WordNoteV3ContentService(container: container).deleteTerm(termID, expectedRevision: termRevision(termID, before), at: now)
        let after = try capture(container, before)
        let state = try XCTUnwrap(after.content.candidateStates.first { $0.id == candidateID })
        XCTAssertNil(state.savedTermID)
        XCTAssertEqual(state.savedLinkStateRaw, "targetDeleted")
        XCTAssertEqual(state.confirmationOperationID, operation)
        XCTAssertEqual(state.revision, before.content.candidateStates[index].revision + 1)
        XCTAssertEqual(after.content.content.candidates.first { $0.id == candidateID }?.statusRaw, "saved")
    }

    func testSuspensionDoesNotResetLearningHistoryAndRepeatingItDoesNotSaveAgain() throws {
        let before = try V3TestSupport.reviewedPayload()
        let container = try seeded(before)
        var saves = 0
        let service = try WordNoteV3ContentService(container: container, beforeSave: { _ in saves += 1 })
        let card = before.cards[0]
        try service.suspendReviewCard(card.id, expectedRevision: card.revision, at: now)
        let after = try capture(container, before)
        var expected = card
        expected.schedule.phase = .suspended
        expected.schedule.nextReviewAt = nil
        expected.schedule.priorityRequestedAt = nil
        expected.revision += 1
        expected.updatedAt = now
        XCTAssertEqual(after.cards.first { $0.id == card.id }, expected)
        XCTAssertEqual(after.content.content.reviewEvents, before.content.content.reviewEvents)
        XCTAssertEqual(after.eventStates, before.eventStates)
        XCTAssertEqual(after.termHistories, before.termHistories)
        try service.suspendReviewCard(card.id, expectedRevision: card.revision + 1, at: now)
        XCTAssertEqual(try capture(container, before), after)
        XCTAssertEqual(saves, 1)
    }

    func testDeletingCurrentCardPausesRemainingPendingItemsButKeepsAnUnaffectedCursor() throws {
        for deleteCurrent in [true, false] {
            var before = try V3TestSupport.reviewedPayload()
            let current = before.cards[0]
            var other = before.cards[1]
            other.mode = current.mode
            other.schedule.phase = .review
            other.schedule.nextReviewAt = now
            before.cards[1] = other
            before.sessionItems[0].status = .presented
            before.sessionItems[0].availableAt = nil
            before.sessions[0].status = .active
            before.sessions[0].currentItemID = before.sessionItems[0].id
            before.sessionItems.append(.init(id: UUID(), sessionID: before.sessions[0].id, cardID: other.id,
                originalCardID: other.id, position: 1, status: .pending, attemptCount: 0, availableAt: nil,
                lastActionID: nil, completionOutcome: nil, createdAt: now, updatedAt: now))
            let container = try seeded(before)
            let deleting = deleteCurrent ? current : other
            try WordNoteV3ContentService(container: container).deleteReviewCard(deleting.id, expectedRevision: deleting.revision, at: now)
            let after = try capture(container, before)
            XCTAssertEqual(after.sessionItems.count, before.sessionItems.count)
            XCTAssertEqual(after.sessions[0].status, deleteCurrent ? .paused : .active)
            XCTAssertEqual(after.sessions[0].currentItemID, deleteCurrent ? nil : before.sessions[0].currentItemID)
            XCTAssertNil(after.sessions[0].endedAt)
        }
    }

    func testDeletingCurrentCardLeavesWaitingItemsWaitingWithoutDrawingNewCards() throws {
        var before = try V3TestSupport.reviewedPayload()
        var other = before.cards[1]
        other.mode = before.cards[0].mode
        other.schedule.phase = .review
        other.schedule.nextReviewAt = now
        before.cards[1] = other
        let id = UUID()
        before.sessionItems.append(.init(id: id, sessionID: before.sessions[0].id, cardID: other.id,
            originalCardID: other.id, position: 1, status: .presented, attemptCount: 0, availableAt: nil,
            lastActionID: nil, completionOutcome: nil, createdAt: now, updatedAt: now))
        before.sessions[0].currentItemID = id
        before.sessions[0].status = .active
        let container = try seeded(before)
        try WordNoteV3ContentService(container: container).deleteReviewCard(other.id, expectedRevision: other.revision, at: now)
        let after = try capture(container, before)
        XCTAssertEqual(after.sessions[0].status, .waiting)
        XCTAssertNil(after.sessions[0].currentItemID)
        XCTAssertNil(after.sessions[0].endedAt)
        XCTAssertEqual(after.sessionItems.first { $0.id == before.sessionItems[0].id }, before.sessionItems[0])
    }

    func testDeletingCardInEndedSessionDoesNotRewriteItsEndTimeOrScope() throws {
        var before = try V3TestSupport.reviewedPayload()
        before.sessions[0].status = .ended
        before.sessions[0].endedAt = V3TestSupport.date
        let container = try seeded(before)
        try WordNoteV3ContentService(container: container).deleteReviewCard(before.cards[0].id, expectedRevision: before.cards[0].revision, at: now)
        let after = try capture(container, before)
        XCTAssertEqual(after.sessions[0].status, .ended)
        XCTAssertEqual(after.sessions[0].endedAt, V3TestSupport.date)
        XCTAssertEqual(after.sessions[0].scope, before.sessions[0].scope)
        XCTAssertEqual(after.sessionItems[0].completionOutcome, .unavailable)
    }

    func testCourseUsageCountsAllAuthoritativeReferencesAndPreservesHistoricalScope() throws {
        let before = try V3TestSupport.reviewedPayload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let course = before.content.content.courses[0]
        let revision = try XCTUnwrap(before.content.courseRevisions.first { $0.id == course.id }).revision
        let expected = WordNoteV3CourseUsage(inputRecords: before.content.content.inputRecords.filter { $0.courseID == course.id }.count,
            memberships: before.content.courseLinks.filter { $0.courseID == course.id }.count,
            occurrences: before.content.occurrences.filter { $0.courseID == course.id }.count)
        XCTAssertEqual(try service.courseUsage(course.id), expected)
        XCTAssertTrue(expected.isInUse)
        XCTAssertThrowsError(try service.deleteCourse(course.id, expectedRevision: revision, at: now)) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .courseInUse(expected))
        }
        XCTAssertEqual(try capture(container, before), before.canonicalized)
        var unused = before
        for i in unused.content.content.inputRecords.indices { unused.content.content.inputRecords[i].courseID = nil }
        unused.content.courseLinks.removeAll { $0.courseID == course.id }
        for i in unused.content.occurrences.indices where unused.content.occurrences[i].courseID == course.id { unused.content.occurrences[i].courseID = nil }
        let other = try seeded(unused)
        try WordNoteV3ContentService(container: other).deleteCourse(course.id, expectedRevision: revision, at: now)
        let after = try capture(other, unused)
        XCTAssertFalse(after.content.content.courses.contains { $0.id == course.id })
        XCTAssertFalse(after.content.content.terms.contains { $0.courseID == course.id })
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.cards, before.cards)
    }

    func testEveryMutationRejectsStaleRevisionAndRollsBackAWriteFailure() throws {
        enum Failure: Error { case save }
        let before = try clozeSessionPayload()
        let container = try seeded(before)
        let normal = try WordNoteV3ContentService(container: container)
        let failing = try WordNoteV3ContentService(container: container, beforeSave: { _ in throw Failure.save })
        for operation in try operations(normal, before, revisionOffset: 1) {
            XCTAssertThrowsError(try operation()) { XCTAssertNotNil($0 as? WordNoteV3ContentError) }
            XCTAssertEqual(try capture(container, before), before.canonicalized)
        }
        for operation in try operations(failing, before) {
            XCTAssertThrowsError(try operation()) { XCTAssertTrue($0 is Failure) }
            XCTAssertEqual(try capture(container, before), before.canonicalized)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    func testAllMutationsHonorWriteGateDirtyDraftAndInvalidDate() throws {
        let before = try clozeSessionPayload()
        let container = try seeded(before)
        let service = try WordNoteV3ContentService(container: container)
        let gate = try WordNoteWriteGate.beginRestore(container.mainContext)
        for operation in try operations(service, before) {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress) }
        }
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: gate)
        let draft = WordNoteSchemaV3.CourseModel(courseName: "Unsaved draft")
        container.mainContext.insert(draft)
        for operation in try operations(service, before) {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges) }
        }
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(draft.courseName, "Unsaved draft")
        container.mainContext.rollback()
        for operation in try operations(service, before, at: Date(timeIntervalSince1970: .infinity)) {
            XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? WordNoteV3ContentError, .invalidValue) }
        }
        XCTAssertEqual(try capture(container, before), before.canonicalized)
    }

    func testCorruptGraphCannotBeSilentlyRepairedByDeletingIt() throws {
        let before = try V3TestSupport.reviewedPayload()
        let container = try seeded(before)
        let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).first)
        item.sessionID = UUID()
        try container.mainContext.save()
        let broken = try Payload.captureForIntegrityInspection(from: container.mainContext)
        XCTAssertThrowsError(try WordNoteV3ContentService(container: container).deleteTerm(before.cards[0].termID,
            expectedRevision: termRevision(before.cards[0].termID, before), at: now))
        XCTAssertEqual(try Payload.captureForIntegrityInspection(from: container.mainContext), broken)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testCounterOverflowRollsBackEarlierCandidateAndCardMutations() throws {
        var before = try V3TestSupport.reviewedPayload()
        before.content.termStates[0].revision = 1_000_000_000
        let termID = before.content.termStates[0].id
        let card = try XCTUnwrap(before.cards.first { $0.termID == termID })
        let container = try seeded(before)
        XCTAssertThrowsError(try WordNoteV3ContentService(container: container).suspendReviewCard(card.id, expectedRevision: card.revision, at: now)) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .counterLimit)
        }
        XCTAssertEqual(try capture(container, before), before.canonicalized)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testServiceRejectsBothOldSchemas() throws {
        for version in [WordNoteSchemaV1.self as any VersionedSchema.Type, WordNoteSchemaV2.self] {
            XCTAssertThrowsError(try WordNoteV3ContentService(container: V3TestSupport.container(version))) {
                XCTAssertEqual($0 as? WordNoteV3ContentError, .wrongSchema)
            }
        }
    }

    func testDeletedSourceRoundTripsThroughFullBackupAndStagedDiskRestore() async throws {
        let before = try clozeSessionPayload()
        let container = try seeded(before)
        let source = before.content.occurrences[0]
        try WordNoteV3ContentService(container: container).deleteOccurrence(source.id, expectedTermRevision: termRevision(source.termID, before), at: now)
        let after = try capture(container, before)
        let data = try WordNoteSnapshotV3Codec.encode(after, kind: .manual)
        XCTAssertEqual(try WordNoteSnapshotV3Codec.decode(data).payload, after)
        let h = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let restored = try await h.seed(.v3(after))
        XCTAssertEqual(try h.capture(restored), .v3(after))
        XCTAssertEqual(try h.capture(h.store.open()), .v3(after))
    }

    private func seeded(_ payload: Payload) throws -> ModelContainer {
        let container = try V3TestSupport.container()
        try payload.populateEmptyStore(container.mainContext)
        return container
    }

    private func capture(_ container: ModelContainer, _ original: Payload) throws -> Payload {
        try Payload.capture(from: container.mainContext, preferences: original.content.content.preferences)
    }

    private func termRevision(_ id: UUID, _ payload: Payload) throws -> Int {
        try XCTUnwrap(payload.content.termStates.first { $0.id == id }).revision
    }

    private func clozeSessionPayload() throws -> Payload {
        var payload = try V3TestSupport.clozePayload()
        let index = try XCTUnwrap(payload.cards.firstIndex { $0.mode == .contextCloze })
        payload.cards[index].schedule = try ReviewCardScheduler().presentation(for: payload.cards[index].schedule,
            at: now, studyTimeZoneID: "Asia/Hong_Kong").after
        let card = payload.cards[index]
        let sessionID = UUID(), itemID = UUID()
        payload.sessions = [.init(id: sessionID, scope: .init(mode: .contextCloze, queue: .dueToday,
            includesNewCards: true, studyTimeZoneID: "Asia/Hong_Kong"), targetCardCount: 20, newCardLimitSnapshot: 10,
            status: .active, currentItemID: itemID, createdAt: now, updatedAt: now, endedAt: nil, revision: 0)]
        payload.sessionItems = [.init(id: itemID, sessionID: sessionID, cardID: card.id, originalCardID: card.id,
            position: 0, status: .presented, attemptCount: 0, availableAt: nil, lastActionID: nil,
            completionOutcome: nil, createdAt: now, updatedAt: now)]
        let unused = WordNoteSchemaV3.CourseModel(courseName: "Unused")
        payload.content.content.courses.append(.init(unused))
        payload.content.courseRevisions.append(.init(unused))
        try payload.validate()
        return payload.canonicalized
    }

    private func operations(_ service: WordNoteV3ContentService, _ payload: Payload, revisionOffset: Int = 0,
                            at date: Date? = nil) throws -> [() throws -> Void] {
        let date = date ?? now
        let card = try XCTUnwrap(payload.cards.first { $0.mode == .contextCloze })
        let source = payload.content.occurrences[0]
        let termRevision = try termRevision(card.termID, payload)
        let record = payload.content.content.inputRecords[0]
        let recordRevision = try XCTUnwrap(payload.content.recordStates.first { $0.id == record.id }).revision
        let course = try XCTUnwrap(payload.content.content.courses.first { $0.courseName == "Unused" })
        return [
            { try service.deleteInputRecord(record.id, expectedRevision: recordRevision + revisionOffset, at: date) },
            { try service.deleteOccurrence(source.id, expectedTermRevision: termRevision + revisionOffset, at: date) },
            { try service.deleteTerm(card.termID, expectedRevision: termRevision + revisionOffset, at: date) },
            { try service.deleteReviewCard(card.id, expectedRevision: card.revision + revisionOffset, at: date) },
            { try service.suspendReviewCard(card.id, expectedRevision: card.revision + revisionOffset, at: date) },
            { try service.deleteCourse(course.id, expectedRevision: revisionOffset, at: date) }
        ]
    }
}
