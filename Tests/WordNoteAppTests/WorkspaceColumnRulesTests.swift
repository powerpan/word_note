import XCTest
@testable import WordNote

final class WorkspaceColumnRulesTests: XCTestCase {
    private let columns: [WorkspaceColumnRules] = [.sidebar, .inbox, .vocabulary, .courses]

    func testStoredWidthsAreFiniteAndBounded() {
        for rules in columns {
            XCTAssertEqual(rules.storedWidth(.nan), rules.preferred)
            XCTAssertEqual(rules.storedWidth(.infinity), rules.preferred)
            XCTAssertEqual(rules.storedWidth(-.infinity), rules.preferred)
            XCTAssertEqual(rules.storedWidth(-1), rules.minimum)
            XCTAssertEqual(rules.storedWidth(10_000), rules.maximum)
            XCTAssertEqual(rules.storedWidth(rules.preferred), rules.preferred)
        }
    }

    func testDefaultColumnsFitEachSupportedWindowWithReadingSpace() {
        for window in [980.0, 1320, 1920] {
            for hidden in [false, true] {
                let fixed = WorkspaceColumnRules.fixedSidebarWidth(hidden: hidden, available: window)
                let sidebar = fixed ?? WorkspaceColumnRules.sidebar.visibleWidth(preference: 320, available: window)
                let divider = fixed == nil ? WorkspaceColumnRules.dividerWidth : (sidebar > 0 ? 1 : 0)
                let content = window - sidebar - divider
                XCTAssertGreaterThanOrEqual(content, 800)
                for rules in [WorkspaceColumnRules.inbox, .vocabulary, .courses] {
                    for requested in [rules.minimum, rules.preferred, rules.maximum] {
                        let list = rules.visibleWidth(preference: requested, available: content)
                        XCTAssertGreaterThanOrEqual(list, rules.minimum)
                        XCTAssertGreaterThanOrEqual(content - list - WorkspaceColumnRules.dividerWidth, rules.detailMinimum)
                    }
                }
            }
        }
    }

    func testNarrowingDoesNotOverwriteRequestedWidth() {
        let rules = WorkspaceColumnRules.inbox
        let requested = 520.0
        XCTAssertEqual(rules.visibleWidth(preference: requested, available: 907), 460)
        XCTAssertEqual(rules.visibleWidth(preference: requested, available: 1081), requested)
    }

    func testCollapsedOrCompactSidebarDoesNotUseStoredExpandedWidth() {
        XCTAssertEqual(WorkspaceColumnRules.fixedSidebarWidth(hidden: true, available: 1920), 0)
        XCTAssertEqual(WorkspaceColumnRules.fixedSidebarWidth(hidden: true, available: 980), 0)
        XCTAssertEqual(WorkspaceColumnRules.fixedSidebarWidth(hidden: false, available: 1179), 72)
        XCTAssertNil(WorkspaceColumnRules.fixedSidebarWidth(hidden: false, available: 1180))
    }

    func testDragUsesStartingWidthNotRepeatedlyAccumulatedTranslation() {
        let rules = WorkspaceColumnRules.vocabulary
        XCTAssertEqual(rules.draggedWidth(start: 350, translation: 25, available: 1100), 375)
        XCTAssertEqual(rules.draggedWidth(start: 350, translation: 50, available: 1100), 400)
    }

    func testDragStopsAtBothBoundsAndProtectsDetail() {
        let rules = WorkspaceColumnRules.inbox
        XCTAssertEqual(rules.draggedWidth(start: 350, translation: -1000, available: 907), 310)
        XCTAssertEqual(rules.draggedWidth(start: 350, translation: 1000, available: 907), 460)
        XCTAssertEqual(rules.draggedWidth(start: 350, translation: 1000, available: 1920), 520)
        XCTAssertEqual(rules.draggedWidth(start: 350, translation: .nan, available: 907), 350)
    }

    func testTransientZeroOrInvalidGeometryNeverProducesNegativeWidth() {
        for rules in columns {
            for width in [0.0, -10, .nan, .infinity, 100] {
                let result = rules.visibleWidth(preference: rules.preferred, available: width)
                XCTAssertTrue(result.isFinite)
                XCTAssertEqual(result, 0)
            }
        }
    }
}
