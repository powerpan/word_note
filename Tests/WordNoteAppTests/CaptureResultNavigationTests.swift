import XCTest
import WordNoteCore
@testable import WordNote

@MainActor
final class CaptureResultNavigationTests: XCTestCase {
    func testMostRecentlyActiveMainWindowAloneReceivesExactTarget() throws {
        let navigator = CaptureResultNavigator()
        let first = EndpointStub(), second = EndpointStub()
        navigator.register(first)
        navigator.register(second)
        navigator.activated(first.id)
        let target = CaptureResultTarget.inputRecord(UUID())
        try navigator.open(target)
        XCTAssertEqual(first.targets, [target])
        XCTAssertTrue(second.targets.isEmpty)
    }

    func testClosedWindowIsNotReused() throws {
        let navigator = CaptureResultNavigator()
        let first = EndpointStub(), closed = EndpointStub()
        navigator.register(first)
        navigator.register(closed)
        navigator.unregister(closed.id)
        let target = CaptureResultTarget.vocabulary(UUID())
        try navigator.open(target)
        XCTAssertEqual(first.targets, [target])
        XCTAssertTrue(closed.targets.isEmpty)
    }

    func testWindowEndpointsAreWeakAndNoWindowLaunchesTheMainScene() throws {
        let navigator = CaptureResultNavigator()
        weak var weakEndpoint: EndpointStub?
        do { let endpoint = EndpointStub(); weakEndpoint = endpoint; navigator.register(endpoint) }
        XCTAssertNil(weakEndpoint)
        var launches = 0
        navigator.openMainWindow = { launches += 1 }
        let target = CaptureResultTarget.vocabulary(UUID())
        try navigator.open(target)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(navigator.pending, target)
        let next = EndpointStub()
        navigator.register(next)
        XCTAssertEqual(next.targets, [target])
        XCTAssertNil(navigator.pending)
        navigator.register(next)
        XCTAssertEqual(next.targets.count, 1)
    }

    func testWindowActivationDuringPendingDeliveryDoesNotRecursivelyReplay() throws {
        let navigator = CaptureResultNavigator()
        navigator.openMainWindow = {}
        let target = CaptureResultTarget.inputRecord(UUID())
        try navigator.open(target)
        let endpoint = EndpointStub()
        endpoint.onPresent = { navigator.register(endpoint) }
        navigator.register(endpoint)
        XCTAssertEqual(endpoint.targets, [target])
        endpoint.onPresent = nil
    }

    func testPendingLaunchCannotBeReplacedByAnotherResultClick() throws {
        let navigator = CaptureResultNavigator()
        var launches = 0
        navigator.openMainWindow = { launches += 1 }
        let target = CaptureResultTarget.inputRecord(UUID())
        try navigator.open(target)
        XCTAssertThrowsError(try navigator.open(.vocabulary(UUID())))
        XCTAssertEqual(navigator.pending, target)
        XCTAssertEqual(launches, 1)
    }

    func testRestorePreventsNavigationAndCanCancelPendingLaunch() throws {
        var available = true
        let navigator = CaptureResultNavigator { available }
        navigator.openMainWindow = {}
        try navigator.open(.inputRecord(UUID()))
        available = false
        navigator.cancelPending()
        XCTAssertThrowsError(try navigator.open(.vocabulary(UUID())))
        let endpoint = EndpointStub()
        navigator.register(endpoint)
        XCTAssertTrue(endpoint.targets.isEmpty)
        XCTAssertNil(navigator.pending)
    }

    func testBusyWindowDoesNotSilentlyRouteIntoAnUnrelatedWindow() {
        let navigator = CaptureResultNavigator()
        let other = EndpointStub(), busy = EndpointStub()
        busy.accepts = false
        navigator.register(other)
        navigator.register(busy)
        XCTAssertThrowsError(try navigator.open(.inputRecord(UUID())))
        XCTAssertTrue(other.targets.isEmpty)
    }

    func testMissingMainSceneLauncherFailsExplicitly() {
        XCTAssertThrowsError(try CaptureResultNavigator().open(.inputRecord(UUID())))
    }

    func testRouteIsConsumedOnceOnlyByTheMatchingDestination() {
        let state = CaptureNavigationState()
        let id = UUID()
        state.open(.inputRecord(id))
        XCTAssertNil(state.takeVocabulary())
        XCTAssertEqual(state.takeInputRecord(), id)
        XCTAssertNil(state.takeInputRecord())
        state.open(.vocabulary(id))
        XCTAssertNil(state.takeInputRecord())
        XCTAssertEqual(state.takeVocabulary(), id)
        XCTAssertNil(state.pending)
    }

    func testRepeatedNavigationToSameTargetCreatesANewRequest() {
        let state = CaptureNavigationState()
        let target = CaptureResultTarget.vocabulary(UUID())
        state.open(target)
        let old = state.pending?.id
        state.open(target)
        XCTAssertNotEqual(state.pending?.id, old)
    }

    func testDirtyWindowNavigationWaitsForDiscardAndSheetDismissal() {
        let state = CaptureNavigationState(), protection = WordNoteEditProtection()
        var dirty = true, navigated = 0
        protection.track(id: UUID(), title: "Draft", preview: { "Uncommitted edit" }, isDirty: { dirty }, save: { dirty = false }, discard: { dirty = false })
        let id = UUID()
        XCTAssertTrue(state.request(.inputRecord(id), protection: protection) { navigated += 1 })
        XCTAssertNil(state.pending)
        XCTAssertEqual(navigated, 0)
        protection.resolve(.discard)
        XCTAssertNil(state.pending)
        protection.completeTransition()
        XCTAssertEqual(state.takeInputRecord(), id)
        XCTAssertEqual(navigated, 1)
    }

    func testCancelNavigationKeepsDraftAndDoesNotReplaceAnotherPendingTransition() {
        let state = CaptureNavigationState(), protection = WordNoteEditProtection()
        var dirty = true, navigated = 0
        protection.track(id: UUID(), title: "Draft", preview: { "Uncommitted edit" }, isDirty: { dirty }, save: { dirty = false }, discard: { dirty = false })
        XCTAssertTrue(state.request(.inputRecord(UUID()), protection: protection) { navigated += 1 })
        XCTAssertFalse(state.request(.vocabulary(UUID()), protection: protection) { navigated += 10 })
        protection.resolve(.cancel)
        protection.completeTransition()
        XCTAssertTrue(dirty)
        XCTAssertEqual(navigated, 0)
        XCTAssertNil(state.pending)
    }
}

@MainActor
private final class EndpointStub: CaptureNavigationEndpoint {
    let id = UUID()
    var targets: [CaptureResultTarget] = []
    var accepts = true
    var onPresent: (() -> Void)?
    func present(_ target: CaptureResultTarget) -> Bool {
        guard accepts else { return false }
        targets.append(target)
        onPresent?()
        return true
    }
}
