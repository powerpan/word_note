import Foundation

public struct CaptureShortcut: Codable, Equatable, Sendable {
    public enum Key: String, Codable, CaseIterable, Identifiable, Sendable {
        case space
        case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        public var id: String { rawValue }
        public var title: String { self == .space ? "Space" : rawValue.uppercased() }
    }

    public struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Self(rawValue: 1)
        public static let option = Self(rawValue: 2)
        public static let shift = Self(rawValue: 4)
        public static let command = Self(rawValue: 8)
        public static let all: Self = [.control, .option, .shift, .command]
    }

    public var key: Key
    public var modifiers: Modifiers
    public init(key: Key = .space, modifiers: Modifiers = [.control, .shift]) {
        self.key = key
        self.modifiers = modifiers
    }
    public var isValid: Bool {
        modifiers.subtracting(.all).isEmpty && modifiers.rawValue.nonzeroBitCount >= 2
            && !modifiers.intersection([.control, .command]).isEmpty
    }
    public var title: String {
        let names: [(Modifiers, String)] = [(.control, "Control"), (.option, "Option"), (.shift, "Shift"), (.command, "Command")]
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [key.title]).joined(separator: " + ")
    }
}

public struct CaptureShortcutConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var shortcut: CaptureShortcut
    public init(enabled: Bool = true, shortcut: CaptureShortcut = .init()) {
        self.enabled = enabled
        self.shortcut = shortcut
    }
    public var isValid: Bool {
        shortcut.modifiers.subtracting(.all).isEmpty && (!enabled || shortcut.isValid)
    }
}

public enum CaptureShortcutError: LocalizedError, Equatable {
    case invalidCombination
    case invalidSavedConfiguration
    case systemReserved
    case registrationFailed(Int32)
    case removalFailed(Int32)
    case identifierExhausted

    public var errorDescription: String? {
        switch self {
        case .invalidCombination: "Choose at least two modifiers, including Control or Command."
        case .invalidSavedConfiguration: "The saved shortcut is invalid. Choose a new combination to enable it."
        case .systemReserved: "This shortcut is enabled in macOS Keyboard settings. Choose another combination."
        case .registrationFailed(let code): "The shortcut could not be registered (macOS error \(code)). It may be in use by another app."
        case .removalFailed(let code): "The previous shortcut could not be released (macOS error \(code)). Retry or restart Word Note."
        case .identifierExhausted: "Restart Word Note before registering another shortcut."
        }
    }
}

@MainActor
public protocol CaptureShortcutBackend: AnyObject {
    func register(_ shortcut: CaptureShortcut, id: UInt32, onKey: @escaping @MainActor (Bool) -> Void) throws
    func unregister(_ id: UInt32) throws
}
