import Foundation

extension WordNoteV3ReviewService {
    public func learningOverview(courseID: UUID? = nil, mode: ReviewMode, studyTimeZoneID: String,
                                 at date: Date = Date()) throws -> LearningOverviewSnapshot {
        try content.transaction {
            try LearningOverviewBuilder(payload: Payload.capture(from: context))
                .overview(courseID: courseID, mode: mode, studyTimeZoneID: studyTimeZoneID, at: date)
        }
    }

    public func statistics(courseID: UUID? = nil, mode: ReviewMode? = nil, studyTimeZoneID: String,
                           at date: Date = Date()) throws -> ReviewStatisticsSnapshot {
        try content.transaction {
            try ReviewStatisticsBuilder(payload: Payload.capture(from: context))
                .overview(courseID: courseID, mode: mode, studyTimeZoneID: studyTimeZoneID, at: date)
        }
    }

    public func sessionStatistics(_ id: UUID, at date: Date = Date()) throws -> ReviewSessionStatistics {
        try content.transaction {
            try ReviewStatisticsBuilder(payload: Payload.capture(from: context)).session(id, at: date)
        }
    }
}
