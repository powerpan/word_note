import XCTest
@testable import WordNoteCore

final class AppAppearancePreferenceTests: XCTestCase {
    func testStoredValuesRemainStable() {
        XCTAssertEqual(AppAppearancePreference.system.rawValue, "system")
        XCTAssertEqual(AppAppearancePreference.light.rawValue, "light")
        XCTAssertEqual(AppAppearancePreference.dark.rawValue, "dark")
    }

    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppAppearancePreference.resolved(from: "unknown"), .system)
    }
}
