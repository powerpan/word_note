import SwiftData
import SwiftUI
import WordNoteCore

struct ContentView: View {
    @SceneStorage("sidebarSelection") private var selection: SidebarDestination = .dashboard

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            DetailRouter(selection: selection)
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarDestination

    var body: some View {
        List(SidebarDestination.allCases, selection: $selection) { destination in
            Label(destination.title, systemImage: destination.systemImage)
                .tag(destination)
        }
        .listStyle(.sidebar)
        .navigationTitle("Word Note")
    }
}

private struct DetailRouter: View {
    let selection: SidebarDestination

    var body: some View {
        switch selection {
        case .dashboard:
            DashboardView()
        case .quickAdd:
            PlaceholderFeatureView(
                title: "Quick Add",
                systemImage: "plus.square",
                message: "M2 will add the raw input capture flow."
            )
        case .inbox:
            PlaceholderFeatureView(
                title: "Inbox",
                systemImage: "tray",
                message: "M2 will show draft, analyzed, and failed input records."
            )
        case .vocabulary:
            PlaceholderFeatureView(
                title: "Vocabulary",
                systemImage: "books.vertical",
                message: "M4 will add term search, detail, edit, and delete."
            )
        case .review:
            PlaceholderFeatureView(
                title: "Review",
                systemImage: "rectangle.stack",
                message: "M6 will add due cards and feedback scheduling."
            )
        case .courses:
            CoursesOverviewView()
        case .settings:
            SettingsView()
        }
    }
}
