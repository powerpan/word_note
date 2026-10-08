import Foundation
import SwiftData

@MainActor
enum WordNoteV3ReviewOwnership {
    final class State {
        weak var container: ModelContainer?
        var lease: WordNoteV3ReviewLease?
        var revealed: WordNoteV3ReviewAnswerSnapshot?
        init(_ container: ModelContainer) { self.container = container }
    }

    private static var states: [ObjectIdentifier: State] = [:]

    static func acquire(sessionID: UUID, ownerID: UUID, in context: ModelContext) throws -> WordNoteV3ReviewLease {
        let ticket = try WordNoteWriteGate.ticket(for: context)
        let state = state(for: context)
        if let current = state.lease, current.sessionID == sessionID, current.writeTicket == ticket {
            guard current.ownerID == ownerID else { throw WordNoteV3ReviewError.ownershipConflict }
            return current
        }
        // The service has already validated that this is the only resumable session.
        let lease = WordNoteV3ReviewLease(sessionID: sessionID, ownerID: ownerID, id: UUID(), writeTicket: ticket)
        state.lease = lease
        state.revealed = nil
        return lease
    }

    static func require(_ lease: WordNoteV3ReviewLease, in context: ModelContext) throws -> State {
        try WordNoteWriteGate.check(context, ticket: lease.writeTicket)
        let state = state(for: context)
        guard state.lease == lease else { throw WordNoteV3ReviewError.invalidLease }
        return state
    }

    static func release(_ lease: WordNoteV3ReviewLease, in context: ModelContext) {
        let state = state(for: context)
        guard state.lease == lease else { return }
        state.lease = nil
        state.revealed = nil
    }

    static func didSaveAnswer(_ lease: WordNoteV3ReviewLease, ended: Bool, in context: ModelContext) {
        let state = state(for: context)
        guard state.lease == lease else { return }
        state.revealed = nil
        if ended { state.lease = nil }
    }

    private static func state(for context: ModelContext) -> State {
        let container = context.container
        let key = ObjectIdentifier(container)
        if let state = states[key], state.container === container { return state }
        states = states.filter { $0.value.container != nil }
        let state = State(container)
        states[key] = state
        return state
    }
}
