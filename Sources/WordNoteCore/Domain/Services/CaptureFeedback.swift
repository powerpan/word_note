import Foundation
import Observation

public enum CaptureResultTarget: Equatable, Sendable {
    case inputRecord(UUID)
    case vocabulary(UUID)
}

public struct CaptureFeedbackEvent: Sendable {
    public let preview: AIExplanationPreview
    public let direction: LookupDirection
    public let target: CaptureResultTarget
    public let captureID: UUID
    public let capturedVia: CaptureSurface

    public init(
        preview: AIExplanationPreview, direction: LookupDirection, target: CaptureResultTarget,
        captureID: UUID, capturedVia: CaptureSurface
    ) {
        self.preview = preview
        self.direction = direction
        self.target = target
        self.captureID = captureID
        self.capturedVia = capturedVia
    }

    public var rows: [FloatingExplanationRow] { preview.floatingRows(direction: direction) }
}

/// Live delivery only. A newly opened capture surface never reads a cached result.
@MainActor
public final class CaptureFeedbackHub {
    private struct WeakPresentation { weak var value: CaptureResultPresentation? }
    private var presentations: [UUID: WeakPresentation] = [:]

    public init() {}

    public func subscribe(_ presentation: CaptureResultPresentation) {
        prune()
        presentations[presentation.id] = WeakPresentation(value: presentation)
    }

    public func unsubscribe(_ presentation: CaptureResultPresentation) {
        presentations.removeValue(forKey: presentation.id)
        presentation.setVisible(false)
    }

    public func publish(_ event: CaptureFeedbackEvent) {
        prune()
        for presentation in presentations.values { presentation.value?.receive(event) }
    }

    public func clear() {
        prune()
        for presentation in presentations.values { presentation.value?.clear() }
    }

    private func prune() { presentations = presentations.filter { $0.value.value != nil } }
}

@MainActor
@Observable
public final class CaptureResultPresentation {
    public enum Mode { case main, floating }
    public let id = UUID()
    public private(set) var event: CaptureFeedbackEvent?
    public private(set) var isVisible = false
    public private(set) var isFocused = false
    public private(set) var remainingTime: TimeInterval = 10
    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private let now: @MainActor () -> TimeInterval
    @ObservationIgnored private let sleep: @MainActor (TimeInterval) async throws -> Void
    @ObservationIgnored private let onResultChange: @MainActor () -> Void
    @ObservationIgnored private var focusSources = Set<UUID>()
    @ObservationIgnored private var lastEventID: UUID?
    @ObservationIgnored private var countdownStartedAt: TimeInterval?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var timerToken = UUID()

    public init(
        mode: Mode,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        onResultChange: @escaping @MainActor () -> Void = {}
    ) {
        self.mode = mode
        self.now = now
        self.sleep = sleep
        self.onResultChange = onResultChange
    }

    deinit { timer?.cancel() }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if !visible {
            focusSources.removeAll()
            isFocused = false
            clear()
        }
    }

    /// A panel and its popover can both own focus; ending one must not resume the other.
    public func setFocused(_ focused: Bool, source: UUID) {
        if focused, isVisible { focusSources.insert(source) } else { focusSources.remove(source) }
        let next = !focusSources.isEmpty
        guard next != isFocused else { return }
        isFocused = next
        if next { pauseCountdown() } else { startCountdown() }
    }

    public func receive(_ value: CaptureFeedbackEvent) {
        guard isVisible, value.preview.id != lastEventID else { return }
        onResultChange()
        invalidateTimer()
        lastEventID = value.preview.id
        event = value
        remainingTime = 10
        startCountdown()
    }

    public func clear() {
        if event != nil { onResultChange() }
        invalidateTimer()
        event = nil
        remainingTime = 10
    }

    private func pauseCountdown() {
        if let started = countdownStartedAt { remainingTime = max(0, remainingTime - max(0, now() - started)) }
        invalidateTimer()
        if remainingTime <= 0 { clear() }
    }

    private func startCountdown() {
        guard mode == .floating, isVisible, !isFocused, event != nil, timer == nil else { return }
        guard remainingTime > 0 else { clear(); return }
        let token = UUID()
        timerToken = token
        countdownStartedAt = now()
        let delay = remainingTime
        let sleep = sleep
        timer = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.countdownFinished(token: token)
        }
    }

    private func countdownFinished(token: UUID) {
        guard token == timerToken, isVisible, !isFocused, let started = countdownStartedAt else { return }
        remainingTime = max(0, remainingTime - max(0, now() - started))
        invalidateTimer()
        if remainingTime <= 0 { clear() } else { startCountdown() }
    }

    private func invalidateTimer() {
        timer?.cancel()
        timer = nil
        countdownStartedAt = nil
        timerToken = UUID()
    }
}
