import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV2PersistenceTests: XCTestCase {
    func testFrozenV1StoreConvertsIntoSeparateV2StoreAndReopensWithEveryField() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "v1", withExtension: "store", subdirectory: "Fixtures"))
        let originalBytes = try Data(contentsOf: fixture)
        let copy = directory.appending(path: "original-v1.store")
        try FileManager.default.copyItem(at: fixture, to: copy)
        let source = try autoreleasepool {
            let container = try makeContainer(WordNoteSchemaV1.self, url: copy)
            return try WordNoteSnapshotPayload.capture(from: container.mainContext)
        }
        XCTAssertEqual(source, try makeSource())
        let result = try WordNoteV1ToV2Migration.convert(source)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.payload.courseLinks.count, 4)
        XCTAssertTrue(result.payload.occurrences.isEmpty)
        XCTAssertTrue(result.payload.lookupEvents.isEmpty)
        XCTAssertEqual(result.payload.content.terms, source.terms)
        XCTAssertEqual(result.payload.content.reviewEvents, source.reviewEvents)
        try assertPersistentRoundTrip(result.payload, directory: directory)
        let unchanged = try makeContainer(WordNoteSchemaV1.self, url: copy)
        XCTAssertEqual(try WordNoteSnapshotPayload.capture(from: unchanged.mainContext), source)
        XCTAssertEqual(try Data(contentsOf: fixture), originalBytes)
    }

    func testProductionAliasesAndMigrationPlanStillUseOnlyV1() {
        XCTAssertTrue(TermModel.self == WordNoteSchemaV1.TermModel.self)
        XCTAssertTrue(InputRecordModel.self == WordNoteSchemaV1.InputRecordModel.self)
        XCTAssertEqual(WordNoteMigrationPlan.schemas.count, 1)
        XCTAssertEqual(ObjectIdentifier(WordNoteMigrationPlan.schemas[0]), ObjectIdentifier(WordNoteSchemaV1.self))
        XCTAssertTrue(WordNoteMigrationPlan.stages.isEmpty)
        XCTAssertEqual(WordNoteSchemaV1.models.count, 5)
        XCTAssertEqual(WordNoteSchemaV2.models.count, 8)
    }

    func testConversionIsDeterministicAcrossRepeatsAndFetchOrder() throws {
        var source = try sourceWithOccurrences()
        let first = try WordNoteV1ToV2Migration.convert(source)
        XCTAssertEqual(first.payload.recordStates[0].captureID.uuidString.lowercased(), "c5088a57-6e1a-86cf-85d3-aaa026e8d8e8")
        source.courses.reverse()
        source.inputRecords.reverse()
        source.terms.reverse()
        source.candidates.reverse()
        XCTAssertEqual(try WordNoteV1ToV2Migration.convert(source).payload, first.payload)
        XCTAssertEqual(try WordNoteV1ToV2Migration.convert(source).issues, first.issues)
        let original = try WordNoteSnapshotV2Codec.contentChecksum(first.payload)
        var reordered = first.payload
        reordered.occurrences.reverse()
        reordered.courseLinks.reverse()
        reordered.recordStates.reverse()
        XCTAssertEqual(try WordNoteSnapshotV2Codec.contentChecksum(reordered), original)
    }

    func testTwoTermsShareCaptureButKeepIndependentOccurrencesAndOriginalContext() throws {
        let source = try sourceWithOccurrences()
        let payload = try WordNoteV1ToV2Migration.convert(source).payload
        let record = source.inputRecords[0]
        let occurrences = payload.occurrences.filter { $0.sourceRecordID == record.id }
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(Set(occurrences.map(\.captureID)).count, 1)
        XCTAssertEqual(Set(occurrences.map(\.id)).count, 2)
        XCTAssertTrue(occurrences.allSatisfy {
            $0.rawTextSnapshot == record.rawText && $0.note == record.note && $0.courseID == record.courseID
                && $0.sourceTypeRaw == record.sourceTypeRaw && $0.occurredAt == record.createdAt && $0.legacy
        })
        XCTAssertEqual(payload.content.terms, source.terms)
        XCTAssertTrue(payload.courseLinks.contains { $0.termID == source.terms[0].id && $0.courseID == source.terms[0].courseID })
    }

    func testFallbackContextKeepsWhitespaceAndDoesNotInventMissingSources() throws {
        var source = try makeSource()
        source.terms[0].contextSentence = "  Original sentence.\n"
        source.terms[1].contextSentence = " \n\t "
        let payload = try WordNoteV1ToV2Migration.convert(source).payload
        XCTAssertEqual(payload.occurrences.count, 1)
        let occurrence = try XCTUnwrap(payload.occurrences.first)
        XCTAssertEqual(occurrence.rawTextSnapshot, "  Original sentence.\n")
        XCTAssertEqual(occurrence.termID, source.terms[0].id)
        XCTAssertNil(occurrence.sourceRecordID)
        XCTAssertEqual(occurrence.occurredAt, source.terms[0].createdAt)
        XCTAssertEqual(occurrence.capturedViaRaw, "legacy")
    }

    func testSavedCandidateOnlyLinksToUniqueTermWithMatchingSourceAndNormalizedHeadword() throws {
        var source = try makeSource()
        let candidateID = source.candidates[0].id
        let termIndex = try XCTUnwrap(source.terms.firstIndex { $0.normalizedTerm == source.candidates[0].normalizedTerm })
        source.candidates[0].statusRaw = "saved"
        source.terms[termIndex].sourceRecordID = source.candidates[0].inputRecordID
        let resolved = try WordNoteV1ToV2Migration.convert(source)
        let state = try XCTUnwrap(resolved.payload.candidateStates.first { $0.id == candidateID })
        XCTAssertEqual(state.savedTermID, source.terms[termIndex].id)
        XCTAssertEqual(state.savedLinkStateRaw, "resolved")
        XCTAssertNil(state.confirmationOperationID)
        var duplicate = source.terms[termIndex]
        duplicate.id = UUID()
        source.terms.append(duplicate)
        let ambiguous = try WordNoteV1ToV2Migration.convert(source)
        XCTAssertNil(ambiguous.payload.candidateStates.first { $0.id == candidateID }?.savedTermID)
        XCTAssertEqual(ambiguous.payload.candidateStates.first { $0.id == candidateID }?.savedLinkStateRaw, "unresolvedLegacy")
        XCTAssertTrue(ambiguous.issues.contains { $0.kind == .unresolvedSavedCandidate && $0.entityID == candidateID })
        source.terms.removeLast()
        source.terms[termIndex].sourceRecordID = nil
        let noSource = try WordNoteV1ToV2Migration.convert(source)
        XCTAssertEqual(noSource.payload.candidateStates.first { $0.id == candidateID }?.savedLinkStateRaw, "unresolvedLegacy")
    }

    func testLegacyCountersAndNonEnglishSubjectsAreRetainedWithoutInventedLookupEvents() throws {
        var source = try makeSource()
        source.terms[0].term = "舊詞條"
        source.terms[0].normalizedTerm = "舊詞條"
        source.terms[0].wrongCount = 17
        source.terms[0].duplicateHitCount = 29
        let result = try WordNoteV1ToV2Migration.convert(source)
        XCTAssertEqual(result.payload.content.terms, source.terms)
        XCTAssertTrue(result.payload.lookupEvents.isEmpty)
        XCTAssertTrue(result.payload.termStates.allSatisfy { $0.counterSemanticsVersionRaw == "legacyMixed" && $0.revision == 0 })
        XCTAssertTrue(result.issues.contains { $0.kind == .legacySubjectNeedsReview && $0.entityID == source.terms[0].id })
    }

    func testDirectionAndInterruptedQueueStateAreFrozenWithoutNetworkAttempts() throws {
        var source = try makeSource()
        source.inputRecords[0].rawText = "過擬合"
        source.inputRecords[0].statusRaw = "analyzing"
        let payload = try WordNoteV1ToV2Migration.convert(source).payload
        let interrupted = try XCTUnwrap(payload.recordStates.first { $0.id == source.inputRecords[0].id })
        XCTAssertEqual(interrupted.resolvedLookupDirectionRaw, "chineseToEnglish")
        XCTAssertEqual(interrupted.directionDetectorVersion, "han-latin-v1")
        XCTAssertEqual(interrupted.lookupIntentRaw, "auto")
        XCTAssertEqual(interrupted.queueStateRaw, "queued")
        XCTAssertEqual(interrupted.analysisGeneration, 1)
        XCTAssertNil(interrupted.attemptID)
        XCTAssertEqual(interrupted.autoRetryCount, 0)
        XCTAssertNil(interrupted.nextAttemptAt)
        XCTAssertEqual(payload.content.inputRecords.first { $0.id == interrupted.id }?.statusRaw, "draft")
        let failed = try XCTUnwrap(source.inputRecords.first { $0.statusRaw == "failed" })
        XCTAssertEqual(payload.recordStates.first { $0.id == failed.id }?.queueStateRaw, "failed")
        XCTAssertEqual(payload.content.inputRecords.first { $0.id == failed.id }?.aiErrorSummary, failed.aiErrorSummary)
    }

    func testFrozenDirectionAlgorithmMatchesBaselineBoundaryCases() {
        let samples: [(String, LookupDirection)] = [
            ("quick", .englishToChinese), ("", .englishToChinese), ("過擬合", .chineseToEnglish),
            ("汉字abc", .englishToChinese), ("汉字ab", .chineseToEnglish), ("123", .englishToChinese),
            ("漢abc", .englishToChinese), ("é漢", .chineseToEnglish), ("𠀀a", .chineseToEnglish),
            ("中文（AI）", .chineseToEnglish), ("a中", .chineseToEnglish), ("漢_🙂", .chineseToEnglish)
        ]
        for (sample, expected) in samples {
            XCTAssertEqual(LookupDirectionDetectorV1.detect(sample), expected, sample)
        }
    }

    func testEmptyV1ConvertsToValidEmptyV2WithoutFabricatedEntities() throws {
        let v1 = try makeContainer(WordNoteSchemaV1.self)
        let payload = try WordNoteV1ToV2Migration.convert(WordNoteSnapshotPayload.capture(from: v1.mainContext)).payload
        XCTAssertEqual(payload.counts.total, 0)
        let v2 = try makeContainer(WordNoteSchemaV2.self)
        try payload.populateEmptyStore(v2.mainContext)
        XCTAssertEqual(try WordNoteSnapshotV2Payload.capture(from: v2.mainContext), payload)
    }

    func testDistinctLegacySubmissionsWithIdenticalTextKeepDistinctCaptureIDs() throws {
        var source = try makeSource()
        source.inputRecords[1].rawText = source.inputRecords[0].rawText
        source.inputRecords[1].normalizedText = source.inputRecords[0].normalizedText
        let payload = try WordNoteV1ToV2Migration.convert(source).payload
        XCTAssertNotEqual(payload.recordStates[0].captureID, payload.recordStates[1].captureID)
        XCTAssertEqual(payload.recordStates.count, source.inputRecords.count)
    }

    func testPreflightReportsDanglingReferencesAndDoesNotRepairSource() throws {
        var source = try makeSource()
        let missingCourse = UUID()
        source.terms[0].courseID = missingCourse
        source.terms[0].sourceRecordID = UUID()
        source.candidates[0].inputRecordID = UUID()
        source.reviewEvents[0].termID = UUID()
        let before = source
        let issues = WordNoteV1ToV2Migration.preflight(source)
        XCTAssertEqual(issues.count, 4)
        XCTAssertTrue(issues.allSatisfy(\.blocksMigration))
        XCTAssertTrue(issues.contains { $0.kind == .missingCourse && $0.relatedID == missingCourse })
        XCTAssertThrowsError(try WordNoteV1ToV2Migration.convert(source)) {
            XCTAssertEqual($0 as? WordNoteV1ToV2Migration.MigrationError, .preflightFailed(issues))
        }
        XCTAssertEqual(source, before)
    }

    func testV2SnapshotPersistsAllNewFieldsAndMultipleCourseMemberships() throws {
        var payload = try WordNoteV1ToV2Migration.convert(sourceWithOccurrences()).payload
        payload.content.preferences = .init(appearance: "dark", defaultSource: "paper")
        payload.courseRevisions[0].revision = 9
        payload.termStates[0].revision = 4
        payload.recordStates[0].revision = 2
        payload.recordStates[0].analysisGeneration = 3
        payload.recordStates[0].lookupIntentRaw = "englishToChinese"
        payload.recordStates[0].resolvedLookupDirectionRaw = "englishToChinese"
        payload.recordStates[0].directionDetectorVersion = "explicit-v1"
        payload.recordStates[0].queueStateRaw = "failed"
        payload.recordStates[0].attemptID = UUID()
        payload.recordStates[0].autoRetryCount = 2
        payload.recordStates[0].nextAttemptAt = WordNoteTestFixture.referenceDate.addingTimeInterval(60)
        payload.content.candidates[0].statusRaw = "saved"
        payload.candidateStates[0].savedLinkStateRaw = "resolved"
        payload.candidateStates[0].savedTermID = payload.content.terms[0].id
        payload.candidateStates[0].confirmationOperationID = UUID()
        payload.candidateStates[0].revision = 7
        payload.candidateStates[0].analysisGeneration = 2
        payload.occurrences[0].sourceTitle = "Synthetic source"
        payload.occurrences[0].sourceURL = "https://example.com/notes"
        payload.occurrences[0].sourcePage = "8-9"
        let newSource = WordNoteSchemaV2.TermOccurrenceModel(
            termID: payload.content.terms[0].id, captureID: UUID(), rawTextSnapshot: "quick",
            note: "Another encounter", courseID: payload.content.courses[1].id,
            sourceType: .book, occurredAt: WordNoteTestFixture.referenceDate,
            capturedVia: .floatingQuickAdd, createdAt: WordNoteTestFixture.referenceDate
        )
        payload.occurrences.append(.init(newSource))
        payload.lookupEvents.append(.init(WordNoteSchemaV2.LookupEventModel(
            termID: newSource.termID, captureID: newSource.captureID, occurrenceID: newSource.id,
            occurredAt: newSource.occurredAt, createdAt: newSource.createdAt
        )))
        payload.courseLinks.append(.init(WordNoteSchemaV2.TermCourseLinkModel(
            termID: payload.content.terms[0].id, courseID: payload.content.courses[1].id,
            createdAt: WordNoteTestFixture.referenceDate
        )))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try assertPersistentRoundTrip(payload, directory: directory)
    }

    func testV2SnapshotRejectsMissingExtraAndDuplicateMetadata() throws {
        let payload = try WordNoteV1ToV2Migration.convert(makeSource()).payload
        var missing = payload
        missing.recordStates.removeLast()
        assertInvalid(missing, .missingReference)
        var extra = payload
        extra.termStates.append(.init(id: UUID(), revision: 0, counterSemanticsVersionRaw: "legacyMixed"))
        assertInvalid(extra, .missingReference)
        var duplicate = payload
        duplicate.courseRevisions.append(duplicate.courseRevisions[0])
        assertInvalid(duplicate, .duplicateID)
        var capture = payload
        capture.recordStates[1].captureID = capture.recordStates[0].captureID
        assertInvalid(capture, .duplicateID)
    }

    func testV2SnapshotRejectsDuplicateBusinessKeysEvenWithDifferentRowIDs() throws {
        let payload = try WordNoteV1ToV2Migration.convert(sourceWithOccurrences()).payload
        var occurrences = payload
        var duplicateOccurrence = occurrences.occurrences[0]
        duplicateOccurrence.id = UUID()
        occurrences.occurrences.append(duplicateOccurrence)
        assertInvalid(occurrences, .duplicateID)
        var memberships = payload
        var duplicateLink = memberships.courseLinks[0]
        duplicateLink.id = UUID()
        memberships.courseLinks.append(duplicateLink)
        assertInvalid(memberships, .duplicateID)
        var events = payload
        let source = events.occurrences[0]
        var event = WordNoteSnapshotV2Payload.LookupEvent(WordNoteSchemaV2.LookupEventModel(
            termID: source.termID, captureID: source.captureID, occurrenceID: source.id, occurredAt: source.occurredAt
        ))
        events.lookupEvents.append(event)
        event.id = UUID()
        events.lookupEvents.append(event)
        assertInvalid(events, .duplicateID)
    }

    func testV2SnapshotRejectsInvalidStatesAndFutureCandidateGeneration() throws {
        let payload = try WordNoteV1ToV2Migration.convert(makeSource()).payload
        let mutations: [(inout WordNoteSnapshotV2Payload) -> Void] = [
            { $0.termStates[0].revision = -1 },
            { $0.recordStates[0].autoRetryCount = 3 },
            { $0.recordStates[0].queueStateRaw = "running" },
            { $0.recordStates[0].nextAttemptAt = Date() },
            { $0.recordStates[0].directionDetectorVersion = "unknown" },
            { $0.recordStates[0].lookupIntentRaw = "chineseToEnglish" },
            { $0.candidateStates[0].analysisGeneration = 999 },
            { $0.content.inputRecords[0].statusRaw = "analyzing" }
        ]
        for mutate in mutations {
            var invalid = payload
            mutate(&invalid)
            assertInvalid(invalid, .invalidValue)
        }
        var invalidEnum = payload
        invalidEnum.termStates[0].counterSemanticsVersionRaw = "future"
        assertInvalid(invalidEnum, .invalidEnum)
    }

    func testV2SnapshotValidatesSavedLinkLifecycle() throws {
        var payload = try WordNoteV1ToV2Migration.convert(makeSource()).payload
        payload.candidateStates[0].savedTermID = payload.content.terms[0].id
        assertInvalid(payload, .invalidValue)
        payload.content.candidates[0].statusRaw = "saved"
        payload.candidateStates[0].savedLinkStateRaw = "resolved"
        XCTAssertNoThrow(try payload.validate())
        payload.candidateStates[0].savedTermID = UUID()
        assertInvalid(payload, .missingReference)
        payload.candidateStates[0].savedTermID = nil
        payload.candidateStates[0].savedLinkStateRaw = "targetDeleted"
        XCTAssertNoThrow(try payload.validate())
        payload.candidateStates[0].savedLinkStateRaw = "unresolvedLegacy"
        XCTAssertNoThrow(try payload.validate())
        payload.candidateStates[0].savedLinkStateRaw = "none"
        assertInvalid(payload, .invalidValue)
    }

    func testV2SnapshotRejectsCrossLinkedCapturesAndLookupSources() throws {
        let payload = try WordNoteV1ToV2Migration.convert(sourceWithOccurrences()).payload
        var sourceMismatch = payload
        sourceMismatch.occurrences[0].captureID = UUID()
        assertInvalid(sourceMismatch, .missingReference)
        var lookupMismatch = payload
        let source = lookupMismatch.occurrences[0]
        lookupMismatch.lookupEvents.append(.init(WordNoteSchemaV2.LookupEventModel(
            termID: source.termID, captureID: UUID(), occurrenceID: source.id, occurredAt: source.occurredAt
        )))
        assertInvalid(lookupMismatch, .missingReference)
        lookupMismatch.lookupEvents[0].occurrenceID = nil
        XCTAssertNoThrow(try lookupMismatch.validate())
        var missingCourse = payload
        missingCourse.courseLinks[0].courseID = UUID()
        assertInvalid(missingCourse, .missingReference)
    }

    func testV2SnapshotRejectsInvalidNewDatesAndOversizedSourceText() throws {
        var payload = try WordNoteV1ToV2Migration.convert(sourceWithOccurrences()).payload
        payload.occurrences[0].createdAt = Date(timeIntervalSince1970: .infinity)
        assertInvalid(payload, .invalidValue)
        payload.occurrences[0].createdAt = WordNoteTestFixture.referenceDate
        payload.occurrences[0].sourceTitle = String(repeating: "x", count: WordNoteSnapshotPayload.maximumTextCharacters + 1)
        assertInvalid(payload, .sizeLimit)
    }

    func testVersionedReaderRoutesV1AndV2AndRejectsUnknownVersions() throws {
        let source = try makeSource()
        let v1 = try WordNoteSnapshotCodec.encode(source, kind: .manual)
        guard case .v1(let old) = try WordNoteSnapshotReader.decode(v1) else { return XCTFail("Expected V1") }
        XCTAssertEqual(old.payload, source)
        let payload = try WordNoteV1ToV2Migration.convert(source).payload
        let v2 = try WordNoteSnapshotV2Codec.encode(payload, kind: .manual)
        guard case .v2(let new) = try WordNoteSnapshotReader.decode(v2) else { return XCTFail("Expected V2") }
        XCTAssertEqual(new.payload, payload)
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(v2)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        var document = new.document
        document.sourceSchemaVersion = "99.0.0"
        XCTAssertThrowsError(try WordNoteSnapshotReader.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        document.formatVersion = 99
        XCTAssertThrowsError(try WordNoteSnapshotReader.decode(JSONEncoder().encode(document))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedFormat)
        }
    }

    func testV2CodecRejectsDamagedChecksumWrongCountsAndMalformedDocument() throws {
        let payload = try WordNoteV1ToV2Migration.convert(sourceWithOccurrences()).payload
        let original = try WordNoteSnapshotV2Codec.decode(WordNoteSnapshotV2Codec.encode(payload, kind: .manual)).document
        var damaged = original
        damaged.payload += " "
        XCTAssertThrowsError(try WordNoteSnapshotV2Codec.decode(JSONEncoder().encode(damaged))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .checksumMismatch)
        }
        damaged = original
        damaged.counts.occurrences += 1
        XCTAssertThrowsError(try WordNoteSnapshotV2Codec.decode(JSONEncoder().encode(damaged))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .countMismatch)
        }
        XCTAssertThrowsError(try WordNoteSnapshotReader.decode(Data("{}".utf8))) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidDocument)
        }
    }

    func testRestoreRefusesV1OrNonEmptyTargetAndInvalidPayloadBeforeInserting() throws {
        let payload = try WordNoteV1ToV2Migration.convert(sourceWithOccurrences()).payload
        let v1 = try makeContainer(WordNoteSchemaV1.self)
        XCTAssertThrowsError(try payload.populateEmptyStore(v1.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        XCTAssertThrowsError(try WordNoteSnapshotV2Payload.capture(from: v1.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        let v2 = try makeContainer(WordNoteSchemaV2.self)
        var invalid = payload
        XCTAssertThrowsError(try payload.content.populateEmptyStore(v2.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        XCTAssertThrowsError(try WordNoteSnapshotPayload.capture(from: v2.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema)
        }
        invalid.courseLinks[0].courseID = UUID()
        XCTAssertThrowsError(try invalid.populateEmptyStore(v2.mainContext))
        XCTAssertEqual(try v2.mainContext.fetchCount(FetchDescriptor<WordNoteSchemaV2.TermModel>()), 0)
        try payload.populateEmptyStore(v2.mainContext)
        XCTAssertThrowsError(try payload.populateEmptyStore(v2.mainContext)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .destinationNotEmpty)
        }
        XCTAssertEqual(try WordNoteSnapshotV2Payload.capture(from: v2.mainContext), payload)
    }

    private func assertInvalid(_ payload: WordNoteSnapshotV2Payload, _ error: WordNoteSnapshotError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try payload.validate(), file: file, line: line) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, error, file: file, line: line)
        }
    }

    private func makeSource() throws -> WordNoteSnapshotPayload {
        let container = try makeContainer(WordNoteSchemaV1.self)
        try WordNoteTestFixture.populated.populate(container.mainContext)
        return try WordNoteSnapshotPayload.capture(from: container.mainContext)
    }

    private func sourceWithOccurrences() throws -> WordNoteSnapshotPayload {
        var source = try makeSource()
        source.inputRecords[0].rawText = "  An original source with two terms.\n"
        source.inputRecords[0].note = "Original note"
        source.inputRecords[0].courseID = source.courses[1].id
        source.terms[0].sourceRecordID = source.inputRecords[0].id
        source.terms[1].sourceRecordID = source.inputRecords[0].id
        return source
    }

    private func makeContainer(_ version: any VersionedSchema.Type, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: version)
        let configuration = url.map { ModelConfiguration("Fixture", schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wordnote-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertPersistentRoundTrip(_ payload: WordNoteSnapshotV2Payload, directory: URL) throws {
        let data = try WordNoteSnapshotV2Codec.encode(payload, kind: .beforeMigration)
        let decoded = try WordNoteSnapshotV2Codec.decode(data)
        XCTAssertEqual(decoded.payload, payload.canonicalized)
        let url = directory.appending(path: "isolated-v2.store")
        try autoreleasepool {
            let container = try makeContainer(WordNoteSchemaV2.self, url: url)
            try decoded.payload.populateEmptyStore(container.mainContext)
            XCTAssertEqual(try WordNoteSnapshotV2Payload.capture(from: container.mainContext, preferences: payload.content.preferences), payload.canonicalized)
        }
        let reopened = try makeContainer(WordNoteSchemaV2.self, url: url)
        XCTAssertEqual(try WordNoteSnapshotV2Payload.capture(from: reopened.mainContext, preferences: payload.content.preferences), payload.canonicalized)
    }
}
