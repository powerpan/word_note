#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import Foundation
import Observation
import SwiftData
import WordNoteCore

/// This build must never fall through to the user's production store or credentials.
@MainActor
@Observable
final class VersionedValidationRuntime {
    struct Ready {
        let session: WordNoteStoreSession
        let queue: QuickAddAnalysisQueue
        let protection: WordNoteDataProtection
        let undoHistory: AppUndoHistory
        let panel: QuickAddPanelController
        let shortcut: CaptureShortcutController
        let captureContext: CaptureContextController
        let captureNavigator: CaptureResultNavigator
    }

    private(set) var ready: Ready?
    private(set) var startup: WordNoteStartupCoordinator?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private var attempted = false
    private var store: WordNoteRestoreStore?
    private var vault: WordNoteBackupVault?

    func start(retry: Bool = false) async {
        guard !isLoading, ready == nil, !attempted || retry else { return }
        attempted = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard AppRuntime.isUITest, let fixture = AppRuntime.fixture else {
                throw ValidationError.qaBundleRequired
            }
            if startup == nil {
                let directory = AppRuntime.fixtureDirectoryURL
                let fresh = !FileManager.default.fileExists(atPath: directory.appending(path: "store-generations.json").path)
                    && !FileManager.default.fileExists(atPath: directory.appending(path: "WordNote.store").path)
                if fresh {
                    // Migration snapshots must start with this QA session's requested appearance.
                    UserDefaults.standard.set(AppRuntime.fixtureAppearance.rawValue, forKey: AppAppearancePreference.storageKey)
                    let original = try WordNoteRestoreStore(directoryURL: directory).open()
                    try fixture.populate(original.container.mainContext)
                }
                let store = WordNoteRestoreStore(directoryURL: directory, targetSchema: VersionedAppConfiguration.schema)
                let vault = WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"), appVersion: VersionedAppConfiguration.version)
                self.store = store
                self.vault = vault
                startup = WordNoteStartupCoordinator(store: store, vault: vault, preferences: Self.preferences)
            }
            guard let startup else { throw ValidationError.qaBundleRequired }
            try install(await startup.open(retryMigration: retry))
        } catch { errorMessage = error.localizedDescription }
    }

    func inspectRepair() async {
        guard !isLoading, let startup else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            #if WORDNOTE_V3_VALIDATION
            _ = try await startup.inspectV3Repair()
            #else
            _ = try await startup.inspectRepair()
            #endif
        }
        catch { errorMessage = error.localizedDescription }
    }

    func repair() async {
        guard !isLoading, let startup else { return }
        isLoading = true
        defer { isLoading = false }
        do { try install(await startup.repair()) }
        catch { errorMessage = error.localizedDescription }
    }

    private func install(_ session: WordNoteStoreSession) throws {
        guard let store, let vault else { throw ValidationError.qaBundleRequired }
        UserDefaults.standard.set(AppRuntime.fixtureAppearance.rawValue, forKey: AppAppearancePreference.storageKey)
        if let preferences = session.preferencesToApply {
            UserDefaults.standard.set(preferences.appearance, forKey: AppAppearancePreference.storageKey)
            UserDefaults.standard.set(preferences.defaultSource, forKey: "defaultSourceType")
            guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            try store.acknowledgePreferences(for: session.generation)
        }
        let queue = try QuickAddAnalysisQueue(session: session, store: store, analysisHandler: AppRuntime.analyze)
        _ = try queue.recoverPendingAnalyses()
        let protection = WordNoteDataProtection(session: session, store: store, vault: vault, queue: queue, preferences: Self.preferences)
        let captureContext = CaptureContextController(
            preferences: .standard,
            availableCourseIDs: Set(try session.container.mainContext.fetch(FetchDescriptor<AppSchema.CourseModel>()).map(\.id))
        )
        let captureNavigator = CaptureResultNavigator { [weak protection] in protection?.isRestoring == false }
        let panel = QuickAddPanelController(
            modelContainer: session.container, analysisQueue: queue,
            dataProtection: protection, captureContext: captureContext, captureNavigator: captureNavigator
        )
        let shortcut = CaptureShortcutController(backend: CarbonCaptureShortcutBackend(), defaults: .standard) { [weak panel] in panel?.toggle() }
        protection.restoreStateDidChange = { [weak shortcut, weak captureNavigator] restoring in
            shortcut?.setAvailable(!restoring)
            if restoring { captureNavigator?.cancelPending() }
        }
        ready?.protection.restoreStateDidChange = nil
        ready?.shortcut.stop()
        ready?.panel.close()
        ready = Ready(
            session: session, queue: queue, protection: protection,
            undoHistory: try AppUndoHistory(container: session.container),
            panel: panel, shortcut: shortcut, captureContext: captureContext, captureNavigator: captureNavigator
        )
        shortcut.start()
        errorMessage = nil
    }

    private static func preferences() -> WordNoteSnapshotPayload.Preferences {
        .init(
            appearance: AppAppearancePreference.resolved(from: UserDefaults.standard.string(forKey: AppAppearancePreference.storageKey) ?? "system").rawValue,
            defaultSource: SourceType(rawValue: UserDefaults.standard.string(forKey: "defaultSourceType") ?? "other")?.rawValue ?? "other"
        )
    }

    private enum ValidationError: LocalizedError {
        case qaBundleRequired
        var errorDescription: String? { "This validation build only opens an isolated QA fixture. Use script/build_and_run.sh \(VersionedAppConfiguration.launchFlag)." }
    }
}
#endif
