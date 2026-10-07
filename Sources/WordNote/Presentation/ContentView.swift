import SwiftData
import SwiftUI
import WordNoteCore

struct ContentView: View {
    @Environment(\.editProtection) private var editProtection
    @SceneStorage("sidebarSelection") private var selection: SidebarDestination = .dashboard

    private var protectedSelection: Binding<SidebarDestination> {
        Binding(get: { selection }, set: { destination in
            guard selection != destination else { return }
            protectingEdits(editProtection) { selection = destination }
        })
    }

    var body: some View {
        GeometryReader { proxy in
            let sidebarPresentation = SidebarPresentation.presentation(for: proxy.size.width)

            HStack(spacing: 0) {
                SidebarView(selection: protectedSelection, presentation: sidebarPresentation)
                    .frame(
                        minWidth: sidebarPresentation.width,
                        idealWidth: sidebarPresentation.width,
                        maxWidth: sidebarPresentation.width
                    )
                    .layoutPriority(3)

                DetailRouter(selection: protectedSelection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WordNoteTheme.canvas)
                    .layoutPriority(1)
            }
            .animation(.smooth(duration: 0.18), value: sidebarPresentation)
        }
        .frame(minWidth: AppLayoutMetrics.minWindowWidth, minHeight: AppLayoutMetrics.minWindowHeight)
        .background(WordNoteTheme.canvas)
        .tint(WordNoteTheme.brand)
    }
}

private enum AppLayoutMetrics {
    static let minWindowWidth: CGFloat = 980
    static let minWindowHeight: CGFloat = 680
    static let sidebarCompactBreakpoint: CGFloat = 1180
    static let expandedSidebarWidth: CGFloat = 232
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
                    .foregroundStyle(WordNoteTheme.brand)
                    .frame(width: 40, height: 40)
                    .padding(.top, 24)
                    .help("Word Note")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Word Note")
                        .font(WordNoteTheme.editorialFont(size: 27, weight: .semibold))
                        .lineLimit(1)
                    Text("AI / CS Vocabulary")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WordNoteTheme.mutedInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, 22)
                .padding(.top, 28)
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
            .frame(maxWidth: .infinity)
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
                        .foregroundStyle(WordNoteTheme.mutedInk)
                    Text("DeepSeek is used only when you analyze a record.")
                        .font(.caption2)
                        .foregroundStyle(WordNoteTheme.mutedInk.opacity(0.8))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
        .background(WordNoteTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(WordNoteTheme.line)
                .frame(width: 1)
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
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(isSelected ? WordNoteTheme.brand : .clear)
                        .frame(width: 3, height: 24)
                    Image(systemName: destination.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 42, height: 38)
                        .foregroundStyle(isSelected ? WordNoteTheme.brand : Color.primary)
                        .padding(.leading, 3)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
            } else {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(isSelected ? WordNoteTheme.brand : .clear)
                        .frame(width: 3, height: 24)
                    Image(systemName: destination.systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 20)
                    Text(destination.title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(isSelected ? WordNoteTheme.brand : Color.primary)
                .padding(.trailing, 12)
                .frame(height: 39)
                .background(isSelected ? WordNoteTheme.brand.opacity(0.055) : .clear)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help(destination.title)
        .accessibilityLabel(destination.title)
    }
}

private struct DetailRouter: View {
    @Binding var selection: SidebarDestination

    var body: some View {
        switch selection {
        case .dashboard:
            DashboardView(
                onOpenReview: { selection = .review },
                onOpenInbox: { selection = .inbox }
            )
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
