import Foundation

extension WordNoteSnapshotV2Payload {
    public func validate() throws {
        try content.validate()
        guard counts.total <= WordNoteSnapshotPayload.maximumEntityCount else {
            throw WordNoteSnapshotError.sizeLimit
        }
        let courses = try indexed(content.courses, by: \.id)
        let records = try indexed(content.inputRecords, by: \.id)
        let candidates = try indexed(content.candidates, by: \.id)
        let terms = try indexed(content.terms, by: \.id)
        let recordMetadata = try indexed(recordStates, by: \.id)
        let candidateMetadata = try indexed(candidateStates, by: \.id)
        let termMetadata = try indexed(termStates, by: \.id)
        let courseMetadata = try indexed(courseRevisions, by: \.id)
        guard Set(records.keys) == Set(recordMetadata.keys), Set(candidates.keys) == Set(candidateMetadata.keys),
              Set(terms.keys) == Set(termMetadata.keys), Set(courses.keys) == Set(courseMetadata.keys) else {
            throw WordNoteSnapshotError.missingReference
        }
        _ = try indexed(recordStates, by: \.captureID)
        for state in courseRevisions { try counter(state.revision) }
        for state in termStates {
            try counter(state.revision)
            let _: TermCounterSemanticsVersion = try snapshotEnum(state.counterSemanticsVersionRaw)
        }
        for state in recordStates {
            try counter(state.revision)
            try counter(state.analysisGeneration)
            let intent: LookupIntent = try snapshotEnum(state.lookupIntentRaw)
            let _: CaptureSurface = try snapshotEnum(state.capturedViaRaw)
            let direction: LookupDirection = try snapshotEnum(state.resolvedLookupDirectionRaw)
            let queue: AnalysisQueueState = try snapshotEnum(state.queueStateRaw)
            guard (0...2).contains(state.autoRetryCount),
                  queue != .running || state.attemptID != nil,
                  state.nextAttemptAt == nil || queue == .queued || queue == .failed || queue == .cancelled,
                  records[state.id]?.statusRaw != InputRecordStatus.analyzing.rawValue,
                  records[state.id]?.statusRaw != InputRecordStatus.failed.rawValue else {
                throw WordNoteSnapshotError.invalidValue
            }
            if intent == .auto {
                guard state.directionDetectorVersion == LookupDirectionDetectorV1.version else {
                    throw WordNoteSnapshotError.invalidValue
                }
            } else {
                guard state.directionDetectorVersion == "explicit-v1", intent.rawValue == direction.rawValue else {
                    throw WordNoteSnapshotError.invalidValue
                }
            }
            try date(state.nextAttemptAt)
        }
        for state in candidateStates {
            try counter(state.revision)
            try counter(state.analysisGeneration)
            guard let candidate = candidates[state.id],
                  let record = recordMetadata[candidate.inputRecordID],
                  state.analysisGeneration <= record.analysisGeneration else {
                throw WordNoteSnapshotError.invalidValue
            }
            let link: CandidateSavedLinkState = try snapshotEnum(state.savedLinkStateRaw)
            if candidate.statusRaw == CandidateStatus.saved.rawValue {
                switch link {
                case .resolved:
                    guard let id = state.savedTermID, terms[id] != nil else {
                        throw WordNoteSnapshotError.missingReference
                    }
                case .unresolvedLegacy, .targetDeleted:
                    guard state.savedTermID == nil else { throw WordNoteSnapshotError.invalidValue }
                case .none:
                    throw WordNoteSnapshotError.invalidValue
                }
            } else {
                guard link == .none, state.savedTermID == nil, state.confirmationOperationID == nil else {
                    throw WordNoteSnapshotError.invalidValue
                }
            }
        }
        let sources = try indexed(occurrences, by: \.id)
        _ = try indexed(occurrences) { Pair(first: $0.termID, second: $0.captureID) }
        for source in occurrences {
            guard terms[source.termID] != nil,
                  source.courseID.map({ courses[$0] != nil }) ?? true,
                  source.sourceRecordID.map({ recordMetadata[$0]?.captureID == source.captureID
                      && recordMetadata[$0]?.capturedViaRaw == source.capturedViaRaw }) ?? true else {
                throw WordNoteSnapshotError.missingReference
            }
            let _: SourceType = try snapshotEnum(source.sourceTypeRaw)
            let surface: CaptureSurface = try snapshotEnum(source.capturedViaRaw)
            guard source.legacy == (surface == .legacy) else { throw WordNoteSnapshotError.invalidValue }
            try texts([source.rawTextSnapshot, source.note, source.sourceTitle, source.sourceURL, source.sourcePage])
            try date(source.occurredAt)
            try date(source.createdAt)
        }
        _ = try indexed(courseLinks, by: \.id)
        _ = try indexed(courseLinks) { Pair(first: $0.termID, second: $0.courseID) }
        for link in courseLinks {
            guard terms[link.termID] != nil, courses[link.courseID] != nil else {
                throw WordNoteSnapshotError.missingReference
            }
            try date(link.createdAt)
        }
        _ = try indexed(lookupEvents, by: \.id)
        _ = try indexed(lookupEvents) { Pair(first: $0.termID, second: $0.captureID) }
        for event in lookupEvents {
            guard terms[event.termID] != nil else { throw WordNoteSnapshotError.missingReference }
            if let id = event.occurrenceID {
                guard let source = sources[id], source.termID == event.termID, source.captureID == event.captureID else {
                    throw WordNoteSnapshotError.missingReference
                }
            }
            let _: LookupEventKind = try snapshotEnum(event.kindRaw)
            try date(event.occurredAt)
            try date(event.createdAt)
        }
    }

    private struct Pair: Hashable {
        let first: UUID
        let second: UUID
    }

    private func indexed<T, Key: Hashable>(_ values: [T], by key: (T) -> Key) throws -> [Key: T] {
        var result: [Key: T] = [:]
        for value in values {
            guard result.updateValue(value, forKey: key(value)) == nil else { throw WordNoteSnapshotError.duplicateID }
        }
        return result
    }

    private func counter(_ value: Int) throws {
        guard (0...1_000_000_000).contains(value) else { throw WordNoteSnapshotError.invalidValue }
    }

    private func date(_ value: Date?) throws {
        guard let value else { return }
        guard value.timeIntervalSince1970.isFinite, abs(value.timeIntervalSince1970) < 100_000_000_000 else {
            throw WordNoteSnapshotError.invalidValue
        }
    }

    private func texts(_ values: [String?]) throws {
        guard values.allSatisfy({ ($0?.count ?? 0) <= WordNoteSnapshotPayload.maximumTextCharacters }) else {
            throw WordNoteSnapshotError.sizeLimit
        }
    }
}
