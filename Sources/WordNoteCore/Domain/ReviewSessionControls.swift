import Foundation

public enum ReviewSessionControlKind: String, Codable, Sendable { case skip, later }

public struct ReviewSessionControlRecord: Codable, Equatable, Sendable {
    public var actionID: UUID
    public var kind: ReviewSessionControlKind
    public var itemID: UUID
    public var originalCardID: UUID
    public var sourceFingerprint: String
    public var performedAt: Date
    public var effectiveAt: Date
    public var postponedUntil: Date?
    public var resultingRevision: Int
    public var resultingStatus: ReviewSessionStatus
}

public struct ReviewSessionControls: Codable, Equatable, Sendable {
    public static let maximumRecords = 10_000
    public var records: [ReviewSessionControlRecord] = []
    public var skippedItemIDs: [UUID] = []
    public init() {}
}

public struct WordNoteV3ControlReceipt: Equatable, Sendable {
    public let sessionID: UUID
    public let record: ReviewSessionControlRecord
    public let isReplay: Bool
    public var pausedForSkipRound: Bool { record.kind == .skip && record.resultingStatus == .paused }
}
