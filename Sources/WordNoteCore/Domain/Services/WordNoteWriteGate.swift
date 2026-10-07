import Foundation
import SwiftData

public enum WordNoteWriteError: LocalizedError, Equatable {
    case restoreInProgress
    case expiredOperation

    public var errorDescription: String? {
        switch self {
        case .restoreInProgress: "Data changes are paused while a restore is being prepared."
        case .expiredOperation: "This operation belongs to an earlier data session and was not saved."
        }
    }
}

@MainActor
public enum WordNoteWriteGate {
    public struct Ticket: Equatable, Sendable { fileprivate let id: UUID }

    private final class State {
        weak var container: ModelContainer?
        var ticket = Ticket(id: UUID())
        var blocked = false
        init(_ container: ModelContainer) { self.container = container }
    }

    private static var states: [ObjectIdentifier: State] = [:]

    public static func check(_ context: ModelContext, ticket: Ticket? = nil) throws {
        let state = state(for: context)
        guard !state.blocked else { throw WordNoteWriteError.restoreInProgress }
        if let ticket, ticket != state.ticket { throw WordNoteWriteError.expiredOperation }
    }

    public static func ticket(for context: ModelContext) throws -> Ticket {
        try check(context)
        return state(for: context).ticket
    }

    public static func isBlocked(_ context: ModelContext) -> Bool { state(for: context).blocked }

    public static func beginRestore(_ context: ModelContext) throws -> Ticket {
        try check(context)
        let state = state(for: context)
        state.ticket = Ticket(id: UUID())
        state.blocked = true
        return state.ticket
    }

    public static func endRestore(_ context: ModelContext, ticket: Ticket) throws {
        let state = state(for: context)
        guard state.blocked, state.ticket == ticket else { throw WordNoteWriteError.expiredOperation }
        state.ticket = Ticket(id: UUID())
        state.blocked = false
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
