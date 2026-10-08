import SwiftData
import XCTest
import WordNoteCore
@testable import WordNote

@MainActor
final class V3ReviewControllerTests: XCTestCase {
    private let now = Date()

    func testLoadDoesNotCreateOrPresentAGroup() throws {
        let container = try fixture()
        let controller = try V3ReviewController(container: container)
        controller.load(at: now)
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.front)
        XCTAssertTrue(try snapshot(container).sessions.isEmpty)
        XCTAssertNil(try snapshot(container).cards.first?.schedule.introducedAt)
    }

    func testStartRequiresAnActiveAvailableWindow() throws {
        let container = try fixture()
        let controller = try V3ReviewController(container: container)
        controller.start(scope: scope, target: 5, newLimit: 10, at: now)
        XCTAssertNil(controller.session)
        controller.setWindowActive(true)
        controller.setAvailable(false)
        controller.start(scope: scope, target: 5, newLimit: 10, at: now)
        XCTAssertTrue(try snapshot(container).sessions.isEmpty)
    }

    func testNewCardsRequireExplicitOptIn() throws {
        let container = try fixture()
        let controller = try V3ReviewController(container: container)
        controller.setWindowActive(true)
        var value = scope
        value.includesNewCards = false
        controller.start(scope: value, target: 5, newLimit: 10, at: now)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertTrue(try snapshot(container).sessions.isEmpty)
        controller.start(scope: scope, target: 5, newLimit: 10, at: now)
        XCTAssertNotNil(controller.front)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.back)
    }

    func testAnswerCannotBypassRevealAndDoubleClickCannotScoreNextCard() throws {
        let container = try fixture(count: 2)
        let controller = try started(container)
        controller.answer(.good, at: now)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
        controller.reveal(at: now)
        XCTAssertTrue(controller.canAnswer)
        XCTAssertEqual(controller.delay(for: .again), "10 min")
        controller.answer(.good, at: now)
        controller.answer(.good, at: now)
        XCTAssertEqual(try snapshot(container).eventStates.count, 1)
        XCTAssertNotNil(controller.front)
        XCTAssertNil(controller.back)
        XCTAssertEqual(controller.statistics?.reviewed, 1)
        XCTAssertEqual(controller.statistics?.answers.answerCount, 1)
    }

    func testFocusLossHidesAnswerAndReleasesOwnershipWithoutRebuilding() throws {
        let container = try fixture()
        let first = try started(container)
        first.reveal(at: now)
        let before = try snapshot(container)
        first.setWindowActive(false)
        XCTAssertNil(first.front)
        XCTAssertNil(first.back)
        XCTAssertFalse(first.ownsSession)
        let second = try V3ReviewController(container: container)
        second.setWindowActive(true)
        second.resume(at: now)
        XCTAssertNil(second.errorMessage)
        XCTAssertNil(second.back)
        XCTAssertEqual(second.session?.session.id, before.sessions.first?.id)
        XCTAssertEqual(try snapshot(container).sessionItems, before.sessionItems)
        XCTAssertEqual(try snapshot(container).cards, before.cards)
    }

    func testSecondWindowCannotStealActiveAnsweringLease() throws {
        let container = try fixture()
        let first = try started(container)
        first.reveal(at: now)
        let second = try V3ReviewController(container: container)
        second.setWindowActive(true)
        second.resume(at: now)
        XCTAssertNotNil(second.errorMessage)
        XCTAssertFalse(second.ownsSession)
        XCTAssertNil(second.front)
        first.answer(.good, at: now)
        XCTAssertEqual(try snapshot(container).eventStates.count, 1)
    }

    func testReturnAndTypingKeysAreNeverCaptured() throws {
        let container = try fixture()
        let controller = try started(container)
        XCTAssertFalse(controller.handleKey("\r", isRepeat: false, hasModifiers: false, isTextEditing: false))
        XCTAssertFalse(controller.handleKey(" ", isRepeat: false, hasModifiers: false, isTextEditing: true))
        XCTAssertFalse(controller.handleKey(" ", isRepeat: true, hasModifiers: false, isTextEditing: false))
        XCTAssertFalse(controller.handleKey(" ", isRepeat: false, hasModifiers: true, isTextEditing: false))
        XCTAssertNil(controller.back)
        XCTAssertTrue(controller.handleKey(" ", isRepeat: false, hasModifiers: false, isTextEditing: false))
        XCTAssertFalse(controller.handleKey("3", isRepeat: false, hasModifiers: false, isTextEditing: true))
        XCTAssertFalse(controller.handleKey("3", isRepeat: true, hasModifiers: false, isTextEditing: false))
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
        XCTAssertTrue(controller.handleKey("3", isRepeat: false, hasModifiers: false, isTextEditing: false))
        XCTAssertEqual(try snapshot(container).eventStates.count, 1)
    }

    func testPauseAndResumeDoNotCreateASecondGroupOrNewIntroduction() throws {
        let container = try fixture()
        let controller = try started(container)
        let before = try snapshot(container)
        controller.reveal(at: now)
        controller.pause(at: now)
        XCTAssertEqual(controller.session?.session.status, .paused)
        XCTAssertNil(controller.back)
        XCTAssertFalse(controller.ownsSession)
        controller.resume(at: now)
        XCTAssertNotNil(controller.front)
        XCTAssertNil(controller.back)
        XCTAssertEqual(try snapshot(container).sessions.count, 1)
        XCTAssertEqual(try snapshot(container).sessions.first?.introductions, before.sessions.first?.introductions)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
    }

    func testEndKeepsUnansweredCardsOutOfCompletionCounts() throws {
        let container = try fixture(count: 2)
        let controller = try started(container)
        controller.end(at: now)
        XCTAssertEqual(controller.session?.session.status, .ended)
        XCTAssertEqual(controller.statistics?.processedItems, 0)
        XCTAssertEqual(controller.statistics?.reviewed, 0)
        XCTAssertEqual(controller.statistics?.remaining, 2)
        XCTAssertFalse(controller.ownsSession)
        controller.showSetup()
        XCTAssertNil(controller.session)
        XCTAssertNil(controller.statistics)
    }

    func testSkipRoundPausesWithoutAReviewEvent() throws {
        let container = try fixture(count: 2)
        let controller = try started(container)
        let firstID = controller.front?.cardID
        controller.skip(at: now)
        XCTAssertNotEqual(controller.front?.cardID, firstID)
        controller.skip(at: now)
        XCTAssertEqual(controller.session?.session.status, .paused)
        XCTAssertEqual(controller.statistics?.processedItems, 0)
        XCTAssertNil(controller.front)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
        controller.resume(at: now)
        XCTAssertEqual(controller.front?.cardID, firstID)
    }

    func testConfirmedEndWorksWhileItsSheetHasTakenFocus() throws {
        let container = try fixture()
        let controller = try started(container)
        controller.setWindowActive(false)
        controller.end(at: now)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.session?.session.status, .ended)
        XCTAssertEqual(controller.statistics?.reviewed, 0)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
    }

    func testConfirmedEndCannotStealAnotherWindowsLease() throws {
        let container = try fixture()
        let first = try started(container)
        first.setWindowActive(false)
        let second = try V3ReviewController(container: container)
        second.setWindowActive(true)
        second.resume(at: now)
        first.end(at: now)
        XCTAssertNotNil(first.errorMessage)
        XCTAssertEqual(first.session?.session.status, .active)
        second.reveal(at: now)
        second.answer(.good, at: now)
        XCTAssertEqual(try snapshot(container).eventStates.count, 1)
    }

    func testLaterIsClassifiedSeparatelyFromSuccessfulReview() throws {
        let container = try fixture()
        let controller = try started(container)
        controller.later(at: now)
        XCTAssertEqual(controller.session?.session.status, .completed)
        XCTAssertEqual(controller.statistics?.manualLater, 1)
        XCTAssertEqual(controller.statistics?.reviewed, 0)
        XCTAssertEqual(controller.statistics?.processedItems, 1)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
    }

    func testAgainWaitsAndTimerOnlyPresentsWhenDue() throws {
        let container = try fixture()
        let controller = try started(container)
        controller.reveal(at: now)
        controller.answer(.again, at: now)
        XCTAssertEqual(controller.session?.session.status, .waiting)
        XCTAssertEqual(controller.statistics?.waiting, 1)
        XCTAssertNil(controller.front)
        controller.tick(at: now.addingTimeInterval(599))
        XCTAssertNil(controller.front)
        controller.tick(at: now.addingTimeInterval(600))
        XCTAssertNotNil(controller.front)
        XCTAssertNil(controller.back)
        XCTAssertEqual(try snapshot(container).eventStates.count, 1)
    }

    func testRestoreAvailabilityClearsEphemeralAnswerAndStopsWrites() throws {
        let container = try fixture()
        let controller = try started(container)
        controller.reveal(at: now)
        controller.setAvailable(false)
        let before = try snapshot(container)
        controller.answer(.easy, at: now)
        controller.resume(at: now)
        controller.end(at: now)
        XCTAssertNil(controller.front)
        XCTAssertNil(controller.back)
        XCTAssertEqual(try snapshot(container), before)
        controller.setAvailable(true)
        controller.resume(at: now)
        XCTAssertNotNil(controller.front)
        XCTAssertNil(controller.back)
    }

    func testExternalDeletionCannotScoreStaleAnswer() throws {
        let container = try fixture()
        let controller = try started(container)
        controller.reveal(at: now)
        let card = try XCTUnwrap(snapshot(container).cards.first)
        try WordNoteV3ContentService(container: container).deleteReviewCard(card.id, expectedRevision: card.revision, at: now)
        controller.answer(.good, at: now)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.back)
        XCTAssertFalse(controller.canAnswer)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
    }

    func testChineseQuestionHasNoHeadwordAndTypedMatchDoesNotAutoGrade() throws {
        let container = try fixture()
        let term = try XCTUnwrap(snapshot(container).content.content.terms.first)
        let state = try XCTUnwrap(snapshot(container).content.termStates.first)
        _ = try WordNoteV3ContentService(container: container).enableReviewDirection(termID: term.id,
            expectedTermRevision: state.revision, mode: .chineseToEnglish, studyTimeZoneID: "Asia/Hong_Kong", at: now)
        let controller = try V3ReviewController(container: container)
        controller.setWindowActive(true)
        var value = scope
        value.mode = .chineseToEnglish
        controller.start(scope: value, target: 5, newLimit: 10, at: now)
        XCTAssertFalse(try XCTUnwrap(controller.front).prompt.contains(term.term))
        controller.typedAnswer = term.term
        controller.reveal(at: now)
        XCTAssertEqual(controller.back?.assessment, .matchesSavedAnswer)
        XCTAssertEqual(controller.back?.typedAnswer, term.term)
        XCTAssertTrue(try snapshot(container).eventStates.isEmpty)
        controller.answer(.hard, at: now)
        XCTAssertEqual(try snapshot(container).content.content.reviewEvents.first?.feedbackRaw, ReviewFeedback.hard.rawValue)
    }

    private var scope: ReviewSessionScopeSnapshot {
        .init(includesNewCards: true, studyTimeZoneID: "Asia/Hong_Kong")
    }

    private func started(_ container: ModelContainer) throws -> V3ReviewController {
        let controller = try V3ReviewController(container: container)
        controller.setWindowActive(true)
        controller.start(scope: scope, target: 5, newLimit: 10, at: now)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.front)
        return controller
    }

    private func fixture(count: Int = 1) throws -> ModelContainer {
        let schema = Schema(versionedSchema: WordNoteSchemaV3.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        container.mainContext.autosaveEnabled = false
        let content = try WordNoteV3ContentService(container: container)
        for name in ["vector", "matrix"].prefix(count) {
            let result = try content.capture(.init(rawText: "A \(name) represents data.", sourceType: .other), analyze: false, at: now)
            guard case .inputRecord(let id, _) = result.destination else { throw WordNoteSnapshotError.invalidValue }
            _ = try content.createManualTerm(sourceRecordID: id, expectedRecordRevision: 0, termText: name,
                chineseMeaning: "\(name)：向量或矩陣", englishDefinition: "A mathematical representation.", at: now)
        }
        return container
    }

    private func snapshot(_ container: ModelContainer) throws -> WordNoteSnapshotV3Payload {
        try .capture(from: container.mainContext)
    }
}
