import CoreFoundation
import Foundation

/// Portable defaults only. Current capture context, shortcuts and credentials stay on the device.
public struct WordNoteLearningPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var defaultCourseID: UUID?
    public var defaultLookupIntent: LookupIntent
    public var reviewTargetCards: Int
    public var reviewDailyNewLimit: Int

    public static let targetStorageKey = "reviewTargetCards"
    public static let newLimitStorageKey = "reviewDailyNewLimit"

    public init(defaultCourseID: UUID? = nil, defaultLookupIntent: LookupIntent = .auto,
                reviewTargetCards: Int = 20, reviewDailyNewLimit: Int = 10) {
        self.defaultCourseID = defaultCourseID
        self.defaultLookupIntent = defaultLookupIntent
        self.reviewTargetCards = reviewTargetCards
        self.reviewDailyNewLimit = reviewDailyNewLimit
    }

    public func validate(courseIDs: Set<UUID>) throws {
        try validateValues()
        if let defaultCourseID, !courseIDs.contains(defaultCourseID) { throw WordNoteSnapshotError.missingReference }
    }

    func validateValues() throws {
        guard version == 1, (5...100).contains(reviewTargetCards), (0...50).contains(reviewDailyNewLimit) else {
            throw WordNoteSnapshotError.invalidValue
        }
    }

    @MainActor
    public static func capture(from defaults: UserDefaults) throws -> Self {
        var value = Self()
        if defaults.object(forKey: CaptureContextController.storageKey) != nil {
            guard let data = defaults.data(forKey: CaptureContextController.storageKey),
                  let saved = try? JSONDecoder().decode(StoredCaptureDefaults.self, from: data), saved.version == 1 else {
                throw WordNoteLearningPreferencesError.invalidStoredDefaults
            }
            value.defaultCourseID = saved.courseID
            value.defaultLookupIntent = saved.intent
        }
        value.reviewTargetCards = try integer(defaults, key: targetStorageKey, fallback: 20)
        value.reviewDailyNewLimit = try integer(defaults, key: newLimitStorageKey, fallback: 10)
        do { try value.validateValues() }
        catch { throw WordNoteLearningPreferencesError.invalidStoredDefaults }
        return value
    }

    @MainActor
    public func apply(to defaults: UserDefaults, courseIDs: Set<UUID>) throws {
        try validate(courseIDs: courseIDs)
        let data = try JSONEncoder().encode(StoredCaptureDefaults(courseID: defaultCourseID, intent: defaultLookupIntent))
        defaults.set(data, forKey: CaptureContextController.storageKey)
        defaults.set(reviewTargetCards, forKey: Self.targetStorageKey)
        defaults.set(reviewDailyNewLimit, forKey: Self.newLimitStorageKey)
        guard defaults.synchronize(), try Self.capture(from: defaults) == self else { throw CocoaError(.fileWriteUnknown) }
    }

    @MainActor
    private static func integer(_ defaults: UserDefaults, key: String, fallback: Int) throws -> Int {
        guard let stored = defaults.object(forKey: key) else { return fallback }
        guard let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else {
            throw WordNoteLearningPreferencesError.invalidStoredDefaults
        }
        return number.intValue
    }
}

struct StoredCaptureDefaults: Codable {
    var version = 1
    var courseID: UUID?
    var intent: LookupIntent
}

public enum WordNoteLearningPreferencesError: LocalizedError {
    case invalidStoredDefaults
    public var errorDescription: String? {
        "Saved capture or learning defaults are invalid. Check Settings before creating a backup."
    }
}
