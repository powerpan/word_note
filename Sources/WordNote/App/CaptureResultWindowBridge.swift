import AppKit
import SwiftUI
import WordNoteCore

/// Window notifications cover orderOut/minimize, where SwiftUI onDisappear is not sufficient.
struct CaptureResultWindowBridge: NSViewRepresentable {
    let presentation: CaptureResultPresentation
    var ownsVisibility = true

    func makeCoordinator() -> Coordinator { Coordinator(presentation: presentation, ownsVisibility: ownsVisibility) }

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }

    func updateNSView(_ view: Probe, context: Context) { context.coordinator.attach(view.window) }

    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.detach()
    }

    final class Probe: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?(window) }
    }

    @MainActor
    final class Coordinator: NSObject {
        private let presentation: CaptureResultPresentation
        private let ownsVisibility: Bool
        private let focusID = UUID()
        private weak var window: NSWindow?

        init(presentation: CaptureResultPresentation, ownsVisibility: Bool) {
            self.presentation = presentation
            self.ownsVisibility = ownsVisibility
        }

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { synchronize(); return }
            detach()
            guard let window else { return }
            self.window = window
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: NSApp)
            }
            synchronize()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            window = nil
            presentation.setFocused(false, source: focusID)
            if ownsVisibility { presentation.setVisible(false) }
        }

        @objc private func changed(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification {
                presentation.setFocused(false, source: focusID)
                if ownsVisibility { presentation.setVisible(false) }
            } else { synchronize() }
        }

        private func synchronize() {
            guard let window else { return }
            if ownsVisibility { presentation.setVisible(window.isVisible && !window.isMiniaturized && !NSApp.isHidden) }
            presentation.setFocused(window.isVisible && window.isKeyWindow && NSApp.isActive, source: focusID)
        }
    }
}
