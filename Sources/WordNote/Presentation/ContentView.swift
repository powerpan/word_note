import SwiftData
import SwiftUI
import WordNoteCore

struct ContentView: View {
    @SceneStorage("sidebarSelection") private var selection: SidebarDestination = .dashboard

    var body: some View {
        GeometryReader { proxy in
            let sidebarPresentation = SidebarPresentation.presentation(for: proxy.size.width)

            HStack(spacing: 0) {
                SidebarView(selection: $selection, presentation: sidebarPresentation)
                    .frame(
                        minWidth: sidebarPresentation.width,
                        idealWidth: sidebarPresentation.width,
                        maxWidth: sidebarPresentation.width
                    )
                    .layoutPriority(3)

                DetailRouter(selection: selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .layoutPriority(1)
            }
            .animation(.smooth(duration: 0.18), value: sidebarPresentation)
        }
        .frame(minWidth: AppLayoutMetrics.minWindowWidth, minHeight: AppLayoutMetrics.minWindowHeight)
    }
}

private enum AppLayoutMetrics {
    static let minWindowWidth: CGFloat = 980
    static let minWindowHeight: CGFloat = 680
    static let sidebarCompactBreakpoint: CGFloat = 1180
    static let expandedSidebarWidth: CGFloat = 252
    static let compactSidebarWidth: CGFloat = 72
}

private enum SidebarPresentation: Equatable {
    case expanded
    case compact

    static func presentation(for windowWidth: CGFloat) -> SidebarPresentation {
        windowWidth < AppLayoutMetrics.sidebarCompactBreakpoint ? .compact : .expanded
    }

    var width: CGFloat {
        switch self {
        case .expanded:
            AppLayoutMetrics.expandedSidebarWidth
        case .compact:
            AppLayoutMetrics.compactSidebarWidth
        }
    }

    var isCompact: Bool {
        self == .compact
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarDestination
    let presentation: SidebarPresentation

    var body: some View {
        VStack(alignment: presentation.isCompact ? .center : .leading, spacing: 18) {
            if presentation.isCompact {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .padding(.top, 24)
                    .help("Word Note")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Word Note")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text("AI / CS Vocabulary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 18)
                .padding(.top, 24)
            }

            VStack(spacing: 4) {
                ForEach(SidebarDestination.allCases) { destination in
                    SidebarRow(
                        destination: destination,
                        isSelected: selection == destination,
                        presentation: presentation
                    ) {
                        selection = destination
                    }
                }
            }
            .padding(.horizontal, presentation.isCompact ? 8 : 10)

            Spacer()

            if presentation.isCompact {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 32)
                    .padding(.bottom, 18)
                    .help("Local-first")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Local-first", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("DeepSeek is used only when you analyze a record.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
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
    let presentation: SidebarPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if presentation.isCompact {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 42, height: 38)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                        }
                    }
            } else {
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
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(destination.title)
        .accessibilityLabel(destination.title)
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
