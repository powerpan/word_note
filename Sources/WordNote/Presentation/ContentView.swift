import SwiftData
import SwiftUI
import WordNoteCore

struct ContentView: View {
    @SceneStorage("sidebarSelection") private var selection: SidebarDestination = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
                .frame(width: 248)

            DetailRouter(selection: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1120, minHeight: 720)
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Word Note")
                    .font(.title2.bold())
                    .lineLimit(1)
                Text("AI / CS Vocabulary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)

            VStack(spacing: 4) {
                ForEach(SidebarDestination.allCases) { destination in
                    SidebarRow(
                        destination: destination,
                        isSelected: selection == destination
                    ) {
                        selection = destination
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label("Local-first", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("DeepSeek is used only when you analyze a record.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .background(.thinMaterial)
        .overlay(alignment: .trailing) {
            Divider()
        }
    }
}

private struct SidebarRow: View {
    let destination: SidebarDestination
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(destination.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            ReviewView()
        case .courses:
            CoursesOverviewView()
        case .settings:
            SettingsView()
        }
    }
}
