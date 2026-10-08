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
    typealias VersionedReader = @Sendable (ModelContainer, WordNoteSnapshotPayload.Preferences) async throws -> WordNoteVersionedPayload
    private let container: ModelContainer
    private let reader: VersionedReader

    public init(container: ModelContainer) {
        self.container = container
        reader = { container, preferences in
            try await Self.readVersionedOnBackgroundExecutor(container: container, preferences: preferences)
        }
    }

    init(container: ModelContainer, reader: @escaping Reader) {
        self.container = container
        self.reader = { container, preferences in .v1(try await reader(container, preferences)) }
    }

    init(versionedContainer container: ModelContainer, reader: @escaping VersionedReader) {
        self.container = container
        self.reader = reader
    }

    public func capture(
        preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) async throws -> WordNoteSnapshotPayload {
        guard container.schema.version == WordNoteSchemaV1.versionIdentifier else { throw WordNoteSnapshotError.unsupportedSchema }
        guard case .v1(let payload) = try await captureVersioned(preferences: preferences) else { throw WordNoteSnapshotError.unsupportedSchema }
        return payload
    }

    public func captureVersioned(
        preferences: WordNoteSnapshotPayload.Preferences = .init(), requireCleanContext: Bool = false
    ) async throws -> WordNoteVersionedPayload {
        let schema: WordNoteDataSchemaVersion
        switch container.schema.version {
        case WordNoteSchemaV1.versionIdentifier: schema = .v1
        case WordNoteSchemaV2.versionIdentifier: schema = .v2
        case WordNoteSchemaV3.versionIdentifier: schema = .v3
        default: throw WordNoteSnapshotError.unsupportedSchema
        }
        let changes = SnapshotSaveCounter(container: container)
        for _ in 0..<3 {
            try Task.checkCancellation()
            if container.mainContext.hasChanges {
                // Versioned form drafts must not bypass their revision-checked service through a backup.
                guard schema == .v1, !requireCleanContext else { throw WordNoteV2ContentError.unsavedChanges }
                try container.mainContext.save()
            }
            let revision = changes.revision
            do {
                let payload = try await reader(container, preferences)
                try Task.checkCancellation()
                guard payload.schemaVersion == schema else { throw WordNoteSnapshotError.unsupportedSchema }
                if changes.revision == revision, !container.mainContext.hasChanges { return payload }
            } catch {
                try Task.checkCancellation()
                // A concurrent save may temporarily invalidate cross-entity references; retry the whole read.
                if changes.revision == revision, !container.mainContext.hasChanges { throw error }
            }
        }
        throw WordNoteSnapshotCaptureError.dataKeptChanging
    }

    static func captureForIntegrityInspection(
        container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences
    ) async throws -> WordNoteSnapshotV2Payload {
        guard container.schema.version == WordNoteSchemaV2.versionIdentifier else { throw WordNoteSnapshotError.unsupportedSchema }
        guard case .v2(let payload) = try await captureVersionedForIntegrityInspection(container: container, preferences: preferences) else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        return payload
    }

    static func captureVersionedForIntegrityInspection(
        container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences
    ) async throws -> WordNoteVersionedPayload {
        guard [WordNoteSchemaV2.versionIdentifier, WordNoteSchemaV3.versionIdentifier].contains(container.schema.version) else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        let reader = WordNoteSnapshotCapture(versionedContainer: container) { container, preferences in
            try await readVersionedOnBackgroundExecutor(container: container, preferences: preferences, integrityInspection: true)
        }
        return try await reader.captureVersioned(preferences: preferences, requireCleanContext: true)
    }

    nonisolated static func readOnBackgroundExecutor(
        container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences
    ) async throws -> WordNoteSnapshotPayload {
        guard container.schema.version == WordNoteSchemaV1.versionIdentifier else { throw WordNoteSnapshotError.unsupportedSchema }
        guard case .v1(let payload) = try await readVersionedOnBackgroundExecutor(container: container, preferences: preferences) else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        return payload
    }

    nonisolated static func readVersionedOnBackgroundExecutor(
        container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences, integrityInspection: Bool = false
    ) async throws -> WordNoteVersionedPayload {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                let payload: WordNoteVersionedPayload
                if integrityInspection {
                    switch container.schema.version {
                    case WordNoteSchemaV2.versionIdentifier:
                        payload = .v2(try WordNoteSnapshotV2Payload.captureForIntegrityInspection(from: context, preferences: preferences))
                    case WordNoteSchemaV3.versionIdentifier:
                        payload = .v3(try WordNoteSnapshotV3Payload.captureForIntegrityInspection(from: context, preferences: preferences))
                    default: throw WordNoteSnapshotError.unsupportedSchema
                    }
                } else {
                    payload = try WordNoteVersionedPayload.capture(from: context, preferences: preferences)
                }
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
