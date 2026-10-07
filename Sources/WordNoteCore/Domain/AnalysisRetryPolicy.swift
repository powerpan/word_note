import Foundation

public struct AIAnalysisRetryAfterError: LocalizedError, Equatable, Sendable {
    public let failure: AIAnalysisError
    public let notBefore: Date

    public init(failure: AIAnalysisError, notBefore: Date) {
        self.failure = failure
        self.notBefore = notBefore
    }

    public var errorDescription: String? { failure.errorDescription }
}

public struct AnalysisFailureDecision: Equatable, Sendable {
    public enum Category: String, Sendable { case connection, timeout, rateLimit, credentials, format, server, unknown }
    public let category: Category
    public let summary: String
    public let automaticRetryAt: Date?
    public let manualRetryNotBefore: Date?
}

public enum AnalysisRetryPolicy {
    public static let maximumAutomaticRetries = 2
    public static let maximumAutomaticDelay: TimeInterval = 60

    public static func decide(_ error: Error, retries: Int, at now: Date) -> AnalysisFailureDecision {
        let wrapped = error as? AIAnalysisRetryAfterError
        let failure = wrapped?.failure ?? (error as? AIAnalysisError)
        let category: AnalysisFailureDecision.Category
        let summary: String
        let retryable: Bool
        switch failure {
        case .network:
            (category, summary, retryable) = (.connection, "Connection failed. Check your network and retry.", true)
        case .timeout:
            (category, summary, retryable) = (.timeout, "Analysis timed out. The provider may already have processed the request.", true)
        case .rateLimited:
            (category, summary, retryable) = (.rateLimit, "Rate limit reached. Retry after the waiting period.", true)
        case .missingAPIKey, .server(statusCode: 401, summary: _), .server(statusCode: 403, summary: _):
            (category, summary, retryable) = (.credentials, "Credentials were not accepted. Check the API key in Settings.", false)
        case .server(let code, _):
            (category, summary, retryable) = (.server, "The analysis service returned HTTP \(code).", (500..<600).contains(code))
        case .invalidResponse, .emptyResponse, .schemaMismatch:
            (category, summary, retryable) = (.format, "The response did not match the required format. No content was replaced.", false)
        case .inputTooLong, .invalidURL:
            (category, summary, retryable) = (.format, "The analysis request is invalid. Check the input and configuration.", false)
        case nil:
            (category, summary, retryable) = (.unknown, "Analysis could not finish. Retry manually after checking the error.", false)
        }
        let notBefore = wrapped?.notBefore
        let providerDelay = max(0, notBefore?.timeIntervalSince(now) ?? 0)
        let delay = max(retries == 0 ? 2.0 : 4.0, providerDelay)
        let canRetry = retryable && (0..<maximumAutomaticRetries).contains(retries)
            && delay.isFinite && delay <= maximumAutomaticDelay
        return AnalysisFailureDecision(
            category: category, summary: summary,
            automaticRetryAt: canRetry ? now.addingTimeInterval(delay) : nil,
            manualRetryNotBefore: !canRetry && providerDelay > 0 ? notBefore : nil
        )
    }
}

enum HTTPRetryAfter {
    static func date(_ value: String?, receivedAt now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = Double(value), seconds.isFinite else { return Date(timeIntervalSince1970: 99_999_999_999) }
            return Date(timeIntervalSince1970: min(99_999_999_999, now.timeIntervalSince1970 + seconds))
        }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if format.contains("-yy ") {
                formatter.twoDigitStartDate = formatter.calendar.date(byAdding: .year, value: -50, to: now)
            }
            if var date = formatter.date(from: value), abs(date.timeIntervalSince1970) < 100_000_000_000 {
                if format.contains("-yy "),
                   let limit = formatter.calendar.date(byAdding: .year, value: 50, to: now), date > limit,
                   let previousCentury = formatter.calendar.date(byAdding: .year, value: -100, to: date) {
                    date = previousCentury
                }
                return date
            }
        }
        return nil
    }
}
