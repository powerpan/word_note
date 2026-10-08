import Foundation

public enum ReviewCardPhase: String, Codable, Sendable { case new, review, relearning, suspended }
public enum ReviewSessionStatus: String, Codable, Sendable {
    case active, waiting, paused, completed, ended
    public var isResumable: Bool { self == .active || self == .waiting || self == .paused }
}
public enum ReviewSessionItemStatus: String, Codable, Sendable {
    case pending, presented, waiting, completed, postponed, siblingDeferred, unavailable
    public var isTerminal: Bool {
        self == .completed || self == .postponed || self == .siblingDeferred || self == .unavailable
    }
}
public enum ReviewCompletionOutcome: String, Codable, Sendable { case reviewed, postponed, siblingDeferred, unavailable }
public enum ReviewClockAnomaly: String, Codable, Sendable { case movedBackward }

public enum ReviewSchedulerVersion {
    public static let legacy = "legacy-v1"
    public static let current = "simple-v2"
}

/// A complete schedule value is shared by cards, event history, and later scheduler previews.
public struct ReviewCardSchedule: Codable, Equatable, Sendable {
    public var phase: ReviewCardPhase = .new
    public var masteryLevel: MasteryLevel = .new
    public var intervalDays: Int = 0
    public var confidentStreak: Int = 0
    public var lapseCount: Int = 0
    public var nextReviewAt: Date? = nil
    public var priorityRequestedAt: Date? = nil
    public var introducedAt: Date? = nil
    public var lastReviewedAt: Date? = nil
    public var relearningDayKey: String? = nil
    public var relearningTimeZoneID: String? = nil
    public var relearningRepeatCount: Int = 0
    public var buriedUntil: Date? = nil

    public init() {}
}

public struct ReviewClozeTarget: Codable, Equatable, Sendable {
    public var id: UUID
    public var occurrenceID: UUID
    public var sourceHash: String
    public var startCharacterOffset: Int
    public var characterCount: Int
    public var answer: String
    public var acceptedAnswers: [String]
    public var sourceDeletedAt: Date?
    public var sourceChangedAt: Date? = nil

    public init(id: UUID = UUID(), occurrenceID: UUID, sourceHash: String, startCharacterOffset: Int,
                characterCount: Int, answer: String, acceptedAnswers: [String] = []) {
        self.id = id
        self.occurrenceID = occurrenceID
        self.sourceHash = sourceHash
        self.startCharacterOffset = startCharacterOffset
        self.characterCount = characterCount
        self.answer = answer
        self.acceptedAnswers = acceptedAnswers
        self.sourceDeletedAt = nil
    }

    public var contentScopeKey: String { "cloze:\(id.uuidString.lowercased())" }
}

public struct ReviewSessionScopeSnapshot: Codable, Equatable, Sendable {
    public var courseID: UUID?
    public var courseName: String?
    public var mode: ReviewMode
    public var queue: ReviewQueueScope
    public var includesNewCards: Bool
    public var studyTimeZoneID: String

    public init(courseID: UUID? = nil, courseName: String? = nil, mode: ReviewMode = .englishToChinese,
                queue: ReviewQueueScope = .dueToday, includesNewCards: Bool = false, studyTimeZoneID: String) {
        self.courseID = courseID
        self.courseName = courseName
        self.mode = mode
        self.queue = queue
        self.includesNewCards = includesNewCards
        self.studyTimeZoneID = studyTimeZoneID
    }
}
