import Foundation
import SwiftData

extension WordNoteSchemaV2 {
    @Model
    public final class ReviewEventModel {
        @Attribute(.unique) public var id: UUID
        public var termID: UUID
        public var modeRaw: String
        public var feedbackRaw: String
        public var previousMasteryLevelRaw: String
        public var newMasteryLevelRaw: String
        public var previousNextReviewAt: Date?
        public var newNextReviewAt: Date?
        public var reviewedAt: Date

        public var mode: ReviewMode {
            get { ReviewMode(rawValue: modeRaw) ?? .englishToChinese }
            set { modeRaw = newValue.rawValue }
        }

        public var feedback: ReviewFeedback {
            get { ReviewFeedback(rawValue: feedbackRaw) ?? .good }
            set { feedbackRaw = newValue.rawValue }
        }

        public var previousMasteryLevel: MasteryLevel {
            get { MasteryLevel(rawValue: previousMasteryLevelRaw) ?? .new }
            set { previousMasteryLevelRaw = newValue.rawValue }
        }

        public var newMasteryLevel: MasteryLevel {
            get { MasteryLevel(rawValue: newMasteryLevelRaw) ?? .new }
            set { newMasteryLevelRaw = newValue.rawValue }
        }

        public init(
            id: UUID = UUID(),
            termID: UUID,
            mode: ReviewMode,
            feedback: ReviewFeedback,
            previousMasteryLevel: MasteryLevel,
            newMasteryLevel: MasteryLevel,
            previousNextReviewAt: Date? = nil,
            newNextReviewAt: Date? = nil,
            reviewedAt: Date = Date()
        ) {
            self.id = id
            self.termID = termID
            self.modeRaw = mode.rawValue
            self.feedbackRaw = feedback.rawValue
            self.previousMasteryLevelRaw = previousMasteryLevel.rawValue
            self.newMasteryLevelRaw = newMasteryLevel.rawValue
            self.previousNextReviewAt = previousNextReviewAt
            self.newNextReviewAt = newNextReviewAt
            self.reviewedAt = reviewedAt
        }
    }
}
