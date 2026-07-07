import SwiftData
import SwiftUI
import WordNoteCore

@main
struct WordNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema(Self.modelTypes)
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup("Word Note") {
            ContentView()
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)

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
