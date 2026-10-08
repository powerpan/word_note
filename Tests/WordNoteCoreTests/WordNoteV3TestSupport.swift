import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
enum V3TestSupport {
    static let date = WordNoteTestFixture.referenceDate

    static func container(_ version: any VersionedSchema.Type = WordNoteSchemaV3.self, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: version)
        let configuration = url.map { ModelConfiguration("Fixture", schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.autosaveEnabled = false
        return container
    }

    static func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appending(path: "wordnote-v3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    static func source() throws -> WordNoteSnapshotV2Payload {
        let container = try container(WordNoteSchemaV1.self)
        try WordNoteTestFixture.populated.populate(container.mainContext)
        var source = try WordNoteSnapshotPayload.capture(from: container.mainContext)
        source.terms[0].sourceRecordID = source.inputRecords[0].id
        var v2 = try WordNoteV1ToV2Migration.convert(source).payload
        let occurrence = try XCTUnwrap(v2.occurrences.first)
        v2.lookupEvents = [.init(id: UUID(), termID: occurrence.termID, captureID: occurrence.captureID,
            occurrenceID: occurrence.id, occurredAt: date, kindRaw: "exactRepeat", createdAt: date)]
        v2.content.preferences = .init(appearance: "dark", defaultSource: "book")
        return v2
    }

    static func payload() throws -> WordNoteSnapshotV3Payload {
        try WordNoteV2ToV3Migration.convert(source(), at: date)
    }

    static func reviewedPayload() throws -> WordNoteSnapshotV3Payload {
        var payload = try payload()
        let before = payload.cards[0].schedule
        var after = before
        after.phase = .relearning
        after.masteryLevel = .vague
        after.confidentStreak = 0
        after.lapseCount = 1
        after.nextReviewAt = date.addingTimeInterval(600)
        after.lastReviewedAt = date
        after.relearningDayKey = "2026-09-21"
        after.relearningTimeZoneID = "Asia/Hong_Kong"
        payload.cards[0].schedule = after
        payload.cards[0].schedulerVersion = ReviewSchedulerVersion.current
        payload.cards[0].revision = 3
        let card = payload.cards[0]
        let sessionID = UUID(), itemID = UUID(), actionID = UUID()
        let event = WordNoteSchemaV3.ReviewEventModel(termID: card.termID, mode: card.mode, feedback: .again,
            previousMasteryLevel: before.masteryLevel, newMasteryLevel: after.masteryLevel,
            previousNextReviewAt: before.nextReviewAt, newNextReviewAt: after.nextReviewAt, reviewedAt: date)
        payload.content.content.reviewEvents.append(.init(event))
        payload.sessions = [.init(id: sessionID,
            scope: .init(courseID: payload.content.content.courses[0].id, courseName: "Original course", mode: card.mode,
                         queue: .weakTerms, includesNewCards: true, studyTimeZoneID: "Asia/Hong_Kong"),
            targetCardCount: 20, newCardLimitSnapshot: 10, status: .waiting, currentItemID: nil,
            createdAt: date, updatedAt: date, endedAt: nil, revision: 2)]
        payload.sessionItems = [.init(id: itemID, sessionID: sessionID, cardID: card.id, originalCardID: card.id,
            position: 0, status: .waiting, attemptCount: 1, availableAt: after.nextReviewAt, lastActionID: actionID,
            completionOutcome: nil, createdAt: date, updatedAt: date)]
        payload.eventStates.append(.init(id: event.id, cardID: card.id, originalCardID: card.id,
            sessionID: sessionID, actionID: actionID, feedbackSemanticsVersion: 2,
            schedulerVersion: ReviewSchedulerVersion.current, studyDayKey: "2026-09-21", studyTimeZoneID: "Asia/Hong_Kong",
            beforeSchedule: before, afterSchedule: after, clockAnomaly: .movedBackward, invalidatedAt: nil))
        try payload.validate()
        return payload
    }

    static func clozePayload() throws -> WordNoteSnapshotV3Payload {
        var payload = try payload()
        let source = "A 👩🏽‍💻 writes cafe\u{301}, then quick and quick."
        payload.content.occurrences[0].rawTextSnapshot = source
        let occurrence = payload.content.occurrences[0]
        let target = ReviewClozeTarget(occurrenceID: occurrence.id, sourceHash: WordNoteSnapshotV3Payload.sourceHash(source),
            startCharacterOffset: "A 👩🏽‍💻 writes cafe\u{301}, then ".count, characterCount: 5, answer: "quick", acceptedAnswers: ["quick"])
        payload.cards.append(.init(id: UUID(), termID: occurrence.termID, mode: .contextCloze,
            contentScopeKey: target.contentScopeKey, schedule: .init(), clozeTarget: target, revision: 0,
            schedulerVersion: ReviewSchedulerVersion.current, createdAt: date, updatedAt: date))
        try payload.validate()
        return payload
    }
}
