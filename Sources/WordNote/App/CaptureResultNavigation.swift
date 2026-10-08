import AppKit
import Observation
import SwiftUI
import WordNoteCore

@MainActor
protocol CaptureNavigationEndpoint: AnyObject {
    var id: UUID { get }
    func present(_ target: CaptureResultTarget) -> Bool
}

enum CaptureNavigationError: LocalizedError {
    case unavailable, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: "The main window is unavailable. Try again after data recovery finishes."
        case .busy: "Finish the pending window transition before opening another record."
        }
    }
}

/// Weak, per-window endpoints prevent a result click from navigating every open window.
@MainActor
final class CaptureResultNavigator {
    private struct Endpoint {
        weak var value: CaptureNavigationEndpoint?
        var order: Int
    }
    private var endpoints: [UUID: Endpoint] = [:]
    private var order = 0
    private(set) var pending: CaptureResultTarget?
    var openMainWindow: (() -> Void)?
    private let isAvailable: () -> Bool

    init(isAvailable: @escaping () -> Bool = { true }) { self.isAvailable = isAvailable }

    func register(_ endpoint: CaptureNavigationEndpoint) {
        if endpoints[endpoint.id] == nil {
            order += 1
            endpoints[endpoint.id] = Endpoint(value: endpoint, order: order)
        }
        if let target = pending, isAvailable() {
            pending = nil
            if !endpoint.present(target) { pending = target }
        }
    }

    func unregister(_ id: UUID) { endpoints.removeValue(forKey: id) }

    func activated(_ id: UUID) {
        guard endpoints[id] != nil else { return }
        order += 1
        endpoints[id]?.order = order
    }

    func open(_ target: CaptureResultTarget) throws {
        guard isAvailable() else { throw CaptureNavigationError.unavailable }
        endpoints = endpoints.filter { $0.value.value != nil }
        if let endpoint = endpoints.values.max(by: { $0.order < $1.order })?.value {
            guard endpoint.present(target) else { throw CaptureNavigationError.busy }
        } else {
            guard pending == nil else { throw CaptureNavigationError.busy }
            guard let openMainWindow else { throw CaptureNavigationError.unavailable }
            pending = target
            openMainWindow()
        }
    }

    func cancelPending() { pending = nil }
}

struct CaptureNavigationBanner: View {
    let onReturn: () -> Void
    var body: some View {
        HStack {
            Text("Opened from Quick Add").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Return to Results", systemImage: "arrow.uturn.backward", action: onReturn)
                .labelStyle(.iconOnly).help("Return to current results")
        }.padding(.horizontal, 16).padding(.bottom, 10)
    }
}

@MainActor
@Observable
final class CaptureNavigationState {
    struct Request: Equatable {
        let id = UUID()
        let target: CaptureResultTarget
    }
    private(set) var pending: Request?
    func open(_ target: CaptureResultTarget) { pending = Request(target: target) }

    func request(_ target: CaptureResultTarget, protection: WordNoteEditProtection?, select: @escaping () -> Void) -> Bool {
        let proceed = { self.open(target); select() }
        if let protection { return protection.request(proceed: proceed) }
        proceed()
        return true
    }

    func takeInputRecord() -> UUID? {
        guard case let .inputRecord(id) = pending?.target else { return nil }
        pending = nil
        return id
    }

    func takeVocabulary() -> UUID? {
        guard case let .vocabulary(id) = pending?.target else { return nil }
        pending = nil
        return id
    }
}

private struct CaptureNavigatorKey: EnvironmentKey { static let defaultValue: CaptureResultNavigator? = nil }
private struct CaptureNavigationStateKey: EnvironmentKey { static let defaultValue: CaptureNavigationState? = nil }
extension EnvironmentValues {
    var captureNavigator: CaptureResultNavigator? {
        get { self[CaptureNavigatorKey.self] }
        set { self[CaptureNavigatorKey.self] = newValue }
    }
    var captureNavigation: CaptureNavigationState? {
        get { self[CaptureNavigationStateKey.self] }
        set { self[CaptureNavigationStateKey.self] = newValue }
    }
}

struct CaptureNavigationWindowBridge: NSViewRepresentable {
    let navigator: CaptureResultNavigator
    let onOpen: (CaptureResultTarget) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(navigator: navigator, onOpen: onOpen) }
    func makeNSView(context: Context) -> CaptureResultWindowBridge.Probe {
        let view = CaptureResultWindowBridge.Probe()
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.attach($0) }
        return view
    }
    func updateNSView(_ view: CaptureResultWindowBridge.Probe, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.attach(view.window)
    }
    static func dismantleNSView(_ view: CaptureResultWindowBridge.Probe, coordinator: Coordinator) {
        view.windowChanged = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, CaptureNavigationEndpoint {
        let id = UUID()
        var onOpen: (CaptureResultTarget) -> Bool
        private let navigator: CaptureResultNavigator
        private weak var window: NSWindow?

        init(navigator: CaptureResultNavigator, onOpen: @escaping (CaptureResultTarget) -> Bool) {
            self.navigator = navigator
            self.onOpen = onOpen
        }

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            detach()
            guard let window else { return }
            self.window = window
            NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: window)
            navigator.register(self)
            if window.isKeyWindow { navigator.activated(id) }
        }

        func detach() {
            navigator.unregister(id)
            NotificationCenter.default.removeObserver(self)
            window = nil
        }

        func present(_ target: CaptureResultTarget) -> Bool {
            guard let window else { return false }
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return onOpen(target)
        }

        @objc private func activated() {
            navigator.register(self)
            navigator.activated(id)
        }
        @objc private func closed() { navigator.unregister(id) }
    }
}
