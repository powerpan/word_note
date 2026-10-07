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
    private let fault: (@Sendable (Checkpoint) throws -> Void)?

    private struct Manifest: Codable {
        var version = 1
        var active = WordNoteStoreGeneration.legacy
        var previous: WordNoteStoreGeneration?
        var pending: PendingRestore?
        var analysisRequiresResume = false
        var preferencesToApply: WordNoteSnapshotPayload.Preferences?
    }

    private struct PendingRestore: Codable {
        enum Phase: String, Codable {
            case prepared
            case activating
        }
        var phase: Phase
        let generation: WordNoteStoreGeneration
        let sourceSnapshotID: UUID
        let protectionSnapshotID: UUID
        let payloadChecksum: String
        let counts: WordNoteSnapshotCounts
        let preferences: WordNoteSnapshotPayload.Preferences
        let analysisRequiresResume: Bool
    }

    public init(directoryURL: URL, fault: (@Sendable (Checkpoint) throws -> Void)? = nil) {
        self.directoryURL = directoryURL
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
            let container = try makeContainer(at: url, requireExisting: true)
            let payload = try WordNoteSnapshotPayload.capture(from: container.mainContext, preferences: pending.preferences)
            guard payload.counts == pending.counts,
                  try WordNoteSnapshotCodec.contentChecksum(payload) == pending.payloadChecksum else {
                throw WordNoteRestoreError.stagingMismatch
            }
            manifest.previous = manifest.active
            manifest.active = pending.generation
            manifest.pending = nil
            manifest.analysisRequiresResume = pending.analysisRequiresResume
            manifest.preferencesToApply = pending.preferences
            try fault?(.commitJournal)
            try writeManifest(manifest)
            return WordNoteStoreSession(
                container: container, generation: manifest.active, storeURL: url, restoreOutcome: .restored,
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
    ) throws -> WordNoteStoreGeneration {
        var manifest = try readManifest()
        guard manifest.active == expectedGeneration else { throw WordNoteRestoreError.staleGeneration }
        guard manifest.pending == nil else { throw WordNoteRestoreError.restoreAlreadyPending }
        guard backup.kind == .beforeRestore else { throw WordNoteRestoreError.protectionRequired }
        // Revalidate an independently constructed DTO as well as files read by the import picker.
        try snapshot.payload.validate()
        let generation = WordNoteStoreGeneration(id: UUID())
        let url = try storeURL(for: generation)
        let canonical = snapshot.payload.canonicalized
        try autoreleasepool {
            let staged = try makeContainer(at: url, requireExisting: false)
            try canonical.populateEmptyStore(staged.mainContext)
            guard try WordNoteSnapshotPayload.capture(from: staged.mainContext, preferences: canonical.preferences) == canonical else {
                throw WordNoteRestoreError.stagingMismatch
            }
        }
        try secureStore(at: url, requireExisting: true)
        try fault?(.stagingSaved)
        // Reopening validates the persisted store, not just SwiftData's in-memory identity map.
        try autoreleasepool {
            let reopened = try makeContainer(at: url, requireExisting: true)
            guard try WordNoteSnapshotPayload.capture(from: reopened.mainContext, preferences: canonical.preferences) == canonical else {
                throw WordNoteRestoreError.stagingMismatch
            }
        }
        manifest.pending = PendingRestore(
            phase: .prepared, generation: generation, sourceSnapshotID: snapshot.document.snapshotID,
            protectionSnapshotID: backup.id, payloadChecksum: try WordNoteSnapshotCodec.contentChecksum(canonical),
            counts: canonical.counts, preferences: canonical.preferences,
            analysisRequiresResume: canonical.inputRecords.contains { $0.statusRaw == InputRecordStatus.analyzing.rawValue }
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
            container: try makeContainer(at: url, requireExisting: requireExisting || manifest.active != .legacy),
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

    private func makeContainer(at url: URL, requireExisting: Bool) throws -> ModelContainer {
        try secureStore(at: url, requireExisting: requireExisting)
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let configuration = ModelConfiguration("WordNote", schema: schema, url: url)
        let container = try ModelContainer(for: schema, migrationPlan: WordNoteMigrationPlan.self, configurations: [configuration])
        try secureStore(at: url, requireExisting: true)
        return container
    }

    private func secureStore(at url: URL, requireExisting: Bool) throws {
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
            guard manifest.version == 1 else { throw WordNoteRestoreError.invalidJournal }
            if let pending = manifest.pending {
                guard pending.generation.id != nil, pending.generation != manifest.active,
                      pending.payloadChecksum.count == 64,
                      pending.payloadChecksum.allSatisfy({ "0123456789abcdef".contains($0) }),
                      [pending.counts.courses, pending.counts.inputRecords, pending.counts.candidates,
                       pending.counts.terms, pending.counts.reviewEvents].allSatisfy({ (0...100_000).contains($0) }),
                      pending.counts.total <= WordNoteSnapshotPayload.maximumEntityCount else {
                    throw WordNoteRestoreError.invalidJournal
                }
                try validatePreferences(pending.preferences)
            }
            if let preferences = manifest.preferencesToApply { try validatePreferences(preferences) }
            return manifest
        } catch {
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
