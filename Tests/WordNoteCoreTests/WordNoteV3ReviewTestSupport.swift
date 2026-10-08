import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum V3ReviewTestSupport {
    typealias Payload = WordNoteSnapshotV3Payload
    static let now = V3TestSupport.date.addingTimeInterval(1200)
    enum Failure: Error { case save }

    static func payload(relearningRepeat: Int? = nil, pending: Bool = false) throws -> Payload {
        var value = try relearningRepeat == nil ? V3TestSupport.payload() : V3TestSupport.reviewedPayload()
        let index: Int
        if let count = relearningRepeat {
            index = try XCTUnwrap(value.cards.firstIndex { $0.schedule.phase == .relearning })
            value.cards[index].schedule.relearningRepeatCount = count - 1
            value.sessionItems[0].status = .presented
            value.sessionItems[0].availableAt = nil
            value.sessionItems[0].updatedAt = now
            value.sessions[0].status = .active
            value.sessions[0].currentItemID = value.sessionItems[0].id
        } else {
            let termID = try XCTUnwrap(value.content.content.terms.first { $0.term == "quick" }).id
            index = try XCTUnwrap(value.cards.firstIndex { $0.termID == termID })
            let sessionID = UUID(), itemID = UUID()
            value.sessions = [.init(id: sessionID, scope: .init(studyTimeZoneID: "Asia/Hong_Kong"), targetCardCount: 20,
                newCardLimitSnapshot: 10, status: .active, currentItemID: itemID, createdAt: now, updatedAt: now, endedAt: nil, revision: 0)]
            value.sessionItems = [.init(id: itemID, sessionID: sessionID, cardID: value.cards[index].id, originalCardID: value.cards[index].id,
                position: 0, status: .presented, attemptCount: 0, availableAt: nil, lastActionID: nil, completionOutcome: nil,
                createdAt: now, updatedAt: now)]
        }
        let card = value.cards[index]
        value.cards[index].schedule = try ReviewCardScheduler().presentation(for: card.schedule, at: now,
            studyTimeZoneID: "Asia/Hong_Kong", lastInteractionAt: card.updatedAt).after
        value.cards[index].revision += 1
        value.cards[index].updatedAt = now
        if pending {
            let other = try XCTUnwrap(value.cards.first { $0.id != card.id && $0.mode == card.mode })
            value.sessionItems.append(.init(id: UUID(), sessionID: value.sessions[0].id, cardID: other.id, originalCardID: other.id,
                position: 1, status: .pending, attemptCount: 0, availableAt: nil, lastActionID: nil, completionOutcome: nil,
                createdAt: now, updatedAt: now))
        }
        try value.validate()
        return value.canonicalized
    }

    static func seeded(_ payload: Payload) throws -> ModelContainer {
        let container = try V3TestSupport.container()
        try payload.populateEmptyStore(container.mainContext)
        return container
    }

    static func snapshot(_ container: ModelContainer, original: Payload) throws -> Payload {
        try Payload.capture(from: container.mainContext, preferences: original.content.content.preferences)
    }

    static func reveal(_ service: WordNoteV3ReviewService, sessionID: UUID, at date: Date = now) throws -> WordNoteV3ReviewLease {
        let lease = try service.acquireLease(sessionID: sessionID, ownerID: UUID())
        let source = try service.currentAnswerSnapshot(sessionID: sessionID)
        _ = try service.revealAnswer(source, lease: lease, at: date)
        return lease
    }
}
