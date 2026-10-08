import Foundation
import SwiftData

/// Reuses validated values, not live models. Every mutation still validates the complete graph.
@MainActor
final class WordNoteV3TransactionState {
    private typealias V3 = WordNoteSchemaV3
    private typealias Payload = WordNoteSnapshotV3Payload
    private static var states: [ObjectIdentifier: WordNoteV3TransactionState] = [:]
    private weak var context: ModelContext?
    private let saves: V3SaveCounter
    private var payload: Payload?
    private var revision: UInt64?
    private var identities: [PersistentIdentifier: UUID] = [:]
    private(set) var fullReadCount = 0

    static func shared(for context: ModelContext) -> WordNoteV3TransactionState {
        let key = ObjectIdentifier(context)
        if let state = states[key], state.context === context { return state }
        states = states.filter { $0.value.context != nil }
        let state = WordNoteV3TransactionState(context: context)
        states[key] = state
        return state
    }

    private init(context: ModelContext) {
        self.context = context
        saves = V3SaveCounter(container: context.container)
    }

    func validatedSnapshot() throws -> WordNoteSnapshotV3Payload {
        guard let context else { throw WordNoteWriteError.expiredOperation }
        if let payload, revision == saves.revision {
            if !context.hasChanges { return payload }
            let value = try applyingChanges(to: payload, in: context)
            try value.validate()
            return value
        }
        guard !context.hasChanges else { throw WordNoteV3ContentError.unsavedChanges }
        let before = saves.revision
        let value = try Payload.capture(from: context)
        var identifiers: [PersistentIdentifier: UUID] = [:]
        func collect<Model: PersistentModel>(_ type: Model.Type, _ id: KeyPath<Model, UUID>) throws {
            for model in try context.fetch(FetchDescriptor<Model>()) {
                identifiers[model.persistentModelID] = model[keyPath: id]
            }
        }
        try collect(V3.CourseModel.self, \.id)
        try collect(V3.InputRecordModel.self, \.id)
        try collect(V3.CandidateTermModel.self, \.id)
        try collect(V3.TermModel.self, \.id)
        try collect(V3.ReviewEventModel.self, \.id)
        try collect(V3.TermOccurrenceModel.self, \.id)
        try collect(V3.TermCourseLinkModel.self, \.id)
        try collect(V3.LookupEventModel.self, \.id)
        try collect(V3.ReviewCardModel.self, \.id)
        try collect(V3.ReviewSessionModel.self, \.id)
        try collect(V3.ReviewSessionItemModel.self, \.id)
        guard before == saves.revision else { throw WordNoteWriteError.expiredOperation }
        payload = value
        identities = identifiers
        revision = before
        fullReadCount += 1
        return value
    }

    func save() throws {
        guard let context, let revision, revision == saves.revision else { throw WordNoteWriteError.expiredOperation }
        context.processPendingChanges()
        let value = try validatedSnapshot()
        let removed = context.deletedModelsArray.map(\.persistentModelID)
        let removedIDs = Set(removed)
        let changed = try (context.insertedModelsArray + context.changedModelsArray)
            .filter { !removedIDs.contains($0.persistentModelID) }.map { (model: $0, id: try entityID($0)) }
        let oldIDs = changed.map { $0.model.persistentModelID }
        guard revision == saves.revision else { throw WordNoteWriteError.expiredOperation }
        try context.save()
        // A reentrant or another-context save is not part of this receipt.
        let savedRevision = revision &+ 2
        guard saves.revision == savedRevision, !context.hasChanges else {
            invalidate()
            return
        }
        for id in removed + oldIDs { identities.removeValue(forKey: id) }
        for change in changed { identities[change.model.persistentModelID] = change.id }
        payload = value
        self.revision = savedRevision
    }

    func invalidate() {
        payload = nil
        revision = nil
        identities = [:]
    }

    private func applyingChanges(to source: Payload, in context: ModelContext) throws -> Payload {
        context.processPendingChanges()
        let deleted = context.deletedModelsArray
        let deletedIDs = Set(deleted.map(\.persistentModelID))
        var seen = Set<PersistentIdentifier>()
        let changed = (context.insertedModelsArray + context.changedModelsArray).filter {
            !deletedIDs.contains($0.persistentModelID) && seen.insert($0.persistentModelID).inserted
        }
        for model in changed + deleted { _ = try entityID(model) }

        func update<Model: PersistentModel, Value>(
            _ values: inout [Value], _ type: Model.Type, _ id: KeyPath<Value, UUID>,
            _ transform: (Model) throws -> Value
        ) throws {
            let updated = changed.compactMap { $0 as? Model }
            let removed = deleted.compactMap { $0 as? Model }
            guard !updated.isEmpty || !removed.isEmpty else { return }
            let oldIDs = Set((updated + removed).compactMap { identities[$0.persistentModelID] })
            values.removeAll { oldIDs.contains($0[keyPath: id]) }
            values.append(contentsOf: try updated.map(transform))
        }

        var value = source
        try update(&value.content.content.courses, V3.CourseModel.self, \.id, WordNoteSnapshotPayload.Course.init)
        try update(&value.content.courseRevisions, V3.CourseModel.self, \.id, WordNoteSnapshotV2Payload.CourseRevision.init)
        try update(&value.content.content.inputRecords, V3.InputRecordModel.self, \.id, WordNoteSnapshotPayload.InputRecord.init)
        try update(&value.content.recordStates, V3.InputRecordModel.self, \.id, WordNoteSnapshotV2Payload.RecordState.init)
        try update(&value.content.content.candidates, V3.CandidateTermModel.self, \.id, WordNoteSnapshotPayload.Candidate.init)
        try update(&value.content.candidateStates, V3.CandidateTermModel.self, \.id, WordNoteSnapshotV2Payload.CandidateState.init)
        try update(&value.content.content.terms, V3.TermModel.self, \.id, WordNoteSnapshotPayload.Term.init)
        try update(&value.content.termStates, V3.TermModel.self, \.id, WordNoteSnapshotV2Payload.TermState.init)
        try update(&value.termHistories, V3.TermModel.self, \.id, Payload.TermHistory.init)
        try update(&value.content.content.reviewEvents, V3.ReviewEventModel.self, \.id, WordNoteSnapshotPayload.ReviewEvent.init)
        try update(&value.eventStates, V3.ReviewEventModel.self, \.id, Payload.EventState.init)
        try update(&value.content.occurrences, V3.TermOccurrenceModel.self, \.id, WordNoteSnapshotV2Payload.Occurrence.init)
        try update(&value.content.courseLinks, V3.TermCourseLinkModel.self, \.id, WordNoteSnapshotV2Payload.CourseLink.init)
        try update(&value.content.lookupEvents, V3.LookupEventModel.self, \.id, WordNoteSnapshotV2Payload.LookupEvent.init)
        try update(&value.cards, V3.ReviewCardModel.self, \.id, Payload.Card.init)
        try update(&value.sessions, V3.ReviewSessionModel.self, \.id, Payload.Session.init)
        try update(&value.sessionItems, V3.ReviewSessionItemModel.self, \.id, Payload.SessionItem.init)
        return value
    }

    private func entityID(_ model: any PersistentModel) throws -> UUID {
        switch model {
        case let value as V3.CourseModel: value.id
        case let value as V3.InputRecordModel: value.id
        case let value as V3.CandidateTermModel: value.id
        case let value as V3.TermModel: value.id
        case let value as V3.ReviewEventModel: value.id
        case let value as V3.TermOccurrenceModel: value.id
        case let value as V3.TermCourseLinkModel: value.id
        case let value as V3.LookupEventModel: value.id
        case let value as V3.ReviewCardModel: value.id
        case let value as V3.ReviewSessionModel: value.id
        case let value as V3.ReviewSessionItemModel: value.id
        default: throw WordNoteV3ContentError.wrongSchema
        }
    }
}

/// Counts synchronously on the saving executor, including saves outside the MainActor writer.
private final class V3SaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    var revision: UInt64 { lock.withLock { value } }

    init(container: ModelContainer) {
        observers = [ModelContext.willSave, ModelContext.didSave].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self, weak container] notification in
                guard let self, let container, let context = notification.object as? ModelContext,
                      context.container === container else { return }
                self.lock.withLock { self.value &+= 1 }
            }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
