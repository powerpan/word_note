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

    var activeSchema: WordNoteDataSchemaVersion { activeSchemaVersion ?? .v1 }

    mutating func enableVersionedJournal() {
        guard version == 1 else { return }
        version = 2
        activeSchemaVersion = .v1
        previousSchemaVersion = previous == nil ? nil : .v1
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

        var schema: WordNoteDataSchemaVersion { schemaVersion ?? .v1 }

        init(
            generation: WordNoteStoreGeneration, sourceSnapshotID: UUID, protectionSnapshotID: UUID,
            payloadChecksum: String, payload: WordNoteVersionedPayload, journalVersion: Int
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
        }

        private enum CodingKeys: String, CodingKey {
            case phase, generation, sourceSnapshotID, protectionSnapshotID, payloadChecksum
            case schemaVersion, counts, preferences, analysisRequiresResume
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            phase = try values.decode(Phase.self, forKey: .phase)
            generation = try values.decode(WordNoteStoreGeneration.self, forKey: .generation)
            sourceSnapshotID = try values.decode(UUID.self, forKey: .sourceSnapshotID)
            protectionSnapshotID = try values.decode(UUID.self, forKey: .protectionSnapshotID)
            payloadChecksum = try values.decode(String.self, forKey: .payloadChecksum)
            schemaVersion = try values.decodeIfPresent(WordNoteDataSchemaVersion.self, forKey: .schemaVersion)
            if schemaVersion == nil {
                counts = WordNoteBackupCounts(try values.decode(WordNoteSnapshotCounts.self, forKey: .counts))
            } else {
                counts = try values.decode(WordNoteBackupCounts.self, forKey: .counts)
            }
            preferences = try values.decode(WordNoteSnapshotPayload.Preferences.self, forKey: .preferences)
            analysisRequiresResume = try values.decode(Bool.self, forKey: .analysisRequiresResume)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(phase, forKey: .phase)
            try values.encode(generation, forKey: .generation)
            try values.encode(sourceSnapshotID, forKey: .sourceSnapshotID)
            try values.encode(protectionSnapshotID, forKey: .protectionSnapshotID)
            try values.encode(payloadChecksum, forKey: .payloadChecksum)
            try values.encodeIfPresent(schemaVersion, forKey: .schemaVersion)
            if schemaVersion == nil {
                let legacyCounts = WordNoteSnapshotCounts(
                    courses: counts.courses, inputRecords: counts.inputRecords, candidates: counts.candidates,
                    terms: counts.terms, reviewEvents: counts.reviewEvents
                )
                try values.encode(legacyCounts, forKey: .counts)
            } else {
                try values.encode(counts, forKey: .counts)
            }
            try values.encode(preferences, forKey: .preferences)
            try values.encode(analysisRequiresResume, forKey: .analysisRequiresResume)
        }
    }
}
