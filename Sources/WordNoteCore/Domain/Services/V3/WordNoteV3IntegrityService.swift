import Foundation
import SwiftData

public enum WordNoteV3IntegrityService {
    typealias Issue = WordNoteV3IntegrityIssue
    typealias Payload = WordNoteSnapshotV3Payload

    public static func inspect(_ source: WordNoteSnapshotV3Payload) -> WordNoteV3IntegrityReport {
        let content = WordNoteV2IntegrityService.inspect(source.content)
        let issues = reviewIssues(source).sorted {
            ($0.entity.rawValue, $0.entityID.uuidString, $0.field, $0.kind.rawValue, $0.relatedID?.uuidString ?? "")
                < ($1.entity.rawValue, $1.entityID.uuidString, $1.field, $1.kind.rawValue, $1.relatedID?.uuidString ?? "")
        }
        var detached = source
        detached.content = WordNoteV2IntegrityService.detachingOptionalReferences(in: source.content, issues: content.issues)
        let validationError: WordNoteSnapshotError?
        do { try detached.validate(); validationError = nil }
        catch { validationError = (error as? WordNoteSnapshotError) ?? .invalidValue }
        return .init(content: content, issues: issues, remainingValidationError: validationError)
    }

    public static func prepareRepair(_ source: WordNoteSnapshotV3Payload, at date: Date = Date()) throws -> WordNoteV3IntegrityRepairPlan {
        let report = inspect(source)
        guard !report.requiresManualResolution else { throw WordNoteV3IntegrityError.unresolvedIssues(report) }
        var repaired = source
        // Reuse only the established optional-reference repair; all V3 review values remain intact.
        repaired.content = try WordNoteV2IntegrityService.prepareRepair(source.content, at: date).repairedPayload
        repaired = repaired.canonicalized
        try repaired.validate()
        return .init(report: report, source: source.canonicalized, repairedPayload: repaired)
    }

    @MainActor
    public static func inspect(in container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences = .init()) throws -> WordNoteV3IntegrityReport {
        inspect(try persistedPayload(in: container, preferences: preferences))
    }

    @MainActor
    public static func prepareRepair(in container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences = .init(),
                                     at date: Date = Date()) throws -> WordNoteV3IntegrityRepairPlan {
        try prepareRepair(persistedPayload(in: container, preferences: preferences), at: date)
    }

    @MainActor
    public static func validate(_ plan: WordNoteV3IntegrityRepairPlan, against container: ModelContainer,
                                preferences: WordNoteSnapshotPayload.Preferences = .init()) throws -> WordNoteSnapshotV3Payload {
        try plan.validatedPayload(matching: persistedPayload(in: container, preferences: preferences))
    }

    @MainActor
    private static func persistedPayload(in container: ModelContainer, preferences: WordNoteSnapshotPayload.Preferences) throws -> Payload {
        guard container.schema.version == WordNoteSchemaV3.versionIdentifier else { throw WordNoteV3ContentError.wrongSchema }
        guard !container.mainContext.hasChanges else { throw WordNoteV3ContentError.unsavedChanges }
        return try Payload.captureForIntegrityInspection(from: container.mainContext, preferences: preferences)
    }

    private static func reviewIssues(_ source: Payload) -> [Issue] {
        var issues: [Issue] = []
        let tables: [(Issue.Entity, [UUID])] = [(.card, source.cards.map(\.id)), (.session, source.sessions.map(\.id)),
            (.sessionItem, source.sessionItems.map(\.id)), (.termHistory, source.termHistories.map(\.id)), (.eventState, source.eventStates.map(\.id))]
        for (entity, ids) in tables {
            for (id, values) in Dictionary(grouping: ids, by: { $0 }) where values.count > 1 {
                issues.append(.init(entity: entity, entityID: id, field: "id", kind: .duplicateIdentifier, relatedID: nil))
            }
        }
        for (entity, ids, metadata) in [
            (Issue.Entity.termHistory, source.content.content.terms.map(\.id), source.termHistories.map(\.id)),
            (.eventState, source.content.content.reviewEvents.map(\.id), source.eventStates.map(\.id))
        ] {
            for id in Set(ids).symmetricDifference(Set(metadata)) {
                issues.append(.init(entity: entity, entityID: id, field: "id", kind: .metadataMismatch, relatedID: nil))
            }
        }
        duplicates(source.cards, key: { CardKey(termID: $0.termID, mode: $0.mode, scope: $0.contentScopeKey) }, id: \.id,
                   entity: .card, field: "termID/mode/contentScopeKey", into: &issues)
        duplicates(source.sessionItems, key: { Pair(first: $0.sessionID, second: $0.originalCardID) }, id: \.id,
                   entity: .sessionItem, field: "sessionID/originalCardID", into: &issues)
        duplicates(source.sessionItems, key: { Position(sessionID: $0.sessionID, position: $0.position) }, id: \.id,
                   entity: .sessionItem, field: "sessionID/position", into: &issues)
        duplicates(source.eventStates.filter { $0.actionID != nil }, key: \.actionID, id: \.id,
                   entity: .eventState, field: "actionID", into: &issues)
        inspectReferences(source, into: &issues)
        return issues
    }

    private static func inspectReferences(_ source: Payload, into issues: inout [Issue]) {
        let terms = Set(source.content.content.terms.map(\.id))
        let cards = Dictionary(grouping: source.cards, by: \.id)
        let sessions = Dictionary(grouping: source.sessions, by: \.id)
        let items = Dictionary(grouping: source.sessionItems, by: \.id)
        let sources = Dictionary(grouping: source.content.occurrences, by: \.id)
        let events = Dictionary(grouping: source.content.content.reviewEvents, by: \.id)
        func add(_ entity: Issue.Entity, _ id: UUID, _ field: String, _ kind: Issue.Kind, _ related: UUID? = nil) {
            issues.append(.init(entity: entity, entityID: id, field: field, kind: kind, relatedID: related))
        }
        for card in source.cards {
            if !terms.contains(card.termID) { add(.card, card.id, "termID", .missingReference, card.termID) }
            if card.mode == .contextCloze {
                if let target = card.clozeTarget {
                    if target.sourceDeletedAt == nil {
                        if sources[target.occurrenceID] == nil { add(.card, card.id, "clozeTarget.occurrenceID", .missingReference, target.occurrenceID) }
                        else if sources[target.occurrenceID]?.count == 1, sources[target.occurrenceID]?.first?.termID != card.termID {
                            add(.card, card.id, "clozeTarget.occurrenceID", .mismatchedReference, target.occurrenceID)
                        }
                    }
                } else { add(.card, card.id, "clozeTarget", .invalidState) }
            }
        }
        let resumable = source.sessions.filter { $0.status.isResumable }
        if resumable.count > 1 { resumable.forEach { add(.session, $0.id, "status", .invalidState) } }
        for session in source.sessions {
            if let id = session.currentItemID {
                if items[id] == nil { add(.session, session.id, "currentItemID", .missingReference, id) }
                else if let item = items[id]?.first, items[id]?.count == 1,
                        item.sessionID != session.id || item.status.isTerminal || item.status == .waiting {
                    add(.session, session.id, "currentItemID", .mismatchedReference, id)
                }
            }
        }
        for item in source.sessionItems {
            if sessions[item.sessionID] == nil { add(.sessionItem, item.id, "sessionID", .missingReference, item.sessionID) }
            if let id = item.cardID {
                if cards[id] == nil { add(.sessionItem, item.id, "cardID", .missingReference, id) }
                else if let card = cards[id]?.first, cards[id]?.count == 1,
                        id != item.originalCardID || (!item.status.isTerminal && card.schedule.phase == .suspended)
                        || (sessions[item.sessionID]?.count == 1 && sessions[item.sessionID]?.first?.scope.mode != card.mode) {
                    add(.sessionItem, item.id, "cardID", .mismatchedReference, id)
                }
            } else if item.status != .unavailable { add(.sessionItem, item.id, "cardID", .missingReference, item.originalCardID) }
        }
        for state in source.eventStates {
            if let id = state.cardID {
                if cards[id] == nil { add(.eventState, state.id, "cardID", .missingReference, id) }
                else if let card = cards[id]?.first, let event = events[state.id]?.first,
                        cards[id]?.count == 1, events[state.id]?.count == 1,
                        card.termID != event.termID || card.mode.rawValue != event.modeRaw {
                    add(.eventState, state.id, "cardID", .mismatchedReference, id)
                }
            }
            if state.feedbackSemanticsVersion == 2 {
                if state.actionID == nil { add(.eventState, state.id, "actionID", .missingReference) }
                if state.originalCardID == nil { add(.eventState, state.id, "originalCardID", .missingReference) }
                if state.sessionID == nil || sessions[state.sessionID!] == nil { add(.eventState, state.id, "sessionID", .missingReference, state.sessionID) }
            }
        }
    }

    private struct CardKey: Hashable { let termID: UUID; let mode: ReviewMode; let scope: String }
    private struct Pair: Hashable { let first: UUID; let second: UUID }
    private struct Position: Hashable { let sessionID: UUID; let position: Int }

    private static func duplicates<Value, Key: Hashable>(_ values: [Value], key: (Value) -> Key, id: (Value) -> UUID,
                                                        entity: Issue.Entity, field: String, into issues: inout [Issue]) {
        for group in Dictionary(grouping: values, by: key).values where group.count > 1 {
            for identifier in Set(group.map(id)) {
                issues.append(.init(entity: entity, entityID: identifier, field: field, kind: .duplicateBusinessKey, relatedID: nil))
            }
        }
    }
}
