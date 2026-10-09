import Foundation

public enum CommandShortcutPreference {
    public static let storageKey = "commandShortcutsEnabled"
    public static let defaultValue = false

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: storageKey)
    }
}
