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
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .modelContainer(modelContainer)
        }
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
