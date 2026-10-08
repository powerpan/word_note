#if WORDNOTE_V2_VALIDATION
import Foundation
import Observation
import SwiftData
import WordNoteCore

/// This build must never fall through to the user's production store or credentials.
@MainActor
@Observable
final class V2ValidationRuntime {
    struct Ready {
        let session: WordNoteStoreSession
        let queue: WordNoteV2AnalysisQueue
        let protection: WordNoteDataProtection
        let undoHistory: WordNoteV2UndoHistory
        let panel: QuickAddPanelController
        let shortcut: CaptureShortcutController
        let captureContext: CaptureContextController
    }

    private(set) var ready: Ready?
    private(set) var startup: WordNoteV2StartupCoordinator?
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
                    let original = try WordNoteRestoreStore(directoryURL: directory).open()
                    try fixture.populate(original.container.mainContext)
                }
                let store = WordNoteRestoreStore(directoryURL: directory, targetSchema: .v2)
                let vault = WordNoteBackupVault(directoryURL: directory.appending(path: "Backups"), appVersion: "V2-QA")
                self.store = store
                self.vault = vault
                startup = WordNoteV2StartupCoordinator(store: store, vault: vault, preferences: Self.preferences)
            }
            guard let startup else { throw ValidationError.qaBundleRequired }
            try install(await startup.open(retryMigration: retry))
        } catch { errorMessage = error.localizedDescription }
    }

    func inspectRepair() async {
        guard !isLoading, let startup else { return }
        isLoading = true
        defer { isLoading = false }
        do { _ = try await startup.inspectRepair() }
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
        let queue = try WordNoteV2AnalysisQueue(session: session, store: store, analysisHandler: AppRuntime.analyze)
        _ = try queue.recoverPendingAnalyses()
        let protection = WordNoteDataProtection(session: session, store: store, vault: vault, queue: queue, preferences: Self.preferences)
        let captureContext = CaptureContextController(
            preferences: .standard,
            availableCourseIDs: Set(try session.container.mainContext.fetch(FetchDescriptor<WordNoteSchemaV2.CourseModel>()).map(\.id))
        )
        let panel = QuickAddPanelController(
            modelContainer: session.container, analysisQueue: queue,
            dataProtection: protection, captureContext: captureContext
        )
        let shortcut = CaptureShortcutController(backend: CarbonCaptureShortcutBackend(), defaults: .standard) { [weak panel] in panel?.toggle() }
        protection.restoreStateDidChange = { [weak shortcut] restoring in shortcut?.setAvailable(!restoring) }
        ready?.protection.restoreStateDidChange = nil
        ready?.shortcut.stop()
        ready?.panel.close()
        ready = Ready(
            session: session, queue: queue, protection: protection,
            undoHistory: try WordNoteV2UndoHistory(container: session.container),
            panel: panel, shortcut: shortcut, captureContext: captureContext
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
        var errorDescription: String? { "This validation build only opens an isolated QA fixture. Use script/build_and_run.sh --ui-v2-fixture." }
    }
}
#endif
