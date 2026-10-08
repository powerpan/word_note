import XCTest
import WordNoteCore
@testable import WordNote

@MainActor
final class CaptureResultActionsTests: XCTestCase {
    func testReceivingAResultDoesNotSpeakOrTouchTheClipboard() {
        let backend = SpeechStub()
        var copies: [String] = []
        let actions = CaptureResultActions(speech: backend, copyText: { copies.append($0); return true })
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(actions.speakingRowID)
    }

    func testChineseLookupCopiesEnglishAnswerNotOriginalChineseOrMeaning() throws {
        let backend = SpeechStub()
        var copies: [String] = []
        let actions = CaptureResultActions(speech: backend, copyText: { copies.append($0); return true })
        let row = try chineseRow()
        actions.copy(row)
        XCTAssertEqual(copies, ["overfitting"])
        XCTAssertEqual(actions.copiedRowID, row.id)
        XCTAssertTrue(backend.requests.isEmpty)
        XCTAssertNil(actions.message)
    }

    func testCopyFailureHasVisibleStateAndDoesNotClaimSuccess() throws {
        let actions = CaptureResultActions(speech: SpeechStub(), copyText: { _ in false })
        actions.copy(try chineseRow())
        XCTAssertNil(actions.copiedRowID)
        XCTAssertNotNil(actions.message)
    }

    func testChineseOnlyPlaceholderCannotBeCopiedOrSpoken() throws {
        let backend = SpeechStub()
        var copies = 0
        let actions = CaptureResultActions(speech: backend, copyText: { _ in copies += 1; return true })
        let row = try XCTUnwrap(AIExplanationPreview(rawText: "未知", sentenceMeaning: nil, candidates: []).floatingRows.first)
        actions.copy(row)
        actions.toggleSpeech(row)
        XCTAssertEqual(copies, 0)
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testEnglishSentenceIsCopiedAndSpokenInFull() throws {
        let backend = SpeechStub()
        var copied: String?
        let actions = CaptureResultActions(speech: backend, copyText: { copied = $0; return true })
        let row = try sentenceRow("A quick response improves throughput.")
        actions.copy(row)
        actions.toggleSpeech(row)
        XCTAssertEqual(copied, row.source)
        XCTAssertEqual(backend.requests.map(\.text), [row.source])
        XCTAssertEqual(actions.speakingRowID, row.id)
        actions.reset()
    }

    func testClickingSpeakingRowStopsWithoutEnqueueingAgain() throws {
        let backend = SpeechStub()
        let actions = CaptureResultActions(speech: backend)
        let row = try chineseRow()
        actions.toggleSpeech(row)
        let stopsBefore = backend.stops
        actions.toggleSpeech(row)
        XCTAssertNil(actions.speakingRowID)
        XCTAssertEqual(backend.requests.count, 1)
        XCTAssertEqual(backend.stops, stopsBefore + 1)
    }

    func testSwitchingRowsStopsPreviousAndIgnoresItsLateCompletion() throws {
        let backend = SpeechStub()
        let actions = CaptureResultActions(speech: backend)
        actions.toggleSpeech(try chineseRow())
        let old = try XCTUnwrap(backend.requests.first).id
        let next = try sentenceRow("Use the next value.")
        actions.toggleSpeech(next)
        backend.didComplete?(old, false)
        XCTAssertEqual(actions.speakingRowID, next.id)
        XCTAssertNil(actions.message)
        backend.didComplete?(try XCTUnwrap(backend.requests.last).id, true)
        XCTAssertNil(actions.speakingRowID)
        XCTAssertNil(actions.message)
    }

    func testReplacementOrHideResetsActionsAndLateSpeechCannotRestoreThem() throws {
        let backend = SpeechStub()
        let actions = CaptureResultActions(speech: backend, copyText: { _ in true })
        let row = try chineseRow()
        actions.copy(row)
        actions.toggleSpeech(row)
        let id = try XCTUnwrap(backend.requests.first).id
        actions.reset()
        backend.didComplete?(id, false)
        XCTAssertNil(actions.copiedRowID)
        XCTAssertNil(actions.speakingRowID)
        XCTAssertNil(actions.message)
    }

    func testUnavailableVoiceDoesNotLeaveAFalsePlayingState() throws {
        let backend = SpeechStub()
        backend.failure = CaptureSpeechError.unavailable
        let actions = CaptureResultActions(speech: backend)
        actions.toggleSpeech(try chineseRow())
        XCTAssertNil(actions.speakingRowID)
        XCTAssertEqual(actions.message, CaptureSpeechError.unavailable.localizedDescription)
    }

    func testInterruptedSpeechHasVisibleStatus() throws {
        let backend = SpeechStub()
        let actions = CaptureResultActions(speech: backend)
        actions.toggleSpeech(try chineseRow())
        backend.didComplete?(try XCTUnwrap(backend.requests.first).id, false)
        XCTAssertNil(actions.speakingRowID)
        XCTAssertNotNil(actions.message)
    }

    func testBackendCompletionDoesNotRetainTheActionController() {
        let backend = SpeechStub()
        weak var weakActions: CaptureResultActions?
        do { let actions = CaptureResultActions(speech: backend); weakActions = actions }
        XCTAssertNil(weakActions)
        backend.didComplete?(UUID(), true)
    }

    func testHiddenResultStopsSpeechSynchronouslyWithoutAViewRedraw() throws {
        let backend = SpeechStub()
        let actions = CaptureResultActions(speech: backend)
        let presentation = CaptureResultPresentation(mode: .main, onResultChange: actions.reset)
        presentation.setVisible(true)
        presentation.receive(.init(preview: .init(rawText: "quick", sentenceMeaning: nil, candidates: []),
                                   direction: .englishToChinese, target: .vocabulary(UUID()),
                                   captureID: UUID(), capturedVia: .floatingQuickAdd))
        actions.toggleSpeech(try chineseRow())
        let stops = backend.stops
        XCTAssertNotNil(actions.speakingRowID)
        presentation.setVisible(false)
        XCTAssertNil(actions.speakingRowID)
        XCTAssertEqual(backend.stops, stops + 1)
    }

    private func chineseRow() throws -> FloatingExplanationRow {
        try XCTUnwrap(AIExplanationPreview(rawText: "過擬合", sentenceMeaning: nil, candidates: [
            .init(id: "test", term: "overfitting", importance: .high, chineseMeaning: "過擬合", englishDefinition: nil)
        ]).floatingRows.first)
    }

    private func sentenceRow(_ text: String) throws -> FloatingExplanationRow {
        try XCTUnwrap(AIExplanationPreview(rawText: text, sentenceMeaning: "完整句意", candidates: []).floatingRows.first)
    }
}

@MainActor
private final class SpeechStub: CaptureSpeechBackend {
    struct Request { let id: UUID; let text: String }
    var didComplete: ((UUID, Bool) -> Void)?
    var requests: [Request] = []
    var stops = 0
    var failure: Error?
    func speak(_ text: String, requestID: UUID) throws {
        if let failure { throw failure }
        requests.append(.init(id: requestID, text: text))
    }
    func stop() { stops += 1 }
}
