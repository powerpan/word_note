import Foundation
import Combine
import Observation
import SwiftData

public struct WordNoteRestorePreview: Identifiable, Sendable {
    public var id: UUID { snapshot.document.snapshotID }
    public let snapshot: DecodedWordNoteSnapshot
}

public struct WordNoteVersionedRestorePreview: Identifiable, Sendable {
    public var id: UUID { snapshot.summary.id }
    public let snapshot: VersionedWordNoteSnapshot
}

public enum WordNoteDataOperationError: LocalizedError {
    case busy
    case protectedDestination

    public var errorDescription: String? {
        switch self {
        case .busy: "Another data operation is in progress."
        case .protectedDestination: "Choose an export location outside Word Note's managed data directory."
        }
    }
}

@MainActor
@Observable
public final class WordNoteDataProtection {
    public enum RestorePhase: Equatable { case idle, preparing, readyToQuit, recoveryRequired }

    public private(set) var snapshots: [WordNoteBackupSummary] = []
    public private(set) var unreadableBackupCount = 0
    public private(set) var catalogNeedsRepair = false
    public private(set) var isWorking = false
    public private(set) var restorePhase = RestorePhase.idle {
        didSet {
            if (oldValue == .idle) != (restorePhase == .idle) { restoreStateDidChange?(isRestoring) }
        }
    }
    public private(set) var statusMessage: String?
    public private(set) var errorMessage: String?
    public var isRestoring: Bool { restorePhase != .idle }
    public var analysisRequiresResume: Bool { queue.isSuspended }
    public let backupDirectoryURL: URL

    // The runtime owns this hook so process-wide capture does not depend on an open SwiftUI window.
    @ObservationIgnored public var restoreStateDidChange: (@MainActor (Bool) -> Void)? {
        didSet { restoreStateDidChange?(isRestoring) }
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let store: WordNoteRestoreStore
    @ObservationIgnored private let generation: WordNoteStoreGeneration
    @ObservationIgnored private let vault: WordNoteBackupVault
    @ObservationIgnored private let queue: DataProtectionAnalysisQueue
    @ObservationIgnored private let schemaVersion: WordNoteDataSchemaVersion
    @ObservationIgnored private let preferences: @MainActor () -> WordNoteSnapshotPayload.Preferences
    @ObservationIgnored private var restoreTicket: WordNoteWriteGate.Ticket?
    @ObservationIgnored private var autosaveBeforeRestore = true
    @ObservationIgnored private var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: AnyCancellable?
    @ObservationIgnored private var changeRevision = 0
    @ObservationIgnored private var automaticNeedsCheck = true
    @ObservationIgnored private var automaticCheckNotBefore = Date.distantPast

    public convenience init(
        session: WordNoteStoreSession, store: WordNoteRestoreStore, vault: WordNoteBackupVault,
        queue: QuickAddAnalysisQueue,
        preferences: @escaping @MainActor () -> WordNoteSnapshotPayload.Preferences
    ) {
        self.init(session: session, store: store, vault: vault, queue: .v1(queue), preferences: preferences)
    }

    public convenience init(
        session: WordNoteStoreSession, store: WordNoteRestoreStore, vault: WordNoteBackupVault,
        queue: WordNoteV2AnalysisQueue,
        preferences: @escaping @MainActor () -> WordNoteSnapshotPayload.Preferences
    ) {
        self.init(session: session, store: store, vault: vault, queue: .v2(queue), preferences: preferences)
    }

    private init(
        session: WordNoteStoreSession, store: WordNoteRestoreStore, vault: WordNoteBackupVault,
        queue: DataProtectionAnalysisQueue,
        preferences: @escaping @MainActor () -> WordNoteSnapshotPayload.Preferences
    ) {
        container = session.container
        schemaVersion = session.schemaVersion
        self.store = store
        generation = session.generation
        self.vault = vault
        backupDirectoryURL = vault.directoryURL
        self.queue = queue
        self.preferences = preferences
        if session.analysisRequiresResume { queue.suspendForRestore() }
        switch session.restoreOutcome {
        case .restored: statusMessage = "Backup restored. The previous data store was retained."
        case .migrated: statusMessage = "Data upgrade completed. The previous data store and backup were retained."
        case .repaired: statusMessage = "Data repair completed. The original data store and repair evidence were retained."
        case .rolledBack: errorMessage = "Restore did not complete. The previous data store is still active."
        case .none: break
        }
        if session.recoveryRequired != nil { errorMessage = "A data switch did not complete. The previous data store is still active." }
    }

    public func startAutomaticBackups() {
        guard automaticTask == nil else { return }
        saveObserver = NotificationCenter.default.publisher(for: ModelContext.didSave, object: container.mainContext)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.noteDataChanged() }
        automaticTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.checkAutomaticBackup()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                guard self != nil else { return }
            }
        }
    }

    public func stopAutomaticBackups() {
        automaticTask?.cancel()
        automaticTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        saveObserver = nil
    }

    public func noteDataChanged() {
        changeRevision += 1
        automaticNeedsCheck = true
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) }
            catch { return }
            await self?.checkAutomaticBackup()
        }
    }

    public func refresh() async {
        guard !isWorking else { return }
        do { try await updateInventory() }
        catch { errorMessage = error.localizedDescription }
    }

    public func checkAutomaticBackup(now: Date = Date()) async {
        guard automaticNeedsCheck, !isWorking, !isRestoring else { return }
        // A wall-clock rollback must not postpone the next check indefinitely.
        guard now >= automaticCheckNotBefore || automaticCheckNotBefore.timeIntervalSince(now) > WordNoteBackupVault.automaticInterval else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await updateInventory()
            if snapshots.filter({ $0.kind == .automatic }).count > WordNoteBackupVault.automaticRetentionCount {
                try await vault.maintainAutomaticRetention()
                try await updateInventory()
            }
            if let latest = snapshots.first {
                let elapsed = now.timeIntervalSince(latest.createdAt)
                if (0..<WordNoteBackupVault.automaticInterval).contains(elapsed) {
                    automaticCheckNotBefore = latest.createdAt.addingTimeInterval(WordNoteBackupVault.automaticInterval)
                    return
                }
            }
            let revision = changeRevision
            let snapshot = try await currentSnapshot()
            let result = try await vault.createIfDue(snapshot, now: now)
            automaticNeedsCheck = changeRevision != revision || result?.retentionNeedsAttention == true
            automaticCheckNotBefore = now
            if let result {
                statusMessage = "Automatic backup saved."
                if result.retentionNeedsAttention { errorMessage = "Backup saved, but automatic backup cleanup needs attention." }
            }
            try await updateInventory()
        } catch {
            errorMessage = "Automatic backup failed: \(error.localizedDescription)"
        }
    }

    public func createBackup() async throws {
        try await perform {
            let payload = try await self.currentSnapshot()
            let result = try await self.vault.create(payload, kind: .manual)
            self.statusMessage = "Backup saved."
            if result.retentionNeedsAttention { self.errorMessage = "Backup saved, but automatic backup cleanup needs attention." }
            try await self.updateInventory()
        }
    }

    public func exportBackup(to url: URL, id: UUID? = nil) async throws {
        try await perform {
            try self.validateExportDestination(url)
            if let id { try await self.vault.exportSnapshot(id: id, to: url) }
            else { try await self.vault.exportSnapshot(self.currentSnapshot(), to: url) }
            self.statusMessage = "Complete JSON backup exported."
        }
    }

    public func exportVocabulary(
        terms: [WordNoteSnapshotPayload.Term], courses: [WordNoteSnapshotPayload.Course],
        courseMemberships: [UUID: Set<UUID>]? = nil, to url: URL
    ) async throws {
        try await perform {
            try self.validateExportDestination(url)
            if self.schemaVersion != .v1, courseMemberships == nil { throw WordNoteV2ContentError.invalidValue }
            try await self.vault.exportCSV(terms: terms, courses: courses, courseMemberships: courseMemberships, to: url)
            self.statusMessage = "Exported \(terms.count) vocabulary entries."
        }
    }

    public func previewRestore(url: URL) async throws -> WordNoteRestorePreview {
        try await perform { WordNoteRestorePreview(snapshot: try await self.vault.readSnapshot(at: url)) }
    }

    public func previewRestore(id: UUID) async throws -> WordNoteRestorePreview {
        try await perform { WordNoteRestorePreview(snapshot: try await self.vault.readSnapshot(id: id)) }
    }

    public func previewVersionedRestore(url: URL) async throws -> WordNoteVersionedRestorePreview {
        try await perform {
            try self.validatedPreview(await self.vault.readVersionedSnapshot(at: url))
        }
    }

    public func previewVersionedRestore(id: UUID) async throws -> WordNoteVersionedRestorePreview {
        try await perform {
            try self.validatedPreview(await self.vault.readVersionedSnapshot(id: id))
        }
    }

    private func validatedPreview(_ snapshot: VersionedWordNoteSnapshot) throws -> WordNoteVersionedRestorePreview {
        guard schemaVersion.supports(snapshot.payload.schemaVersion) else {
            throw WordNoteSnapshotError.unsupportedSchema
        }
        return WordNoteVersionedRestorePreview(snapshot: snapshot)
    }

    public func deleteBackup(id: UUID) async throws {
        try await perform {
            try await self.vault.delete(id: id)
            try await self.updateInventory()
            self.statusMessage = "Backup deleted. Active vocabulary was not changed."
        }
    }

    public func prepareRestore(_ preview: WordNoteRestorePreview) async throws {
        try await prepareRestore(WordNoteVersionedRestorePreview(snapshot: .v1(preview.snapshot)))
    }

    public func prepareRestore(_ preview: WordNoteVersionedRestorePreview) async throws {
        guard !isWorking, !isRestoring else { throw WordNoteDataOperationError.busy }
        do {
            _ = try validatedPreview(preview.snapshot)
            if schemaVersion != .v1, container.mainContext.hasChanges { throw WordNoteV2ContentError.unsavedChanges }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
        isWorking = true
        restorePhase = .preparing
        errorMessage = nil
        defer { isWorking = false }
        do {
            // Persist the pause before awaiting any IO, so a crash cannot replay interrupted paid requests.
            restoreTicket = try WordNoteWriteGate.beginRestore(container.mainContext)
            autosaveBeforeRestore = container.mainContext.autosaveEnabled
            container.mainContext.autosaveEnabled = false
            queue.suspendForRestore()
            try store.requireAnalysisPause(for: generation)
            try container.mainContext.save()
            let current = try await currentSnapshot()
            let protection = try await vault.create(current, kind: .beforeRestore)
            _ = try await vault.readVersionedSnapshot(id: protection.snapshot.id)
            try await store.prepareRestore(preview.snapshot, replacing: generation, protectedBy: protection.snapshot)
            restorePhase = .readyToQuit
            statusMessage = "Restore prepared. Quit Word Note to complete the switch on next launch."
            try await updateInventory()
        } catch {
            errorMessage = error.localizedDescription
            do {
                if try store.hasPreparedRestore(for: generation) { restorePhase = .readyToQuit }
                else { try releaseRestoreGate() }
            } catch {
                // An uncertain durable journal is not permission to resume writing to the old generation.
                restorePhase = .recoveryRequired
            }
            throw error
        }
    }

    public func cancelRestore() throws {
        guard restorePhase == .readyToQuit else { throw WordNoteDataOperationError.busy }
        do {
            try store.cancelPreparedRestore(replacing: generation)
            try releaseRestoreGate()
            statusMessage = "Restore cancelled. Pending analysis remains paused."
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func resumeAnalysis() throws {
        guard !isWorking, !isRestoring else { throw WordNoteDataOperationError.busy }
        do {
            // V2 normalizes interrupted attempts before clearing the durable pause itself.
            if schemaVersion == .v1 { try store.authorizeAnalysisResume(for: generation) }
            let count = try queue.resumePendingAnalyses()
            statusMessage = "Resumed \(count) pending analysis requests."
            errorMessage = nil
        } catch {
            try? store.requireAnalysisPause(for: generation)
            queue.suspendForRestore()
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func pendingAnalysisCount() throws -> Int {
        switch schemaVersion {
        case .v1:
            return try container.mainContext.fetch(FetchDescriptor<InputRecordModel>()).filter { $0.status == .analyzing }.count
        case .v2:
            return try container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.InputRecordModel>())
                .filter { ["queued", "running"].contains($0.queueStateRaw) }.count
        case .v3:
            // V3 runtime writers are deliberately not connected until the scheduler transition.
            throw WordNoteSnapshotError.unsupportedSchema
        }
    }

    private func releaseRestoreGate() throws {
        if let restoreTicket {
            try WordNoteWriteGate.endRestore(container.mainContext, ticket: restoreTicket)
            self.restoreTicket = nil
            container.mainContext.autosaveEnabled = autosaveBeforeRestore
        }
        restorePhase = .idle
        noteDataChanged()
    }

    private func currentSnapshot() async throws -> WordNoteVersionedPayload {
        try await WordNoteSnapshotCapture(container: container).captureVersioned(preferences: preferences())
    }

    private func updateInventory() async throws {
        let inventory = try await vault.inventory()
        snapshots = inventory.snapshots
        unreadableBackupCount = inventory.unreadableFileCount
        catalogNeedsRepair = inventory.recoveredCatalog
    }

    private func validateExportDestination(_ url: URL) throws {
        let root = store.directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destination = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: url.lastPathComponent).resolvingSymlinksInPath().standardizedFileURL.path
        guard destination != root, !destination.hasPrefix(root + "/") else {
            throw WordNoteDataOperationError.protectedDestination
        }
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        guard !isWorking, !isRestoring else { throw WordNoteDataOperationError.busy }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { return try await operation() }
        catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}

@MainActor
private enum DataProtectionAnalysisQueue {
    case v1(QuickAddAnalysisQueue)
    case v2(WordNoteV2AnalysisQueue)

    var isSuspended: Bool {
        switch self {
        case .v1(let queue): queue.isSuspended
        case .v2(let queue): queue.isSuspended
        }
    }

    func suspendForRestore() {
        switch self {
        case .v1(let queue): queue.suspendForRestore()
        case .v2(let queue): queue.suspendForRestore()
        }
    }

    func resumePendingAnalyses() throws -> Int {
        switch self {
        case .v1(let queue): try queue.resumePendingAnalyses()
        case .v2(let queue): try queue.resumePendingAnalyses()
        }
    }
}
