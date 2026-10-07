import Foundation

extension WordNoteV2IntegrityService {
    static func inspectRelationships(_ source: Payload, into issues: inout [Issue]) {
        let courses = Set(source.content.courses.map(\.id))
        let records = Set(source.content.inputRecords.map(\.id))
        let terms = Set(source.content.terms.map(\.id))
        let occurrences = Set(source.occurrences.map(\.id))
        let statesByID = Dictionary(grouping: source.recordStates, by: \.id)
        let sourcesByID = Dictionary(grouping: source.occurrences, by: \.id)

        func reference(
            _ id: UUID?, in identifiers: Set<UUID>, entity: Issue.Entity, entityID: UUID, field: String,
            detachable: Bool = false
        ) {
            guard let id, !identifiers.contains(id) else { return }
            issues.append(Issue(entity: entity, entityID: entityID, field: field, kind: .missingReference, relatedID: id,
                                resolution: detachable ? .detachMissingOptionalReference : .manualResolutionRequired))
        }
        for record in source.content.inputRecords {
            reference(record.courseID, in: courses, entity: .inputRecord, entityID: record.id, field: "courseID")
        }
        for term in source.content.terms {
            reference(term.courseID, in: courses, entity: .term, entityID: term.id, field: "courseID")
            reference(term.sourceRecordID, in: records, entity: .term, entityID: term.id, field: "sourceRecordID", detachable: true)
        }
        for candidate in source.content.candidates {
            reference(candidate.inputRecordID, in: records, entity: .candidate, entityID: candidate.id, field: "inputRecordID")
        }
        for state in source.candidateStates {
            reference(state.savedTermID, in: terms, entity: .candidate, entityID: state.id, field: "savedTermID")
        }
        for event in source.content.reviewEvents {
            reference(event.termID, in: terms, entity: .reviewEvent, entityID: event.id, field: "termID")
        }
        for occurrence in source.occurrences {
            reference(occurrence.termID, in: terms, entity: .occurrence, entityID: occurrence.id, field: "termID")
            reference(occurrence.courseID, in: courses, entity: .occurrence, entityID: occurrence.id, field: "courseID")
            reference(occurrence.sourceRecordID, in: records, entity: .occurrence, entityID: occurrence.id, field: "sourceRecordID", detachable: true)
            if let recordID = occurrence.sourceRecordID, let states = statesByID[recordID], states.count == 1,
               states[0].captureID != occurrence.captureID || states[0].capturedViaRaw != occurrence.capturedViaRaw {
                issues.append(Issue(entity: .occurrence, entityID: occurrence.id, field: "sourceRecordID", kind: .mismatchedReference,
                                    relatedID: recordID, resolution: .manualResolutionRequired))
            }
        }
        for link in source.courseLinks {
            reference(link.termID, in: terms, entity: .courseLink, entityID: link.id, field: "termID")
            reference(link.courseID, in: courses, entity: .courseLink, entityID: link.id, field: "courseID")
        }
        for event in source.lookupEvents {
            reference(event.termID, in: terms, entity: .lookupEvent, entityID: event.id, field: "termID")
            reference(event.occurrenceID, in: occurrences, entity: .lookupEvent, entityID: event.id, field: "occurrenceID", detachable: true)
            if let sourceID = event.occurrenceID, let matches = sourcesByID[sourceID], matches.count == 1,
               matches[0].termID != event.termID || matches[0].captureID != event.captureID {
                issues.append(Issue(entity: .lookupEvent, entityID: event.id, field: "occurrenceID", kind: .mismatchedReference,
                                    relatedID: sourceID, resolution: .manualResolutionRequired))
            }
        }
    }

    static func inspectCandidates(_ source: Payload, into issues: inout [Issue]) {
        let candidatesByID = Dictionary(grouping: source.content.candidates, by: \.id)
        for state in source.candidateStates {
            guard let candidates = candidatesByID[state.id], candidates.count == 1 else { continue }
            let candidate = candidates[0]
            let valid: Bool
            if candidate.statusRaw == "saved" {
                switch CandidateSavedLinkState(rawValue: state.savedLinkStateRaw) {
                case .resolved: valid = state.savedTermID != nil
                case .unresolvedLegacy, .targetDeleted: valid = state.savedTermID == nil
                default: valid = false
                }
            } else {
                valid = state.savedLinkStateRaw == "none" && state.savedTermID == nil && state.confirmationOperationID == nil
            }
            if !valid {
                issues.append(Issue(entity: .candidate, entityID: state.id, field: "savedLinkStateRaw", kind: .invalidCandidateState,
                                    relatedID: state.savedTermID, resolution: .manualResolutionRequired))
            } else if candidate.statusRaw == "saved", state.savedLinkStateRaw == "unresolvedLegacy" {
                issues.append(Issue(entity: .candidate, entityID: state.id, field: "savedTermID", kind: .unresolvedSavedCandidate,
                                    relatedID: nil, resolution: .warning))
            }
        }
    }

    static func inspectIdentifiers(_ source: Payload, into issues: inout [Issue]) {
        let tables: [(Issue.Entity, [UUID])] = [
            (.course, source.content.courses.map(\.id)), (.inputRecord, source.content.inputRecords.map(\.id)),
            (.candidate, source.content.candidates.map(\.id)), (.term, source.content.terms.map(\.id)),
            (.reviewEvent, source.content.reviewEvents.map(\.id)), (.occurrence, source.occurrences.map(\.id)),
            (.courseLink, source.courseLinks.map(\.id)), (.lookupEvent, source.lookupEvents.map(\.id)),
            (.courseRevision, source.courseRevisions.map(\.id)), (.recordState, source.recordStates.map(\.id)),
            (.candidateState, source.candidateStates.map(\.id)), (.termState, source.termStates.map(\.id))
        ]
        for (entity, ids) in tables {
            for (id, group) in Dictionary(grouping: ids, by: { $0 }) where group.count > 1 {
                issues.append(Issue(entity: entity, entityID: id, field: "id", kind: .duplicateIdentifier, relatedID: nil, resolution: .manualResolutionRequired))
            }
        }
        let metadata: [(Issue.Entity, [UUID], [UUID])] = [
            (.courseRevision, source.content.courses.map(\.id), source.courseRevisions.map(\.id)),
            (.recordState, source.content.inputRecords.map(\.id), source.recordStates.map(\.id)),
            (.candidateState, source.content.candidates.map(\.id), source.candidateStates.map(\.id)),
            (.termState, source.content.terms.map(\.id), source.termStates.map(\.id))
        ]
        for (entity, actual, expected) in metadata {
            for id in Set(actual).symmetricDifference(Set(expected)) {
                issues.append(Issue(entity: entity, entityID: id, field: "id", kind: .metadataMismatch, relatedID: nil, resolution: .manualResolutionRequired))
            }
        }
        duplicates(source.recordStates, key: \.captureID, id: \.id, entity: .inputRecord, field: "captureID", into: &issues)
        duplicates(source.occurrences, key: { Pair($0.termID, $0.captureID) }, id: \.id, entity: .occurrence, field: "termID/captureID", into: &issues)
        duplicates(source.courseLinks, key: { Pair($0.termID, $0.courseID) }, id: \.id, entity: .courseLink, field: "termID/courseID", into: &issues)
        duplicates(source.lookupEvents, key: { Pair($0.termID, $0.captureID) }, id: \.id, entity: .lookupEvent, field: "termID/captureID", into: &issues)
    }

    private struct Pair: Hashable {
        let first: UUID
        let second: UUID
        init(_ first: UUID, _ second: UUID) { self.first = first; self.second = second }
    }

    private static func duplicates<Value, Key: Hashable>(
        _ values: [Value], key: (Value) -> Key, id: (Value) -> UUID,
        entity: Issue.Entity, field: String, into issues: inout [Issue]
    ) {
        for group in Dictionary(grouping: values, by: key).values where group.count > 1 {
            for identifier in Set(group.map(id)) {
                issues.append(Issue(entity: entity, entityID: identifier, field: field, kind: .duplicateBusinessKey,
                                    relatedID: nil, resolution: .manualResolutionRequired))
            }
        }
    }
}
