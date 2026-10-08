import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class CaptureContextIntegrationTests: XCTestCase {
    private typealias Support = WordNoteV2ServiceTestSupport
    private var suite = ""
    private var preferences: UserDefaults!
    private var directory: URL!

    override func setUp() async throws {
        suite = "WordNote-Capture-Integration-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite)
    }

    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
        preferences = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testTwoSurfacesQueueWithoutWaitingAndAnalyzeTheirOwnFrozenContexts() async throws {
        let container = try Support.container()
        let content = try WordNoteV2ContentService(container: container)
        let courses = try Support.snapshot(container).content.courses
        let ids = Set(courses.map(\.id))
        let context = CaptureContextController(preferences: preferences, availableCourseIDs: ids)
        var sent: [AIAnalysisRequest] = []
        let queue = try makeQueue(content: content, paused: true) { request in
            sent.append(request)
            return AnalysisTestValues.result()
        }
        try context.updateDefaults(.init(courseID: courses[0].id, sourceType: .book, intent: .chineseToEnglish))
        let first = try context.request(rawText: "precision", note: "main note", capturedVia: .mainQuickAdd, availableCourseIDs: ids)
        let firstID = try Support.inputID(queue.enqueue(first))
        try context.selectCourse(courses[1].id)
        context.selectSource(.paper)
        context.selectIntent(.englishToChinese)
        let second = try context.request(rawText: "精度", capturedVia: .floatingQuickAdd, availableCourseIDs: ids)
        let secondID = try Support.inputID(queue.enqueue(second))
        context.useDefaults()
        try context.updateDefaults(.init())
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(queue.queuedCount, 2)
        XCTAssertEqual(try Support.record(firstID, in: container).courseID, courses[0].id)
        XCTAssertEqual(try Support.record(secondID, in: container).courseID, courses[1].id)
        _ = try queue.resumePendingAnalyses()
        try await waitUntil { !queue.isBusy }
        XCTAssertEqual(sent.count, 2)
        let main = try XCTUnwrap(sent.first { $0.rawText == "precision" })
        let floating = try XCTUnwrap(sent.first { $0.rawText == "精度" })
        XCTAssertEqual(main.lookupDirection, .chineseToEnglish)
        XCTAssertEqual(main.courseName, courses[0].courseName)
        XCTAssertEqual(main.sourceType, .book)
        XCTAssertEqual(main.userNote, "main note")
        XCTAssertEqual(floating.lookupDirection, .englishToChinese)
        XCTAssertEqual(floating.courseName, courses[1].courseName)
        XCTAssertEqual(floating.sourceType, .paper)
        XCTAssertNil(floating.userNote)
        XCTAssertEqual(try Support.record(firstID, in: container).capturedViaRaw, "mainQuickAdd")
        XCTAssertEqual(try Support.record(secondID, in: container).capturedViaRaw, "floatingQuickAdd")
    }

    func testManualDirectionAndContextSurviveSnapshotRoundTripAndRetry() throws {
        let container = try Support.container()
        let content = try WordNoteV2ContentService(container: container)
        let courses = try Support.snapshot(container).content.courses
        let ids = Set(courses.map(\.id))
        let context = CaptureContextController(preferences: preferences, availableCourseIDs: ids)
        try context.selectCourse(courses[0].id)
        context.selectSource(.slides)
        context.selectIntent(.chineseToEnglish)
        let request = try context.request(rawText: "precision", note: "frozen", capturedVia: .floatingQuickAdd, availableCourseIDs: ids)
        let id = try Support.inputID(content.capture(request, at: Support.now))
        let first = try content.beginAnalysis(id, expectedRevision: 0, at: Support.now)
        try content.failAnalysis(first, error: AIAnalysisError.invalidResponse, at: Support.now)
        let saved = try Support.snapshot(container)
        let decoded = try WordNoteSnapshotV2Codec.decode(WordNoteSnapshotV2Codec.encode(saved, kind: .manual)).payload
        let restored = try Support.container(populated: false)
        try decoded.populateEmptyStore(restored.mainContext)
        context.useDefaults()
        try context.updateDefaults(.init(courseID: courses[1].id, sourceType: .book, intent: .englishToChinese))
        let nextContext = CaptureContextController(preferences: preferences, availableCourseIDs: ids)
        XCTAssertEqual(nextContext.current.intent, .englishToChinese)
        let next = try WordNoteV2ContentService(container: restored)
        let record = try Support.record(id, in: restored)
        _ = try next.queueAnalysis(id, expectedRevision: record.revision, at: Support.now)
        let retry = try next.beginAnalysis(id, expectedRevision: record.revision, at: Support.now)
        XCTAssertEqual(retry.request.lookupDirection, .chineseToEnglish)
        XCTAssertEqual(retry.request.sourceType, .slides)
        XCTAssertEqual(retry.request.userNote, "frozen")
        XCTAssertEqual(retry.request.courseName, courses[0].courseName)
        XCTAssertEqual(record.captureID, request.captureID)
        XCTAssertEqual(record.lookupIntentRaw, "chineseToEnglish")
        XCTAssertEqual(record.directionDetectorVersion, "explicit-v1")
    }

    func testDraftUsesCurrentContextAndDoesNotAdoptLaterDefaultWhenAnalyzed() throws {
        let container = try Support.container()
        let content = try WordNoteV2ContentService(container: container)
        let ids = Set(try Support.snapshot(container).content.courses.map(\.id))
        let context = CaptureContextController(preferences: preferences, availableCourseIDs: ids)
        context.selectSource(.assignment)
        context.selectIntent(.englishToChinese)
        let request = try context.request(rawText: "準確度", capturedVia: .mainQuickAdd, availableCourseIDs: ids)
        let id = try Support.inputID(content.capture(request, analyze: false, at: Support.now))
        XCTAssertEqual(try Support.record(id, in: container).queueStateRaw, "none")
        context.useDefaults()
        try context.updateDefaults(.init(sourceType: .paper, intent: .chineseToEnglish))
        let queued = try content.queueAnalysis(id, expectedRevision: 0, at: Support.now)
        let attempt = try content.beginAnalysis(id, expectedRevision: queued.revision, at: Support.now)
        XCTAssertEqual(attempt.request.lookupDirection, .englishToChinese)
        XCTAssertEqual(attempt.request.sourceType, .assignment)
        XCTAssertNil(attempt.request.courseName)
    }

    func testLocalHitAddsSelectedCourseWithoutAIWhileManualChineseDirectionQueues() throws {
        let container = try Support.container()
        let content = try WordNoteV2ContentService(container: container)
        let before = try Support.snapshot(container)
        let course = before.content.courses[1]
        let ids = Set(before.content.courses.map(\.id))
        let context = CaptureContextController(preferences: preferences, availableCourseIDs: ids)
        try context.selectCourse(course.id)
        context.selectSource(.paper)
        context.selectIntent(.englishToChinese)
        var calls = 0
        let queue = try makeQueue(content: content, paused: true) { _ in calls += 1; return AnalysisTestValues.result() }
        let request = try context.request(rawText: "quick", capturedVia: .floatingQuickAdd, availableCourseIDs: ids)
        _ = try queue.enqueue(request)
        let after = try Support.snapshot(container)
        XCTAssertEqual(after.content.inputRecords.count, before.content.inputRecords.count)
        XCTAssertEqual(after.courseLinks.count, before.courseLinks.count + 1)
        XCTAssertEqual(after.occurrences.last?.courseID, course.id)
        XCTAssertEqual(after.occurrences.last?.sourceTypeRaw, "paper")
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(queue.latestAIExplanation?.candidates.first?.term, "quick")
        context.selectIntent(.chineseToEnglish)
        let explicit = try context.request(rawText: "quick", capturedVia: .mainQuickAdd, availableCourseIDs: ids)
        let id = try Support.inputID(queue.enqueue(explicit))
        XCTAssertEqual(try Support.record(id, in: container).lookupIntentRaw, "chineseToEnglish")
        XCTAssertEqual(queue.queuedCount, 1)
        XCTAssertEqual(calls, 0)
    }

    func testFailedSaveLeavesContextAndImmutableSubmissionIntactForRetry() throws {
        let container = try Support.container()
        let ids = Set(try Support.snapshot(container).content.courses.map(\.id))
        let context = CaptureContextController(preferences: preferences, availableCourseIDs: ids)
        try context.selectCourse(ids.first)
        context.selectSource(.book)
        context.selectIntent(.chineseToEnglish)
        let request = try context.request(rawText: "precision", note: "keep me", capturedVia: .mainQuickAdd, availableCourseIDs: ids)
        let selection = context.current
        let before = try Support.snapshot(container)
        let failing = try WordNoteV2ContentService(container: container, save: { _ in throw Support.Failure.save })
        XCTAssertThrowsError(try failing.capture(request, at: Support.now))
        XCTAssertEqual(context.current, selection)
        XCTAssertEqual(request.rawText, "precision")
        XCTAssertEqual(request.note, "keep me")
        XCTAssertEqual(try Support.snapshot(container), before)
        let content = try WordNoteV2ContentService(container: container)
        let id = try Support.inputID(content.capture(request, at: Support.now))
        XCTAssertEqual(try Support.record(id, in: container).captureID, request.captureID)
    }

    func testDiskReopenUsesSavedCaptureDespiteNewDefaultAndControllerInstance() async throws {
        let store = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2)
        let vault = WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"))
        let first = try await WordNoteV2StartupCoordinator(store: store, vault: vault, preferences: { .init() }).open()
        let content = try WordNoteV2ContentService(container: first.container)
        let course = try content.createCourse(courseName: "Capture Fixture")
        let context = CaptureContextController(preferences: preferences, availableCourseIDs: [course.id])
        try context.updateDefaults(.init(courseID: course.id, sourceType: .slides, intent: .chineseToEnglish))
        let request = try context.request(rawText: "precision", note: "disk fixture", capturedVia: .floatingQuickAdd, availableCourseIDs: [course.id])
        let id = try Support.inputID(content.capture(request))
        _ = try content.beginAnalysis(id, expectedRevision: 0)
        try context.updateDefaults(.init(sourceType: .book, intent: .englishToChinese))
        let reopened = try store.open()
        let restarted = CaptureContextController(preferences: preferences, availableCourseIDs: [course.id])
        XCTAssertNil(restarted.current.courseID)
        XCTAssertEqual(restarted.current.intent, .englishToChinese)
        var sent: [AIAnalysisRequest] = []
        let queue = try WordNoteV2AnalysisQueue(session: reopened, store: store) { request in
            sent.append(request)
            return AnalysisTestValues.result()
        }
        _ = try queue.recoverPendingAnalyses()
        XCTAssertTrue(queue.isSuspended)
        XCTAssertTrue(sent.isEmpty)
        _ = try queue.resumePendingAnalyses()
        try await waitUntil { !queue.isBusy }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.courseName, "Capture Fixture")
        XCTAssertEqual(sent.first?.sourceType, .slides)
        XCTAssertEqual(sent.first?.lookupDirection, .chineseToEnglish)
        XCTAssertEqual(sent.first?.userNote, "disk fixture")
        let record = try Support.record(id, in: reopened.container)
        XCTAssertEqual(record.captureID, request.captureID)
        XCTAssertEqual(record.lookupIntentRaw, "chineseToEnglish")
        XCTAssertEqual(record.capturedViaRaw, "floatingQuickAdd")
    }

    private func makeQueue(
        content: WordNoteV2ContentService, paused: Bool,
        handler: @escaping WordNoteV2AnalysisQueue.AnalysisHandler
    ) throws -> WordNoteV2AnalysisQueue {
        try WordNoteV2AnalysisQueue(
            content: content, initiallySuspended: paused, analysisHandler: handler,
            persistPause: {}, authorizeResume: {}, validateSelection: {}, now: { Support.now }
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The isolated analysis queue did not finish.")
    }
}
