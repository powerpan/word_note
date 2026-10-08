import AppKit
import AVFAudio
import Observation
import WordNoteCore

@MainActor
protocol CaptureSpeechBackend: AnyObject {
    var didComplete: ((UUID, Bool) -> Void)? { get set }
    func speak(_ text: String, requestID: UUID) throws
    func stop()
}

enum CaptureSpeechError: LocalizedError {
    case unavailable
    var errorDescription: String? { "No installed English voice is available." }
}

@MainActor
final class SystemCaptureSpeech: CaptureSpeechBackend {
    var didComplete: ((UUID, Bool) -> Void)?
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: RequestDelegate?

    func speak(_ text: String, requestID: UUID) throws {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier.hasPrefix("com.apple.") && $0.language.lowercased().hasPrefix("en-")
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        guard let voice = voices.first(where: { $0.language == "en-US" }) ?? voices.first else {
            throw CaptureSpeechError.unavailable
        }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        let delegate = RequestDelegate(requestID: requestID) { [weak self] id, finished in self?.didComplete?(id, finished) }
        self.synthesizer = synthesizer
        self.delegate = delegate
        synthesizer.delegate = delegate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer?.delegate = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        delegate = nil
    }

    @MainActor
    private final class RequestDelegate: NSObject, AVSpeechSynthesizerDelegate {
        nonisolated let requestID: UUID
        private let didComplete: (UUID, Bool) -> Void

        init(requestID: UUID, didComplete: @escaping (UUID, Bool) -> Void) {
            self.requestID = requestID
            self.didComplete = didComplete
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { complete(true) }
        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { complete(false) }

        private nonisolated func complete(_ finished: Bool) {
            let id = requestID
            Task { @MainActor [weak self] in self?.didComplete(id, finished) }
        }
    }
}

/// Per-surface actions: no speech or clipboard access occurs when a result arrives.
@MainActor
@Observable
final class CaptureResultActions {
    private(set) var speakingRowID: String?
    private(set) var copiedRowID: String?
    private(set) var message: String?
    @ObservationIgnored private let speech: CaptureSpeechBackend
    @ObservationIgnored private let copyText: (String) -> Bool
    @ObservationIgnored private var requestID: UUID?

    init(speech: CaptureSpeechBackend = SystemCaptureSpeech(), copyText: @escaping (String) -> Bool = {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString($0, forType: .string)
    }) {
        self.speech = speech
        self.copyText = copyText
        speech.didComplete = { [weak self] id, finished in
            guard let self, requestID == id else { return }
            requestID = nil
            speakingRowID = nil
            message = finished ? nil : "Speech was interrupted."
        }
    }

    func copy(_ row: FloatingExplanationRow) {
        guard let english = row.englishText else { return }
        let copied = copyText(english)
        copiedRowID = copied ? row.id : nil
        message = copied ? nil : "Could not copy the English text."
    }

    func toggleSpeech(_ row: FloatingExplanationRow) {
        guard let english = row.englishText else { return }
        if speakingRowID == row.id { stop(); message = nil; return }
        stop()
        let id = UUID()
        requestID = id
        speakingRowID = row.id
        message = nil
        do { try speech.speak(english, requestID: id) }
        catch { stop(); message = error.localizedDescription }
    }

    func reset() {
        stop()
        copiedRowID = nil
        message = nil
    }

    func showError(_ error: Error) { message = error.localizedDescription }

    private func stop() {
        requestID = nil
        speakingRowID = nil
        speech.stop()
    }
}
