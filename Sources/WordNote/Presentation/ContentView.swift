import SwiftData
import SwiftUI
import WordNoteCore

struct ContentView: View {
    @SceneStorage("sidebarSelection") private var selection: SidebarDestination = .dashboard

    var body: some View {
        HSplitView {
            SidebarView(selection: $selection)
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 320)

            DetailRouter(selection: selection)
                .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Word Note")
                .font(.title2.bold())
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)

            List(SidebarDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .listStyle(.sidebar)
        }
        .background(.bar)
    }
}

private struct DetailRouter: View {
    let selection: SidebarDestination

    var body: some View {
        switch selection {
        case .dashboard:
            DashboardView()
        case .quickAdd:
            QuickAddView()
        case .inbox:
            InboxView()
        case .vocabulary:
            VocabularyView()
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
