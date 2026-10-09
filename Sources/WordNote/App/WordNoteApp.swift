import SwiftData
import SwiftUI
import WordNoteCore

#if !WORDNOTE_V2_VALIDATION && !WORDNOTE_V3_VALIDATION
@main
@MainActor
struct WordNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearancePreference.storageKey) private var appearanceRawValue = AppAppearancePreference.system.rawValue
    @State private var analysisQueue: QuickAddAnalysisQueue
    @State private var quickAddPanelController: QuickAddPanelController
    @State private var dataProtection: WordNoteDataProtection?

    private let modelContainer: ModelContainer
    private let startupIssue: AppStartupIssue?

    private var selectedAppearance: AppAppearancePreference {
        AppAppearancePreference.resolved(from: appearanceRawValue)
    }

    init() {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let storeManager = WordNoteStoreLocationManager()
        let initialization: (container: ModelContainer, session: WordNoteStoreSession?, store: WordNoteRestoreStore?, issue: AppStartupIssue?)
        var failureStoreURL = storeManager.storeURL
        var failureBackupURL = storeManager.backupRootURL

        do {
            if AppRuntime.isUITest {
                guard let fixture = AppRuntime.fixture else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let directory = AppRuntime.fixtureDirectoryURL
                failureStoreURL = directory.appending(path: "WordNote.store")
                failureBackupURL = directory.appending(path: "Backups")
                let isNewSession = !FileManager.default.fileExists(atPath: directory.appending(path: "WordNote.store").path)
                    && !FileManager.default.fileExists(atPath: directory.appending(path: "store-generations.json").path)
                let store = WordNoteRestoreStore(directoryURL: directory)
                let session = try store.open()
                failureStoreURL = session.storeURL
                if isNewSession { try fixture.populate(session.container.mainContext) }
                try DataIntegrityService(modelContext: session.container.mainContext).validateBeforeOpening()
                UserDefaults.standard.set(AppRuntime.fixtureAppearance.rawValue, forKey: AppAppearancePreference.storageKey)
                try Self.applyRestoredPreferences(session, store: store)
                initialization = (session.container, session, store, nil)
            } else {
                let directory = storeManager.storeURL.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: directory.appending(path: "store-generations.json").path) {
                    _ = try storeManager.prepareStoreLocation()
                }
                let store = WordNoteRestoreStore(directoryURL: directory)
                let session = try store.open()
                failureStoreURL = session.storeURL
                failureBackupURL = directory.appending(path: "Backups")
                try DataIntegrityService(modelContext: session.container.mainContext).validateBeforeOpening()
                try Self.applyRestoredPreferences(session, store: store)
                _ = try? DeepSeekEnvironmentFileStore().migrateFromProcessEnvironmentIfNeeded()
                initialization = (session.container, session, store, nil)
            }
        } catch {
            initialization = (
                Self.makeEmergencyContainer(schema: schema),
                nil, nil,
                AppStartupIssue(
                    message: error.localizedDescription,
                    storePath: failureStoreURL.path,
                    backupPath: failureBackupURL.path
                )
            )
        }

        modelContainer = initialization.container
        startupIssue = initialization.issue

        let queue = QuickAddAnalysisQueue(
            modelContext: initialization.container.mainContext,
            initiallySuspended: initialization.session?.analysisRequiresResume ?? true,
            analysisHandler: AppRuntime.analyze
        )
        if initialization.issue == nil {
            _ = try? queue.recoverPendingAnalyses()
        }
        _analysisQueue = State(initialValue: queue)
        let protection: WordNoteDataProtection?
        if let session = initialization.session, let store = initialization.store {
            protection = WordNoteDataProtection(
                session: session, store: store,
                vault: WordNoteBackupVault(
                    directoryURL: store.directoryURL.appending(path: "Backups"),
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
                ), queue: queue,
                preferences: {
                    WordNoteSnapshotPayload.Preferences(
                        appearance: AppAppearancePreference.resolved(from: UserDefaults.standard.string(forKey: AppAppearancePreference.storageKey) ?? "system").rawValue,
                        defaultSource: SourceType(rawValue: UserDefaults.standard.string(forKey: "defaultSourceType") ?? "other")?.rawValue ?? "other"
                    )
                }
            )
        } else { protection = nil }
        _dataProtection = State(initialValue: protection)
        _quickAddPanelController = State(
            initialValue: QuickAddPanelController(
                modelContainer: initialization.container,
                analysisQueue: queue,
                dataProtection: protection
            )
        )
        appDelegate.dataProtection = protection
    }

    var body: some Scene {
        WindowGroup(AppRuntime.isUITest ? "Word Note QA" : "Word Note", id: "main") {
            Group {
                if let startupIssue {
                    AppStartupFailureView(issue: startupIssue)
                } else if let dataProtection {
                    ContentView()
                        .environment(analysisQueue)
                        .environment(dataProtection)
                        .modifier(DataProtectionOverlay(protection: dataProtection))
                        .task { dataProtection.startAutomaticBackups() }
                }
            }
            .modelContainer(modelContainer)
            .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .defaultSize(width: 1320, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Capture") {
                Button {
                    quickAddPanelController.show()
                } label: {
                    Label("Quick Add", systemImage: "plus.circle")
                }
                .commandShortcut("n", modifiers: [.command, .shift])
                .disabled(startupIssue != nil || dataProtection?.isRestoring == true)
            }
        }

        MenuBarExtra {
            WordNoteMenuBarMenu(
                analysisQueue: analysisQueue,
                quickAddPanelController: quickAddPanelController,
                captureAvailable: startupIssue == nil && dataProtection?.isRestoring != true
            )
        } label: {
            WordNoteMenuBarLabel(analysisQueue: analysisQueue)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            Group {
                if let dataProtection {
                    SettingsView()
                        .environment(dataProtection)
                        .modifier(DataProtectionOverlay(protection: dataProtection))
                        .task { dataProtection.startAutomaticBackups() }
                } else if let startupIssue {
                    AppStartupFailureView(issue: startupIssue)
                }
            }
                .modelContainer(modelContainer)
                .preferredColorScheme(selectedAppearance.preferredColorScheme)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
    }

    private static func makeEmergencyContainer(schema: Schema) -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            preconditionFailure("SwiftData could not create an in-memory recovery container: \(error)")
        }
    }

    private static func applyRestoredPreferences(_ session: WordNoteStoreSession, store: WordNoteRestoreStore) throws {
        guard let preferences = session.preferencesToApply else { return }
        UserDefaults.standard.set(preferences.appearance, forKey: AppAppearancePreference.storageKey)
        UserDefaults.standard.set(preferences.defaultSource, forKey: "defaultSourceType")
        guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        try store.acknowledgePreferences(for: session.generation)
    }
}
#endif
