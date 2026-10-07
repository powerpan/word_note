import Foundation

public struct WordNoteBackupSummary: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let kind: WordNoteBackupKind
    public let schemaVersion: WordNoteDataSchemaVersion
    public let counts: WordNoteBackupCounts
    public let payloadChecksum: String
    public let appVersion: String

    init(_ document: WordNoteSnapshotDocument) {
        id = document.snapshotID
        createdAt = document.createdAt
        kind = document.kind
        schemaVersion = .v1
        counts = WordNoteBackupCounts(document.counts)
        payloadChecksum = document.payloadChecksum
        appVersion = document.appVersion
    }

    init(_ document: WordNoteSnapshotV2Document) {
        id = document.snapshotID
        createdAt = document.createdAt
        kind = document.kind
        schemaVersion = .v2
        counts = WordNoteBackupCounts(document.counts)
        payloadChecksum = document.payloadChecksum
        appVersion = document.appVersion
    }
}

public struct WordNoteBackupInventory: Sendable {
    /// Newest successful creation first; ordering does not depend on the wall clock.
    public let snapshots: [WordNoteBackupSummary]
    public let unreadableFileCount: Int
    public let recoveredCatalog: Bool
}

public struct WordNoteBackupResult: Sendable {
    public let snapshot: WordNoteBackupSummary
    public let retentionNeedsAttention: Bool
}

public actor WordNoteBackupVault {
    public enum Checkpoint: Sendable {
        case snapshotWrite
        case catalogWrite
        case pruning
    }

    public static let automaticRetentionCount = 7
    public static let automaticInterval: TimeInterval = 24 * 60 * 60
    public nonisolated let directoryURL: URL
    private let appVersion: String
    private let fault: (@Sendable (Checkpoint) throws -> Void)?
    private static let suffix = ".wordnote-backup.json"

    private struct Catalog: Codable {
        var version = 1
        var snapshotIDs: [UUID]
    }

    public init(
        directoryURL: URL, appVersion: String = "development",
        fault: (@Sendable (Checkpoint) throws -> Void)? = nil
    ) {
        self.directoryURL = directoryURL
        self.appVersion = appVersion
        self.fault = fault
    }

    public func inventory() throws -> WordNoteBackupInventory {
        try PrivateFileIO.prepareDirectory(directoryURL)
        let urls = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        guard urls.count <= 100_000 else { throw WordNoteSnapshotError.sizeLimit }
        var summaries: [UUID: WordNoteBackupSummary] = [:]
        var unreadable = 0
        for url in urls where url.lastPathComponent.hasSuffix(Self.suffix) {
            do {
                let idText = String(url.lastPathComponent.dropLast(Self.suffix.count))
                guard let id = UUID(uuidString: idText), url.lastPathComponent == fileName(id) else {
                    throw WordNoteSnapshotError.invalidDocument
                }
                let decoded = try readVersionedSnapshot(at: url)
                guard decoded.summary.id == id else { throw WordNoteSnapshotError.invalidDocument }
                summaries[id] = decoded.summary
            } catch {
                unreadable += 1
            }
        }
        var catalogIDs: [UUID] = []
        var recoveredCatalog = false
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            do {
                let catalog = try JSONDecoder().decode(
                    Catalog.self, from: PrivateFileIO.read(catalogURL, maximumBytes: 8 * 1_024 * 1_024)
                )
                guard catalog.version == 1, Set(catalog.snapshotIDs).count == catalog.snapshotIDs.count else {
                    throw WordNoteSnapshotError.invalidDocument
                }
                catalogIDs = catalog.snapshotIDs.filter { summaries[$0] != nil }
            } catch {
                recoveredCatalog = true
            }
        }
        let knownIDs = Set(catalogIDs)
        let uncataloged = summaries.values.filter { !knownIDs.contains($0.id) }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        catalogIDs.append(contentsOf: uncataloged.map(\.id))
        return WordNoteBackupInventory(
            snapshots: catalogIDs.reversed().compactMap { summaries[$0] },
            unreadableFileCount: unreadable, recoveredCatalog: recoveredCatalog
        )
    }

    public func createIfDue(
        _ payload: WordNoteSnapshotPayload, now: Date = Date()
    ) throws -> WordNoteBackupResult? {
        try createIfDue(.v1(payload), now: now)
    }

    public func createIfDue(
        _ payload: WordNoteSnapshotV2Payload, now: Date = Date()
    ) throws -> WordNoteBackupResult? {
        try createIfDue(.v2(payload), now: now)
    }

    public func createIfDue(
        _ payload: WordNoteVersionedPayload, now: Date = Date()
    ) throws -> WordNoteBackupResult? {
        guard now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteSnapshotError.invalidValue
        }
        try payload.validate()
        let existing = try inventory()
        var isDue = true
        if let latest = existing.snapshots.first {
            let elapsed = now.timeIntervalSince(latest.createdAt)
            isDue = try (payload.schemaVersion != latest.schemaVersion || payload.contentChecksum() != latest.payloadChecksum)
                && (elapsed >= Self.automaticInterval || elapsed < 0)
        } else if payload.counts.total == 0 {
            isDue = false
        }
        if !isDue {
            try pruneExpiredAutomaticBackups(existing.snapshots)
            return nil
        }
        return try create(payload, kind: .automatic, now: now)
    }

    public func create(
        _ payload: WordNoteSnapshotPayload, kind: WordNoteBackupKind, now: Date = Date()
    ) throws -> WordNoteBackupResult {
        try create(.v1(payload), kind: kind, now: now)
    }

    public func create(
        _ payload: WordNoteSnapshotV2Payload, kind: WordNoteBackupKind, now: Date = Date()
    ) throws -> WordNoteBackupResult {
        try create(.v2(payload), kind: kind, now: now)
    }

    public func create(
        _ payload: WordNoteVersionedPayload, kind: WordNoteBackupKind, now: Date = Date()
    ) throws -> WordNoteBackupResult {
        let existing = try inventory()
        let id = UUID()
        let data = try payload.encode(kind: kind, snapshotID: id, createdAt: now, appVersion: appVersion)
        try fault?(.snapshotWrite)
        let url = snapshotURL(id)
        try PrivateFileIO.write(data, to: url, replaceExisting: false)
        let verified = try readVersionedSnapshot(at: url)
        guard verified.summary.id == id else { throw WordNoteSnapshotError.invalidDocument }
        let summary = verified.summary
        var snapshots = existing.snapshots
        snapshots.insert(summary, at: 0)
        try writeCatalog(snapshots)

        var retentionNeedsAttention = false
        do {
            try pruneExpiredAutomaticBackups(snapshots)
        } catch {
            // A valid new backup remains successful even when disk cleanup needs a retry.
            retentionNeedsAttention = true
        }
        return WordNoteBackupResult(snapshot: summary, retentionNeedsAttention: retentionNeedsAttention)
    }

    public func readSnapshot(at url: URL) throws -> DecodedWordNoteSnapshot {
        guard case .v1(let snapshot) = try readVersionedSnapshot(at: url) else { throw WordNoteSnapshotError.unsupportedSchema }
        return snapshot
    }

    public func readSnapshot(id: UUID) throws -> DecodedWordNoteSnapshot {
        guard case .v1(let snapshot) = try readVersionedSnapshot(id: id) else { throw WordNoteSnapshotError.unsupportedSchema }
        return snapshot
    }

    public func readVersionedSnapshot(at url: URL) throws -> VersionedWordNoteSnapshot {
        try WordNoteSnapshotReader.decode(PrivateFileIO.read(url, maximumBytes: WordNoteSnapshotCodec.maximumDocumentBytes))
    }

    public func readVersionedSnapshot(id: UUID) throws -> VersionedWordNoteSnapshot {
        let decoded = try readVersionedSnapshot(at: snapshotURL(id))
        guard decoded.summary.id == id else { throw WordNoteSnapshotError.invalidDocument }
        return decoded
    }

    public func exportSnapshot(_ payload: WordNoteSnapshotPayload, to url: URL) throws {
        try exportSnapshot(.v1(payload), to: url)
    }

    public func exportSnapshot(_ payload: WordNoteSnapshotV2Payload, to url: URL) throws {
        try exportSnapshot(.v2(payload), to: url)
    }

    public func exportSnapshot(_ payload: WordNoteVersionedPayload, to url: URL) throws {
        let data = try payload.encode(kind: .manual, appVersion: appVersion)
        try PrivateFileIO.write(data, to: url)
    }

    public func exportSnapshot(id: UUID, to url: URL) throws {
        let data = try PrivateFileIO.read(snapshotURL(id), maximumBytes: WordNoteSnapshotCodec.maximumDocumentBytes)
        guard try WordNoteSnapshotReader.decode(data).summary.id == id else { throw WordNoteSnapshotError.invalidDocument }
        try PrivateFileIO.write(data, to: url)
    }

    public func exportCSV(
        terms: [WordNoteSnapshotPayload.Term], courses: [WordNoteSnapshotPayload.Course],
        courseMemberships: [UUID: Set<UUID>]? = nil, to url: URL
    ) throws {
        try PrivateFileIO.write(VocabularyCSVExporter.export(terms: terms, courses: courses, courseMemberships: courseMemberships), to: url)
    }

    public func delete(id: UUID) throws {
        let existing = try inventory()
        guard existing.snapshots.contains(where: { $0.id == id }) else { throw WordNoteSnapshotError.invalidDocument }
        try FileManager.default.removeItem(at: snapshotURL(id))
        try writeCatalog(existing.snapshots.filter { $0.id != id })
    }

    public func maintainAutomaticRetention() throws {
        try pruneExpiredAutomaticBackups(inventory().snapshots)
    }

    private var catalogURL: URL { directoryURL.appending(path: "catalog.json") }

    private func fileName(_ id: UUID) -> String { id.uuidString.lowercased() + Self.suffix }

    private func snapshotURL(_ id: UUID) -> URL { directoryURL.appending(path: fileName(id)) }

    private func writeCatalog(_ snapshots: [WordNoteBackupSummary]) throws {
        try fault?(.catalogWrite)
        let data = try JSONEncoder().encode(Catalog(snapshotIDs: snapshots.reversed().map(\.id)))
        try PrivateFileIO.write(data, to: catalogURL)
    }

    private func pruneExpiredAutomaticBackups(_ snapshots: [WordNoteBackupSummary]) throws {
        let expired = snapshots.filter { $0.kind == .automatic }.dropFirst(Self.automaticRetentionCount)
        guard !expired.isEmpty else { return }
        // Persist any recovered ordering before deleting files, including after an interrupted catalog write.
        try writeCatalog(snapshots)
        try fault?(.pruning)
        for snapshot in expired {
            try FileManager.default.removeItem(at: snapshotURL(snapshot.id))
        }
        let removedIDs = Set(expired.map(\.id))
        try writeCatalog(snapshots.filter { !removedIDs.contains($0.id) })
    }
}
