import Foundation
import Observation

@MainActor
@Observable
public final class WordNoteEditDraft<Value: Equatable> {
    public var value: Value
    public var baseline: Value
    public var revision: Int
    public var isDirty: Bool { value != baseline }

    public init(_ value: Value, revision: Int = 0) {
        self.value = value
        baseline = value
        self.revision = revision
    }
}

/// One window's detached drafts and pending navigation. No persistence or model bindings.
@MainActor
@Observable
public final class WordNoteEditProtection {
    public enum Decision { case save, discard, cancel }

    public struct DraftSummary: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public let preview: String
    }

    private struct Entry {
        let summary: () -> DraftSummary
        let isDirty: () -> Bool
        let save: () throws -> Void
        let discard: () -> Void
        var isAttached = true
    }

    private struct Transition {
        let proceed: () -> Void
        let cancel: () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var transition: Transition?
    private var decision: Decision?
    public private(set) var isPresented = false
    public private(set) var errorMessage: String?
    @ObservationIgnored public var willPresent: (() -> Void)?
    @ObservationIgnored public var didCancel: (() -> Void)?

    public init() {}

    public var drafts: [DraftSummary] { order.compactMap { id in
        guard let entry = entries[id], entry.isDirty() else { return nil }
        return entry.summary()
    } }
    public var hasUnsavedChanges: Bool { entries.values.contains { $0.isDirty() } }
    public var hasPendingTransition: Bool { transition != nil }

    public func detach(_ id: UUID) {
        guard entries[id]?.isDirty() == true else { remove(id); return }
        entries[id]?.isAttached = false
    }

    /// Read the reference-owned value draft at decision time, including the last keystroke.
    public func track(
        id: UUID, title: String, preview: @escaping () -> String, isDirty: @escaping () -> Bool,
        save: @escaping () throws -> Void, discard: @escaping () -> Void
    ) {
        if entries[id] == nil { order.append(id) }
        entries[id] = Entry(summary: { DraftSummary(id: id, title: title, preview: preview()) },
                            isDirty: isDirty, save: save, discard: discard)
    }

    /// A second request must not replace the destination the user is deciding about.
    @discardableResult
    public func request(proceed: @escaping () -> Void, cancel: @escaping () -> Void = {}) -> Bool {
        guard transition == nil else { return false }
        guard hasUnsavedChanges else { proceed(); return true }
        transition = Transition(proceed: proceed, cancel: cancel)
        errorMessage = nil
        decision = nil
        willPresent?()
        isPresented = true
        return true
    }

    public func resolve(_ choice: Decision) {
        guard isPresented, transition != nil else { return }
        do {
            if choice != .cancel {
                for id in order {
                    guard let entry = entries[id], entry.isDirty() else { continue }
                    if choice == .save { try entry.save() } else { entry.discard() }
                    guard !entry.isDirty() else { throw WordNoteV2ContentError.unsavedChanges }
                    if !entry.isAttached { remove(id) }
                }
            }
            decision = choice
            errorMessage = nil
            isPresented = false
        } catch {
            // Earlier successful saves remain saved; all remaining drafts and the destination survive.
            errorMessage = error.localizedDescription
        }
    }

    /// The UI calls this after its sheet has dismissed, before closing or replacing a view.
    public func completeTransition() {
        guard !isPresented, let transition, let decision else { return }
        self.transition = nil
        self.decision = nil
        if decision == .cancel {
            didCancel?()
            transition.cancel()
        } else {
            transition.proceed()
        }
    }

    private func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }
}
