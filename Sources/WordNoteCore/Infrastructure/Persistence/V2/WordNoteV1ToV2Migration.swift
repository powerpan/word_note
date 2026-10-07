import CryptoKit
import Foundation

public enum WordNoteV1ToV2Migration {
    public struct Issue: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case missingCourse
            case missingSourceRecord
            case orphanCandidate
            case orphanReviewEvent
            case unresolvedSavedCandidate
            case legacySubjectNeedsReview
        }

        public let kind: Kind
        public let entityID: UUID
        public let relatedID: UUID?

        public var blocksMigration: Bool {
            switch kind {
            case .missingCourse, .missingSourceRecord, .orphanCandidate, .orphanReviewEvent: true
            case .unresolvedSavedCandidate, .legacySubjectNeedsReview: false
            }
        }
    }

    public struct Result: Sendable {
        public let payload: WordNoteSnapshotV2Payload
        public let issues: [Issue]
    }

    public enum MigrationError: Error, Equatable {
        case preflightFailed([Issue])
    }

    public static func preflight(_ source: WordNoteSnapshotPayload) -> [Issue] {
        let courseIDs = Set(source.courses.map(\.id))
        let recordIDs = Set(source.inputRecords.map(\.id))
        let termIDs = Set(source.terms.map(\.id))
        var issues: [Issue] = []
        for record in source.inputRecords {
            if let id = record.courseID, !courseIDs.contains(id) {
                issues.append(Issue(kind: .missingCourse, entityID: record.id, relatedID: id))
            }
        }
        for term in source.terms {
            if let id = term.courseID, !courseIDs.contains(id) {
                issues.append(Issue(kind: .missingCourse, entityID: term.id, relatedID: id))
            }
            if let id = term.sourceRecordID, !recordIDs.contains(id) {
                issues.append(Issue(kind: .missingSourceRecord, entityID: term.id, relatedID: id))
            }
            if !LookupDirectionDetector.isEnglishVocabularyTerm(term.term) {
                issues.append(Issue(kind: .legacySubjectNeedsReview, entityID: term.id, relatedID: nil))
            }
        }
        for candidate in source.candidates where !recordIDs.contains(candidate.inputRecordID) {
            issues.append(Issue(kind: .orphanCandidate, entityID: candidate.id, relatedID: candidate.inputRecordID))
        }
        for event in source.reviewEvents where !termIDs.contains(event.termID) {
            issues.append(Issue(kind: .orphanReviewEvent, entityID: event.id, relatedID: event.termID))
        }
        return issues.sorted(by: issueOrder)
    }

    /// Pure conversion; never edits, repairs, or opens the source database.
    public static func convert(_ source: WordNoteSnapshotPayload) throws -> Result {
        var issues = preflight(source)
        guard !issues.contains(where: \.blocksMigration) else { throw MigrationError.preflightFailed(issues) }
        try source.validate()
        let source = source.canonicalized
        let records = Dictionary(uniqueKeysWithValues: source.inputRecords.map { ($0.id, $0) })
        let candidateRecordIDs = Set(source.candidates.map(\.inputRecordID))
        let recordStates = source.inputRecords.map { record in
            WordNoteSnapshotV2Payload.RecordState(
                id: record.id, captureID: stableID("record-capture", record.id), capturedViaRaw: "legacy", lookupIntentRaw: "auto",
                resolvedLookupDirectionRaw: LookupDirectionDetectorV1.detect(record.rawText).rawValue,
                directionDetectorVersion: LookupDirectionDetectorV1.version,
                analysisGeneration: record.analyzedAt != nil || candidateRecordIDs.contains(record.id)
                    || record.statusRaw == "analyzing" || record.statusRaw == "failed" ? 1 : 0,
                attemptID: nil, queueStateRaw: record.statusRaw == "analyzing" ? "queued"
                    : record.statusRaw == "failed" ? "failed" : "none",
                autoRetryCount: 0, nextAttemptAt: nil, revision: 0
            )
        }
        let recordStateByID = Dictionary(uniqueKeysWithValues: recordStates.map { ($0.id, $0) })
        let termsBySource = Dictionary(grouping: source.terms.filter { $0.sourceRecordID != nil }) {
            SourceTermKey(recordID: $0.sourceRecordID!, normalizedTerm: $0.normalizedTerm)
        }
        let candidateStates = source.candidates.map { candidate in
            var savedTermID: UUID?
            var link: CandidateSavedLinkState = .none
            if candidate.statusRaw == CandidateStatus.saved.rawValue {
                let matches = termsBySource[SourceTermKey(
                    recordID: candidate.inputRecordID, normalizedTerm: candidate.normalizedTerm
                )] ?? []
                if matches.count == 1 {
                    savedTermID = matches[0].id
                    link = .resolved
                } else {
                    link = .unresolvedLegacy
                    issues.append(Issue(kind: .unresolvedSavedCandidate, entityID: candidate.id, relatedID: nil))
                }
            }
            return WordNoteSnapshotV2Payload.CandidateState(
                id: candidate.id, revision: 0, savedTermID: savedTermID, savedLinkStateRaw: link.rawValue,
                confirmationOperationID: nil, analysisGeneration: recordStateByID[candidate.inputRecordID]!.analysisGeneration
            )
        }
        var occurrences: [WordNoteSnapshotV2Payload.Occurrence] = []
        for term in source.terms {
            if let sourceID = term.sourceRecordID, let record = records[sourceID] {
                let captureID = recordStateByID[sourceID]!.captureID
                occurrences.append(WordNoteSnapshotV2Payload.Occurrence(
                    id: stableID("occurrence", term.id, captureID), termID: term.id, captureID: captureID,
                    sourceRecordID: sourceID, rawTextSnapshot: record.rawText, note: record.note,
                    courseID: record.courseID, sourceTypeRaw: record.sourceTypeRaw,
                    occurredAt: record.createdAt, capturedViaRaw: "legacy", legacy: true,
                    sourceTitle: nil, sourceURL: nil, sourcePage: nil, createdAt: record.createdAt
                ))
            } else if let context = term.contextSentence,
                      !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let captureID = stableID("context-capture", term.id)
                occurrences.append(WordNoteSnapshotV2Payload.Occurrence(
                    id: stableID("occurrence", term.id, captureID), termID: term.id, captureID: captureID,
                    sourceRecordID: nil, rawTextSnapshot: context, note: nil, courseID: term.courseID,
                    sourceTypeRaw: term.sourceTypeRaw, occurredAt: term.createdAt, capturedViaRaw: "legacy",
                    legacy: true, sourceTitle: nil, sourceURL: nil, sourcePage: nil, createdAt: term.createdAt
                ))
            }
        }
        var content = source
        // Processing status becomes durable queue state, not a curation status.
        for index in content.inputRecords.indices where ["analyzing", "failed"].contains(content.inputRecords[index].statusRaw) {
            content.inputRecords[index].statusRaw = InputRecordStatus.draft.rawValue
        }
        let payload = WordNoteSnapshotV2Payload(
            content: content,
            courseRevisions: source.courses.map { .init(id: $0.id, revision: 0) },
            recordStates: recordStates, candidateStates: candidateStates,
            termStates: source.terms.map { .init(id: $0.id, revision: 0, counterSemanticsVersionRaw: "legacyMixed") },
            occurrences: occurrences,
            courseLinks: source.terms.compactMap { term in
                term.courseID.map { courseID in
                    .init(id: stableID("course-link", term.id, courseID), termID: term.id, courseID: courseID, createdAt: term.createdAt)
                }
            },
            lookupEvents: []
        ).canonicalized
        try payload.validate()
        return Result(payload: payload, issues: issues.sorted(by: issueOrder))
    }

    private struct SourceTermKey: Hashable {
        let recordID: UUID
        let normalizedTerm: String
    }

    private static func issueOrder(_ lhs: Issue, _ rhs: Issue) -> Bool {
        (lhs.entityID.uuidString, lhs.kind.rawValue) < (rhs.entityID.uuidString, rhs.kind.rawValue)
    }

    // Domain-separated deterministic UUIDs; never use this mapping for new user submissions.
    private static func stableID(_ domain: String, _ ids: UUID...) -> UUID {
        let key = (["wordnote/v1-to-v2/1", domain] + ids.map { $0.uuidString.lowercased() }).joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
