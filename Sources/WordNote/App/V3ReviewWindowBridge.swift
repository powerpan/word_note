import AppKit
import SwiftUI

struct V3ReviewWindowBridge: NSViewRepresentable {
    let controller: V3ReviewController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> CaptureResultWindowBridge.Probe {
        let view = CaptureResultWindowBridge.Probe()
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: CaptureResultWindowBridge.Probe, context: Context) { context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: CaptureResultWindowBridge.Probe, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let controller: V3ReviewController
        private weak var window: NSWindow?
        private var monitor: Any?

        init(_ controller: V3ReviewController) { self.controller = controller }

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { synchronize(); return }
            detach()
            guard let window else { return }
            self.window = window
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSApplication.didHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(changed), name: name, object: NSApp)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.keyDown(event) == nil
                }
                return consumed ? nil : event
            }
            synchronize()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window = nil
            controller.setWindowActive(false)
        }

        @objc private func changed(_ notification: Notification) {
            if notification.name == NSWindow.willCloseNotification { detach() }
            else { synchronize() }
        }

        private func synchronize() {
            controller.setWindowActive(window?.isKeyWindow == true && window?.isVisible == true
                && window?.isMiniaturized == false && NSApp.isActive && !NSApp.isHidden)
        }

        private func keyDown(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            let editing = window.firstResponder is NSText || window.firstResponder is NSTextField
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            return controller.handleKey(event.characters ?? "", isRepeat: event.isARepeat,
                hasModifiers: !modifiers.isEmpty, isTextEditing: editing) ? nil : event
        }
    }
}
