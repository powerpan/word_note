import SwiftData
import SwiftUI
import WordNoteCore

@main
@MainActor
struct WordNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearancePreference.storageKey) private var appearanceRawValue = AppAppearancePreference.system.rawValue
    @State private var analysisQueue: QuickAddAnalysisQueue
    @State private var quickAddPanelController: QuickAddPanelController

    private let modelContainer: ModelContainer
    private let startupIssue: AppStartupIssue?

    private var selectedAppearance: AppAppearancePreference {
        AppAppearancePreference.resolved(from: appearanceRawValue)
    }

    init() {
        let schema = Schema(versionedSchema: WordNoteSchemaV1.self)
        let storeManager = WordNoteStoreLocationManager()
        let initialization: (container: ModelContainer, issue: AppStartupIssue?)

        do {
            if AppRuntime.isUITest {
                guard let fixture = AppRuntime.fixture else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                let container = try ModelContainer(for: schema, configurations: [configuration])
                try fixture.populate(container.mainContext)
                UserDefaults.standard.set(AppRuntime.fixtureAppearance.rawValue, forKey: AppAppearancePreference.storageKey)
                initialization = (container, nil)
            } else {
                let storeMigration = try storeManager.prepareStoreLocation()
                let configuration = ModelConfiguration(
                    "WordNote",
                    schema: schema,
                    url: storeMigration.storeURL
                )
                let persistentContainer = try ModelContainer(
                    for: schema,
                    migrationPlan: WordNoteMigrationPlan.self,
                    configurations: [configuration]
                )
                try storeManager.secureStoreFiles()
                _ = try DataIntegrityService(modelContext: persistentContainer.mainContext).repairDanglingReferences()
                _ = try? DeepSeekEnvironmentFileStore().migrateFromProcessEnvironmentIfNeeded()
                initialization = (persistentContainer, nil)
            }
        } catch {
            initialization = (
                Self.makeEmergencyContainer(schema: schema),
                AppStartupIssue(
                    message: error.localizedDescription,
                    storePath: storeManager.storeURL.path,
                    backupPath: storeManager.backupRootURL.path
                )
            )
        }

        modelContainer = initialization.container
        startupIssue = initialization.issue

        let queue = QuickAddAnalysisQueue(
            modelContext: initialization.container.mainContext,
            analysisHandler: AppRuntime.analyze
        )
        if initialization.issue == nil {
            _ = try? queue.recoverPendingAnalyses()
        }
        _analysisQueue = State(initialValue: queue)
        _quickAddPanelController = State(
            initialValue: QuickAddPanelController(
                modelContainer: initialization.container,
                analysisQueue: queue
            )
        )
    }

    var body: some Scene {
        WindowGroup(AppRuntime.isUITest ? "Word Note QA" : "Word Note", id: "main") {
            Group {
                if let startupIssue {
                    AppStartupFailureView(issue: startupIssue)
                } else {
                    ContentView()
                        .environment(analysisQueue)
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
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(startupIssue != nil)
            }
        }

        MenuBarExtra {
            WordNoteMenuBarMenu(
                analysisQueue: analysisQueue,
                quickAddPanelController: quickAddPanelController,
                captureAvailable: startupIssue == nil
            )
        } label: {
            WordNoteMenuBarLabel(analysisQueue: analysisQueue)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
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
}
