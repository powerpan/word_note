import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3SessionControlTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testSkipRotatesFixedItemsWithoutScoringOrChangingCardsAndPausesAtRoundEnd() throws {
        let container = try Support.container(count: 2, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, first) = try Support.startPresented(service, newCards: true)
        let before = try Support.snapshot(container)
        let skipped = try service.skip(first, actionID: UUID(), lease: lease, at: Support.now)
        XCTAssertFalse(skipped.pausedForSkipRound)
        XCTAssertEqual(try Support.snapshot(container).cards, before.cards)
        let second = try Support.show(service, lease: lease)
        XCTAssertNotEqual(second.card.id, first.card.id)
        XCTAssertEqual(try service.reviewSession(lease.sessionID).items.map(\.originalCardID), [second.card.id, first.card.id])
        XCTAssertTrue(try service.skip(second, actionID: UUID(), lease: lease, at: Support.now).pausedForSkipRound)
        let paused = try service.reviewSession(lease.sessionID)
        XCTAssertEqual(paused.items.map(\.status), [.presented, .presented])
        XCTAssertTrue(try Support.snapshot(container).eventStates.isEmpty)
        let newLease = try service.acquireLease(sessionID: lease.sessionID, ownerID: UUID())
        _ = try service.resumeSession(lease: newLease, expectedRevision: paused.session.revision, at: Support.now)
        let cards = try Support.snapshot(container).cards
        XCTAssertEqual(try Support.show(service, lease: newLease).card.id, first.card.id)
        XCTAssertEqual(try Support.snapshot(container).cards, cards)
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 2)
        XCTAssertThrowsError(try service.skip(first, actionID: UUID(), lease: lease, at: Support.now))
    }

    func testFutureRelearningDoesNotPreventSkipPauseButReadyRepeatIsPresentedFirst() throws {
        for delay in [1.0, 600.0] {
            let container = try Support.container(count: 2)
            let service = try WordNoteV3ReviewService(container: container)
            let (lease, first) = try Support.startPresented(service)
            _ = try Support.answer(service, lease: lease, feedback: .again)
            let second = try Support.show(service, lease: lease, at: Support.now.addingTimeInterval(1))
            let receipt = try service.skip(second, actionID: UUID(), lease: lease, at: Support.now.addingTimeInterval(delay))
            XCTAssertEqual(receipt.pausedForSkipRound, delay == 1)
            if delay == 600 {
                XCTAssertThrowsError(try service.currentAnswerSnapshot(sessionID: lease.sessionID))
                let repeated = try Support.show(service, lease: lease, at: Support.now.addingTimeInterval(delay))
                XCTAssertEqual(repeated.card.id, first.card.id)
                XCTAssertEqual(repeated.card.schedule.relearningRepeatCount, 1)
                XCTAssertTrue(try service.skip(repeated, actionID: UUID(), lease: lease,
                    at: Support.now.addingTimeInterval(delay)).pausedForSkipRound)
            }
        }
    }

    func testLaterDoesNotRequireRevealAndDoesNotInventAReviewOrRefundNewQuota() throws {
        let container = try Support.container(count: 1, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try Support.startPresented(service, newCards: true)
        let receipt = try service.later(source, actionID: UUID(), lease: lease, at: Support.now)
        let saved = try Support.snapshot(container)
        var expected = source.card.schedule
        expected.phase = .review
        expected.nextReviewAt = try ReviewStudyDay(containing: Support.now, timeZoneID: Support.zone).end
        XCTAssertEqual(saved.cards[0].schedule, expected)
        XCTAssertEqual(receipt.record.postponedUntil, expected.nextReviewAt)
        XCTAssertEqual(receipt.record.resultingStatus, .completed)
        XCTAssertEqual(saved.sessionItems[0].status, .postponed)
        XCTAssertEqual(saved.sessionItems[0].attemptCount, 0)
        XCTAssertNil(saved.sessionItems[0].lastActionID)
        XCTAssertTrue(saved.eventStates.isEmpty)
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 1)
    }

    func testLaterPreservesRelearningEvidenceAndAttemptCounts() throws {
        let container = try Support.container(count: 1)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, _) = try Support.startPresented(service)
        _ = try Support.answer(service, lease: lease, feedback: .again)
        let date = Support.now.addingTimeInterval(600)
        let source = try Support.show(service, lease: lease, at: date)
        _ = try service.later(source, actionID: UUID(), lease: lease, at: date)
        let saved = try Support.snapshot(container)
        var expected = source.card.schedule
        expected.nextReviewAt = try ReviewStudyDay(containing: date, timeZoneID: Support.zone).end
        XCTAssertEqual(saved.cards[0].schedule, expected)
        XCTAssertEqual(saved.cards[0].schedule.phase, .relearning)
        XCTAssertEqual(saved.sessionItems[0].attemptCount, 1)
        XCTAssertEqual(saved.sessionItems[0].lastActionID, source.item.lastActionID)
        XCTAssertEqual(saved.eventStates.count, 1)
    }

    func testFeedbackAndLaterResetSkipRoundAndReplayDoesNotClearNextReveal() throws {
        for useLater in [false, true] {
            let container = try Support.container(count: 3)
            let service = try WordNoteV3ReviewService(container: container)
            let (lease, first) = try Support.startPresented(service)
            let id = UUID()
            _ = try service.skip(first, actionID: id, lease: lease, at: Support.now)
            let second = try Support.show(service, lease: lease)
            let revealed = try service.revealAnswer(second, lease: lease, at: Support.now)
            let before = try Support.snapshot(container)
            XCTAssertTrue(try service.skip(first, actionID: id, lease: lease, at: .distantPast).isReplay)
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertNoThrow(try service.previewFeedback(.good, lease: lease, at: Support.now))
            if useLater { _ = try service.later(revealed, actionID: UUID(), lease: lease, at: Support.now) }
            else { _ = try Support.answer(service, lease: lease) }
            XCTAssertEqual(try service.reviewSession(lease.sessionID).session.controls?.skippedItemIDs, [])
        }
    }

    func testControlSaveFailureRollsBackEverythingAndKeepsRevealForRetry() throws {
        for kind in [ReviewSessionControlKind.skip, .later] {
            let container = try Support.container(count: 2)
            var shouldFail = false
            let service = try WordNoteV3ReviewService(container: container, beforeSave: { _ in
                if shouldFail { throw V3ReviewTestSupport.Failure.save }
            })
            let (lease, source) = try Support.startPresented(service)
            let revealed = try service.revealAnswer(source, lease: lease, at: Support.now)
            let before = try Support.snapshot(container)
            let id = UUID()
            shouldFail = true
            XCTAssertThrowsError(try perform(kind, service, revealed, id, lease))
            XCTAssertEqual(try Support.snapshot(container), before)
            XCTAssertFalse(container.mainContext.hasChanges)
            XCTAssertNoThrow(try service.previewFeedback(.good, lease: lease, at: Support.now))
            shouldFail = false
            XCTAssertFalse(try perform(kind, service, revealed, id, lease).isReplay)
            XCTAssertNotNil(try service.controlReceipt(actionID: id))
        }
    }

    func testActionIDsConflictAcrossKindsSourcesAndFormalFeedbackBothWays() throws {
        let container = try Support.container(count: 3)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, source) = try Support.startPresented(service)
        let id = UUID()
        _ = try service.skip(source, actionID: id, lease: lease, at: Support.now)
        XCTAssertThrowsError(try service.later(source, actionID: id, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .actionConflict)
        }
        let next = try Support.show(service, lease: lease)
        XCTAssertThrowsError(try service.skip(next, actionID: id, lease: lease, at: Support.now))
        _ = try service.revealAnswer(next, lease: lease, at: Support.now)
        let preview = try service.previewFeedback(.good, lease: lease, at: Support.now)
        XCTAssertThrowsError(try service.recordFeedback(preview, actionID: id, lease: lease, at: Support.now))
        let answerID = UUID()
        _ = try service.recordFeedback(preview, actionID: answerID, lease: lease, at: Support.now)
        let third = try Support.show(service, lease: lease)
        XCTAssertThrowsError(try service.later(third, actionID: answerID, lease: lease, at: Support.now)) {
            XCTAssertEqual($0 as? WordNoteV3ReviewError, .actionConflict)
        }
    }

    func testStaleContentDirtyDraftAndRestoreTicketCannotChangeProgress() throws {
        for kind in [ReviewSessionControlKind.skip, .later] {
            let container = try Support.container(count: 2)
            let service = try WordNoteV3ReviewService(container: container)
            let (lease, source) = try Support.startPresented(service)
            let term = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.TermModel>()).first { $0.id == source.term.id })
            term.chineseMeaning = "changed"
            XCTAssertThrowsError(try perform(kind, service, source, UUID(), lease))
            XCTAssertTrue(container.mainContext.hasChanges)
            XCTAssertEqual(term.chineseMeaning, "changed")
            try container.mainContext.save()
            let before = try Support.snapshot(container)
            XCTAssertThrowsError(try perform(kind, service, source, UUID(), lease)) {
                XCTAssertEqual($0 as? WordNoteV3ReviewError, .stalePreview)
            }
            let fresh = try service.currentAnswerSnapshot(sessionID: lease.sessionID)
            let ticket = try WordNoteWriteGate.beginRestore(container.mainContext)
            XCTAssertThrowsError(try perform(kind, service, fresh, UUID(), lease))
            try WordNoteWriteGate.endRestore(container.mainContext, ticket: ticket)
            XCTAssertThrowsError(try perform(kind, service, fresh, UUID(), lease)) {
                XCTAssertEqual($0 as? WordNoteWriteError, .expiredOperation)
            }
            XCTAssertEqual(try Support.snapshot(container), before)
        }
    }

    func testSkipRoundAndReceiptsSurviveBackupRestoreAndTermDeletion() async throws {
        let container = try Support.container(count: 2)
        let service = try WordNoteV3ReviewService(container: container)
        let (lease, first) = try Support.startPresented(service)
        let id = UUID()
        _ = try service.skip(first, actionID: id, lease: lease, at: Support.now)
        let saved = try Support.snapshot(container)
        let decoded = try WordNoteSnapshotV3Codec.decode(WordNoteSnapshotV3Codec.encode(saved, kind: .manual)).payload
        let harness = V3RecoveryHarness(directory: try V3TestSupport.directory())
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        _ = try await harness.seed(.v3(decoded))
        let restored = try harness.store.open()
        let next = try WordNoteV3ReviewService(container: restored.container)
        XCTAssertTrue(try next.skip(first, actionID: id, lease: lease, at: Support.now).isReplay)
        let newLease = try next.acquireLease(sessionID: lease.sessionID, ownerID: UUID())
        let second = try Support.show(next, lease: newLease)
        XCTAssertTrue(try next.skip(second, actionID: UUID(), lease: newLease, at: Support.now).pausedForSkipRound)
        try WordNoteV3ContentService(container: restored.container).deleteTerm(first.term.id,
            expectedRevision: first.termState.revision, at: Support.now)
        let before = try Support.snapshot(restored.container)
        XCTAssertTrue(try next.skip(first, actionID: id, lease: lease, at: Support.now).isReplay)
        XCTAssertEqual(try Support.snapshot(restored.container), before)
    }

    func testActionRecordLimitAndRevisionOverflowFailWithoutPartialWrites() throws {
        for limit in [true, false] {
            let container = try Support.container(count: 2)
            let service = try WordNoteV3ReviewService(container: container)
            let (lease, original) = try Support.startPresented(service)
            let model = try XCTUnwrap(container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()).first)
            if limit {
                var controls = ReviewSessionControls()
                controls.records = (1...ReviewSessionControls.maximumRecords).map { index in
                    .init(actionID: UUID(), kind: .skip, itemID: original.item.id, originalCardID: original.card.id,
                          sourceFingerprint: String(repeating: "a", count: 64), performedAt: Support.now, effectiveAt: Support.now,
                          postponedUntil: nil, resultingRevision: index, resultingStatus: .active)
                }
                model.controlsJSON = try ReviewPersistenceJSON.encode(controls)
                model.revision = ReviewSessionControls.maximumRecords
            } else { model.revision = ReviewStateValidation.maximumCounter }
            try container.mainContext.save()
            let source = try service.currentAnswerSnapshot(sessionID: lease.sessionID)
            let before = try Support.snapshot(container)
            XCTAssertThrowsError(try service.later(source, actionID: UUID(), lease: lease, at: Support.now))
            XCTAssertThrowsError(try service.skip(source, actionID: UUID(), lease: lease, at: Support.now))
            XCTAssertEqual(try Support.snapshot(container), before)
        }
    }

    private func perform(_ kind: ReviewSessionControlKind, _ service: WordNoteV3ReviewService,
                         _ source: WordNoteV3ReviewAnswerSnapshot, _ id: UUID,
                         _ lease: WordNoteV3ReviewLease) throws -> WordNoteV3ControlReceipt {
        try kind == .skip ? service.skip(source, actionID: id, lease: lease, at: Support.now)
            : service.later(source, actionID: id, lease: lease, at: Support.now)
    }
}
