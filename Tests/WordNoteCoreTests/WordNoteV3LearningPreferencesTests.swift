import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3LearningPreferencesTests: XCTestCase {
    private var h: V3RecoveryHarness!

    override func setUp() async throws { h = V3RecoveryHarness(directory: try V3TestSupport.directory()) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: h.directory); h = nil }

    func testFormatFiveRoundTripAndPreferenceOnlyChecksumChanges() throws {
        let payload = try portablePayload()
        let decoded = try WordNoteSnapshotReader.decode(payloadBytes(payload))
        XCTAssertEqual(decoded.payload, .v3(payload.canonicalized))
        guard case .v3(let value) = decoded else { return XCTFail("Expected V3") }
        XCTAssertEqual(value.document.formatVersion, 5)
        let checksum = try WordNoteSnapshotV3Codec.contentChecksum(payload)
        let mutations: [(inout WordNoteLearningPreferences) -> Void] = [
            { $0.defaultCourseID = nil }, { $0.defaultLookupIntent = .auto },
            { $0.reviewTargetCards = 25 }, { $0.reviewDailyNewLimit = 0 }
        ]
        for mutate in mutations {
            var changed = payload
            mutate(&changed.learningPreferences!)
            XCTAssertNotEqual(try WordNoteSnapshotV3Codec.contentChecksum(changed), checksum)
            XCTAssertEqual(changed.content, payload.content)
            XCTAssertEqual(changed.cards, payload.cards)
            XCTAssertEqual(changed.sessions, payload.sessions)
        }
    }

    func testPortablePreferencesCannotBeRelabeledAsAnOlderFormat() throws {
        let payload = try portablePayload()
        var document = try WordNoteSnapshotV3Codec.decode(payloadBytes(payload)).document
        for version in 1...4 {
            document.formatVersion = version
            let bytes = try JSONEncoder().encode(document)
            XCTAssertThrowsError(try WordNoteSnapshotReader.decode(bytes)) {
                XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedFormat)
            }
        }
        let bytes = try payloadBytes(payload)
        XCTAssertThrowsError(try WordNoteSnapshotCodec.decode(bytes))
        XCTAssertThrowsError(try WordNoteSnapshotV2Codec.decode(bytes))
    }

    func testAbsentExtensionKeepsLegacyPayloadShapeAndV1V2Bytes() throws {
        var payload = try V3TestSupport.payload()
        let id = UUID(), date = V3TestSupport.date
        let v1 = try WordNoteSnapshotCodec.encode(payload.content.content, kind: .manual, snapshotID: id, createdAt: date)
        let v2 = try WordNoteSnapshotV2Codec.encode(payload.content, kind: .manual, snapshotID: id, createdAt: date)
        var document = try WordNoteSnapshotV3Codec.decode(payloadBytes(payload)).document
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(document.payload.utf8)) as? [String: Any])
        XCTAssertNil(dictionary["learningPreferences"])
        for version in 1...4 {
            document.formatVersion = version
            XCTAssertEqual(try WordNoteSnapshotV3Codec.decode(JSONEncoder().encode(document)).payload, payload.canonicalized)
        }
        payload.learningPreferences = .init(defaultCourseID: payload.content.content.courses[0].id)
        XCTAssertEqual(try WordNoteSnapshotCodec.encode(payload.content.content, kind: .manual, snapshotID: id, createdAt: date), v1)
        XCTAssertEqual(try WordNoteSnapshotV2Codec.encode(payload.content, kind: .manual, snapshotID: id, createdAt: date), v2)
    }

    func testInvalidExtensionValuesOrMissingCourseRejectOrdinarySnapshots() throws {
        let payload = try portablePayload()
        let mutations: [(inout WordNoteLearningPreferences) -> Void] = [
            { $0.version = 2 }, { $0.defaultCourseID = UUID() },
            { $0.reviewTargetCards = 0 }, { $0.reviewDailyNewLimit = 51 }
        ]
        for mutate in mutations {
            var invalid = payload
            mutate(&invalid.learningPreferences!)
            XCTAssertThrowsError(try invalid.validate())
            XCTAssertThrowsError(try payloadBytes(invalid))
        }
    }

    func testRepairEvidencePreservesInvalidPreferencesAndRequiresFormatFive() async throws {
        var payload = try portablePayload()
        payload.learningPreferences?.defaultCourseID = UUID()
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: h.directory.appending(path: "Evidence"))
        let saved = try await vault.create(payload, generation: .init(id: UUID()))
        let reopened = try await vault.read(id: saved.summary.id)
        XCTAssertEqual(reopened.payload, payload.canonicalized)
        XCTAssertTrue(WordNoteV3IntegrityService.inspect(payload).requiresManualResolution)
        let url = await vault.fileURL(saved.summary.id)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(document["evidenceFormatVersion"] as? Int, 5)
        document["evidenceFormatVersion"] = 4
        try PrivateFileIO.write(JSONSerialization.data(withJSONObject: document), to: url)
        do { _ = try await vault.read(id: saved.summary.id); XCTFail("Must reject relabeling") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedFormat) }
    }

    func testBackgroundCaptureIncludesPreferencesAndOlderSchemasRejectThem() async throws {
        let payload = try portablePayload(), container = try V3TestSupport.container()
        try payload.populateEmptyStore(container.mainContext)
        let captured = try await WordNoteSnapshotCapture(container: container).captureVersioned(
            preferences: payload.content.content.preferences, learningPreferences: payload.learningPreferences)
        XCTAssertEqual(captured, .v3(payload.canonicalized))
        for schema in [WordNoteSchemaV1.self as any VersionedSchema.Type, WordNoteSchemaV2.self] {
            let old = try V3TestSupport.container(schema)
            do {
                _ = try await WordNoteSnapshotCapture(container: old).captureVersioned(learningPreferences: .init())
                XCTFail("Must not silently drop unsupported preferences")
            } catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        }
    }

    func testPreferenceRestoreKeepsVersionedJournalUntilAppliedAndAcknowledged() async throws {
        let source = try await h.seed(.v3(V3TestSupport.payload()))
        let payload = try portablePayload()
        let backup = try await h.protection(h.capture(source))
        let nextID = try await h.store.prepareRestore(h.snapshot(.v3(payload)), replacing: source.generation, protectedBy: backup)
        XCTAssertEqual(try h.journal()["version"] as? Int, 4)
        let next = try h.store.open()
        XCTAssertEqual(next.generation, nextID)
        XCTAssertEqual(next.learningPreferencesToApply, payload.learningPreferences)
        XCTAssertEqual(next.effectiveLearningPreferencesToApply, payload.learningPreferences)
        XCTAssertEqual(try h.capture(next), .v3(payload.canonicalized))
        XCTAssertEqual(try h.store.open().learningPreferencesToApply, payload.learningPreferences)
        let suite = "V3PreferenceRestore.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try XCTUnwrap(next.effectiveLearningPreferencesToApply).apply(to: defaults, courseIDs: Set(payload.content.content.courses.map(\.id)))
        XCTAssertEqual(try WordNoteLearningPreferences.capture(from: defaults), payload.learningPreferences)
        try h.store.acknowledgePreferences(for: nextID)
        let acknowledged = try h.store.open()
        XCTAssertNil(acknowledged.preferencesToApply)
        XCTAssertNil(acknowledged.learningPreferencesToApply)
        XCTAssertNil(acknowledged.effectiveLearningPreferencesToApply)
        XCTAssertEqual(try h.journal()["version"] as? Int, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.storeURL.path))
    }

    func testCancelledPreferenceRestoreKeepsOriginalValuesAndNewJournalCapability() async throws {
        let source = try await h.seed(.v3(V3TestSupport.payload())), before = try h.capture(source)
        let prepared = try await h.store.prepareRestore(h.snapshot(.v3(portablePayload())), replacing: source.generation,
            protectedBy: h.protection(before))
        try h.store.cancelPreparedRestore(replacing: source.generation, expectedPending: prepared)
        XCTAssertEqual(try h.capture(h.store.open()), before)
        XCTAssertEqual(try h.journal()["version"] as? Int, 4)
        for schema in [WordNoteDataSchemaVersion.v1, .v2] {
            XCTAssertThrowsError(try h.store(schema).open()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedSchema) }
        }
    }

    func testJournalDowngradeAndOrphanPreferenceApplicationAreRejected() async throws {
        let source = try await h.seed(.v3(portablePayload()))
        let valid = try h.journal()
        var changed = valid
        changed["version"] = 3
        try h.writeJournal(changed)
        XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
        changed = valid
        changed.removeValue(forKey: "preferencesToApply")
        try h.writeJournal(changed)
        XCTAssertThrowsError(try h.store.open()) { XCTAssertEqual($0 as? WordNoteRestoreError, .invalidJournal) }
        try h.writeJournal(valid)
        XCTAssertEqual(try h.store.open().generation, source.generation)
    }

    func testChangedPendingPreferenceCannotActivateAgainstOriginalChecksum() async throws {
        let source = try await h.seed(.v3(V3TestSupport.payload())), before = try h.capture(source)
        _ = try await h.store.prepareRestore(h.snapshot(.v3(portablePayload())), replacing: source.generation,
            protectedBy: h.protection(before))
        var journal = try h.journal()
        var pending = try XCTUnwrap(journal["pending"] as? [String: Any])
        var learning = try XCTUnwrap(pending["learningPreferences"] as? [String: Any])
        learning["reviewTargetCards"] = 40
        pending["learningPreferences"] = learning
        journal["pending"] = pending
        try h.writeJournal(journal)
        let result = try h.store.open()
        XCTAssertEqual(result.restoreOutcome, .rolledBack)
        XCTAssertEqual(result.generation, source.generation)
        XCTAssertEqual(try h.capture(result), before)
    }

    func testOldSnapshotsResetPortableDefaultsButNormalReopenDoesNotReapply() async throws {
        var current = try await h.seed(.v3(portablePayload()))
        let v2 = try V3TestSupport.source()
        for legacy in [WordNoteVersionedPayload.v1(v2.content), .v2(v2), .v3(try V3TestSupport.payload())] {
            let backup = try await h.protection(h.capture(current))
            _ = try await h.store.prepareRestore(h.snapshot(legacy), replacing: current.generation, protectedBy: backup)
            current = try h.store.open()
            XCTAssertNil(current.learningPreferencesToApply)
            XCTAssertEqual(current.effectiveLearningPreferencesToApply, .init())
            try h.store.acknowledgePreferences(for: current.generation)
            current = try h.store.open()
            XCTAssertNil(current.effectiveLearningPreferencesToApply)
        }
    }

    func testActivationFailureRetainsOriginalPreferenceReceipt() async throws {
        let source = try await h.seed(.v3(portablePayload())), before = try h.capture(source)
        var incoming = try portablePayload()
        incoming.learningPreferences?.reviewTargetCards = 70
        let backup = try await h.protection(before)
        _ = try await h.store.prepareRestore(h.snapshot(.v3(incoming)), replacing: source.generation, protectedBy: backup)
        let faulty = WordNoteRestoreStore(directoryURL: h.directory, targetSchema: .v3) { point in
            if point == .commitJournal { throw POSIXError(.ENOSPC) }
        }
        let restored = try faulty.open()
        XCTAssertEqual(restored.generation, source.generation)
        XCTAssertEqual(restored.restoreOutcome, .rolledBack)
        XCTAssertEqual(restored.learningPreferencesToApply, source.learningPreferencesToApply)
        XCTAssertEqual(try h.capture(restored), before)
    }

    func testNormalStartupDoesNotLockSettingsBecauseOfInvalidLocalPreferences() async throws {
        let source = try await h.seed(.v3(V3TestSupport.payload()))
        try h.store.acknowledgePreferences(for: source.generation)
        let coordinator = WordNoteStartupCoordinator(store: h.store, vault: h.vault, preferences: { self.h.preferences },
            learningPreferences: { throw WordNoteLearningPreferencesError.invalidStoredDefaults })
        let ready = try await coordinator.open()
        XCTAssertEqual(ready.generation, source.generation)
        XCTAssertEqual(coordinator.phase, .ready)
    }

    func testStartupUsesPendingRestoredValuesInsteadOfLocalDefaults() async throws {
        let payload = try portablePayload(), source = try await h.seed(.v3(payload))
        let coordinator = WordNoteStartupCoordinator(store: h.store, vault: h.vault, preferences: { .init() },
            learningPreferences: { throw WordNoteLearningPreferencesError.invalidStoredDefaults })
        let ready = try await coordinator.open()
        XCTAssertEqual(ready.generation, source.generation)
        XCTAssertEqual(ready.effectiveLearningPreferencesToApply, payload.learningPreferences)
        XCTAssertEqual(try h.capture(ready), .v3(payload.canonicalized))
    }

    private func portablePayload() throws -> WordNoteSnapshotV3Payload {
        var payload = try V3TestSupport.reviewedPayload()
        payload.learningPreferences = .init(defaultCourseID: payload.content.content.courses[0].id,
            defaultLookupIntent: .chineseToEnglish, reviewTargetCards: 35, reviewDailyNewLimit: 7)
        return payload
    }

    private func payloadBytes(_ payload: WordNoteSnapshotV3Payload) throws -> Data {
        try WordNoteSnapshotV3Codec.encode(payload, kind: .manual, createdAt: V3TestSupport.date)
    }
}
