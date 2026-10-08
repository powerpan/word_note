import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteV3NewCardQuotaTests: XCTestCase {
    private typealias Support = V3SessionTestSupport

    func testDailyQuotaIsGlobalAcrossCoursesAndNewSessions() throws {
        let container = try Support.container(newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        _ = try Support.introduce(service, limit: 1)
        let courses = try Support.snapshot(container).content.content.courses
        for course in courses {
            XCTAssertThrowsError(try service.startSession(scope: Support.scope(newCards: true, courseID: course.id),
                newCardLimit: 1, at: Support.now)) {
                XCTAssertEqual($0 as? WordNoteV3ReviewError, .noEligibleCards)
            }
        }
        XCTAssertEqual(try service.newCardQuota(limit: 1, studyTimeZoneID: Support.zone, at: Support.now).remaining, 0)
    }

    func testDeletingCardOrTermDoesNotRefundDailyQuota() throws {
        for deleteTerm in [false, true] {
            let container = try Support.container(newCards: true)
            let service = try WordNoteV3ReviewService(container: container)
            let introduced = try Support.introduce(service, limit: 1)
            let before = try Support.snapshot(container)
            let writer = try WordNoteV3ContentService(container: container)
            if deleteTerm {
                let state = try XCTUnwrap(before.content.termStates.first { $0.id == introduced.term.id })
                try writer.deleteTerm(introduced.term.id, expectedRevision: state.revision, at: Support.now)
            } else {
                let card = try XCTUnwrap(before.cards.first { $0.id == introduced.card.id })
                try writer.deleteReviewCard(card.id, expectedRevision: card.revision, at: Support.now)
            }
            let after = try Support.snapshot(container)
            XCTAssertEqual(after.sessions[0].introductions, before.sessions[0].introductions)
            XCTAssertEqual(after.sessionItems[0].status, .unavailable)
            XCTAssertEqual(try service.newCardQuota(limit: 1, studyTimeZoneID: Support.zone, at: Support.now).used, 1)
            XCTAssertThrowsError(try service.startSession(scope: Support.scope(newCards: true), newCardLimit: 1, at: Support.now))
        }
    }

    func testIntroducedUnansweredCardCanContinueWithoutNewOptInOrAdditionalQuota() throws {
        let container = try Support.container(newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        let start = try service.startSession(scope: Support.scope(newCards: true), newCardLimit: 1, at: Support.now)
        let lease = try service.acquireLease(sessionID: start.session.id, ownerID: UUID())
        let original = try XCTUnwrap(service.presentNextCard(lease: lease, expectedRevision: 0, at: Support.now))
        _ = try service.endSession(lease: lease, expectedRevision: original.session.revision, at: Support.now)
        let continued = try service.startSession(scope: Support.scope(), newCardLimit: 0, at: Support.now)
        XCTAssertEqual(continued.items.map(\.cardID), [original.card.id])
        let nextLease = try service.acquireLease(sessionID: continued.session.id, ownerID: UUID())
        let shown = try XCTUnwrap(service.presentNextCard(lease: nextLease, expectedRevision: 0, at: Support.now))
        XCTAssertEqual(shown.card.schedule.introducedAt, original.card.schedule.introducedAt)
        XCTAssertEqual(shown.session.introductions, [])
        XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: Support.zone, at: Support.now).used, 1)
    }

    func testTimeZoneSwitchKeepsOriginalDayThenCountsOverlapConservatively() throws {
        let now = try ReviewCardTestSupport.date("2026-09-21T15:00:00Z")
        let container = try Support.container(newCards: true, at: now)
        let service = try WordNoteV3ReviewService(container: container)
        _ = try Support.introduce(service, limit: 1, at: now)
        let switched = try service.newCardQuota(limit: 1, studyTimeZoneID: "America/Los_Angeles", at: now.addingTimeInterval(1800))
        XCTAssertEqual(switched.studyTimeZoneID, Support.zone)
        XCTAssertEqual(switched.resetsAt, try ReviewCardTestSupport.date("2026-09-21T16:00:00Z"))
        XCTAssertEqual(switched.remaining, 0)
        let overlap = try service.newCardQuota(limit: 1, studyTimeZoneID: "America/Los_Angeles", at: switched.resetsAt)
        XCTAssertEqual(overlap.studyTimeZoneID, "America/Los_Angeles")
        XCTAssertEqual(overlap.used, 1)
        XCTAssertEqual(try service.newCardQuota(limit: 1, studyTimeZoneID: "America/Los_Angeles", at: overlap.resetsAt).used, 0)
    }

    func testClockRollbackDoesNotResetQuotaAndNewChargeUsesPersistedHighWater() throws {
        let container = try Support.container(newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        _ = try Support.introduce(service, limit: 1)
        let rolledBack = Support.now.addingTimeInterval(-172800)
        let quota = try service.newCardQuota(limit: 2, studyTimeZoneID: Support.zone, at: rolledBack)
        XCTAssertEqual(quota.used, 1)
        XCTAssertEqual(quota.effectiveAt, Support.now)
        _ = try Support.introduce(service, limit: 2, at: rolledBack)
        let entries = try Support.snapshot(container).sessions.flatMap { $0.introductions ?? [] }
        XCTAssertEqual(entries.count, 2)
        let second = try XCTUnwrap(entries.first { $0.introducedAt == rolledBack })
        XCTAssertEqual(second.chargedAt, Support.now)
        XCTAssertEqual(second.studyDayKey, quota.studyDayKey)
        XCTAssertEqual(try service.newCardQuota(limit: 2, studyTimeZoneID: Support.zone, at: rolledBack).remaining, 0)
    }

    func testDSTUsesLocalDayBoundariesAndUnusedQuotaDoesNotAccumulate() throws {
        for (input, hours) in [("2026-03-08T06:00:00Z", 23.0), ("2026-11-01T05:00:00Z", 25.0)] {
            let date = try ReviewCardTestSupport.date(input)
            let zone = "America/New_York"
            let container = try Support.container(newCards: true, at: date)
            let service = try WordNoteV3ReviewService(container: container)
            _ = try Support.introduce(service, at: date, scope: Support.scope(newCards: true, timeZone: zone))
            let day = try ReviewStudyDay(containing: date, timeZoneID: zone)
            let quota = try service.newCardQuota(studyTimeZoneID: zone, at: date)
            XCTAssertEqual(quota.resetsAt.timeIntervalSince(day.start), hours * 3600)
            XCTAssertEqual(quota.used, 1)
            XCTAssertEqual(try service.newCardQuota(studyTimeZoneID: zone, at: day.end).remaining, 10)
        }
    }

    func testLegacySnapshotMissingLedgerDecodesWithoutInventingIntroductionsAndCountsLiveCard() throws {
        let container = try Support.container(count: 1, newCards: true)
        let service = try WordNoteV3ReviewService(container: container)
        _ = try Support.introduce(service)
        var snapshot = try Support.snapshot(container)
        snapshot.sessions[0].introductions = nil
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertNil(sessions[0]["introductions"])
        let decoded = try JSONDecoder().decode(WordNoteSnapshotV3Payload.self, from: data)
        XCTAssertNil(decoded.sessions[0].introductions)
        try decoded.validate()
        let quota = try ReviewNewCardQuota(payload: decoded, limit: 10, at: Support.now, timeZoneID: Support.zone)
        XCTAssertEqual(quota.used, 1)
    }

    func testInvalidLedgerReferencesDuplicatesDatesAndCardMismatchAreRejected() throws {
        let container = try Support.container(count: 1, newCards: true)
        _ = try Support.introduce(WordNoteV3ReviewService(container: container))
        let saved = try Support.snapshot(container)
        let mutations: [(inout WordNoteSnapshotV3Payload) -> Void] = [
            { value in
                let entry = value.sessions[0].introductions![0]
                value.sessions[0].introductions?.append(entry)
            },
            { $0.sessions[0].introductions?[0].originalCardID = UUID() },
            { $0.sessions[0].introductions?[0].studyDayKey = "2026-02-30" },
            { $0.sessions[0].introductions?[0].studyTimeZoneID = "Invalid" },
            { $0.sessions[0].introductions?[0].chargedAt = Support.now.addingTimeInterval(-1) },
            { $0.sessions[0].introductions?[0].chargedAt = Support.now.addingTimeInterval(172800) },
            { $0.cards[0].schedule.introducedAt = nil }
        ]
        for mutate in mutations {
            var bad = saved
            mutate(&bad)
            XCTAssertThrowsError(try bad.validate())
            let empty = try V3TestSupport.container()
            XCTAssertThrowsError(try bad.populateEmptyStore(empty.mainContext))
            XCTAssertEqual(try empty.mainContext.fetchCount(FetchDescriptor<WordNoteSchemaV3.ReviewSessionModel>()), 0)
        }
    }

    func testLedgerBackupUsesNewFormatAndCannotBeRelabeledAsOld() throws {
        let container = try Support.container(count: 1, newCards: true)
        _ = try Support.introduce(WordNoteV3ReviewService(container: container))
        let bytes = try WordNoteSnapshotV3Codec.encode(Support.snapshot(container), kind: .manual)
        var document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self, from: bytes)
        XCTAssertEqual(document.formatVersion, 2)
        XCTAssertNoThrow(try WordNoteSnapshotReader.decode(bytes))
        document.formatVersion = 1
        let downgraded = try JSONEncoder().encode(document)
        XCTAssertThrowsError(try WordNoteSnapshotV3Codec.decode(downgraded)) {
            XCTAssertEqual($0 as? WordNoteSnapshotError, .unsupportedFormat)
        }
        XCTAssertThrowsError(try WordNoteSnapshotReader.decode(downgraded))
    }

    func testPreviousV3EnvelopeWithoutLedgerRemainsReadable() throws {
        let old = try V3TestSupport.reviewedPayload()
        var document = try JSONDecoder().decode(WordNoteSnapshotV3Document.self, from: WordNoteSnapshotV3Codec.encode(old, kind: .manual))
        document.formatVersion = 1
        let bytes = try JSONEncoder().encode(document)
        XCTAssertEqual(try WordNoteSnapshotV3Codec.decode(bytes).payload, old.canonicalized)
        if case .v3(let decoded) = try WordNoteSnapshotReader.decode(bytes) {
            XCTAssertEqual(decoded.payload, old.canonicalized)
        } else { XCTFail("Expected V3 payload") }
    }

    func testRepairEvidenceKeepsInvalidLedgerAndHasItsOwnDownlevelGuard() async throws {
        let directory = try V3TestSupport.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = WordNoteV3RepairEvidenceVault(directoryURL: directory)
        for hasLedger in [false, true] {
            var source = try V3TestSupport.reviewedPayload()
            if hasLedger {
                let container = try Support.container(count: 1, newCards: true)
                _ = try Support.introduce(WordNoteV3ReviewService(container: container))
                source = try Support.snapshot(container)
                source.sessions[0].introductions?[0].studyDayKey = "damaged-day"
                XCTAssertThrowsError(try source.validate())
            }
            let saved = try await vault.create(source, generation: .init(id: UUID()), at: Support.now)
            let read = try await vault.read(id: saved.summary.id)
            XCTAssertEqual(read.payload, source.canonicalized)
            let url = await vault.fileURL(saved.summary.id)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(document["evidenceFormatVersion"] as? Int, 2)
            document["evidenceFormatVersion"] = 1
            try PrivateFileIO.write(JSONSerialization.data(withJSONObject: document), to: url)
            do {
                let old = try await vault.read(id: saved.summary.id)
                XCTAssertFalse(hasLedger)
                XCTAssertEqual(old.payload, source.canonicalized)
            } catch {
                XCTAssertTrue(hasLedger)
                XCTAssertEqual(error as? WordNoteSnapshotError, .unsupportedFormat)
            }
        }
    }
}
