import AppKit
import SwiftData
import SwiftUI
import WordNoteCore

@MainActor
final class QuickAddPanelController {
    private let modelContainer: ModelContainer
    private let analysisQueue: QuickAddAnalysisQueue
    private var panel: QuickAddFloatingPanel?

    init(modelContainer: ModelContainer, analysisQueue: QuickAddAnalysisQueue) {
        self.modelContainer = modelContainer
        self.analysisQueue = analysisQueue
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel

        position(panel)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .quickAddPanelDidShow, object: nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> QuickAddFloatingPanel {
        let panelSize = NSSize(width: 430, height: 126)
        let panel = QuickAddFloatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Add"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = FloatingQuickAddPanelView(
            analysisQueue: analysisQueue,
            onClose: { [weak self] in self?.close() }
        )
        .modelContainer(modelContainer)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 18
        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - margin,
            y: visibleFrame.maxY - panel.frame.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}

private final class QuickAddFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct FloatingQuickAddPanelView: View {
    let analysisQueue: QuickAddAnalysisQueue
    let onClose: () -> Void

    @AppStorage("defaultSourceType") private var defaultSourceType = SourceType.other.rawValue
    @FocusState private var inputFocused: Bool
    @State private var rawText = ""
    @State private var localMessage: String?
    @State private var localMessageIsError = false

    private var canSubmit: Bool {
        !TextNormalizer.isBlank(rawText)
    }

    private var selectedSourceType: SourceType {
        SourceType(rawValue: defaultSourceType) ?? .other
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Quick Add")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                if analysisQueue.isBusy {
                    Label(statusTitle, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }

            HStack(spacing: 10) {
                TextField("Add word, phrase, or sentence", text: $rawText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.88))
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    }

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .foregroundStyle(canSubmit ? Color.accentColor : Color.secondary.opacity(0.45))
                .help("Add to AI analysis queue")
            }

            if let localMessage {
                Label(localMessage, systemImage: localMessageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(localMessageIsError ? Color.orange : Color.green)
            }
        }
        .padding(14)
        .frame(width: 430, height: 126, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .onAppear(perform: focusInput)
        .onReceive(NotificationCenter.default.publisher(for: .quickAddPanelDidShow)) { _ in
            focusInput()
        }
        .onExitCommand(perform: onClose)
    }

    private var statusTitle: String {
        if analysisQueue.queuedCount > 0 {
            return "\(analysisQueue.queuedCount) queued"
        }
        return "Analyzing"
    }

    private func submit() {
        guard canSubmit else { return }
        let text = rawText

        do {
            try analysisQueue.enqueue(
                rawText: text,
                courseID: nil,
                courseName: nil,
                sourceType: selectedSourceType,
                note: nil
            )
            rawText = ""
            showLocalMessage("Queued", isError: false)
            focusInput()
        } catch {
            showLocalMessage(error.localizedDescription, isError: true)
        }
    }

    private func focusInput() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            inputFocused = true
        }
    }

    private func showLocalMessage(_ message: String, isError: Bool) {
        localMessage = message
        localMessageIsError = isError

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if localMessage == message {
                localMessage = nil
            }
        }
    }
}

private extension Notification.Name {
    static let quickAddPanelDidShow = Notification.Name("WordNoteQuickAddPanelDidShow")
}
