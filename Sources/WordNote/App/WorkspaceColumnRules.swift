import Foundation

struct WorkspaceColumnRules: Equatable {
    static let dividerWidth: Double = 7
    static let compactSidebarWidth: Double = 72
    static let sidebarCompactBreakpoint: Double = 1180
    static let sidebar = Self(minimum: 200, preferred: 232, maximum: 320, detailMinimum: 800)
    static let inbox = Self(minimum: 310, preferred: 350, maximum: 520, detailMinimum: 440)
    static let vocabulary = Self(minimum: 310, preferred: 350, maximum: 520, detailMinimum: 440)
    static let courses = Self(minimum: 210, preferred: 240, maximum: 380, detailMinimum: 440)

    let minimum: Double
    let preferred: Double
    let maximum: Double
    let detailMinimum: Double

    func storedWidth(_ value: Double) -> Double {
        min(max(value.isFinite ? value : preferred, minimum), maximum)
    }

    func visibleWidth(preference: Double, available: Double) -> Double {
        let space = available.isFinite ? max(0, available - Self.dividerWidth) : 0
        let upper = min(maximum, max(0, space - detailMinimum))
        return min(storedWidth(preference), upper)
    }

    func draggedWidth(start: Double, translation: Double, available: Double) -> Double {
        visibleWidth(preference: storedWidth(start + (translation.isFinite ? translation : 0)), available: available)
    }

    static func fixedSidebarWidth(hidden: Bool, available: Double) -> Double? {
        if hidden { return 0 }
        return available < sidebarCompactBreakpoint ? compactSidebarWidth : nil
    }
}
