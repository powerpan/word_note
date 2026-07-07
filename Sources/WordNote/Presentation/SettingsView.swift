import SwiftUI
import WordNoteCore

struct SettingsView: View {
    @AppStorage("defaultSourceType") private var defaultSourceType = "other"
    @State private var apiKey = ""
    @State private var keyStatusMessage: String?
    @State private var keyErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Settings",
                    subtitle: "Configure capture defaults and the DeepSeek credential used by analysis."
                ) {
                    EmptyView()
                }

                GroupBox("Defaults") {
                    Picker("Default source", selection: $defaultSourceType) {
                        Text("Class").tag("class")
                        Text("Paper").tag("paper")
                        Text("Slides").tag("slides")
                        Text("Assignment").tag("assignment")
                        Text("Book").tag("book")
                        Text("Other").tag("other")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("DeepSeek") {
                    VStack(alignment: .leading, spacing: 14) {
                        SecureField("API Key", text: $apiKey)
                            .textContentType(.password)
                            .frame(maxWidth: 520)

                        HStack {
                            Button {
                                saveAPIKey()
                            } label: {
                                Label("Save Key", systemImage: "key")
                            }
                            .disabled(TextNormalizer.isBlank(apiKey))

                            Button(role: .destructive) {
                                deleteAPIKey()
                            } label: {
                                Label("Delete Key", systemImage: "trash")
                            }
                        }

                        if let keyStatusMessage {
                            StatusBanner(message: keyStatusMessage, kind: .success)
                        }

                        if let keyErrorMessage {
                            StatusBanner(message: keyErrorMessage, kind: .warning)
                        }

                        Text("The app also reads DEEPSEEK_API_KEY from the process environment when Keychain is empty.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
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
