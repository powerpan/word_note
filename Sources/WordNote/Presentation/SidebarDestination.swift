import Foundation

enum SidebarDestination: String, CaseIterable, Identifiable {
    case dashboard
    case quickAdd
    case inbox
    case vocabulary
    case review
    case courses
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .quickAdd:
            return "Quick Add"
        case .inbox:
            return "Inbox"
        case .vocabulary:
            return "Vocabulary"
        case .review:
            return "Review"
        case .courses:
            return "Courses"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "gauge"
        case .quickAdd:
            return "plus.square"
        case .inbox:
            return "tray"
        case .vocabulary:
            return "books.vertical"
        case .review:
            return "rectangle.stack"
        case .courses:
            return "graduationcap"
        case .settings:
            return "gearshape"
        }
    }
}
