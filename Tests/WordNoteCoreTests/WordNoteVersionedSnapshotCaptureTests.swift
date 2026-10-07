import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteVersionedSnapshotCaptureTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport

    func testBackgroundV2CaptureIncludesAllRelationsMetadataAndPreferences() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let service = try WordNoteV2ContentService(container: container)
        _ = try service.capture(.init(rawText: "quick", capturedVia: .floatingQuickAdd), at: Support.now)
        _ = try service.capture(.init(rawText: "new input"), at: Support.now)
        let preferences = WordNoteSnapshotPayload.Preferences(appearance: "dark", defaultSource: "paper")
        let expected = try WordNoteSnapshotV2Payload.capture(from: container.mainContext, preferences: preferences)
        let payload = try await WordNoteSnapshotCapture(container: container).captureVersioned(preferences: preferences)
        XCTAssertEqual(payload, .v2(expected))
        XCTAssertEqual(payload.schemaVersion, .v2)
        XCTAssertEqual(payload.counts.total, expected.counts.total)
        XCTAssertEqual(payload.preferences, preferences)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testVersionedCaptureDoesNotChangeFrozenV1Serialization() async throws {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        defer { withExtendedLifetime(container) {} }
        try WordNoteTestFixture.populated.populate(container.mainContext)
        let v1 = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        let versioned = try await WordNoteSnapshotCapture(container: container).captureVersioned()
        XCTAssertEqual(versioned, .v1(v1))
        let id = UUID()
        XCTAssertEqual(
            try versioned.encode(kind: .manual, snapshotID: id, createdAt: Support.now, appVersion: "test"),
            try WordNoteSnapshotCodec.encode(v1, kind: .manual, snapshotID: id, createdAt: Support.now, appVersion: "test")
        )
    }

    func testV2SaveDuringReadRetriesWholeEightEntitySnapshot() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let probe = VersionedCaptureProbe()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { container, preferences in
            let count = await probe.record()
            let value = try await WordNoteSnapshotCapture.readVersionedOnBackgroundExecutor(container: container, preferences: preferences)
            if count == 1 {
                try await MainActor.run {
                    let service = try WordNoteV2ContentService(container: container)
                    _ = try service.capture(.init(rawText: "quick", note: "Changed during capture"), at: Support.now)
                }
            }
            return value
        }
        let captured = try await reader.captureVersioned()
        XCTAssertEqual(captured, .v2(try Support.snapshot(container)))
        XCTAssertEqual(captured.counts.occurrences, 1)
        XCTAssertEqual(captured.counts.lookupEvents, 1)
        let calls = await probe.count
        XCTAssertEqual(calls, 2)
    }

    func testV2PendingEditsAreNeitherCommittedNorDiscardedByEitherAPI() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let term = try Support.term("quick", in: container)
        term.chineseMeaning = "Unsaved direct edit"
        let reader = WordNoteSnapshotCapture(container: container)
        do { _ = try await reader.captureVersioned(); XCTFail("V2 backup must not save around revision checks.") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        do { _ = try await reader.capture(); XCTFail("V1 reader must reject before saving.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "Unsaved direct edit")
        container.mainContext.rollback()
    }

    func testStrictV1CaptureDoesNotSaveOrDiscardPendingEdits() async throws {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        defer { withExtendedLifetime(container) {} }
        container.mainContext.autosaveEnabled = false
        try WordNoteTestFixture.populated.populate(container.mainContext)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV1.TermModel>()).first)
        term.chineseMeaning = "Unsubmitted V1 edit"
        do {
            _ = try await WordNoteSnapshotCapture(container: container).captureVersioned(requireCleanContext: true)
            XCTFail("Startup capture must not save a form edit.")
        } catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(term.chineseMeaning, "Unsubmitted V1 edit")
        container.mainContext.rollback()
    }

    func testUnsavedV2EditDuringReadStopsInsteadOfSavingItOnRetry() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let probe = VersionedCaptureProbe()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { container, preferences in
            _ = await probe.record()
            let value = try await WordNoteSnapshotCapture.readVersionedOnBackgroundExecutor(container: container, preferences: preferences)
            try await MainActor.run { try Support.term("quick", in: container).chineseMeaning = "Uncommitted during read" }
            return value
        }
        do { _ = try await reader.captureVersioned(); XCTFail("Pending edits must not become a backup transaction.") }
        catch { XCTAssertEqual(error as? WordNoteV2ContentError, .unsavedChanges) }
        let calls = await probe.count
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(container.mainContext.hasChanges)
        XCTAssertEqual(try Support.term("quick", in: container).chineseMeaning, "Uncommitted during read")
        container.mainContext.rollback()
    }

    func testV2RepeatedChangesStopAfterThreeAttempts() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let probe = VersionedCaptureProbe()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { container, preferences in
            _ = await probe.record()
            let value = try await WordNoteSnapshotCapture.readVersionedOnBackgroundExecutor(container: container, preferences: preferences)
            try await MainActor.run {
                let service = try WordNoteV2ContentService(container: container)
                _ = try service.capture(.init(rawText: "quick"), at: Support.now)
            }
            return value
        }
        do { _ = try await reader.captureVersioned(); XCTFail("No mixed snapshot may escape.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotCaptureError, .dataKeptChanging) }
        let calls = await probe.count
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(try Support.snapshot(container).lookupEvents.count, 3)
    }

    func testCancelledVersionedCaptureCannotReturnAfterIgnoringReaderCancellation() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let probe = VersionedCaptureProbe()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { container, preferences in
            let value = try await WordNoteSnapshotCapture.readVersionedOnBackgroundExecutor(container: container, preferences: preferences)
            await probe.pause()
            return value
        }
        let task = Task { try await reader.captureVersioned() }
        for _ in 0..<500 {
            if await probe.isPaused { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let paused = await probe.isPaused
        XCTAssertTrue(paused)
        task.cancel()
        await probe.release()
        do { _ = try await task.value; XCTFail("Cancelled read must not return a snapshot.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMismatchedReaderSchemaIsRejectedWithoutRetryOrMutation() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let before = try Support.snapshot(container)
        let probe = VersionedCaptureProbe()
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { _, _ in
            _ = await probe.record()
            return .v1(before.content)
        }
        do { _ = try await reader.captureVersioned(); XCTFail("A V2 container cannot produce a V1-only backup.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedSchema) }
        let calls = await probe.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Support.snapshot(container), before)
    }

    func testInvalidV2StoreCannotBeBackedUpThroughVersionedFacade() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let term = try Support.term("quick", in: container)
        term.sourceRecordID = UUID()
        try container.mainContext.save()
        let before = try WordNoteSnapshotV2Payload.captureForIntegrityInspection(from: container.mainContext)
        do { _ = try await WordNoteSnapshotCapture(container: container).captureVersioned(); XCTFail("Invalid foreign key must still fail validation.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .missingReference) }
        XCTAssertEqual(try WordNoteSnapshotV2Payload.captureForIntegrityInspection(from: container.mainContext), before)
    }

    func testFreshReadSeesLatestV2RelationshipsAndWorksWhileRestoreGateIsHeld() async throws {
        let container = try Support.container()
        defer { withExtendedLifetime(container) {} }
        let reader = WordNoteSnapshotCapture(container: container)
        let first = try await reader.captureVersioned()
        _ = try WordNoteV2ContentService(container: container).capture(.init(rawText: "quick"), at: Support.now)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        defer { try? WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket) }
        let second = try await reader.captureVersioned()
        XCTAssertEqual(first.counts.lookupEvents, 0)
        XCTAssertEqual(second.counts.lookupEvents, 1)
        XCTAssertEqual(second, .v2(try Support.snapshot(container)))
    }
}

private actor VersionedCaptureProbe {
    private(set) var count = 0
    private(set) var isPaused = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func record() -> Int { count += 1; return count }
    func pause() async {
        guard !released else { return }
        isPaused = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
