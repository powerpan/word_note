import Foundation
import SwiftData

public enum WordNoteV2IntegrityService {
    typealias Issue = WordNoteV2IntegrityIssue
    typealias Payload = WordNoteSnapshotV2Payload

    /// Returns identifiers and error categories only, never user text or a guessed replacement.
    public static func inspect(_ source: WordNoteSnapshotV2Payload) -> WordNoteV2IntegrityReport {
        var issues: [Issue] = []
        inspectIdentifiers(source, into: &issues)
        inspectRelationships(source, into: &issues)
        inspectCandidates(source, into: &issues)
        for term in source.content.terms where !LookupDirectionDetector.isEnglishVocabularyTerm(term.term) {
            issues.append(Issue(entity: .term, entityID: term.id, field: "term", kind: .legacySubjectNeedsReview, relatedID: nil, resolution: .warning))
        }
        let headwords = Dictionary(grouping: source.content.terms, by: \.normalizedTerm)
        for group in headwords.values where group.count > 1 {
            for term in group {
                issues.append(Issue(entity: .term, entityID: term.id, field: "normalizedTerm", kind: .ambiguousHeadword, relatedID: nil, resolution: .warning))
            }
        }
        let validationError: WordNoteSnapshotError?
        do {
            try detachingOptionalReferences(in: source, issues: issues).validate()
            validationError = nil
        } catch {
            validationError = (error as? WordNoteSnapshotError) ?? .invalidValue
        }
        return WordNoteV2IntegrityReport(issues: issues.sorted(by: issueOrder), remainingValidationError: validationError)
    }

    @MainActor
    public static func inspect(
        in container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) throws -> WordNoteV2IntegrityReport {
        inspect(try persistedPayload(in: container, preferences: preferences))
    }

    /// No rows are deleted. The original value and its source database remain unchanged.
    public static func prepareRepair(
        _ source: WordNoteSnapshotV2Payload, at date: Date = Date()
    ) throws -> WordNoteV2IntegrityRepairPlan {
        let report = inspect(source)
        guard !report.requiresManualResolution else { throw WordNoteV2IntegrityError.unresolvedIssues(report) }
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteSnapshotError.invalidValue
        }
        var repaired = detachingOptionalReferences(in: source, issues: report.issues)
        let sourceTerms = Dictionary(uniqueKeysWithValues: source.occurrences.map { ($0.id, $0.termID) })
        let eventTerms = Dictionary(uniqueKeysWithValues: source.lookupEvents.map { ($0.id, $0.termID) })
        var affectedTerms = Set<UUID>()
        for issue in report.issues where issue.resolution == .detachMissingOptionalReference {
            switch issue.entity {
            case .term: affectedTerms.insert(issue.entityID)
            case .occurrence:
                if let id = sourceTerms[issue.entityID] { affectedTerms.insert(id) }
            case .lookupEvent:
                if let id = eventTerms[issue.entityID] { affectedTerms.insert(id) }
            default: break
            }
        }
        for index in repaired.termStates.indices where affectedTerms.contains(repaired.termStates[index].id) {
            guard repaired.termStates[index].revision < 1_000_000_000 else { throw WordNoteV2ContentError.counterLimit }
            repaired.termStates[index].revision += 1
        }
        for index in repaired.content.terms.indices where affectedTerms.contains(repaired.content.terms[index].id) {
            repaired.content.terms[index].updatedAt = date
        }
        repaired = repaired.canonicalized
        try repaired.validate()
        return WordNoteV2IntegrityRepairPlan(report: report, source: source.canonicalized, repairedPayload: repaired)
    }

    @MainActor
    public static func prepareRepair(
        in container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences = .init(), at date: Date = Date()
    ) throws -> WordNoteV2IntegrityRepairPlan {
        try prepareRepair(persistedPayload(in: container, preferences: preferences), at: date)
    }

    @MainActor
    public static func validate(
        _ plan: WordNoteV2IntegrityRepairPlan, against container: ModelContainer,
        preferences: WordNoteSnapshotPayload.Preferences = .init()
    ) throws -> WordNoteSnapshotV2Payload {
        try plan.validatedPayload(matching: persistedPayload(in: container, preferences: preferences))
    }

    @MainActor
    private static func persistedPayload(
        in container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences
    ) throws -> Payload {
        guard container.schema.version == WordNoteSchemaV2.versionIdentifier else { throw WordNoteV2ContentError.wrongSchema }
        guard !container.mainContext.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
        return try Payload.captureForIntegrityInspection(from: container.mainContext, preferences: preferences)
    }

    static func detachingOptionalReferences(in source: Payload, issues: [Issue]) -> Payload {
        var result = source
        let detachments = issues.filter { $0.resolution == .detachMissingOptionalReference }
        let terms = Set(detachments.filter { $0.entity == .term }.map(\.entityID))
        let occurrences = Set(detachments.filter { $0.entity == .occurrence }.map(\.entityID))
        let events = Set(detachments.filter { $0.entity == .lookupEvent }.map(\.entityID))
        for index in result.content.terms.indices where terms.contains(result.content.terms[index].id) {
            result.content.terms[index].sourceRecordID = nil
        }
        for index in result.occurrences.indices where occurrences.contains(result.occurrences[index].id) {
            result.occurrences[index].sourceRecordID = nil
        }
        for index in result.lookupEvents.indices where events.contains(result.lookupEvents[index].id) {
            result.lookupEvents[index].occurrenceID = nil
        }
        return result
    }

    private static func issueOrder(_ lhs: Issue, _ rhs: Issue) -> Bool {
        (lhs.entity.rawValue, lhs.entityID.uuidString, lhs.field, lhs.kind.rawValue, lhs.relatedID?.uuidString ?? "")
            < (rhs.entity.rawValue, rhs.entityID.uuidString, rhs.field, rhs.kind.rawValue, rhs.relatedID?.uuidString ?? "")
    }
}
