import SwiftUI
import WordNoteCore

struct SettingsView: View {
    @AppStorage("defaultSourceType") private var defaultSourceType = "other"
    @State private var apiKey = ""
    @State private var keyStatusMessage: String?
    @State private var keyErrorMessage: String?

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default source", selection: $defaultSourceType) {
                    Text("Class").tag("class")
                    Text("Paper").tag("paper")
                    Text("Slides").tag("slides")
                    Text("Assignment").tag("assignment")
                    Text("Book").tag("book")
                    Text("Other").tag("other")
                }
                .pickerStyle(.menu)
            }

            Section("DeepSeek") {
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)

                HStack {
                    Button("Save Key") {
                        saveAPIKey()
                    }
                    .disabled(TextNormalizer.isBlank(apiKey))

                    Button("Delete Key", role: .destructive) {
                        deleteAPIKey()
                    }
                }

                if let keyStatusMessage {
                    Label(keyStatusMessage, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }

                if let keyErrorMessage {
                    Label(keyErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                Text("The app also reads DEEPSEEK_API_KEY from the process environment when Keychain is empty.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadKeyStatus)
    }

    private func loadKeyStatus() {
        if let key = try? KeychainStore.deepSeekAPIKey.load(), !TextNormalizer.isBlank(key) {
            keyStatusMessage = "A DeepSeek key is saved in Keychain."
        } else if DeepSeekAPIKeyResolver.resolve() != nil {
            keyStatusMessage = "Using DEEPSEEK_API_KEY from environment."
        }
    }

    private func saveAPIKey() {
        do {
            try KeychainStore.deepSeekAPIKey.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKey = ""
            keyErrorMessage = nil
            keyStatusMessage = "DeepSeek key saved to Keychain."
        } catch {
            keyStatusMessage = nil
            keyErrorMessage = error.localizedDescription
        }
    }

    private func deleteAPIKey() {
        do {
            try KeychainStore.deepSeekAPIKey.delete()
            keyStatusMessage = "DeepSeek key removed from Keychain."
            keyErrorMessage = nil
        } catch {
            keyStatusMessage = nil
            keyErrorMessage = error.localizedDescription
        }
    }
}
