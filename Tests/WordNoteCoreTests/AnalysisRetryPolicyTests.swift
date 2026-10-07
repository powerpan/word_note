import Foundation
import XCTest
@testable import WordNoteCore

final class AnalysisRetryPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTransientFailuresRetryAtMostTwiceWithBackoff() {
        for error in [AIAnalysisError.network("private"), .timeout, .rateLimited, .server(statusCode: 503, summary: "private")] {
            XCTAssertEqual(AnalysisRetryPolicy.decide(error, retries: 0, at: now).automaticRetryAt, now.addingTimeInterval(2))
            XCTAssertEqual(AnalysisRetryPolicy.decide(error, retries: 1, at: now).automaticRetryAt, now.addingTimeInterval(4))
            XCTAssertNil(AnalysisRetryPolicy.decide(error, retries: 2, at: now).automaticRetryAt)
            XCTAssertNil(AnalysisRetryPolicy.decide(error, retries: -1, at: now).automaticRetryAt)
            XCTAssertFalse(AnalysisRetryPolicy.decide(error, retries: 0, at: now).summary.contains("private"))
        }
    }

    func testPermanentFailuresNeverRetryAutomatically() {
        for error in [AIAnalysisError.missingAPIKey, .invalidResponse, .emptyResponse, .schemaMismatch("private"),
                      .invalidURL, .inputTooLong(maxCharacters: 8_000), .server(statusCode: 401, summary: "private"),
                      .server(statusCode: 403, summary: "private"), .server(statusCode: 400, summary: "private")] {
            let decision = AnalysisRetryPolicy.decide(error, retries: 0, at: now)
            XCTAssertNil(decision.automaticRetryAt)
            XCTAssertFalse(decision.summary.contains("private"))
        }
        XCTAssertNil(AnalysisRetryPolicy.decide(CancellationError(), retries: 0, at: now).automaticRetryAt)
    }

    func testProviderDelayIsNeverShortenedAndLongDelayRequiresManualRetry() {
        let short = AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: now.addingTimeInterval(60))
        XCTAssertEqual(AnalysisRetryPolicy.decide(short, retries: 0, at: now).automaticRetryAt, short.notBefore)
        let long = AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: now.addingTimeInterval(61))
        let decision = AnalysisRetryPolicy.decide(long, retries: 0, at: now)
        XCTAssertNil(decision.automaticRetryAt)
        XCTAssertEqual(decision.manualRetryNotBefore, long.notBefore)
        let exhausted = AnalysisRetryPolicy.decide(short, retries: 2, at: now)
        XCTAssertEqual(exhausted.manualRetryNotBefore, short.notBefore)
        let old = AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: now.addingTimeInterval(-30))
        XCTAssertEqual(AnalysisRetryPolicy.decide(old, retries: 0, at: now).automaticRetryAt, now.addingTimeInterval(2))
    }

    func testHTTPRetryAfterAcceptsAllHTTPDateFormatsAndIntegerSeconds() {
        XCTAssertEqual(HTTPRetryAfter.date(" 120 ", receivedAt: now), now.addingTimeInterval(120))
        XCTAssertEqual(HTTPRetryAfter.date("0", receivedAt: now), now)
        for date in ["Tue, 14 Nov 2023 22:14:20 GMT", "Tuesday, 14-Nov-23 22:14:20 GMT", "Tue Nov 14 22:14:20 2023"] {
            XCTAssertEqual(HTTPRetryAfter.date(date, receivedAt: now), now.addingTimeInterval(60))
        }
        for invalid in ["", "-1", "1.5", "+5", "NaN", "tomorrow"] {
            XCTAssertNil(HTTPRetryAfter.date(invalid, receivedAt: now))
        }
        XCTAssertNil(HTTPRetryAfter.date(nil, receivedAt: now))
    }

    func testOverflowRetryAfterDoesNotBecomeAnImmediateRetry() throws {
        let huge = try XCTUnwrap(HTTPRetryAfter.date(String(repeating: "9", count: 400), receivedAt: now))
        let decision = AnalysisRetryPolicy.decide(AIAnalysisRetryAfterError(failure: .rateLimited, notBefore: huge), retries: 0, at: now)
        XCTAssertNil(decision.automaticRetryAt)
        XCTAssertEqual(decision.manualRetryNotBefore, huge)
    }

    func testTwoDigitYearMoreThanFiftyYearsAheadIsPreviousCentury() throws {
        let calendar = Calendar(identifier: .gregorian)
        let before = try XCTUnwrap(HTTPRetryAfter.date("Sunday, 06-Nov-94 08:49:37 GMT", receivedAt: now))
        XCTAssertEqual(calendar.component(.year, from: before), 1994)
        let future = try XCTUnwrap(HTTPRetryAfter.date("Sunday, 06-Nov-50 08:49:37 GMT", receivedAt: now))
        XCTAssertEqual(calendar.component(.year, from: future), 2050)
    }
}
