import AppKit
import SwiftUI
import WordNoteCore

struct WordNoteMenuBarLabel: View {
    let analysisQueue: QuickAddAnalysisQueue

    var body: some View {
        Label("Word Note", systemImage: analysisQueue.isBusy ? "sparkles" : "book.closed")
    }
}

struct WordNoteMenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    let analysisQueue: QuickAddAnalysisQueue
    let quickAddPanelController: QuickAddPanelController
    let captureAvailable: Bool

    var body: some View {
        Button {
            quickAddPanelController.toggle()
        } label: {
            Label("Quick Add", systemImage: "plus.circle")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!captureAvailable)

        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }

        Divider()

        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Word Note", systemImage: "macwindow")
        }

        if analysisQueue.isBusy {
            Divider()
            Label(menuStatusTitle, systemImage: "sparkles")
        }

        if !captureAvailable {
            Divider()
            Label("Storage unavailable", systemImage: "externaldrive.badge.exclamationmark")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var menuStatusTitle: String {
        if analysisQueue.queuedCount > 0 {
            return "\(analysisQueue.queuedCount) queued"
        }
        return "Analyzing"
    }
}
