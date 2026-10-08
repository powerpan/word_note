#if WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct AIProviderSettingsView: View {
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var keyError: String?
    @State private var confirmDelete = false
    @State private var confirmTest = false
    @State private var connection = AIConnectionTestController(run: AppRuntime.testAIConnection)

    private let store = DeepSeekEnvironmentFileStore(
        fileURL: AppRuntime.isUITest ? AppRuntime.fixtureCredentialURL : DeepSeekAPIKeyResolver.defaultEnvironmentFileURL
    )

    var body: some View {
        Form {
            Section("Service") {
                LabeledContent("Provider", value: "DeepSeek")
                LabeledContent("Configured model", value: DeepSeekChatClient.defaultModel)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack {
                        Button("Test Connection", systemImage: "network") { confirmTest = true }
                            .disabled(AppRuntime.isUITest || !connection.canStart(at: timeline.date) || !apiKey.isEmpty)
                        if connection.state == .running {
                            ProgressView().controlSize(.small)
                            Button("Cancel", systemImage: "xmark", action: connection.cancel)
                                .labelStyle(.iconOnly).help("Cancel connection test")
                        }
                    }
                }
                connectionStatus
                if AppRuntime.isUITest { Text("Live connection tests are disabled in the isolated QA app.").foregroundStyle(.secondary) }
            }
            Section("Credential") {
                SecureField("New API key", text: $apiKey).textContentType(.password)
                HStack {
                    Button("Save", systemImage: "checkmark", action: save)
                        .disabled(TextNormalizer.isBlank(apiKey) || connection.state == .running)
                    Button("Remove Saved Key", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(connection.state == .running)
                }
                if let keyStatus { Text(keyStatus).foregroundStyle(.secondary) }
                if let keyError { Label(keyError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                DisclosureGroup("Environment File") {
                    Text(store.fileURL.path).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadStatus)
        .onDisappear { connection.cancel() }
        .onChange(of: apiKey) { if connection.state != .idle { connection.credentialsChanged() } }
        .alert("Test DeepSeek Connection?", isPresented: $confirmTest) {
            Button("Send Test") { connection.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("One fixed test message will be sent using the saved credential and may incur API charges. No vocabulary, notes or course data will be sent.")
        }
        .alert("Remove Saved API Key?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the managed environment file only. Other configured credential sources are unchanged.")
        }
    }

    @ViewBuilder private var connectionStatus: some View {
        switch connection.state {
        case .idle: Text("Not tested").foregroundStyle(.secondary)
        case .running: Text("Connecting...").foregroundStyle(.secondary)
        case .cancelled: Text("Test cancelled. The provider may already have processed it.").foregroundStyle(.secondary)
        case .succeeded(let receipt):
            LabeledContent("Responding model", value: receipt.model)
            LabeledContent("Last successful test") { Text(receipt.completedAt, format: .dateTime.year().month().day().hour().minute()) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            if let date = connection.retryNotBefore {
                LabeledContent("Retry after") { Text(date, format: .dateTime.hour().minute().second()) }
            }
        }
    }

    private func loadStatus() {
        keyError = nil
        if store.load() != nil { keyStatus = "A key is saved in the managed environment file." }
        else if !AppRuntime.isUITest, DeepSeekAPIKeyResolver.resolve() != nil { keyStatus = "A key is available from another configured source." }
        else { keyStatus = "No key configured." }
    }

    private func save() {
        do {
            try store.save(apiKey)
            apiKey = ""
            connection.credentialsChanged()
            loadStatus()
        } catch { keyError = "The environment file could not be saved." }
    }

    private func remove() {
        do {
            try store.delete()
            connection.credentialsChanged()
            loadStatus()
        } catch { keyError = "The environment file could not be removed." }
    }
}
#endif
