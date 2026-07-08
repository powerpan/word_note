import SwiftData
import SwiftUI
import WordNoteCore

@main
struct WordNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var analysisQueue: QuickAddAnalysisQueue
    @State private var quickAddPanelController: QuickAddPanelController

    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema(Self.modelTypes)
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            let queue = QuickAddAnalysisQueue(modelContext: modelContainer.mainContext)
            _analysisQueue = State(initialValue: queue)
            _quickAddPanelController = State(
                initialValue: QuickAddPanelController(
                    modelContainer: modelContainer,
                    analysisQueue: queue
                )
            )
        } catch {
            fatalError("Failed to initialize model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("Word Note", id: "main") {
            ContentView()
                .environment(analysisQueue)
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 1200, height: 760)
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
            }
        }

        MenuBarExtra {
            WordNoteMenuBarMenu(
                analysisQueue: analysisQueue,
                quickAddPanelController: quickAddPanelController
            )
        } label: {
            WordNoteMenuBarLabel(analysisQueue: analysisQueue)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
    }

    private static var modelTypes: [any PersistentModel.Type] {
        [
            CourseModel.self,
            InputRecordModel.self,
            CandidateTermModel.self,
            TermModel.self,
            ReviewEventModel.self
        ]
    }
}
