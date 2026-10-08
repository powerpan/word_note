import SwiftData
import SwiftUI
import WordNoteCore

struct ContentView: View {
    @Environment(\.editProtection) private var editProtection
    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    @Environment(\.captureNavigator) private var captureNavigator
    @Environment(\.openWindow) private var openWindow
    @State private var captureNavigation = CaptureNavigationState()
    #endif
    #if WORDNOTE_V3_VALIDATION
    @State private var workspace = LearningWorkspace()
    @State private var initializedWorkspace = false
    #endif
    @SceneStorage("sidebarSelection") private var selection: SidebarDestination = .dashboard

    private var protectedSelection: Binding<SidebarDestination> {
        #if WORDNOTE_V3_VALIDATION
        Binding(get: { workspace.destination }, set: { workspace.select($0, protection: editProtection) })
        #else
        Binding(get: { selection }, set: { destination in
            guard selection != destination else { return }
            protectingEdits(editProtection) { selection = destination }
        })
        #endif
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

                VStack(spacing: 0) {
                    #if WORDNOTE_V3_VALIDATION
                    if workspace.canGoBack || workspace.errorMessage != nil {
                        HStack {
                            if workspace.canGoBack {
                                Button("Back", systemImage: "chevron.left") { workspace.back(protection: editProtection) }
                                    .labelStyle(.iconOnly).help("Back to previous view")
                            }
                            if let message = workspace.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                        }.padding(.horizontal, 20).padding(.vertical, 8)
                        Divider()
                    }
                    #endif
                    DetailRouter(selection: protectedSelection)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WordNoteTheme.canvas)
                    .layoutPriority(1)
            }
            .animation(.smooth(duration: 0.18), value: sidebarPresentation)
        }
        .frame(minWidth: AppLayoutMetrics.minWindowWidth, minHeight: AppLayoutMetrics.minWindowHeight)
        .background(WordNoteTheme.canvas)
        .tint(WordNoteTheme.brand)
        #if WORDNOTE_V3_VALIDATION
        .environment(\.learningWorkspace, workspace)
        .onAppear {
            if !initializedWorkspace { workspace.destination = selection; initializedWorkspace = true }
        }
        .onChange(of: workspace.destination) { selection = workspace.destination }
        #endif
        #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
        .environment(\.captureNavigation, captureNavigation)
        .background {
            if let captureNavigator { CaptureNavigationWindowBridge(navigator: captureNavigator, onOpen: openCapturedResult) }
        }
        .onAppear {
            let action = openWindow
            captureNavigator?.openMainWindow = { action(id: "main") }
        }
        #endif
    }

    #if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
    private func openCapturedResult(_ target: CaptureResultTarget) -> Bool {
        #if WORDNOTE_V3_VALIDATION
        switch target {
        case .inputRecord(let id): return workspace.open(.record(id), protection: editProtection)
        case .vocabulary(let id): return workspace.open(.term(id), protection: editProtection)
        }
        #else
        captureNavigation.request(target, protection: editProtection) {
            switch target {
            case .inputRecord: selection = .inbox
            case .vocabulary: selection = .vocabulary
            }
        }
        #endif
    }
    #endif
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
            #if WORDNOTE_V3_VALIDATION
            V3CoursesView()
            #else
            CoursesOverviewView()
            #endif
        case .settings:
            SettingsView()
        }
    }
}
