import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2IntegrityTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport
    private typealias Payload = WordNoteSnapshotV2Payload
    private typealias Service = WordNoteV2IntegrityService

    func testHealthyStoreHasNoIssuesAndNoOpRepairDoesNotChangeAnything() throws {
        let payload = try makePayload()
        let report = Service.inspect(payload)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.isStructurallyValid)
        XCTAssertFalse(report.canPrepareRepair)
        XCTAssertNil(report.remainingValidationError)
        let plan = try Service.prepareRepair(payload, at: Support.now)
        XCTAssertEqual(plan.repairedPayload, payload)
        XCTAssertEqual(try plan.validatedPayload(matching: payload), payload)
    }

    func testOptionalReferenceRepairPreservesEveryRowAndTextAndBumpsTermRevisionOnce() throws {
        var source = try makePayload()
        let termID = source.lookupEvents[0].termID
        let termIndex = try XCTUnwrap(source.content.terms.firstIndex { $0.id == termID })
        let stateIndex = try XCTUnwrap(source.termStates.firstIndex { $0.id == termID })
        source.content.terms[termIndex].sourceRecordID = UUID()
        source.occurrences[0].sourceRecordID = UUID()
        source.lookupEvents[0].occurrenceID = UUID()
        let before = source
        let report = Service.inspect(source)
        XCTAssertEqual(report.detachableReferenceCount, 3)
        XCTAssertTrue(report.canPrepareRepair)
        XCTAssertFalse(report.isStructurallyValid)
        XCTAssertFalse(report.requiresManualResolution)
        let plan = try Service.prepareRepair(source, at: Support.now.addingTimeInterval(1))
        var expected = source
        expected.content.terms[termIndex].sourceRecordID = nil
        expected.content.terms[termIndex].updatedAt = Support.now.addingTimeInterval(1)
        expected.termStates[stateIndex].revision += 1
        expected.occurrences[0].sourceRecordID = nil
        expected.lookupEvents[0].occurrenceID = nil
        XCTAssertEqual(plan.repairedPayload, expected.canonicalized)
        XCTAssertEqual(plan.repairedPayload.counts, source.counts)
        XCTAssertEqual(source, before)
        XCTAssertNoThrow(try plan.repairedPayload.validate())
        let again = try Service.prepareRepair(plan.repairedPayload, at: Support.now.addingTimeInterval(2))
        XCTAssertEqual(again.repairedPayload, plan.repairedPayload)
        XCTAssertTrue(again.report.isStructurallyValid)
    }

    func testMissingRequiredRelationsAreReportedWithoutDeletingOrGuessing() throws {
        let payload = try makePayload()
        let missing = UUID()
        let changes: [(inout Payload) -> Void] = [
            { $0.content.inputRecords[0].courseID = missing },
            { $0.content.terms[0].courseID = missing },
            { $0.content.candidates[0].inputRecordID = missing },
            { $0.content.reviewEvents[0].termID = missing },
            { $0.occurrences[0].termID = missing },
            { $0.occurrences[0].courseID = missing },
            { $0.courseLinks[0].termID = missing },
            { $0.courseLinks[0].courseID = missing },
            { $0.lookupEvents[0].termID = missing },
            {
                $0.content.candidates[0].statusRaw = "saved"
                $0.candidateStates[0].savedLinkStateRaw = "resolved"
                $0.candidateStates[0].savedTermID = missing
            }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            let before = invalid
            let report = Service.inspect(invalid)
            XCTAssertTrue(report.requiresManualResolution)
            XCTAssertTrue(report.issues.contains { $0.kind == .missingReference && $0.relatedID == missing && $0.resolution == .manualResolutionRequired })
            assertRepairBlocked(invalid)
            XCTAssertEqual(invalid, before)
        }
    }

    func testCrossLinkedExistingSourcesAreNotSilentlyDetached() throws {
        let payload = try makePayload()
        let changes: [(inout Payload) -> Void] = [
            { $0.occurrences[0].sourceRecordID = $0.content.inputRecords[0].id },
            { $0.lookupEvents[0].captureID = UUID() },
            { $0.lookupEvents[0].termID = $0.content.terms.first { $0.id != payload.lookupEvents[0].termID }!.id }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            let report = Service.inspect(invalid)
            XCTAssertTrue(report.issues.contains { $0.kind == .mismatchedReference })
            XCTAssertEqual(report.detachableReferenceCount, 0)
            assertRepairBlocked(invalid)
        }
    }

    func testAllEntityAndMetadataDuplicateIDsAreReportedWithoutCrashing() throws {
        let payload = try makePayload()
        let changes: [(inout Payload) -> Void] = [
            { $0.content.courses.append($0.content.courses[0]) },
            { $0.content.inputRecords.append($0.content.inputRecords[0]) },
            { $0.content.candidates.append($0.content.candidates[0]) },
            { $0.content.terms.append($0.content.terms[0]) },
            { $0.content.reviewEvents.append($0.content.reviewEvents[0]) },
            { $0.occurrences.append($0.occurrences[0]) },
            { $0.courseLinks.append($0.courseLinks[0]) },
            { $0.lookupEvents.append($0.lookupEvents[0]) },
            { $0.courseRevisions.append($0.courseRevisions[0]) },
            { $0.recordStates.append($0.recordStates[0]) },
            { $0.candidateStates.append($0.candidateStates[0]) },
            { $0.termStates.append($0.termStates[0]) }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            XCTAssertTrue(Service.inspect(invalid).issues.contains { $0.kind == .duplicateIdentifier })
            assertRepairBlocked(invalid)
        }
    }

    func testDuplicateBusinessKeysDoNotPickAnArbitraryWinner() throws {
        let payload = try makePayload()
        let changes: [(inout Payload) -> Void] = [
            { $0.recordStates[1].captureID = $0.recordStates[0].captureID },
            { var row = $0.occurrences[0]; row.id = UUID(); $0.occurrences.append(row) },
            { var row = $0.courseLinks[0]; row.id = UUID(); $0.courseLinks.append(row) },
            { var row = $0.lookupEvents[0]; row.id = UUID(); $0.lookupEvents.append(row) }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            XCTAssertEqual(Service.inspect(invalid).issues.filter { $0.kind == .duplicateBusinessKey }.count, 2)
            assertRepairBlocked(invalid)
        }
    }

    func testMissingAndExtraMetadataAreNotFabricated() throws {
        let payload = try makePayload()
        let changes: [(inout Payload) -> Void] = [
            { $0.courseRevisions.removeLast() },
            { $0.recordStates.removeLast() },
            { $0.candidateStates.removeLast() },
            { $0.termStates.removeLast() },
            { var row = $0.termStates[0]; row.id = UUID(); $0.termStates.append(row) }
        ]
        for change in changes {
            var invalid = payload
            change(&invalid)
            XCTAssertTrue(Service.inspect(invalid).issues.contains { $0.kind == .metadataMismatch })
            assertRepairBlocked(invalid)
        }
    }

    func testCandidateStateConflictsDoNotBecomeInventedDeletions() throws {
        var source = try makePayload()
        source.candidateStates[0].savedTermID = source.content.terms[0].id
        XCTAssertTrue(Service.inspect(source).issues.contains { $0.kind == .invalidCandidateState })
        assertRepairBlocked(source)
        source.content.candidates[0].statusRaw = "saved"
        source.candidateStates[0].savedLinkStateRaw = "resolved"
        source.candidateStates[0].savedTermID = UUID()
        let before = source
        assertRepairBlocked(source)
        XCTAssertEqual(source, before)
        XCTAssertEqual(source.candidateStates[0].savedLinkStateRaw, "resolved")
    }

    func testScalarValidationIsNotHiddenBehindARepairableMissingReference() throws {
        var source = try makePayload()
        source.content.terms[0].sourceRecordID = UUID()
        let changes: [(inout Payload) -> Void] = [
            { $0.content.terms[0].wrongCount = -1 },
            { $0.content.courses[0].updatedAt = Date(timeIntervalSince1970: .infinity) },
            { $0.recordStates[0].queueStateRaw = "unknown" },
            { $0.candidateStates[0].analysisGeneration = 999 },
            { $0.occurrences[0].legacy = true }
        ]
        for change in changes {
            var invalid = source
            change(&invalid)
            let report = Service.inspect(invalid)
            XCTAssertEqual(report.detachableReferenceCount, 1)
            XCTAssertNotNil(report.remainingValidationError)
            assertRepairBlocked(invalid)
        }
    }

    func testLegacyWarningsArePreservedWithoutPretendingToResolveThem() throws {
        var source = try makePayload()
        source.content.terms[0].term = "歷史中文主體"
        source.content.terms[1].normalizedTerm = source.content.terms[0].normalizedTerm
        source.content.candidates[0].statusRaw = "saved"
        source.candidateStates[0].savedLinkStateRaw = "unresolvedLegacy"
        let report = Service.inspect(source)
        XCTAssertTrue(report.isStructurallyValid)
        XCTAssertEqual(report.issues.filter { $0.kind == .ambiguousHeadword }.count, 2)
        XCTAssertTrue(report.issues.contains { $0.kind == .legacySubjectNeedsReview })
        XCTAssertTrue(report.issues.contains { $0.kind == .unresolvedSavedCandidate })
        XCTAssertTrue(report.issues.allSatisfy { $0.resolution == .warning })
        XCTAssertEqual(try Service.prepareRepair(source, at: Support.now).repairedPayload, source)
    }

    func testReportsAndPlansAreIndependentOfFetchOrder() throws {
        var source = try makePayload()
        source.content.terms[0].sourceRecordID = UUID()
        source.occurrences[0].sourceRecordID = UUID()
        let report = Service.inspect(source)
        let plan = try Service.prepareRepair(source, at: Support.now)
        source.content.terms.reverse()
        source.content.inputRecords.reverse()
        source.recordStates.reverse()
        source.termStates.reverse()
        source.courseLinks.reverse()
        XCTAssertEqual(Service.inspect(source), report)
        XCTAssertEqual(try Service.prepareRepair(source, at: Support.now).repairedPayload, plan.repairedPayload)
        XCTAssertEqual(try plan.validatedPayload(matching: source), plan.repairedPayload)
    }

    func testAnyDataOrPreferenceChangeInvalidatesRepairPlanEvenWithoutRevisionChange() throws {
        var source = try makePayload()
        source.content.terms[0].sourceRecordID = UUID()
        let plan = try Service.prepareRepair(source, at: Support.now)
        var changed = source
        changed.content.terms[0].chineseMeaning = "Changed after preview"
        XCTAssertThrowsError(try plan.validatedPayload(matching: changed)) {
            XCTAssertEqual($0 as? WordNoteV2IntegrityError, .staleRepairPlan)
        }
        changed = source
        changed.content.preferences.appearance = "dark"
        XCTAssertThrowsError(try plan.validatedPayload(matching: changed)) {
            XCTAssertEqual($0 as? WordNoteV2IntegrityError, .staleRepairPlan)
        }
    }

    func testRepairRejectsRevisionOverflowAndInvalidClockWithoutChangingSource() throws {
        var source = try makePayload()
        source.content.terms[0].sourceRecordID = UUID()
        source.termStates[0].revision = 1_000_000_000
        let before = source
        XCTAssertThrowsError(try Service.prepareRepair(source, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .counterLimit)
        }
        XCTAssertThrowsError(try Service.prepareRepair(source, at: Date(timeIntervalSince1970: .nan))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidValue)
        }
        XCTAssertEqual(source, before)
    }

    func testInspectionRejectsWrongSchemaAndUncommittedEditsWithoutSavingOrDiscarding() throws {
        let oldSchema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let old = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, isStoredInMemoryOnly: true)])
        XCTAssertThrowsError(try Service.inspect(in: old)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .wrongSchema)
        }
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        term.chineseMeaning = "Uncommitted text"
        XCTAssertThrowsError(try Service.inspect(in: container)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges)
        }
        XCTAssertThrowsError(try Service.prepareRepair(in: container)) {
            XCTAssertEqual($0 as? WordNoteV2ContentError, .unsavedChanges)
        }
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "Uncommitted text")
        container.mainContext.rollback()
    }

    func testInspectionAndPreviewNeverWriteTheContainerEvenDuringRestoreGate() throws {
        let container = try Support.container()
        let term = try Support.term("quick", in: container)
        term.sourceRecordID = UUID()
        try container.mainContext.save()
        let before = try Payload.captureForIntegrityInspection(from: container.mainContext)
        let autosave = container.mainContext.autosaveEnabled
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        defer { try? WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket) }
        let report = try Service.inspect(in: container)
        let plan = try Service.prepareRepair(in: container, at: Support.now)
        XCTAssertTrue(report.canPrepareRepair)
        XCTAssertEqual(try Service.validate(plan, against: container), plan.repairedPayload)
        XCTAssertEqual(try Payload.captureForIntegrityInspection(from: container.mainContext), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertEqual(container.mainContext.autosaveEnabled, autosave)
        XCTAssertThrowsError(try Support.snapshot(container)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .missingReference)
        }
    }

    func testReportContainsIDsAndCategoriesButNoLearningText() throws {
        var source = try makePayload()
        source.content.terms[0].chineseMeaning = "Synthetic private note marker"
        source.content.terms[0].sourceRecordID = UUID()
        let report = Service.inspect(source)
        let encoded = try JSONEncoder().encode(report.issues)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("sourceRecordID"))
        XCTAssertFalse(text.contains("Synthetic private note marker"))
        XCTAssertFalse(text.contains("chineseMeaning"))
    }

    func testRepairedCopyReopensAndOriginalBrokenSQLiteRemainsUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordnote-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appending(path: "original.store")
        let repairedURL = directory.appending(path: "repaired.store")
        let valid = try makePayload()
        let preferences = WordNoteSnapshotPayload.Preferences(appearance: "dark", defaultSource: "paper")
        let (before, repaired) = try autoreleasepool {
            let container = try diskContainer(originalURL)
            try valid.populateEmptyStore(container.mainContext)
            let term = try Support.term("quick", in: container)
            term.sourceRecordID = UUID()
            try container.mainContext.save()
            let before = try Payload.captureForIntegrityInspection(from: container.mainContext, preferences: preferences)
            let plan = try Service.prepareRepair(in: container, preferences: preferences, at: Support.now)
            let repaired = try Service.validate(plan, against: container, preferences: preferences)
            XCTAssertThrowsError(try repaired.populateEmptyStore(container.mainContext)) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .destinationNotEmpty)
            }
            let target = try diskContainer(repairedURL)
            try repaired.populateEmptyStore(target.mainContext)
            return (before, repaired)
        }
        let original = try diskContainer(originalURL)
        XCTAssertEqual(try Payload.captureForIntegrityInspection(from: original.mainContext, preferences: preferences), before)
        let target = try diskContainer(repairedURL)
        XCTAssertEqual(try Payload.capture(from: target.mainContext, preferences: preferences), repaired)
        XCTAssertEqual(repaired.content.preferences, preferences)
        XCTAssertEqual(before.counts, repaired.counts)
    }

    private func makePayload() throws -> Payload {
        let container = try Support.container()
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.capture(.init(rawText: "quick", note: "Original note", capturedVia: .floatingQuickAdd), at: Support.now)
        return try Support.snapshot(container)
    }

    private func assertRepairBlocked(_ payload: Payload, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Service.prepareRepair(payload, at: Support.now), file: file, line: line) {
            guard case WordNoteV2IntegrityError.unresolvedIssues(let report) = $0 else {
                return XCTFail("Expected unresolved issues, got \($0)", file: file, line: line)
            }
            XCTAssertTrue(report.requiresManualResolution, file: file, line: line)
        }
    }

    private func diskContainer(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration("Integrity", schema: schema, url: url)])
        container.mainContext.autosaveEnabled = false
        return container
    }
}
