import Foundation
import Observation

@MainActor
@Observable
public final class CaptureShortcutController {
    public static let storageKey = "captureShortcut.v1"
    public private(set) var configuration: CaptureShortcutConfiguration
    public private(set) var activeShortcut: CaptureShortcut?
    public private(set) var errorMessage: String?
    public private(set) var isAvailable = true
    @ObservationIgnored private let backend: any CaptureShortcutBackend
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let action: @MainActor () -> Void
    @ObservationIgnored private var activeID: UInt32?
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var inactiveIDs = Set<UInt32>()
    @ObservationIgnored private var isPressed = false

    public init(backend: any CaptureShortcutBackend, defaults: UserDefaults, action: @escaping @MainActor () -> Void) {
        self.backend = backend
        self.defaults = defaults
        self.action = action
        if defaults.object(forKey: Self.storageKey) != nil {
            if let data = defaults.data(forKey: Self.storageKey),
               let saved = try? JSONDecoder().decode(CaptureShortcutConfiguration.self, from: data), saved.isValid {
                configuration = saved
            } else {
                configuration = .init(enabled: false)
                errorMessage = CaptureShortcutError.invalidSavedConfiguration.localizedDescription
            }
        } else { configuration = .init() }
    }

    public func start() {
        guard configuration.enabled, isAvailable else { return }
        apply(configuration, persist: false)
    }

    public func apply(_ configuration: CaptureShortcutConfiguration) { apply(configuration, persist: true) }

    public func setAvailable(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        isPressed = false
        if available { start() } else { releaseRegistrations() }
    }

    public func stop() {
        isAvailable = false
        isPressed = false
        releaseRegistrations()
    }

    private func apply(_ proposed: CaptureShortcutConfiguration, persist: Bool) {
        do {
            guard proposed.isValid else { throw CaptureShortcutError.invalidCombination }
            let data = try JSONEncoder().encode(proposed)
            try removeInactiveRegistrations()
            if proposed.enabled && isAvailable {
                if activeShortcut != proposed.shortcut {
                    guard nextID < UInt32.max else { throw CaptureShortcutError.identifierExhausted }
                    let id = nextID
                    nextID += 1
                    try backend.register(proposed.shortcut, id: id) { [weak self] pressed in
                        self?.handleKey(pressed, registrationID: id)
                    }
                    do { if let activeID { try backend.unregister(activeID) } }
                    catch {
                        inactiveIDs.insert(id)
                        try? removeInactiveRegistrations()
                        throw error
                    }
                    activeID = id
                    activeShortcut = proposed.shortcut
                    isPressed = false
                }
            } else {
                if let activeID { try backend.unregister(activeID) }
                activeID = nil
                activeShortcut = nil
                isPressed = false
            }
            configuration = proposed
            if persist { defaults.set(data, forKey: Self.storageKey) }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func handleKey(_ pressed: Bool, registrationID: UInt32) {
        guard isAvailable, configuration.enabled, activeID == registrationID else { return }
        if !pressed { isPressed = false; return }
        guard !isPressed else { return }
        isPressed = true
        action()
    }

    private func removeInactiveRegistrations() throws {
        for id in inactiveIDs {
            try backend.unregister(id)
            inactiveIDs.remove(id)
        }
    }

    private func releaseRegistrations() {
        do {
            try removeInactiveRegistrations()
            if let activeID { try backend.unregister(activeID) }
            activeID = nil
            activeShortcut = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
