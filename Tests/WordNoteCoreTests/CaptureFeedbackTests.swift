import XCTest
@testable import WordNoteCore

@MainActor
final class CaptureFeedbackTests: XCTestCase {
    private var presentations: [CaptureResultPresentation] = []
    private var clocks: [FeedbackClock] = []

    override func tearDown() async throws {
        for presentation in presentations { presentation.setVisible(false) }
        for clock in clocks { clock.cancelAll() }
        presentations.removeAll()
        clocks.removeAll()
        await Task.yield()
    }

    func testHiddenSurfacesIgnoreEventsAndOpeningDoesNotReplay() {
        let hub = CaptureFeedbackHub()
        let (presentation, _) = make()
        hub.subscribe(presentation)
        hub.publish(event())
        XCTAssertNil(presentation.event)
        presentation.setVisible(true)
        XCTAssertNil(presentation.event)
        let next = event()
        hub.publish(next)
        XCTAssertEqual(presentation.event?.preview.id, next.preview.id)
    }

    func testHideClearsResultAndNewVisibleSessionOnlyReceivesNewPublications() {
        let hub = CaptureFeedbackHub()
        let (presentation, _) = make()
        hub.subscribe(presentation)
        presentation.setVisible(true)
        hub.publish(event())
        presentation.setVisible(false)
        XCTAssertNil(presentation.event)
        hub.publish(event())
        presentation.setVisible(true)
        XCTAssertNil(presentation.event)
        let future = event()
        hub.publish(future)
        XCTAssertEqual(presentation.event?.preview.id, future.preview.id)
    }

    func testBroadcastReachesEachShownSurfaceButNotHiddenOnes() {
        let hub = CaptureFeedbackHub()
        let (main, _) = make(.main)
        let (floating, _) = make()
        let (hidden, _) = make(.main)
        for presentation in [main, floating, hidden] { hub.subscribe(presentation) }
        main.setVisible(true)
        floating.setVisible(true)
        let value = event()
        hub.publish(value)
        XCTAssertEqual(main.event?.preview.id, value.preview.id)
        XCTAssertEqual(floating.event?.preview.id, value.preview.id)
        XCTAssertNil(hidden.event)
        hub.unsubscribe(main)
        hub.publish(event())
        XCTAssertNil(main.event)
        XCTAssertNotNil(floating.event)
    }

    func testHubDoesNotRetainAWindowPresentation() {
        let hub = CaptureFeedbackHub()
        weak var weakPresentation: CaptureResultPresentation?
        do {
            let presentation = CaptureResultPresentation(mode: .main)
            weakPresentation = presentation
            hub.subscribe(presentation)
        }
        XCTAssertNil(weakPresentation)
        hub.publish(event())
        hub.clear()
    }

    func testMainResultHasNoAutomaticCountdownAndHidesOnNavigation() async throws {
        let (presentation, clock) = make(.main)
        presentation.setVisible(true)
        presentation.receive(event())
        clock.time = 1_000
        await Task.yield()
        XCTAssertTrue(clock.waits.isEmpty)
        XCTAssertNotNil(presentation.event)
        presentation.setVisible(false)
        XCTAssertNil(presentation.event)
    }

    func testUnfocusedFloatingResultExpiresAfterTenMonotonicSeconds() async throws {
        let (presentation, clock) = make()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        XCTAssertEqual(clock.waits[0].duration, 10)
        clock.wake(0, after: 10)
        try await waitUntil { presentation.event == nil }
    }

    func testFocusedResultDoesNotStartCountdownUntilFocusLeaves() async throws {
        let (presentation, clock) = make()
        let focus = UUID()
        presentation.setVisible(true)
        presentation.setFocused(true, source: focus)
        presentation.receive(event())
        clock.time += 100
        await Task.yield()
        XCTAssertTrue(clock.waits.isEmpty)
        XCTAssertNotNil(presentation.event)
        presentation.setFocused(false, source: focus)
        try await waitUntil { clock.waits.count == 1 }
        XCTAssertEqual(clock.waits[0].duration, 10)
    }

    func testFocusPausePreservesOnlyRemainingTimeAcrossMultipleIntervals() async throws {
        let (presentation, clock) = make()
        let focus = UUID()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        clock.time += 3
        presentation.setFocused(true, source: focus)
        XCTAssertEqual(presentation.remainingTime, 7)
        clock.time += 100
        clock.wake(0)
        await Task.yield()
        XCTAssertNotNil(presentation.event)
        presentation.setFocused(false, source: focus)
        try await waitUntil { clock.waits.count == 2 }
        XCTAssertEqual(clock.waits[1].duration, 7)
        clock.time += 4
        presentation.setFocused(true, source: focus)
        XCTAssertEqual(presentation.remainingTime, 3)
        presentation.setFocused(false, source: focus)
        try await waitUntil { clock.waits.count == 3 }
        XCTAssertEqual(clock.waits[2].duration, 3)
        clock.wake(2, after: 3)
        try await waitUntil { presentation.event == nil }
    }

    func testPanelAndPopoverFocusAreIndependentOwners() async throws {
        let (presentation, clock) = make()
        let panel = UUID(), popover = UUID()
        presentation.setVisible(true)
        presentation.setFocused(true, source: panel)
        presentation.receive(event())
        presentation.setFocused(true, source: popover)
        presentation.setFocused(false, source: panel)
        await Task.yield()
        XCTAssertTrue(presentation.isFocused)
        XCTAssertTrue(clock.waits.isEmpty)
        presentation.setFocused(false, source: popover)
        try await waitUntil { clock.waits.count == 1 }
        XCTAssertFalse(presentation.isFocused)
    }

    func testDuplicateFocusNotificationsDoNotResetElapsedTime() async throws {
        let (presentation, clock) = make()
        let focus = UUID()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        clock.time += 4
        presentation.setVisible(true)
        presentation.setFocused(false, source: focus)
        clock.wake(0, after: 6)
        try await waitUntil { presentation.event == nil }
        XCTAssertEqual(clock.waits.count, 1)
    }

    func testDuplicateEventDoesNotExtendItsDisplayDeadline() async throws {
        let (presentation, clock) = make()
        let value = event()
        presentation.setVisible(true)
        presentation.receive(value)
        try await waitUntil { clock.waits.count == 1 }
        clock.time += 5
        presentation.receive(value)
        clock.wake(0, after: 5)
        try await waitUntil { presentation.event == nil }
        presentation.receive(value)
        XCTAssertNil(presentation.event)
    }

    func testReplacingResultGetsFreshTimeAndOldTimerCannotHideIt() async throws {
        let (presentation, clock) = make()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        clock.time += 8
        let replacement = event()
        presentation.receive(replacement)
        try await waitUntil { clock.waits.count == 2 }
        XCTAssertEqual(clock.waits[1].duration, 10)
        clock.wake(0, after: 2)
        await Task.yield()
        XCTAssertEqual(presentation.event?.preview.id, replacement.preview.id)
        clock.wake(1, after: 8)
        try await waitUntil { presentation.event == nil }
    }

    func testHideThenReopenIgnoresOldTimerAndStaleFocus() async throws {
        let (presentation, clock) = make()
        let oldFocus = UUID()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        presentation.setVisible(false)
        presentation.setFocused(true, source: oldFocus)
        XCTAssertFalse(presentation.isFocused)
        presentation.setVisible(true)
        let replacement = event()
        presentation.receive(replacement)
        try await waitUntil { clock.waits.count == 2 }
        clock.wake(0, after: 5)
        await Task.yield()
        XCTAssertEqual(presentation.event?.preview.id, replacement.preview.id)
        clock.wake(1, after: 5)
        try await waitUntil { presentation.event == nil }
    }

    func testEarlyTimerWakeReschedulesRemainderInsteadOfHidingEarly() async throws {
        let (presentation, clock) = make()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        clock.wake(0, after: 4)
        try await waitUntil { clock.waits.count == 2 }
        XCTAssertEqual(clock.waits[1].duration, 6)
        XCTAssertNotNil(presentation.event)
        clock.wake(1, after: 6)
        try await waitUntil { presentation.event == nil }
    }

    func testFocusArrivingAfterDeadlineDoesNotReviveExpiredResult() async throws {
        let (presentation, clock) = make()
        presentation.setVisible(true)
        presentation.receive(event())
        try await waitUntil { clock.waits.count == 1 }
        clock.time += 11
        presentation.setFocused(true, source: UUID())
        XCTAssertNil(presentation.event)
    }

    func testRestoreClearRemovesAllResultsWithoutUnsubscribingSurfaces() {
        let hub = CaptureFeedbackHub()
        let (main, _) = make(.main)
        let (floating, _) = make()
        for presentation in [main, floating] { hub.subscribe(presentation); presentation.setVisible(true) }
        hub.publish(event())
        hub.clear()
        XCTAssertNil(main.event)
        XCTAssertNil(floating.event)
        XCTAssertTrue(main.isVisible)
        let future = event()
        hub.publish(future)
        XCTAssertEqual(main.event?.preview.id, future.preview.id)
        XCTAssertEqual(floating.event?.preview.id, future.preview.id)
    }

    func testResultLifecycleCallbackRunsSynchronouslyOnlyForAcceptedChanges() {
        var changes = 0
        let presentation = CaptureResultPresentation(mode: .main, onResultChange: { changes += 1 })
        let first = event()
        presentation.receive(first)
        XCTAssertEqual(changes, 0)
        presentation.setVisible(true)
        presentation.receive(first)
        presentation.receive(first)
        XCTAssertEqual(changes, 1)
        presentation.receive(event())
        XCTAssertEqual(changes, 2)
        presentation.setVisible(false)
        XCTAssertEqual(changes, 3)
        presentation.clear()
        XCTAssertEqual(changes, 3)
    }

    private func make(_ mode: CaptureResultPresentation.Mode = .floating) -> (CaptureResultPresentation, FeedbackClock) {
        let clock = FeedbackClock()
        let presentation = CaptureResultPresentation(mode: mode, now: { clock.time }, sleep: clock.sleep)
        clocks.append(clock)
        presentations.append(presentation)
        return (presentation, clock)
    }

    private func event() -> CaptureFeedbackEvent {
        .init(preview: .init(rawText: "precision", sentenceMeaning: nil, candidates: []),
              direction: .englishToChinese, target: .inputRecord(UUID()), captureID: UUID(), capturedVia: .floatingQuickAdd)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw WaitError.timeout
    }

    private enum WaitError: Error { case timeout }
}

@MainActor
private final class FeedbackClock {
    struct Wait {
        let duration: TimeInterval
        var continuation: CheckedContinuation<Void, Error>?
    }
    var time: TimeInterval = 100
    var waits: [Wait] = []

    func sleep(_ duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { waits.append(Wait(duration: duration, continuation: $0)) }
    }

    func wake(_ index: Int, after elapsed: TimeInterval = 0) {
        time += elapsed
        let continuation = waits[index].continuation
        waits[index].continuation = nil
        continuation?.resume()
    }

    func cancelAll() {
        for index in waits.indices {
            let continuation = waits[index].continuation
            waits[index].continuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }
}
