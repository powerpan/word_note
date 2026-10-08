import Foundation
import WordNoteCore

enum AppRuntime {
    static let isUITest = Bundle.main.bundleIdentifier == "com.powerpan.WordNote.UITest"

    static var fixture: WordNoteTestFixture? {
        guard isUITest else { return nil }
        return WordNoteTestFixture(rawValue: argument(after: "--ui-fixture") ?? "")
    }

    static var fixtureAppearance: AppAppearancePreference {
        AppAppearancePreference.resolved(from: argument(after: "--ui-appearance") ?? "light")
    }

    static let fixtureSessionID = UUID(uuidString: argument(after: "--ui-session") ?? "") ?? UUID()
    static let fixtureDirectoryURL = FileManager.default.temporaryDirectory
        .appending(path: "WordNote-QA/\(fixtureSessionID.uuidString.lowercased())", directoryHint: .isDirectory)
    static let fixtureCredentialURL = fixtureDirectoryURL.appending(path: "deepseek.env")

    @MainActor
    static func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult {
        if isUITest {
            return WordNoteTestFixture.analysisResult(for: request)
        }
        guard let apiKey = DeepSeekAPIKeyResolver.resolve() else {
            throw AIAnalysisError.missingAPIKey
        }
        return try await AIAnalysisService(client: DeepSeekChatClient(apiKey: apiKey)).analyze(request)
    }

    @MainActor
    static func testAIConnection() async throws -> String {
        guard !isUITest else { throw AIAnalysisError.network("Live connection tests are disabled in QA.") }
        guard let apiKey = DeepSeekAPIKeyResolver.resolve() else { throw AIAnalysisError.missingAPIKey }
        return try await DeepSeekConnectionProbe(client: DeepSeekChatClient(apiKey: apiKey)).run()
    }

    private static func argument(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
