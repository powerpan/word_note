import Observation
import SwiftUI
import WordNoteCore

struct VocabularyWorkspaceState: Equatable {
    var query = VocabularyBrowseQuery()
    var cards = VocabularyCardQuery()
    var selection = VocabularySelection()
    var openedTermID: UUID?
    var openedCardID: UUID?
    var scrollID: UUID?
}

struct InboxWorkspaceState: Equatable {
    var query = InboxBrowseQuery()
    var selection = InboxSelection()
    var openedRecordID: UUID?
    var scrollID: UUID?
}

struct ReviewSetupSelection: Equatable {
    var courseID: UUID?
    var mode: ReviewMode = .englishToChinese
    var queue: ReviewQueueScope = .dueToday
    var includesNew = false
}

enum LearningCourseTab: String, CaseIterable, Identifiable {
    case vocabulary = "Vocabulary", cards = "Cards", weak = "Needs Attention", encounters = "Recent Captures", inbox = "Inbox"
    var id: String { rawValue }
}

enum LearningRoute: Equatable {
    case term(UUID, cardID: UUID? = nil)
    case vocabulary(courseID: UUID?, cards: VocabularyCardQuery)
    case record(UUID)
    case inbox(courseID: UUID?)
    case course(UUID)
    case review(ReviewSetupSelection)
    case continueReview
    case capture(courseID: UUID)
}

/// Owned by ContentView, not the app runtime: a second window has its own reading history.
@MainActor
@Observable
final class LearningWorkspace {
    var destination: SidebarDestination = .dashboard
    var vocabulary = VocabularyWorkspaceState()
    var inbox = InboxWorkspaceState()
    var courseID: UUID?
    var courseTab = LearningCourseTab.vocabulary
    var courseMode = ReviewMode.englishToChinese
    var dashboardMode = ReviewMode.englishToChinese
    var courseCardState = ReviewCardBrowseState.ready
    var dashboardCardState = ReviewCardBrowseState.ready
    var courseScrollID: UUID?
    var dashboardScrollID: UUID?
    static let courseHeaderID = UUID(uuidString: "FFFFFFFF-FFFF-4000-8000-000000000001")!
    static let dashboardHeaderID = UUID(uuidString: "FFFFFFFF-FFFF-4000-8000-000000000002")!
    var review = ReviewSetupSelection()
    var errorMessage: String?
    private var history: [Snapshot] = []
    var canGoBack: Bool { !history.isEmpty }

    private struct Snapshot {
        let destination: SidebarDestination
        let vocabulary: VocabularyWorkspaceState
        let inbox: InboxWorkspaceState
        let courseID: UUID?
        let courseTab: LearningCourseTab
        let courseMode: ReviewMode
        let dashboardMode: ReviewMode
        let courseCardState: ReviewCardBrowseState
        let dashboardCardState: ReviewCardBrowseState
        let courseScrollID: UUID?
        let dashboardScrollID: UUID?
        let review: ReviewSetupSelection
    }

    @discardableResult
    func open(_ route: LearningRoute, protection: WordNoteEditProtection? = nil,
              prepare: @escaping () throws -> Void = {}) -> Bool {
        let proceed = {
            do {
                try prepare()
                self.history.append(self.snapshot)
                if self.history.count > 30 { self.history.removeFirst() }
                self.apply(route)
                self.errorMessage = nil
            } catch { self.errorMessage = error.localizedDescription }
        }
        if let protection { return protection.request(proceed: proceed) }
        proceed()
        return true
    }

    func restoreDestination(_ value: SidebarDestination) {
        destination = value == .settings ? .dashboard : value
    }

    func select(_ value: SidebarDestination, protection: WordNoteEditProtection?, openSettings: () -> Void = {}) {
        if value == .settings { openSettings(); return }
        guard destination != value else { return }
        protectingEdits(protection) {
            self.destination = value
            self.history.removeAll()
            self.errorMessage = nil
        }
    }

    func back(protection: WordNoteEditProtection? = nil) {
        guard canGoBack else { return }
        protectingEdits(protection) {
            guard let value = self.history.popLast() else { return }
            self.destination = value.destination
            self.vocabulary = value.vocabulary
            self.inbox = value.inbox
            self.courseID = value.courseID
            self.courseTab = value.courseTab
            self.courseMode = value.courseMode
            self.dashboardMode = value.dashboardMode
            self.courseCardState = value.courseCardState
            self.dashboardCardState = value.dashboardCardState
            self.courseScrollID = value.courseScrollID
            self.dashboardScrollID = value.dashboardScrollID
            self.review = value.review
            self.errorMessage = nil
        }
    }

    private var snapshot: Snapshot {
        .init(destination: destination, vocabulary: vocabulary, inbox: inbox, courseID: courseID,
              courseTab: courseTab, courseMode: courseMode, dashboardMode: dashboardMode,
              courseCardState: courseCardState, dashboardCardState: dashboardCardState,
              courseScrollID: courseScrollID, dashboardScrollID: dashboardScrollID, review: review)
    }

    private func apply(_ route: LearningRoute) {
        switch route {
        case .term(let id, let cardID):
            vocabulary.openedTermID = id
            vocabulary.openedCardID = cardID
            destination = .vocabulary
        case .vocabulary(let courseID, let cards):
            vocabulary = .init()
            vocabulary.query.courseID = courseID
            vocabulary.cards = cards
            destination = .vocabulary
        case .record(let id): inbox.openedRecordID = id; destination = .inbox
        case .inbox(let courseID):
            inbox.query.courseID = courseID
            inbox.query.text = ""
            inbox.query.status = .all
            inbox.query.source = nil
            inbox.openedRecordID = nil
            inbox.selection = .init()
            inbox.scrollID = nil
            destination = .inbox
        case .course(let id):
            if courseID != id { courseScrollID = nil }
            courseID = id
            destination = .courses
        case .review(let value): review = value; destination = .review
        case .continueReview: destination = .review
        case .capture: destination = .quickAdd
        }
    }
}

private struct LearningWorkspaceKey: EnvironmentKey { static let defaultValue: LearningWorkspace? = nil }
extension EnvironmentValues {
    var learningWorkspace: LearningWorkspace? {
        get { self[LearningWorkspaceKey.self] }
        set { self[LearningWorkspaceKey.self] = newValue }
    }
}
