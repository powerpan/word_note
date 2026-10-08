import Foundation

struct WordNoteStoreManifest: Codable {
    var version = 1
    var active = WordNoteStoreGeneration.legacy
    var activeSchemaVersion: WordNoteDataSchemaVersion?
    var previous: WordNoteStoreGeneration?
    var previousSchemaVersion: WordNoteDataSchemaVersion?
    var pending: PendingRestore?
    var analysisRequiresResume = false
    var preferencesToApply: WordNoteSnapshotPayload.Preferences?
    var recoveryRequired: WordNoteStoreTransitionKind?

    var activeSchema: WordNoteDataSchemaVersion { activeSchemaVersion ?? .v1 }

    mutating func enableVersionedJournal(for schema: WordNoteDataSchemaVersion = .v2) {
        guard schema != .v1 else { return }
        if version == 1 {
            activeSchemaVersion = .v1
            previousSchemaVersion = previous == nil ? nil : .v1
        }
        // A cancelled or rolled-back V3 transition must not become readable by an older writer.
        version = max(version, schema.journalVersion)
    }

    struct PendingRestore: Codable {
        enum Phase: String, Codable {
            case prepared
            case activating
        }
        var phase: Phase
        let generation: WordNoteStoreGeneration
        let sourceSnapshotID: UUID
        let protectionSnapshotID: UUID
        let payloadChecksum: String
        let schemaVersion: WordNoteDataSchemaVersion?
        let counts: WordNoteBackupCounts
        let preferences: WordNoteSnapshotPayload.Preferences
        let analysisRequiresResume: Bool
        let operation: WordNoteStoreTransitionKind?

        var schema: WordNoteDataSchemaVersion { schemaVersion ?? .v1 }
        var transition: WordNoteStoreTransitionKind { operation ?? .restore }

        init(
            generation: WordNoteStoreGeneration, sourceSnapshotID: UUID, protectionSnapshotID: UUID,
            payloadChecksum: String, payload: WordNoteVersionedPayload, journalVersion: Int,
            transition: WordNoteStoreTransitionKind
        ) {
            phase = .prepared
            self.generation = generation
            self.sourceSnapshotID = sourceSnapshotID
            self.protectionSnapshotID = protectionSnapshotID
            self.payloadChecksum = payloadChecksum
            schemaVersion = journalVersion == 1 ? nil : payload.schemaVersion
            counts = payload.counts
            preferences = payload.preferences
            analysisRequiresResume = payload.requiresAnalysisResume
            operation = journalVersion == 1 ? nil : transition
        }

        private enum CodingKeys: String, CodingKey {
            case phase, generation, sourceSnapshotID, protectionSnapshotID, payloadChecksum
            case schemaVersion, counts, preferences, analysisRequiresResume, operation
        }

        private enum CountKeys: String, CodingKey, CaseIterable {
            case courses, inputRecords, candidates, terms, reviewEvents, occurrences, courseLinks, lookupEvents
            case cards, sessions, sessionItems
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phase = try values.decode(Phase.self, forKey: .phase)
            generation = try values.decode(WordNoteStoreGeneration.self, forKey: .generation)
            sourceSnapshotID = try values.decode(UUID.self, forKey: .sourceSnapshotID)
            protectionSnapshotID = try values.decode(UUID.self, forKey: .protectionSnapshotID)
            payloadChecksum = try values.decode(String.self, forKey: .payloadChecksum)
            schemaVersion = try values.decodeIfPresent(WordNoteDataSchemaVersion.self, forKey: .schemaVersion)
            let countKeys = try values.nestedContainer(keyedBy: CountKeys.self, forKey: .counts).allKeys
            let countFieldCount = switch schemaVersion ?? .v1 {
            case .v1: 5
            case .v2: 8
            case .v3: 11
            }
            guard Set(countKeys) == Set(CountKeys.allCases.prefix(countFieldCount)) else {
                throw WordNoteRestoreError.invalidJournal
            }
            switch schemaVersion ?? .v1 {
            case .v1:
                counts = WordNoteBackupCounts(try values.decode(WordNoteSnapshotCounts.self, forKey: .counts))
            case .v2:
                counts = WordNoteBackupCounts(try values.decode(WordNoteSnapshotV2Counts.self, forKey: .counts))
            case .v3:
                counts = WordNoteBackupCounts(try values.decode(WordNoteSnapshotV3Counts.self, forKey: .counts))
            }
            preferences = try values.decode(WordNoteSnapshotPayload.Preferences.self, forKey: .preferences)
            analysisRequiresResume = try values.decode(Bool.self, forKey: .analysisRequiresResume)
            operation = try values.decodeIfPresent(WordNoteStoreTransitionKind.self, forKey: .operation)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(phase, forKey: .phase)
            try values.encode(generation, forKey: .generation)
            try values.encode(sourceSnapshotID, forKey: .sourceSnapshotID)
            try values.encode(protectionSnapshotID, forKey: .protectionSnapshotID)
            try values.encode(payloadChecksum, forKey: .payloadChecksum)
            try values.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
            switch schemaVersion ?? .v1 {
            case .v1:
                let legacyCounts = WordNoteSnapshotCounts(
                    courses: counts.courses, inputRecords: counts.inputRecords, candidates: counts.candidates,
                    terms: counts.terms, reviewEvents: counts.reviewEvents
                )
                try values.encode(legacyCounts, forKey: .counts)
            case .v2:
                let legacyCounts = WordNoteSnapshotV2Counts(
                    courses: counts.courses, inputRecords: counts.inputRecords, candidates: counts.candidates,
                    terms: counts.terms, reviewEvents: counts.reviewEvents, occurrences: counts.occurrences,
                    courseLinks: counts.courseLinks, lookupEvents: counts.lookupEvents
                )
                try values.encode(legacyCounts, forKey: .counts)
            case .v3:
                try values.encode(counts, forKey: .counts)
            }
            try values.encode(preferences, forKey: .preferences)
            try values.encode(analysisRequiresResume, forKey: .analysisRequiresResume)
            try values.encodeIfPresent(operation, forKey: .operation)
        }
    }
}
