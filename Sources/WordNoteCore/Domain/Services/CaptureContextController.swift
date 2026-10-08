import Foundation
import Observation

public struct CaptureContextSelection: Equatable, Sendable {
    public var courseID: UUID?
    public var sourceType: SourceType
    public var intent: LookupIntent

    public init(courseID: UUID? = nil, sourceType: SourceType = .other, intent: LookupIntent = .auto) {
        self.courseID = courseID
        self.sourceType = sourceType
        self.intent = intent
    }
}

public enum CaptureContextError: LocalizedError, Equatable {
    case unavailable
    case missingCourse

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Capture context is unavailable. Reopen Quick Add before saving."
        case .missingCourse: "The selected course no longer exists. Check the course selection, then save again."
        }
    }
}

/// One session-wide selection, separate from durable defaults and already-saved requests.
@MainActor
@Observable
public final class CaptureContextController {
    public static let storageKey = "captureContextDefaults.v1"
    public static let sourceStorageKey = "defaultSourceType"

    public private(set) var defaultContext: CaptureContextSelection
    public private(set) var current: CaptureContextSelection
    public private(set) var preferenceWarning: String?
    public private(set) var courseWarning: String?
    private var overrides: Set<Field> = []
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var availableCourseIDs: Set<UUID>

    private enum Field { case course, source, intent }

    public init(preferences: UserDefaults, availableCourseIDs: Set<UUID>) {
        self.preferences = preferences
        self.availableCourseIDs = availableCourseIDs
        var selection = CaptureContextSelection()
        if let stored = preferences.object(forKey: Self.sourceStorageKey) {
            if let raw = stored as? String, let source = SourceType(rawValue: raw) {
                selection.sourceType = source
            } else {
                preferenceWarning = "Saved capture defaults could not be read. Using safe defaults until you update Settings."
            }
        }
        if preferences.object(forKey: Self.storageKey) != nil {
            if let data = preferences.data(forKey: Self.storageKey),
               let saved = try? JSONDecoder().decode(StoredCaptureDefaults.self, from: data), saved.version == 1 {
                selection.courseID = saved.courseID
                selection.intent = saved.intent
            } else {
                preferenceWarning = "Saved capture defaults could not be read. Using safe defaults until you update Settings."
            }
        }
        defaultContext = selection
        current = selection
        reconcileCourses(availableCourseIDs)
    }

    public var isUsingDefaults: Bool { overrides.isEmpty }

    public func selectCourse(_ id: UUID?) throws {
        try validateCourse(id)
        current.courseID = id
        overrides.insert(.course)
        courseWarning = nil
    }

    public func selectSource(_ source: SourceType) {
        current.sourceType = source
        overrides.insert(.source)
    }

    public func selectIntent(_ intent: LookupIntent) {
        current.intent = intent
        overrides.insert(.intent)
    }

    public func useDefaults() {
        current = defaultContext
        overrides.removeAll()
        courseWarning = nil
    }

    public func updateDefaults(_ selection: CaptureContextSelection) throws {
        try validateCourse(selection.courseID)
        try persistAdditionalDefaults(selection)
        preferences.set(selection.sourceType.rawValue, forKey: Self.sourceStorageKey)
        defaultContext = selection
        if !overrides.contains(.course) { current.courseID = selection.courseID }
        if !overrides.contains(.source) { current.sourceType = selection.sourceType }
        if !overrides.contains(.intent) { current.intent = selection.intent }
        preferenceWarning = nil
    }

    /// A removed course becomes No Course, never a different course at the same list index.
    @discardableResult
    public func reconcileCourses(_ ids: Set<UUID>) -> Bool {
        availableCourseIDs = ids
        let removedDefault = defaultContext.courseID.map { !ids.contains($0) } ?? false
        let removedCurrent = current.courseID.map { !ids.contains($0) } ?? false
        if removedDefault {
            defaultContext.courseID = nil
            if preferenceWarning == nil {
                do { try persistAdditionalDefaults(defaultContext) }
                catch { preferenceWarning = "The cleared default course could not be saved. Check capture defaults in Settings." }
            }
        }
        if removedCurrent { current.courseID = nil }
        if removedDefault || removedCurrent {
            courseWarning = "A selected or default course was removed. Its selection is now No Course."
        }
        return removedCurrent
    }

    public func request(
        rawText: String, note: String? = nil, capturedVia: CaptureSurface,
        availableCourseIDs: Set<UUID>
    ) throws -> WordNoteCaptureRequest {
        guard !reconcileCourses(availableCourseIDs) else { throw CaptureContextError.missingCourse }
        return WordNoteCaptureRequest(
            rawText: rawText, courseID: current.courseID, sourceType: current.sourceType,
            note: note, intent: current.intent, capturedVia: capturedVia
        )
    }

    private func validateCourse(_ id: UUID?) throws {
        if let id, !availableCourseIDs.contains(id) { throw CaptureContextError.missingCourse }
    }

    private func persistAdditionalDefaults(_ selection: CaptureContextSelection) throws {
        let data = try JSONEncoder().encode(StoredCaptureDefaults(courseID: selection.courseID, intent: selection.intent))
        preferences.set(data, forKey: Self.storageKey)
    }
}
