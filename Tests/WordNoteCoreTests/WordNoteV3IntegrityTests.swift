import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3IntegrityTests: XCTestCase {
    private typealias Payload = WordNoteSnapshotV3Payload
    private typealias Service = WordNoteV3IntegrityService
    private let now = V3TestSupport.date.addingTimeInterval(60)

    func testHealthyInspectionAndNoOpPlanPreserveAllElevenEntities() throws {
        let source = try V3TestSupport.reviewedPayload().canonicalized
        let report = Service.inspect(source)
        XCTAssertTrue(report.isStructurallyValid)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertFalse(report.canPrepareRepair)
        XCTAssertNil(report.remainingValidationError)
        let plan = try Service.prepareRepair(source, at: now)
        XCTAssertEqual(try plan.validatedPayload(matching: source), source)
    }

    func testOnlyOptionalContentReferencesAreRepairedWithoutChangingAnyReviewValues() throws {
        var source = try V3TestSupport.reviewedPayload().canonicalized
        let termID = source.content.occurrences[0].termID
        let termIndex = try XCTUnwrap(source.content.content.terms.firstIndex { $0.id == termID })
        let stateIndex = try XCTUnwrap(source.content.termStates.firstIndex { $0.id == termID })
        source.content.content.terms[termIndex].sourceRecordID = UUID()
        source.content.occurrences[0].sourceRecordID = UUID()
        source.content.lookupEvents[0].occurrenceID = UUID()
        let report = Service.inspect(source)
        XCTAssertTrue(report.canPrepareRepair)
        XCTAssertEqual(report.detachableReferenceCount, 3)
        XCTAssertTrue(report.issues.isEmpty)
        let plan = try Service.prepareRepair(source, at: now)
        var expected = source
        expected.content.content.terms[termIndex].sourceRecordID = nil
        expected.content.content.terms[termIndex].updatedAt = now
        expected.content.termStates[stateIndex].revision += 1
        expected.content.occurrences[0].sourceRecordID = nil
        expected.content.lookupEvents[0].occurrenceID = nil
        XCTAssertEqual(plan.repairedPayload, expected)
        XCTAssertEqual(plan.repairedPayload.counts, source.counts)
        XCTAssertEqual(plan.repairedPayload.cards, source.cards)
        XCTAssertEqual(plan.repairedPayload.sessions, source.sessions)
        XCTAssertEqual(plan.repairedPayload.sessionItems, source.sessionItems)
        XCTAssertEqual(plan.repairedPayload.termHistories, source.termHistories)
        XCTAssertEqual(plan.repairedPayload.eventStates, source.eventStates)
        XCTAssertEqual(plan.repairedPayload.content.content.reviewEvents, source.content.content.reviewEvents)
        XCTAssertEqual(try Service.prepareRepair(plan.repairedPayload, at: now).repairedPayload, expected)
    }

    func testMissingRequiredReviewReferencesAreBlockersNotAutomaticDetachments() throws {
        let payload = try V3TestSupport.reviewedPayload()
        let eventIndex = try XCTUnwrap(payload.eventStates.firstIndex { $0.feedbackSemanticsVersion == 2 })
        let missing = UUID()
        let changes: [(inout Payload) -> Void] = [
            { $0.cards[0].termID = missing },
            { $0.sessionItems[0].sessionID = missing },
            { $0.sessionItems[0].cardID = missing },
            { $0.sessions[0].currentItemID = missing },
            { $0.eventStates[eventIndex].cardID = missing },
            { $0.eventStates[eventIndex].sessionID = missing },
            { $0.eventStates[eventIndex].actionID = nil },
            { $0.eventStates[eventIndex].originalCardID = nil }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            let before = invalid
            XCTAssertTrue(Service.inspect(invalid).issues.contains { $0.kind == .missingReference })
            assertBlocked(invalid)
            XCTAssertEqual(invalid, before)
        }
    }

    func testDuplicateReviewIDsBusinessKeysAndMetadataMismatchAreReportedWithoutCrashing() throws {
        let payload = try V3TestSupport.reviewedPayload()
        let event = try XCTUnwrap(payload.eventStates.first { $0.feedbackSemanticsVersion == 2 })
        let changes: [(WordNoteV3IntegrityIssue.Kind, (inout Payload) -> Void)] = [
            (.duplicateIdentifier, { $0.cards.append($0.cards[0]) }),
            (.duplicateIdentifier, { $0.sessions.append($0.sessions[0]) }),
            (.duplicateIdentifier, { $0.sessionItems.append($0.sessionItems[0]) }),
            (.duplicateIdentifier, { $0.termHistories.append($0.termHistories[0]) }),
            (.duplicateIdentifier, { $0.eventStates.append($0.eventStates[0]) }),
            (.duplicateBusinessKey, { var card = $0.cards[0]; card.id = UUID(); $0.cards.append(card) }),
            (.duplicateBusinessKey, { var item = $0.sessionItems[0]; item.id = UUID(); $0.sessionItems.append(item) }),
            (.duplicateBusinessKey, { var row = event; row.id = UUID(); $0.eventStates.append(row) }),
            (.metadataMismatch, { $0.termHistories.removeLast() }),
            (.metadataMismatch, { $0.eventStates.removeLast() }),
            (.metadataMismatch, { var history = $0.termHistories[0]; history.id = UUID(); $0.termHistories.append(history) })
        ]
        for (kind, change) in changes {
            var invalid = payload
            change(&invalid)
            XCTAssertTrue(Service.inspect(invalid).issues.contains { $0.kind == kind }, "Expected \(kind)")
            assertBlocked(invalid)
        }
    }

    func testCrossLinkedCardsAndSessionsAreNotGuessedOrReassigned() throws {
        let payload = try V3TestSupport.reviewedPayload()
        let changes: [(inout Payload) -> Void] = [
            { $0.sessionItems[0].originalCardID = UUID() },
            { $0.sessions[0].scope.mode = .chineseToEnglish },
            { $0.sessionItems[0].cardID = nil },
            { $0.cards[0].schedule.phase = .suspended },
            { var session = $0.sessions[0]; session.id = UUID(); $0.sessions.append(session) }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            XCTAssertFalse(Service.inspect(invalid).issues.isEmpty)
            assertBlocked(invalid)
        }
    }

    func testMissingClozeSourceNeverBecomesAnInventedUserDeletion() throws {
        var source = try V3TestSupport.clozePayload()
        let index = try XCTUnwrap(source.cards.firstIndex { $0.mode == .contextCloze })
        let original = try XCTUnwrap(source.cards[index].clozeTarget)
        source.cards[index].clozeTarget?.occurrenceID = UUID()
        let report = Service.inspect(source)
        XCTAssertTrue(report.issues.contains { $0.field == "clozeTarget.occurrenceID" && $0.kind == .missingReference })
        assertBlocked(source)
        XCTAssertNil(source.cards[index].clozeTarget?.sourceDeletedAt)
        XCTAssertEqual(source.cards[index].clozeTarget?.answer, original.answer)
        source.cards[index].clozeTarget = nil
        assertBlocked(source)
    }

    func testClozeSourceDeletionMarkerIsBackwardCompatibleAndStrictlyValidated() throws {
        var payload = try V3TestSupport.clozePayload()
        let index = try XCTUnwrap(payload.cards.firstIndex { $0.mode == .contextCloze })
        var target = try XCTUnwrap(payload.cards[index].clozeTarget)
        let oldJSON = try ReviewPersistenceJSON.encode(target)
        XCTAssertFalse(oldJSON.contains("sourceDeletedAt"))
        XCTAssertEqual(try ReviewPersistenceJSON.decode(oldJSON) as ReviewClozeTarget, target)
        payload.content.occurrences.removeAll { $0.id == target.occurrenceID }
        payload.content.lookupEvents[0].occurrenceID = nil
        target.sourceDeletedAt = now
        target.sourceHash = ""
        target.startCharacterOffset = 0
        target.characterCount = 0
        target.answer = ""
        target.acceptedAnswers = []
        payload.cards[index].clozeTarget = target
        payload.cards[index].schedule.phase = .suspended
        XCTAssertTrue(Service.inspect(payload).isStructurallyValid)
        XCTAssertNoThrow(try payload.validate())
        let changes: [(inout Payload) -> Void] = [
            { $0.cards[index].clozeTarget?.sourceDeletedAt = nil },
            { $0.cards[index].clozeTarget?.sourceDeletedAt = Date(timeIntervalSince1970: .infinity) },
            { $0.cards[index].clozeTarget?.sourceHash = "retained" },
            { $0.cards[index].clozeTarget?.answer = "retained" },
            { $0.cards[index].clozeTarget?.acceptedAnswers = ["retained"] },
            { $0.cards[index].clozeTarget?.startCharacterOffset = 1 },
            { $0.cards[index].clozeTarget?.characterCount = 1 },
            { $0.cards[index].schedule.phase = .new },
            { $0.cards[index].schedule.nextReviewAt = self.now },
            { $0.cards[index].schedule.priorityRequestedAt = self.now }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            assertBlocked(invalid)
        }
    }

    func testScalarHistoryAndScheduleErrorsCannotHideBehindRepairableContentReference() throws {
        var source = try V3TestSupport.reviewedPayload()
        source.content.content.terms[0].sourceRecordID = UUID()
        let eventIndex = try XCTUnwrap(source.eventStates.firstIndex { $0.feedbackSemanticsVersion == 2 })
        let changes: [(inout Payload) -> Void] = [
            { $0.cards[0].schedule.lapseCount = -1 },
            { $0.cards[0].schedule.nextReviewAt = nil },
            { $0.cards[0].revision = -1 },
            { $0.cards[0].updatedAt = Date(timeIntervalSince1970: .infinity) },
            { $0.sessions[0].targetCardCount = 0 },
            { $0.sessions[0].scope.studyTimeZoneID = "Invalid/Zone" },
            { $0.sessionItems[0].attemptCount = 99 },
            { $0.sessionItems[0].completionOutcome = .reviewed },
            { $0.eventStates[eventIndex].afterSchedule?.lapseCount += 1 },
            { $0.termHistories[0].legacyWrongCount = 123 }
        ]
        for change in changes {
            var invalid = source
            change(&invalid)
            let report = Service.inspect(invalid)
            XCTAssertEqual(report.detachableReferenceCount, 1)
            XCTAssertNotNil(report.remainingValidationError)
            assertBlocked(invalid)
        }
    }

    func testFullPlanBindingDetectsReviewOnlyOrPreferenceChangesWithoutRevisionBumps() throws {
        var source = try V3TestSupport.reviewedPayload()
        source.content.content.terms[0].sourceRecordID = UUID()
        let plan = try Service.prepareRepair(source, at: now)
        let changes: [(inout Payload) -> Void] = [
            { $0.cards[0].schedule.priorityRequestedAt = self.now },
            { $0.sessions[0].scope.courseName = "Changed" },
            { $0.sessionItems[0].position += 1 },
            { $0.eventStates[0].invalidatedAt = self.now },
            { $0.termHistories[0].legacySnapshotAt = self.now },
            { $0.content.content.preferences.appearance = "light" }
        ]
        for change in changes {
            var changed = source
            change(&changed)
            XCTAssertThrowsError(try plan.validatedPayload(matching: changed)) {
                XCTAssertEqual($0 as? WordNoteV3IntegrityError, .staleRepairPlan)
            }
        }
        var reordered = source
        reordered.cards.reverse()
        reordered.eventStates.reverse()
        reordered.termHistories.reverse()
        reordered.content.content.terms.reverse()
        XCTAssertEqual(Service.inspect(reordered), Service.inspect(source))
        XCTAssertEqual(try plan.validatedPayload(matching: reordered), plan.repairedPayload)
    }

    func testContainerInspectionIsReadOnlyEvenWhileBlockedAndRejectsUncommittedDrafts() throws {
        let container = try V3TestSupport.container()
        try V3TestSupport.reviewedPayload().populateEmptyStore(container.mainContext)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.sourceRecordID = UUID()
        try container.mainContext.save()
        let before = try Payload.captureForIntegrityInspection(from: container.mainContext)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        defer { try? WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket) }
        XCTAssertTrue(try Service.inspect(in: container).canPrepareRepair)
        let plan = try Service.prepareRepair(in: container, at: now)
        XCTAssertEqual(try Service.validate(plan, against: container), plan.repairedPayload)
        XCTAssertEqual(try Payload.captureForIntegrityInspection(from: container.mainContext), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        term.chineseMeaning = "Unsaved text"
        XCTAssertThrowsError(try Service.inspect(in: container)) { XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges) }
        XCTAssertThrowsError(try Service.prepareRepair(in: container)) { XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges) }
        XCTAssertThrowsError(try Service.validate(plan, against: container)) { XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges) }
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "Unsaved text")
    }

    func testCorruptPersistentJSONFailsInspectionWithoutDroppingItsModel() throws {
        let container = try V3TestSupport.container()
        let payload = try V3TestSupport.reviewedPayload()
        try payload.populateEmptyStore(container.mainContext)
        let session = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
        session.scopeSnapshotJSON = "{broken"
        try container.mainContext.save()
        XCTAssertThrowsError(try Service.inspect(in: container)) { XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidDocument) }
        XCTAssertEqual(session.scopeSnapshotJSON, "{broken")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()), payload.sessions.count)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testInspectionCannotAttachToOldSchemasAndOldInspectionCannotReadV3() async throws {
        for version in [WordNoteSchemaV1.self as any VersionedSchema.Type, WordNoteSchemaV2.self] {
            XCTAssertThrowsError(try Service.inspect(in: V3TestSupport.container(version))) {
                XCTAssertEqual($0 as? WordNoteV3ContentError, .wrongSchema)
            }
        }
        let container = try V3TestSupport.container()
        do {
            _ = try await WordNoteSnapshotCapture.captureForIntegrityInspection(container: container, preferences: .init())
            XCTFail("The V2-only reader must reject V3.")
        } catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
    }

    func testReadOnlyBackgroundCaptureIncludesInvalidV3RelationshipsAndEveryReviewValue() async throws {
        let container = try V3TestSupport.container()
        let valid = try V3TestSupport.reviewedPayload()
        try valid.populateEmptyStore(container.mainContext)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.sourceRecordID = UUID()
        try container.mainContext.save()
        let expected = try Payload.captureForIntegrityInspection(from: container.mainContext, preferences: valid.content.content.preferences)
        let actual = try await WordNoteSnapshotCapture.captureVersionedForIntegrityInspection(container: container, preferences: valid.content.content.preferences)
        XCTAssertEqual(actual, .v3(expected))
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    private func assertBlocked(_ payload: Payload, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Service.prepareRepair(payload, at: now), file: file, line: line) {
            guard case WordNoteV3IntegrityError.unresolvedIssues(let report) = $0 else {
                return XCTFail("Expected unresolved integrity issues, got \($0)", file: file, line: line)
            }
            XCTAssertTrue(report.requiresManualResolution, file: file, line: line)
            XCTAssertFalse(report.canPrepareRepair, file: file, line: line)
        }
    }
}
