import Foundation
import SwiftData

public struct WordNoteStoreGeneration: Codable, Equatable, Sendable {
    public let id: UUID?
    public static let legacy = WordNoteStoreGeneration(id: nil)
}

public enum WordNoteRestoreOutcome: String, Codable, Sendable {
    case none
    case restored
    case rolledBack
}

public enum WordNoteRestoreError: LocalizedError, Equatable {
    case invalidJournal
    case staleGeneration
    case restoreAlreadyPending
    case protectionRequired
    case missingStore
    case stagingMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidJournal: "The restore journal is invalid. Existing stores have not been replaced."
        case .staleGeneration: "The active data store changed. Reopen Word Note before trying again."
        case .restoreAlreadyPending: "A restore is already waiting for Word Note to restart."
        case .protectionRequired: "A verified pre-restore backup is required."
        case .missingStore: "The selected data store is missing. Existing stores have not been replaced."
        case .stagingMismatch: "The staged restore does not match the backup. The previous store is retained."
        }
    }
}

@MainActor
public struct WordNoteStoreSession {
    public let container: ModelContainer
    public let schemaVersion: WordNoteDataSchemaVersion
    public let generation: WordNoteStoreGeneration
    public let storeURL: URL
    public let restoreOutcome: WordNoteRestoreOutcome
    public let analysisRequiresResume: Bool
    public let preferencesToApply: WordNoteSnapshotPayload.Preferences?
}

/// The sole owner of generation selection. No opened SQLite store is renamed or replaced.
@MainActor
public struct WordNoteRestoreStore {
    public enum Checkpoint: Sendable {
        case stagingSaved
        case prepareJournal
        case activateJournal
        case commitJournal
        case rollbackJournal
    }

    public let directoryURL: URL
    public let targetSchema: WordNoteDataSchemaVersion
    private let fault: (@Sendable (Checkpoint) throws -> Void)?
    private typealias Manifest = WordNoteStoreManifest

    public init(
        directoryURL: URL, targetSchema: WordNoteDataSchemaVersion = .v1,
        fault: (@Sendable (Checkpoint) throws -> Void)? = nil
    ) {
        self.directoryURL = directoryURL
        self.targetSchema = targetSchema
        self.fault = fault
    }

    public func open() throws -> WordNoteStoreSession {
        var manifest = try readManifest()
        guard var pending = manifest.pending else {
            return try session(manifest, outcome: .none)
        }
        if pending.phase == .activating {
            // A prior launch stopped before commit. Never retry an uncertain activation automatically.
            manifest.pending = nil
            try fault?(.rollbackJournal)
            try writeManifest(manifest)
            return try session(manifest, outcome: .rolledBack, requireExisting: true)
        }

        do {
            pending.phase = .activating
            manifest.pending = pending
            try fault?(.activateJournal)
            try writeManifest(manifest)
            let url = try storeURL(for: pending.generation)
            let container = try Self.makeContainer(at: url, schemaVersion: pending.schema, requireExisting: true)
            let payload = try WordNoteVersionedPayload.capture(from: container.mainContext, preferences: pending.preferences)
            guard payload.counts == pending.counts,
                  try payload.contentChecksum() == pending.payloadChecksum else {
                throw WordNoteRestoreError.stagingMismatch
            }
            manifest.previous = manifest.active
            manifest.previousSchemaVersion = manifest.activeSchemaVersion
            manifest.active = pending.generation
            manifest.activeSchemaVersion = pending.schemaVersion
            manifest.pending = nil
            manifest.analysisRequiresResume = pending.analysisRequiresResume
            manifest.preferencesToApply = pending.preferences
            try fault?(.commitJournal)
            try writeManifest(manifest)
            return WordNoteStoreSession(
                container: container, schemaVersion: manifest.activeSchema,
                generation: manifest.active, storeURL: url, restoreOutcome: .restored,
                analysisRequiresResume: manifest.analysisRequiresResume, preferencesToApply: manifest.preferencesToApply
            )
        } catch {
            // Reload the durable old selection, not the possibly modified in-memory commit attempt.
            var old = try readManifest()
            if old.pending == nil, old.active == pending.generation {
                // Commit reached disk but its final directory sync failed: do not silently undo it.
                throw error
            }
            old.pending = nil
            try fault?(.rollbackJournal)
            try writeManifest(old)
            return try session(old, outcome: .rolledBack, requireExisting: true)
        }
    }

    @discardableResult
    /// The app coordinator must hold its write barrier and pass a fresh, verified pre-restore backup.
    public func prepareRestore(
        _ snapshot: DecodedWordNoteSnapshot,
        replacing expectedGeneration: WordNoteStoreGeneration,
        protectedBy backup: WordNoteBackupSummary
    ) async throws -> WordNoteStoreGeneration {
        try await prepareRestore(.v1(snapshot), replacing: expectedGeneration, protectedBy: backup)
    }

    @discardableResult
    public func prepareRestore(
        _ snapshot: VersionedWordNoteSnapshot,
        replacing expectedGeneration: WordNoteStoreGeneration,
        protectedBy backup: WordNoteBackupSummary
    ) async throws -> WordNoteStoreGeneration {
        if targetSchema == .v1, snapshot.payload.schemaVersion == .v2 { throw WordNoteSnapshotError.unsupportedSchema }
        var manifest = try readManifest()
        guard manifest.active == expectedGeneration else { throw WordNoteRestoreError.staleGeneration }
        guard manifest.pending == nil else { throw WordNoteRestoreError.restoreAlreadyPending }
        guard backup.kind == .beforeRestore, backup.schemaVersion == manifest.activeSchema else {
            throw WordNoteRestoreError.protectionRequired
        }
        let generation = WordNoteStoreGeneration(id: UUID())
        let url = try storeURL(for: generation)
        let fault = self.fault
        let targetSchema = self.targetSchema
        let staging = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let payload: WordNoteVersionedPayload
            if targetSchema == .v2, case .v1(let legacy) = snapshot.payload {
                payload = .v2(try WordNoteV1ToV2Migration.convert(legacy).payload)
            } else {
                payload = snapshot.payload
            }
            return (payload, try Self.stage(payload, at: url, fault: fault))
        }
        let (payload, checksum) = try await withTaskCancellationHandler {
            try await staging.value
        } onCancel: {
            staging.cancel()
        }
        try Task.checkCancellation()
        // Staging yields MainActor; another coordinator must not replace the durable selection meanwhile.
        manifest = try readManifest()
        guard manifest.active == expectedGeneration else { throw WordNoteRestoreError.staleGeneration }
        guard manifest.pending == nil else { throw WordNoteRestoreError.restoreAlreadyPending }
        if payload.schemaVersion == .v2 { manifest.enableVersionedJournal() }
        manifest.pending = Manifest.PendingRestore(
            generation: generation, sourceSnapshotID: snapshot.summary.id,
            protectionSnapshotID: backup.id, payloadChecksum: checksum,
            payload: payload, journalVersion: manifest.version
        )
        try fault?(.prepareJournal)
        try writeManifest(manifest)
        return generation
    }

    public func cancelPreparedRestore(replacing expectedGeneration: WordNoteStoreGeneration) throws {
        var manifest = try readManifest()
        guard manifest.active == expectedGeneration else { throw WordNoteRestoreError.staleGeneration }
        guard manifest.pending?.phase == .prepared else { throw WordNoteRestoreError.invalidJournal }
        manifest.pending = nil
        try writeManifest(manifest)
    }

    public func acknowledgePreferences(for expectedGeneration: WordNoteStoreGeneration) throws {
        var manifest = try readManifest()
        guard manifest.active == expectedGeneration, manifest.pending == nil else { throw WordNoteRestoreError.staleGeneration }
        manifest.preferencesToApply = nil
        try writeManifest(manifest)
    }

    public func authorizeAnalysisResume(for expectedGeneration: WordNoteStoreGeneration) throws {
        var manifest = try readManifest()
        guard manifest.active == expectedGeneration, manifest.pending == nil else { throw WordNoteRestoreError.staleGeneration }
        manifest.analysisRequiresResume = false
        try writeManifest(manifest)
    }

    public func requireAnalysisPause(for expectedGeneration: WordNoteStoreGeneration) throws {
        var manifest = try readManifest()
        guard manifest.active == expectedGeneration, manifest.pending == nil else { throw WordNoteRestoreError.staleGeneration }
        manifest.analysisRequiresResume = true
        try writeManifest(manifest)
    }

    public func hasPreparedRestore(for expectedGeneration: WordNoteStoreGeneration) throws -> Bool {
        let manifest = try readManifest()
        guard manifest.active == expectedGeneration else { throw WordNoteRestoreError.staleGeneration }
        return manifest.pending != nil
    }

    private func session(
        _ manifest: Manifest, outcome: WordNoteRestoreOutcome, requireExisting: Bool = false
    ) throws -> WordNoteStoreSession {
        let url = try storeURL(for: manifest.active)
        return WordNoteStoreSession(
            container: try Self.makeContainer(
                at: url, schemaVersion: manifest.activeSchema, requireExisting: requireExisting || manifest.active != .legacy
            ),
            schemaVersion: manifest.activeSchema,
            generation: manifest.active, storeURL: url, restoreOutcome: outcome,
            analysisRequiresResume: manifest.analysisRequiresResume, preferencesToApply: manifest.preferencesToApply
        )
    }

    private func storeURL(for generation: WordNoteStoreGeneration) throws -> URL {
        try PrivateFileIO.prepareDirectory(directoryURL)
        guard let id = generation.id else { return directoryURL.appending(path: "WordNote.store") }
        let generations = directoryURL.appending(path: "Stores", directoryHint: .isDirectory)
        try PrivateFileIO.prepareDirectory(generations)
        let directory = generations.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
        try PrivateFileIO.prepareDirectory(directory)
        return directory.appending(path: "WordNote.store")
    }

    private nonisolated static func stage(
        _ payload: WordNoteVersionedPayload, at url: URL,
        fault: (@Sendable (Checkpoint) throws -> Void)?
    ) throws -> String {
        try Task.checkCancellation()
        let canonical = payload.canonicalized
        // Revalidate DTOs created directly as well as those read by the import picker.
        try canonical.validate()
        try autoreleasepool {
            let container = try makeContainer(at: url, schemaVersion: canonical.schemaVersion, requireExisting: false)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            try canonical.populateEmptyStore(context)
            guard try WordNoteVersionedPayload.capture(from: context, preferences: canonical.preferences) == canonical else {
                throw WordNoteRestoreError.stagingMismatch
            }
        }
        try secureStore(at: url, requireExisting: true)
        try fault?(.stagingSaved)
        try Task.checkCancellation()
        // Reopening validates persisted data, not just the first context's identity map.
        try autoreleasepool {
            let container = try makeContainer(at: url, schemaVersion: canonical.schemaVersion, requireExisting: true)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            guard try WordNoteVersionedPayload.capture(from: context, preferences: canonical.preferences) == canonical else {
                throw WordNoteRestoreError.stagingMismatch
            }
        }
        try Task.checkCancellation()
        return try canonical.contentChecksum()
    }

    private nonisolated static func makeContainer(
        at url: URL, schemaVersion: WordNoteDataSchemaVersion, requireExisting: Bool
    ) throws -> ModelContainer {
        try secureStore(at: url, requireExisting: requireExisting)
        let schema = schemaVersion == .v1 ? Schema(versionedSchema: WordNoteSchemaV1.self) : Schema(versionedSchema: WordNoteSchemaV2.self)
        let configuration = ModelConfiguration("WordNote", schema: schema, url: url)
        let container = try ModelContainer(
            for: schema, migrationPlan: schemaVersion == .v1 ? WordNoteMigrationPlan.self : nil, configurations: [configuration]
        )
        try secureStore(at: url, requireExisting: true)
        return container
    }

    private nonisolated static func secureStore(at url: URL, requireExisting: Bool) throws {
        let exists = try PrivateFileIO.secureExistingFile(url)
        if requireExisting, !exists { throw WordNoteRestoreError.missingStore }
        for suffix in ["-wal", "-shm"] {
            try PrivateFileIO.secureExistingFile(URL(fileURLWithPath: url.path + suffix))
        }
    }

    private var manifestURL: URL { directoryURL.appending(path: "store-generations.json") }

    private func readManifest() throws -> Manifest {
        try PrivateFileIO.prepareDirectory(directoryURL)
        guard try PrivateFileIO.secureExistingFile(manifestURL) else { return Manifest() }
        do {
            let data = try PrivateFileIO.read(manifestURL, maximumBytes: 32_768)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard [1, 2].contains(manifest.version) else { throw WordNoteRestoreError.invalidJournal }
            if manifest.version == 2, targetSchema == .v1 { throw WordNoteSnapshotError.unsupportedSchema }
            if manifest.version == 1 {
                guard manifest.activeSchemaVersion == nil, manifest.previousSchemaVersion == nil,
                      manifest.pending?.schemaVersion == nil else { throw WordNoteRestoreError.invalidJournal }
            } else {
                guard manifest.activeSchemaVersion != nil,
                      (manifest.previous == nil) == (manifest.previousSchemaVersion == nil),
                      manifest.pending == nil || manifest.pending?.schemaVersion != nil else {
                    throw WordNoteRestoreError.invalidJournal
                }
            }
            guard manifest.active != .legacy || manifest.activeSchema == .v1,
                  manifest.previous != .legacy || manifest.previousSchemaVersion == nil || manifest.previousSchemaVersion == .v1 else {
                throw WordNoteRestoreError.invalidJournal
            }
            if let pending = manifest.pending {
                guard manifest.version != 2 || pending.schema == .v2 else { throw WordNoteRestoreError.invalidJournal }
                guard pending.generation.id != nil, pending.generation != manifest.active,
                      pending.payloadChecksum.count == 64,
                      pending.payloadChecksum.allSatisfy({ "0123456789abcdef".contains($0) }),
                      [pending.counts.courses, pending.counts.inputRecords, pending.counts.candidates,
                       pending.counts.terms, pending.counts.reviewEvents, pending.counts.occurrences,
                       pending.counts.courseLinks, pending.counts.lookupEvents].allSatisfy({ (0...100_000).contains($0) }),
                      pending.counts.total <= WordNoteSnapshotPayload.maximumEntityCount else {
                    throw WordNoteRestoreError.invalidJournal
                }
                if pending.schema == .v1 {
                    guard pending.counts.occurrences == 0, pending.counts.courseLinks == 0, pending.counts.lookupEvents == 0 else {
                        throw WordNoteRestoreError.invalidJournal
                    }
                }
                try validatePreferences(pending.preferences)
            }
            if let preferences = manifest.preferencesToApply { try validatePreferences(preferences) }
            return manifest
        } catch {
            if error as? WordNoteSnapshotError == .unsupportedSchema { throw error }
            throw WordNoteRestoreError.invalidJournal
        }
    }

    private func validatePreferences(_ preferences: WordNoteSnapshotPayload.Preferences) throws {
        try WordNoteSnapshotPayload(
            courses: [], inputRecords: [], candidates: [], terms: [], reviewEvents: [], preferences: preferences
        ).validate()
    }

    private func writeManifest(_ manifest: Manifest) throws {
        try PrivateFileIO.write(JSONEncoder().encode(manifest), to: manifestURL)
    }
}
