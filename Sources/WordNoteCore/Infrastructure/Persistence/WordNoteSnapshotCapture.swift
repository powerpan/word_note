import Foundation
import SwiftData

public enum WordNoteSnapshotCaptureError: LocalizedError, Equatable {
    case dataKeptChanging

    public var errorDescription: String? {
        "Learning data changed repeatedly during backup. Try again after the current edits finish."
    }
}

/// Application writers are MainActor-isolated. Never transfer their contexts or models to the reader.
@MainActor
public struct WordNoteSnapshotCapture {
    typealias Reader = @Sendable (ModelContainer, WordNoteSnapshotPayload.Preferences) async throws -> WordNoteSnapshotPayload
    private let container: ModelContainer
    private let reader: Reader

    public init(container: ModelContainer) {
        self.container = container
        reader = { container, preferences in
            try await Self.readOnBackgroundExecutor(container: container, preferences: preferences)
        }
    }

    init(container: ModelContainer, reader: @escaping Reader) {
        self.container = container
        self.reader = reader
    }

    public func capture(
        preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) async throws -> WordNoteSnapshotPayload {
        let changes = SnapshotSaveCounter(container: container)
        for _ in 0..<3 {
            try Task.checkCancellation()
            if container.mainContext.hasChanges { try container.mainContext.save() }
            let revision = changes.revision
            do {
                let payload = try await reader(container, preferences)
                try Task.checkCancellation()
                if changes.revision == revision, !container.mainContext.hasChanges { return payload }
            } catch {
                try Task.checkCancellation()
                // A concurrent save may temporarily invalidate cross-entity references; retry the whole read.
                if changes.revision == revision, !container.mainContext.hasChanges { throw error }
            }
        }
        throw WordNoteSnapshotCaptureError.dataKeptChanging
    }

    nonisolated static func readOnBackgroundExecutor(
        container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences
    ) async throws -> WordNoteSnapshotPayload {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let payload = try WordNoteSnapshotPayload.capture(from: context, preferences: preferences)
                try Task.checkCancellation()
                return payload
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Notifications must be counted synchronously, not queued back to MainActor after a reader completes.
private final class SnapshotSaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    var revision: UInt64 { lock.withLock { value } }

    init(container: ModelContainer) {
        observers = [ModelContext.willSave, ModelContext.didSave].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self, let context = notification.object as? ModelContext, context.container === container else { return }
                self.lock.withLock { self.value &+= 1 }
            }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
