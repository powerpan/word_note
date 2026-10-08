import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3ReviewGuardTests: XCTestCase {
    private typealias Support = V3ReviewTestSupport

    func testOwnershipIsSharedAcrossServicesButNotIndependentContainers() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let first = try WordNoteV3ReviewService(container: container)
        let second = try WordNoteV3ReviewService(container: container)
        let owner = UUID(), sessionID = original.sessions[0].id
        let lease = try first.acquireLease(sessionID: sessionID, ownerID: owner)
        XCTAssertEqual(try second.acquireLease(sessionID: sessionID, ownerID: owner), lease)
        XCTAssertThrowsError(try second.acquireLease(sessionID: sessionID, ownerID: UUID())) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .ownershipConflict)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), original)
        let otherContainer = try Support.seeded(original)
        XCTAssertNoThrow(try WordNoteV3ReviewService(container: otherContainer).acquireLease(sessionID: sessionID, ownerID: UUID()))
    }

    func testReleaseRevokesRevealAndDelayedOldReleaseCannotReleaseNewOwner() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let old = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: old, at: Support.now)
        service.releaseLease(old)
        let owner = UUID()
        let new = try service.acquireLease(sessionID: old.sessionID, ownerID: owner)
        service.releaseLease(old)
        XCTAssertEqual(try service.acquireLease(sessionID: old.sessionID, ownerID: owner), new)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: old, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .invalidLease)
        }
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: new, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
    }

    func testRestoreEpochExpiresOldLeaseAndNewOwnerMustRevealAgain() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let old = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: old, at: Support.now)
        let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: old, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteWriteError, .restoreInProgress)
        }
        try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: old, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteWriteError, .expiredOperation)
        }
        let new = try service.acquireLease(sessionID: old.sessionID, ownerID: UUID())
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: new, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
    }

    func testClosedPreviousSessionDoesNotKeepAStaleOwnerLockOnNextSession() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let old = try service.acquireLease(sessionID: original.sessions[0].id, ownerID: UUID())
        let model = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
        model.statusRaw = "ended"
        model.currentItemID = nil
        model.endedAt = Support.now
        let next = WordNoteSchemaV3.ReviewSessionModel(scopeSnapshotJSON: model.scopeSnapshotJSON, createdAt: Support.now)
        container.mainContext.insert(next)
        try container.mainContext.save()
        let lease = try service.acquireLease(sessionID: next.id, ownerID: UUID())
        XCTAssertNotEqual(lease, old)
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: old, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .invalidLease)
        }
    }

    func testCannotPreviewOrRecordAnUnrevealedAnswer() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try service.acquireLease(sessionID: original.sessions[0].id, ownerID: UUID())
        let source = try service.currentAnswerSnapshot(sessionID: lease.sessionID)
        XCTAssertThrowsError(try service.previewFeedback(.good, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
        let plan = try ReviewCardScheduler().feedback(.good, for: source.card.schedule, at: Support.now,
            studyTimeZoneID: source.session.scope.studyTimeZoneID, lastInteractionAt: source.card.updatedAt)
        let preview = WordNoteV3FeedbackPreview(source: source, plan: plan, leaseID: lease.id)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .answerNotRevealed)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), original)
    }

    func testInactiveOrNotYetPresentedItemCannotBeScoredByImplicitPresentation() throws {
        for state in ["pending", "paused", "ended"] {
            var original = try Support.payload()
            if state == "pending" { original.sessionItems[0].status = .pending }
            else if state == "paused" { original.sessions[0].status = .paused }
            else {
                original.sessions[0].status = .ended
                original.sessions[0].currentItemID = nil
                original.sessions[0].endedAt = Support.now
            }
            let container = try Support.seeded(original)
            let service = try WordNoteV3ReviewService(container: container)
            XCTAssertThrowsError(try service.currentAnswerSnapshot(sessionID: original.sessions[0].id)) {
                XCTAssertEqual($0 as? WordNoteV3ReviewError, .noActivePresentedItem)
            }
            XCTAssertEqual(try Support.snapshot(container, original: original), original)
        }
    }

    func testUncommittedDraftIsNeitherSavedNorRolledBackByAnswerOperations() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let saved = try Support.snapshot(container, original: original)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first)
        term.chineseMeaning = "unsaved edit"
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ContentError, .unsavedChanges)
        }
        XCTAssertEqual(term.chineseMeaning, "unsaved edit")
        XCTAssertTrue(container.mainContext.hasChanges)
        container.mainContext.rollback()
        XCTAssertEqual(try Support.snapshot(container, original: original), saved)
        XCTAssertNoThrow(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now))
    }

    func testFullSnapshotRejectsChangedContentCardItemOrSessionEvenWithoutRevisionBump() throws {
        for dependency in ["term", "card", "item", "session", "termRevision"] {
            let original = try Support.payload()
            let container = try Support.seeded(original)
            let service = try WordNoteV3ReviewService(container: container)
            let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
            let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
            switch dependency {
            case "term", "termRevision":
                let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first { $0.id == preview.source.term.id })
                if dependency == "term" { term.chineseMeaning = "changed without revision" }
                else { term.revision += 1 }
            case "card":
                let card = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first { $0.id == preview.source.card.id })
                card.intervalDays += 1
            case "item":
                let item = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionItemModel>()).first)
                item.position += 1
            default:
                let session = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
                session.targetCardCount += 1
            }
            try container.mainContext.save()
            let changed = try Support.snapshot(container, original: original)
            XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)) {
                XCTAssertEqual($0 as? WordNoteV3ReviewError, .stalePreview)
            }
            XCTAssertEqual(try Support.snapshot(container, original: original), changed)
        }
    }

    func testUnrelatedTermEditDoesNotInvalidateCurrentAnswer() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first { $0.id != preview.source.term.id })
        term.chineseMeaning = "unrelated edit"
        term.revision += 1
        try container.mainContext.save()
        XCTAssertNoThrow(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now))
        XCTAssertEqual(term.chineseMeaning, "unrelated edit")
    }

    func testNewLookupAfterPreviewIsPreservedAndRequiresNewAnswerSnapshot() throws {
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        _ = try WordNoteV3ContentService(container: container).capture(.init(rawText: preview.source.term.term), at: Support.now.addingTimeInterval(1))
        let queried = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now.addingTimeInterval(2))) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .stalePreview)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), queried)
    }

    func testSaveFailureRollsBackAllFourEntitiesAndRetainsSameActionRetry() throws {
        let original = try Support.payload(pending: true)
        let container = try Support.seeded(original)
        var fail = false
        let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in if fail { throw Support.Failure.save } })
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.again, lease: lease, at: Support.now)
        let actionID = UUID(), before = try Support.snapshot(container, original: original)
        fail = true
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? Support.Failure, .save)
        }
        XCTAssertEqual(try Support.snapshot(container, original: original), before)
        XCTAssertFalse(container.mainContext.hasChanges)
        XCTAssertNil(try service.feedbackReceipt(actionID: actionID))
        fail = false
        let saved = try service.recordFeedback(preview, actionID: actionID, lease: lease, at: Support.now)
        XCTAssertFalse(saved.isReplay)
        XCTAssertEqual(saved.actionID, actionID)
    }

    func testCardOrSessionRevisionOverflowCannotLeavePartialEventAndProgress() throws {
        for overflow in ["card", "session"] {
            var original = try Support.payload()
            if overflow == "card" {
                let index = try XCTUnwrap(original.cards.firstIndex { $0.id == original.sessionItems[0].cardID })
                original.cards[index].revision = 999_999_999
            } else { original.sessions[0].revision = 1_000_000_000 }
            let container = try Support.seeded(original)
            let service = try WordNoteV3ReviewService(container: container)
            let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
            let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
            let before = try Support.snapshot(container, original: original)
            XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Support.now)) {
                XCTAssertEqual($0 as? WordNoteV3ContentError, .counterLimit)
            }
            XCTAssertEqual(try Support.snapshot(container, original: original), before)
            XCTAssertFalse(container.mainContext.hasChanges)
        }
    }

    func testInvalidClockOrOldSchemaIsRejectedWithoutMutatingState() throws {
        for schema in [WordNoteSchemaV1.self as any VersionedSchema.Type, WordNoteSchemaV2.self] {
            XCTAssertThrowsError(try WordNoteV3ReviewService(container: V3TestSupport.container(schema))) {
                XCTAssertEqual($0 as? WordNoteV3ContentError, .wrongSchema)
            }
        }
        let original = try Support.payload()
        let container = try Support.seeded(original)
        let service = try WordNoteV3ReviewService(container: container)
        let lease = try Support.reveal(service, sessionID: original.sessions[0].id)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        let before = try Support.snapshot(container, original: original)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: UUID(), lease: lease, at: Date(timeIntervalSince1970: .nan)))
        XCTAssertEqual(try Support.snapshot(container, original: original), before)
    }

    func testPresentedNewCardRequiresPersistedIntroductionBeforeImportOrAnswer() throws {
        var value = try Support.payload()
        let index = try XCTUnwrap(value.cards.firstIndex { $0.id == value.sessionItems[0].cardID })
        value.cards[index].schedule = .init()
        value.cards[index].schedulerVersion = ReviewSchedulerVersion.current
        XCTAssertThrowsError(try value.validate()) { XCTAssertEqual($0 as? WordNoteSnapshotError, .invalidValue) }
        let empty = try V3TestSupport.container()
        XCTAssertThrowsError(try value.populateEmptyStore(empty.mainContext))
        XCTAssertEqual(try empty.mainContext.fetchCount(FetchDescriptor<WordNoteSchemaV3.TermModel>()), 0)
        value.cards[index].schedule.introducedAt = Support.now
        XCTAssertNoThrow(try value.validate())
        let container = try Support.seeded(value)
        let model = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewCardModel>()).first { $0.id == value.cards[index].id })
        model.introducedAt = nil
        try container.mainContext.save()
        let broken = try WordNoteSnapshotV3Payload.captureForIntegrityInspection(from: container.mainContext)
        XCTAssertThrowsError(try WordNoteV3ReviewService(container: container).currentAnswerSnapshot(sessionID: value.sessions[0].id))
        XCTAssertEqual(try WordNoteSnapshotV3Payload.captureForIntegrityInspection(from: container.mainContext), broken)
        XCTAssertFalse(container.mainContext.hasChanges)
    }
}
