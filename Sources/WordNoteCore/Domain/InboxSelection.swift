import Foundation

public struct InboxSelection: Equatable, Sendable {
    public var focusedID: UUID?
    public private(set) var batchIDs: Set<UUID> = []
    public private(set) var activeIDs: [UUID] = []
    public private(set) var visibleIDs: [UUID] = []
    public private(set) var confirmableIDs: Set<UUID> = []
    public init() {}

    public mutating func reconcile(active: [UUID], handled: [UUID], confirmable: Set<UUID>, scopeChanged: Bool = false) {
        let visible = active + handled
        let oldActive = activeIDs
        let wasActive = focusedID.map { oldActive.contains($0) } ?? false
        let leftActive = wasActive && !(focusedID.map { active.contains($0) } ?? false)
        let keepFocus = focusedID.map { visible.contains($0) && !leftActive } ?? false
        if !keepFocus {
            focusedID = scopeChanged ? visible.first : neighbor(of: focusedID, in: oldActive, remaining: active) ?? visible.first
        }
        activeIDs = active
        visibleIDs = visible
        confirmableIDs = confirmable.intersection(active)
        batchIDs = scopeChanged ? [] : batchIDs.intersection(confirmableIDs)
    }

    public mutating func setSelected(_ selected: Bool, id: UUID) {
        guard confirmableIDs.contains(id) else { return }
        if selected { batchIDs.insert(id) } else { batchIDs.remove(id) }
    }

    public mutating func toggleAll() {
        batchIDs = !confirmableIDs.isEmpty && confirmableIDs.isSubset(of: batchIDs) ? [] : confirmableIDs
    }

    public mutating func clearBatch() { batchIDs = [] }

    private func neighbor(of id: UUID?, in previous: [UUID], remaining: [UUID]) -> UUID? {
        guard let id, let index = previous.firstIndex(of: id) else { return nil }
        let available = Set(remaining)
        return previous.dropFirst(index + 1).first { available.contains($0) }
            ?? previous.prefix(index).reversed().first { available.contains($0) }
    }
}

public struct InboxCandidateSelection: Equatable, Sendable {
    public private(set) var selectedIDs: Set<UUID> = []
    public private(set) var pendingIDs: Set<UUID> = []
    private var initialized = false
    public init() {}

    public mutating func reconcile(_ candidates: [WordNoteSnapshotPayload.Candidate]) {
        let pending = candidates.filter { $0.statusRaw == "pending" }
        pendingIDs = Set(pending.map(\.id))
        if !initialized && !pending.isEmpty {
            selectedIDs = Set(pending.filter { $0.needToLearn && $0.importanceRaw != Importance.low.rawValue }.map(\.id))
            initialized = true
        } else { selectedIDs.formIntersection(pendingIDs) }
    }

    public mutating func select(_ ids: Set<UUID>) { initialized = true; selectedIDs = ids.intersection(pendingIDs) }
    public mutating func toggleAll() { select(pendingIDs.isSubset(of: selectedIDs) ? [] : pendingIDs) }
}
