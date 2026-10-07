import Foundation
import Observation
import SwiftData

public enum WordNoteStartupMigrationError: LocalizedError, Equatable {
    case busy
    case recoveryRequired
    case sourceChanged
    case protectionMismatch

    public var errorDescription: String? {
        switch self {
        case .busy: "Data initialization is already in progress."
        case .recoveryRequired: "Data migration did not complete. The original store is retained. Review the error before explicitly retrying."
        case .sourceChanged: "The original data changed while migration was being prepared. The original store is retained; retry from its latest state."
        case .protectionMismatch: "The migration backup does not match the original data. Migration was stopped."
        }
    }
}

/// Run before constructing views, form bindings, analysis workers, or any other store writer.
@MainActor
@Observable
public final class WordNoteV2StartupCoordinator {
    public enum Phase: Equatable { case idle, opening, backingUp, staging, activating, ready, recoveryRequired }

    public private(set) var phase = Phase.idle
    public private(set) var errorMessage: String?
    public private(set) var protectionBackup: WordNoteBackupSummary?
    public private(set) var migrationIssues: [WordNoteV1ToV2Migration.Issue] = []
    public private(set) var session: WordNoteStoreSession?

    @ObservationIgnored private let store: WordNoteRestoreStore
    @ObservationIgnored private let vault: WordNoteBackupVault
    @ObservationIgnored private let preferences: @MainActor () -> WordNoteSnapshotPayload.Preferences
    @ObservationIgnored private(set) var sourceSession: WordNoteStoreSession?

    public init(
        store: WordNoteRestoreStore, vault: WordNoteBackupVault,
        preferences: @escaping @MainActor () -> WordNoteSnapshotPayload.Preferences
    ) {
        self.store = store
        self.vault = vault
        self.preferences = preferences
    }

    @discardableResult
    public func open(retryMigration: Bool = false) async throws -> WordNoteStoreSession {
        if phase == .ready, let session { return session }
        guard phase == .idle || phase == .recoveryRequired else { throw WordNoteStartupMigrationError.busy }
        guard store.targetSchema == .v2 else { throw WordNoteSnapshotError.unsupportedSchema }
        phase = .opening
        errorMessage = nil
        protectionBackup = nil
        migrationIssues = []
        session = nil
        sourceSession = nil
        var preparedGeneration: WordNoteStoreGeneration?

        do {
            try Task.checkCancellation()
            let opened = try store.open()
            sourceSession = opened
            let frozenPreferences = opened.preferencesToApply ?? preferences()
            if opened.schemaVersion == .v2 {
                _ = try await capture(opened, preferences: frozenPreferences)
                session = opened
                sourceSession = nil
                phase = .ready
                return opened
            }
            guard retryMigration || (opened.recoveryRequired == nil && opened.restoreOutcome != .rolledBack) else {
                throw WordNoteStartupMigrationError.recoveryRequired
            }
            let context = opened.container.mainContext
            guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
            _ = try WordNoteWriteGate.beginRestore(context)
            context.autosaveEnabled = false
            // A failed backup or a process exit before staging must not trigger an automatic retry next launch.
            try store.beginMigration(replacing: opened.generation)
            let original = try await capture(opened, preferences: frozenPreferences)
            guard case .v1(let originalV1) = original else { throw WordNoteSnapshotError.unsupportedSchema }
            phase = .backingUp
            let result = try await vault.create(original, kind: .beforeMigration)
            try Task.checkCancellation()
            let verified = try await vault.readSnapshot(id: result.snapshot.id)
            guard verified.payload == originalV1, verified.document.kind == .beforeMigration else {
                throw WordNoteStartupMigrationError.protectionMismatch
            }
            protectionBackup = result.snapshot
            try await validateSource(opened, matches: original, preferences: frozenPreferences)
            phase = .staging
            let prepared = try await store.prepareMigration(verified, replacing: opened.generation)
            preparedGeneration = prepared.generation
            migrationIssues = prepared.migrationIssues
            try await validateSource(opened, matches: original, preferences: frozenPreferences)
            guard try store.preparedGeneration(for: opened.generation) == prepared.generation else {
                throw WordNoteRestoreError.staleGeneration
            }
            try Task.checkCancellation()
            phase = .activating
            let upgraded = try store.open()
            guard upgraded.schemaVersion == .v2, upgraded.generation == prepared.generation,
                  upgraded.restoreOutcome == .migrated else { throw WordNoteStartupMigrationError.recoveryRequired }
            session = upgraded
            // No source context is ever attached to UI; retained references must remain write-blocked.
            sourceSession = nil
            phase = .ready
            return upgraded
        } catch {
            if let preparedGeneration, let sourceSession {
                // Do not cancel a different operation that won a race with this startup.
                if (try? store.preparedGeneration(for: sourceSession.generation)) == preparedGeneration {
                    try? store.cancelPreparedRestore(replacing: sourceSession.generation, expectedPending: preparedGeneration)
                }
            }
            errorMessage = error.localizedDescription
            phase = .recoveryRequired
            throw error
        }
    }

    private func capture(
        _ source: WordNoteStoreSession, preferences: WordNoteSnapshotPayload.Preferences
    ) async throws -> WordNoteVersionedPayload {
        try await WordNoteSnapshotCapture(container: source.container)
            .captureVersioned(preferences: preferences, requireCleanContext: true)
    }

    private func validateSource(
        _ source: WordNoteStoreSession, matches original: WordNoteVersionedPayload,
        preferences: WordNoteSnapshotPayload.Preferences
    ) async throws {
        guard try await capture(source, preferences: preferences) == original else { throw WordNoteStartupMigrationError.sourceChanged }
    }
}
