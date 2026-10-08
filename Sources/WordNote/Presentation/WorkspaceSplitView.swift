#if WORDNOTE_V3_VALIDATION
import AppKit
import SwiftUI

/// Keep the requested width while a smaller window temporarily limits the visible width.
struct WorkspaceSplitView<Leading: View, Detail: View>: View {
    @Binding var preferredWidth: Double
    let rules: WorkspaceColumnRules
    let label: String
    var fixedLeadingWidth: Double? = nil
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let detail: () -> Detail
    @State private var dragStart: Double?
    @State private var draggingWidth: Double?
    @FocusState private var dividerFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = fixedLeadingWidth ?? rules.visibleWidth(preference: draggingWidth ?? preferredWidth, available: proxy.size.width)
            HStack(spacing: 0) {
                leading()
                    .frame(width: width, height: proxy.size.height)
                    .clipped()
                    .allowsHitTesting(width > 0)
                    .accessibilityHidden(width == 0)
                if fixedLeadingWidth == nil {
                    resizeHandle(width: width, available: proxy.size.width)
                } else if width > 0 {
                    Divider()
                }
                detail()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .onChange(of: fixedLeadingWidth) { dragStart = nil; draggingWidth = nil }
    }

    private func resizeHandle(width: Double, available: Double) -> some View {
        Rectangle().fill(WordNoteTheme.surface)
            .overlay { Rectangle().fill(dividerFocused ? WordNoteTheme.brand : WordNoteTheme.line).frame(width: 1) }
            .frame(width: WorkspaceColumnRules.dividerWidth)
            .contentShape(Rectangle())
            .background(ResizeCursorRegion())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = width }
                    draggingWidth = rules.draggedWidth(start: dragStart ?? width, translation: value.translation.width, available: available)
                }
                .onEnded { value in
                    preferredWidth = rules.storedWidth(rules.draggedWidth(start: dragStart ?? width, translation: value.translation.width, available: available))
                    dragStart = nil; draggingWidth = nil
                })
            .contextMenu {
                Button("Reset width", systemImage: "arrow.counterclockwise") { preferredWidth = rules.preferred }
            }
            .focusable()
            .focused($dividerFocused)
            .onKeyPress(.leftArrow) { adjust(-20, width: width, available: available); return .handled }
            .onKeyPress(.rightArrow) { adjust(20, width: width, available: available); return .handled }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(20, width: width, available: available)
                case .decrement: adjust(-20, width: width, available: available)
                @unknown default: break
                }
            }
            .accessibilityAction(named: Text("Reset width")) { preferredWidth = rules.preferred }
            .help(label)
    }

    private func adjust(_ amount: Double, width: Double, available: Double) {
        preferredWidth = rules.storedWidth(rules.draggedWidth(start: width, translation: amount, available: available))
    }
}

private struct ResizeCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ nsView: CursorView, context: Context) { nsView.window?.invalidateCursorRects(for: nsView) }

    final class CursorView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WorkspaceSidebarAction {
    let isHidden: Bool
    let toggle: () -> Void
}

private struct WorkspaceSidebarActionKey: FocusedValueKey {
    typealias Value = WorkspaceSidebarAction
}

extension FocusedValues {
    var workspaceSidebar: WorkspaceSidebarAction? {
        get { self[WorkspaceSidebarActionKey.self] }
        set { self[WorkspaceSidebarActionKey.self] = newValue }
    }
}

struct WorkspaceSidebarCommands: Commands {
    @FocusedValue(\.workspaceSidebar) private var sidebar

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(sidebar?.isHidden == true ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") { sidebar?.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(sidebar == nil)
        }
    }
}
#endif
