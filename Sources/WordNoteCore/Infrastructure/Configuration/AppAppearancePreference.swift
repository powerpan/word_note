public enum AppAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public static let storageKey = "appAppearance"

    public var id: String { rawValue }

    public static func resolved(from storedValue: String) -> AppAppearancePreference {
        AppAppearancePreference(rawValue: storedValue) ?? .system
    }
}
