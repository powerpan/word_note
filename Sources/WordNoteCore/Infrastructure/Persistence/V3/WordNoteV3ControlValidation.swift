import Foundation

extension WordNoteSnapshotV3Payload {
    var minimumRequiredFormatVersion: Int {
        if sessions.contains(where: { $0.controls != nil }) || eventStates.contains(where: { $0.recordedOrder != nil }) { return 3 }
        if sessions.contains(where: { $0.introductions != nil }) { return 2 }
        return 1
    }

    func validateReviewControls() throws {
        var actionIDs = Set(eventStates.compactMap(\.actionID))
        var recordedOrders = Set<Int>()
        for event in eventStates {
            if let order = event.recordedOrder {
                guard event.feedbackSemanticsVersion == 2, order > 0, recordedOrders.insert(order).inserted else {
                    throw WordNoteSnapshotError.invalidValue
                }
                try ReviewStateValidation.counter(order)
            }
        }
        let items = Dictionary(uniqueKeysWithValues: sessionItems.map { ($0.id, $0) })
        for session in sessions {
            guard let controls = session.controls else { continue }
            guard controls.records.count <= ReviewSessionControls.maximumRecords,
                  Set(controls.skippedItemIDs).count == controls.skippedItemIDs.count else { throw WordNoteSnapshotError.invalidValue }
            for id in controls.skippedItemIDs {
                guard let item = items[id], item.sessionID == session.id,
                      item.status == .presented || item.status.isTerminal,
                      controls.records.contains(where: { $0.itemID == id && $0.kind == .skip }) else { throw WordNoteSnapshotError.missingReference }
            }
            var revisions = Set<Int>()
            for record in controls.records {
                guard actionIDs.insert(record.actionID).inserted, revisions.insert(record.resultingRevision).inserted,
                      let item = items[record.itemID], item.sessionID == session.id, item.originalCardID == record.originalCardID,
                      record.resultingRevision > 0, record.resultingRevision <= session.revision,
                      record.sourceFingerprint.utf8.count == 64,
                      record.sourceFingerprint.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                      record.effectiveAt >= record.performedAt else { throw WordNoteSnapshotError.invalidValue }
                try [record.performedAt, record.effectiveAt, record.postponedUntil].forEach(ReviewStateValidation.date)
                switch record.kind {
                case .skip:
                    guard record.postponedUntil == nil, record.resultingStatus == .active || record.resultingStatus == .paused else {
                        throw WordNoteSnapshotError.invalidValue
                    }
                case .later:
                    guard let due = record.postponedUntil, due > record.effectiveAt,
                          [.active, .waiting, .completed].contains(record.resultingStatus) else { throw WordNoteSnapshotError.invalidValue }
                }
            }
        }
    }
}
