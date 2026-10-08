import Foundation
import Observation
import WordNoteCore

@MainActor
@Observable
final class AIConnectionTestController {
    struct Receipt: Equatable {
        let model: String
        let completedAt: Date
    }

    enum State: Equatable {
        case idle, running, cancelled
        case succeeded(Receipt)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var retryNotBefore: Date?
    @ObservationIgnored private let run: @MainActor () async throws -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attemptID: UUID?

    init(now: @escaping () -> Date = Date.init, run: @escaping @MainActor () async throws -> String) {
        self.now = now
        self.run = run
    }

    func canStart(at date: Date) -> Bool {
        state != .running && (retryNotBefore.map { date >= $0 } ?? true)
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard canStart(at: now()) else { return nil }
        let id = UUID()
        attemptID = id
        state = .running
        retryNotBefore = nil
        let pending = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard attemptID == id else { return }
                let model = try await run()
                try Task.checkCancellation()
                guard attemptID == id else { return }
                state = .succeeded(.init(model: model, completedAt: now()))
            } catch {
                guard attemptID == id else { return }
                if error is CancellationError || Task.isCancelled {
                    state = .cancelled
                } else {
                    let failure = AnalysisRetryPolicy.decide(error, retries: AnalysisRetryPolicy.maximumAutomaticRetries, at: now())
                    state = .failed(failure.summary)
                    retryNotBefore = failure.manualRetryNotBefore
                }
            }
            guard attemptID == id else { return }
            task = nil
            attemptID = nil
        }
        task = pending
        return pending
    }

    func cancel() {
        guard state == .running else { return }
        attemptID = nil
        task?.cancel()
        task = nil
        state = .cancelled
    }

    func credentialsChanged() {
        cancel()
        state = .idle
        retryNotBefore = nil
    }
}
