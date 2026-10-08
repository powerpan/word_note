import AppKit
import XCTest
@testable import WordNote

final class FloatingQuickAddMetricsTests: XCTestCase {
    func testContentHeightExpandsToAvailableScreenRatherThanLegacyFixedCap() {
        XCTAssertEqual(FloatingQuickAddMetrics.expandedHeight(for: 500, maximumHeight: 700), 584)
        XCTAssertEqual(FloatingQuickAddMetrics.expandedHeight(for: 900, maximumHeight: 700), 700)
        XCTAssertEqual(FloatingQuickAddMetrics.expandedHeight(for: 0, maximumHeight: 700), 132)
    }

    func testLegacyHeightPolicyRemainsUnchangedWithoutScreenLimit() {
        XCTAssertEqual(FloatingQuickAddMetrics.expandedHeight(for: 500), 320)
        XCTAssertEqual(FloatingQuickAddMetrics.collapsedPanelSize, NSSize(width: 360, height: 60))
    }

    func testLargeResultRemainsInsideVisibleScreenIncludingDockAndMenuBar() {
        let screen = NSRect(x: 0, y: 70, width: 1440, height: 760)
        let frame = FloatingQuickAddMetrics.fittedFrame(topRight: NSPoint(x: 1422, y: 812), height: 2000, visibleFrame: screen)
        XCTAssertEqual(frame.height, 724)
        XCTAssertTrue(screen.insetBy(dx: 18, dy: 18).contains(frame))
    }

    func testGrowingDraggedPanelMovesUpInsteadOfExtendingOffScreen() {
        let screen = NSRect(x: 0, y: 40, width: 800, height: 500)
        let frame = FloatingQuickAddMetrics.fittedFrame(topRight: NSPoint(x: 400, y: 150), height: 360, visibleFrame: screen)
        XCTAssertEqual(frame.minY, 58)
        XCTAssertEqual(frame.height, 360)
        XCTAssertTrue(screen.insetBy(dx: 18, dy: 18).contains(frame))
    }

    func testSecondaryDisplayUsesItsOwnOriginAndAvailableHeight() {
        let screen = NSRect(x: -1080, y: -200, width: 1080, height: 620)
        let frame = FloatingQuickAddMetrics.fittedFrame(topRight: NSPoint(x: 1440, y: 900), height: 1000, visibleFrame: screen)
        XCTAssertEqual(frame.maxX, -18)
        XCTAssertEqual(frame.maxY, 402)
        XCTAssertEqual(frame.height, 584)
        XCTAssertTrue(screen.insetBy(dx: 18, dy: 18).contains(frame))
    }
}
