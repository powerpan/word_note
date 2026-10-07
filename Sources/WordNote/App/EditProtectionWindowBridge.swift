#if WORDNOTE_V2_VALIDATION
import AppKit
import SwiftUI
import WordNoteCore

private final class MainThreadWindowDelegate: @unchecked Sendable {
    private weak var storage: (any NSWindowDelegate)?
    var value: (any NSWindowDelegate)? {
        get { precondition(Thread.isMainThread); return storage }
        set { precondition(Thread.isMainThread); storage = newValue }
    }
}

/// Weak window registry is only for normal application termination; each window owns its drafts.
@MainActor
final class EditProtectionWindows {
    static let shared = EditProtectionWindows()
    private var windows: [ObjectIdentifier: WeakBridge] = [:]
    private let quitProtection = WordNoteQuitProtection()

    private struct WeakBridge { weak var value: EditProtectionWindowBridge.Coordinator? }

    func register(_ bridge: EditProtectionWindowBridge.Coordinator) {
        windows = windows.filter { $0.value.value != nil }
        windows[ObjectIdentifier(bridge)] = WeakBridge(value: bridge)
    }

    func unregister(_ bridge: EditProtectionWindowBridge.Coordinator) {
        windows.removeValue(forKey: ObjectIdentifier(bridge))
    }

    func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard !quitProtection.isActive else { return .terminateLater }
        let bridges = windows.values.compactMap(\.value)
        guard !bridges.contains(where: { $0.protection.hasPendingTransition }) else { return .terminateCancel }
        guard bridges.contains(where: { $0.protection.hasUnsavedChanges }) else { return .terminateNow }
        let accepted = quitProtection.request(protections: { [weak self] in
            self?.windows.values.compactMap { $0.value?.protection } ?? []
        }, activate: { [weak self] protection in
            self?.windows.values.compactMap(\.value).first(where: { $0.protection === protection })?.window?.makeKeyAndOrderFront(nil)
        }, completion: { [weak app] allowed in
            // NSApplication must have received terminateLater before its asynchronous reply.
            DispatchQueue.main.async { app?.reply(toApplicationShouldTerminate: allowed) }
        })
        return accepted ? .terminateLater : .terminateCancel
    }
}

struct EditProtectionWindowBridge: NSViewRepresentable {
    let protection: WordNoteEditProtection

    func makeCoordinator() -> Coordinator { Coordinator(protection: protection) }

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) { context.coordinator.attach(view.window) }

    static func dismantleNSView(_ view: WindowProbe, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.detach()
    }

    final class WindowProbe: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowChanged?(window) }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        let protection: WordNoteEditProtection
        private(set) weak var window: NSWindow?
        // NSObject's forwarding hooks are nonisolated; the holder enforces main-thread access.
        nonisolated private let previousDelegate = MainThreadWindowDelegate()
        private weak var previousResponder: NSResponder?
        private weak var lastEditedControl: NSControl?
        private var lastSelection: NSRange?

        init(protection: WordNoteEditProtection) { self.protection = protection }

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            detach()
            guard let window else { return }
            self.window = window
            previousDelegate.value = window.delegate
            window.delegate = self
            NotificationCenter.default.addObserver(self, selector: #selector(editingBegan), name: NSControl.textDidBeginEditingNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(editingEnded), name: NSControl.textDidEndEditingNotification, object: nil)
            protection.willPresent = { [weak self] in
                guard let self else { return }
                if let editor = lastEditedControl?.currentEditor() { lastSelection = editor.selectedRange }
                previousResponder = lastEditedControl ?? self.window?.firstResponder
            }
            protection.didCancel = { [weak self, weak window] in
                guard let self, let responder = previousResponder else { return }
                window?.makeFirstResponder(responder)
                if let range = lastSelection, let editor = lastEditedControl?.currentEditor() {
                    let length = (editor.string as NSString).length
                    if NSMaxRange(range) <= length { editor.selectedRange = range }
                }
            }
            EditProtectionWindows.shared.register(self)
        }

        func detach() {
            if window?.delegate === self { window?.delegate = previousDelegate.value }
            window = nil
            previousDelegate.value = nil
            previousResponder = nil
            lastEditedControl = nil
            lastSelection = nil
            NotificationCenter.default.removeObserver(self)
            protection.willPresent = nil
            protection.didCancel = nil
            EditProtectionWindows.shared.unregister(self)
        }

        @objc private func editingBegan(_ notification: Notification) {
            guard let control = notification.object as? NSControl, control.window === window else { return }
            lastEditedControl = control
            lastSelection = control.currentEditor()?.selectedRange
        }

        @objc private func editingEnded(_ notification: Notification) {
            guard let control = notification.object as? NSControl, control === lastEditedControl else { return }
            if let editor = control.currentEditor() { lastSelection = editor.selectedRange }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if protection.hasPendingTransition { return false }
            if protection.hasUnsavedChanges {
                protection.request { [weak sender] in sender?.performClose(nil) }
                return false
            }
            return previousDelegate.value?.windowShouldClose?(sender) ?? true
        }

        // Preserve the delegate installed by SwiftUI for all other window lifecycle messages.
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            // NSWindow dispatches delegate messages on the main thread.
            guard Thread.isMainThread else { return false }
            return previousDelegate.value?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if Thread.isMainThread {
                if previousDelegate.value?.responds(to: selector) == true { return previousDelegate.value }
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
#endif
