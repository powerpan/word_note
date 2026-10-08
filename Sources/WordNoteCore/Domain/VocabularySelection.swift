import Foundation

public struct VocabularySelection: Equatable, Sendable {
    public var focusedID: UUID?
    public private(set) var batchIDs: Set<UUID> = []
    public private(set) var visibleIDs: [UUID] = []
    public init() {}

    public mutating func reconcile(_ ids: [UUID], scopeChanged: Bool = false) {
        let previousIndex = focusedID.flatMap { visibleIDs.firstIndex(of: $0) } ?? 0
        let visible = Set(ids)
        batchIDs = scopeChanged ? [] : batchIDs.intersection(visible)
        if focusedID.map({ !visible.contains($0) }) ?? true {
            focusedID = ids.isEmpty ? nil : ids[scopeChanged ? 0 : min(previousIndex, ids.count - 1)]
        }
        visibleIDs = ids
    }

    public mutating func setSelected(_ selected: Bool, id: UUID) {
        guard visibleIDs.contains(id) else { return }
        if selected { batchIDs.insert(id) } else { batchIDs.remove(id) }
    }

    public mutating func toggleAll() {
        let visible = Set(visibleIDs)
        batchIDs = !visible.isEmpty && visible.isSubset(of: batchIDs) ? [] : visible
    }

    public mutating func clearBatch() { batchIDs = [] }
}
