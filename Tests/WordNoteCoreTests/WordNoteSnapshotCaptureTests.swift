import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteSnapshotCaptureTests: XCTestCase {
    func testBackgroundCaptureIncludesPendingChangesAndPreferences() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        container.mainContext.insert(CourseModel(courseName: "Unsaved course"))
        let preferences = WordNoteSnapshotPayload.Preferences(appearance: "dark", defaultSource: "paper")

        let payload = try await WordNoteSnapshotCapture(container: container).capture(preferences: preferences)

        XCTAssertEqual(payload.courses.map(\.courseName), ["Unsaved course"])
        XCTAssertEqual(payload.preferences, preferences)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testSaveFromAnotherContextDiscardsStaleSnapshot() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { container, preferences in
            let count = await probe.record()
            let payload = try await WordNoteSnapshotCapture.readOnBackgroundExecutor(container: container, preferences: preferences)
            if count == 1 {
                try await MainActor.run {
                    let otherContext = ModelContext(container)
                    otherContext.insert(CourseModel(courseName: "Saved while reading"))
                    try otherContext.save()
                }
            }
            return payload
        }

        let payload = try await reader.capture()

        XCTAssertEqual(payload.courses.map(\.courseName), ["Saved while reading"])
        let calls = await probe.count
        XCTAssertEqual(calls, 2)
    }

    func testUnrelatedStoreSaveDoesNotInvalidateSnapshot() async throws {
        let container = try container()
        let unrelated = try self.container()
        defer { withExtendedLifetime((container, unrelated)) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { container, preferences in
            _ = await probe.record()
            let payload = try await WordNoteSnapshotCapture.readOnBackgroundExecutor(container: container, preferences: preferences)
            try await MainActor.run {
                unrelated.mainContext.insert(CourseModel(courseName: "Unrelated"))
                try unrelated.mainContext.save()
            }
            return payload
        }

        let payload = try await reader.capture()

        XCTAssertTrue(payload.courses.isEmpty)
        let calls = await probe.count
        XCTAssertEqual(calls, 1)
    }

    func testUnsavedEditDuringReadIsPersistedBeforeRetry() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { container, preferences in
            let count = await probe.record()
            let payload = try await WordNoteSnapshotCapture.readOnBackgroundExecutor(container: container, preferences: preferences)
            if count == 1 {
                await MainActor.run { container.mainContext.insert(CourseModel(courseName: "Concurrent edit")) }
            }
            return payload
        }

        let payload = try await reader.capture()

        XCTAssertEqual(payload.courses.map(\.courseName), ["Concurrent edit"])
        let calls = await probe.count
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testRepeatedConcurrentWritesStopAfterThreeAttempts() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { container, preferences in
            let count = await probe.record()
            let payload = try await WordNoteSnapshotCapture.readOnBackgroundExecutor(container: container, preferences: preferences)
            try await MainActor.run {
                container.mainContext.insert(CourseModel(courseName: "Change \(count)"))
                try container.mainContext.save()
            }
            return payload
        }

        do {
            _ = try await reader.capture()
            XCTFail("A repeatedly changing store must not produce a mixed snapshot.")
        } catch { XCTAssertEqual(error as? WordNoteSnapshotCaptureError, .dataKeptChanging) }
        let calls = await probe.count
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<CourseModel>()), 3)
    }

    func testValidationFailureDuringConcurrentSaveRetriesWholeRead() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { container, preferences in
            if await probe.record() == 1 {
                try await MainActor.run {
                    container.mainContext.insert(CourseModel(courseName: "After relationship update"))
                    try container.mainContext.save()
                }
                throw WordNoteSnapshotError.missingReference
            }
            return try await WordNoteSnapshotCapture.readOnBackgroundExecutor(container: container, preferences: preferences)
        }

        let payload = try await reader.capture()

        XCTAssertEqual(payload.courses.count, 1)
        let calls = await probe.count
        XCTAssertEqual(calls, 2)
    }

    func testUnchangedStoreFailureIsNotRetriedOrHidden() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { _, _ in
            _ = await probe.record()
            throw WordNoteSnapshotError.missingReference
        }

        do { _ = try await reader.capture(); XCTFail("Expected invalid snapshot.") }
        catch { XCTAssertEqual(error as? WordNoteSnapshotError, .missingReference) }
        let calls = await probe.count
        XCTAssertEqual(calls, 1)
    }

    func testCancellationIgnoringReaderCannotReturnCompletedSnapshot() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let probe = CaptureReadProbe()
        let reader = WordNoteSnapshotCapture(container: container) { container, preferences in
            let payload = try await WordNoteSnapshotCapture.readOnBackgroundExecutor(container: container, preferences: preferences)
            await probe.pause()
            return payload
        }
        let task = Task { try await reader.capture() }
        for _ in 0..<500 {
            if await probe.isPaused { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let paused = await probe.isPaused
        XCTAssertTrue(paused)
        task.cancel()
        await probe.release()
        do { _ = try await task.value; XCTFail("Cancelled read must not return data.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEachBackgroundReadUsesFreshContext() async throws {
        let container = try container()
        defer { withExtendedLifetime(container) {} }
        let course = CourseModel(courseName: "Before")
        container.mainContext.insert(course)
        try container.mainContext.save()
        let reader = WordNoteSnapshotCapture(container: container)
        let first = try await reader.capture()
        course.courseName = "After"
        try container.mainContext.save()
        let second = try await reader.capture()

        XCTAssertEqual(first.courses.map(\.courseName), ["Before"])
        XCTAssertEqual(second.courses.map(\.courseName), ["After"])
    }

    private func container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    }
}

private actor CaptureReadProbe {
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
