import SwiftUI
import WordNoteCore

struct SettingsView: View {
    @Environment(WordNoteDataProtection.self) private var dataProtection
    @Environment(\.captureShortcut) private var captureShortcut
    @Environment(\.captureContext) private var captureContext
    @AppStorage(AppAppearancePreference.storageKey) private var appearanceRawValue = AppAppearancePreference.system.rawValue
    @AppStorage("defaultSourceType") private var defaultSourceType = "other"
    @State private var apiKey = ""
    @State private var keyStatusMessage: String?
    @State private var keyErrorMessage: String?
    #if WORDNOTE_V3_VALIDATION
    @AppStorage("reviewTargetCards") private var reviewTarget = 20
    @AppStorage("reviewDailyNewLimit") private var reviewNewLimit = 10
    #endif

    private let environmentFileStore = DeepSeekEnvironmentFileStore(
        fileURL: AppRuntime.isUITest ? AppRuntime.fixtureCredentialURL : DeepSeekAPIKeyResolver.defaultEnvironmentFileURL
    )

    private var appearanceSelection: Binding<AppAppearancePreference> {
        Binding(
            get: { AppAppearancePreference.resolved(from: appearanceRawValue) },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Settings",
                    subtitle: "Configure appearance, capture defaults, and the DeepSeek credential used by analysis."
                ) {
                    EmptyView()
                }

                GroupBox("Appearance") {
                    Picker("Theme", selection: appearanceSelection) {
                        ForEach(AppAppearancePreference.allCases) { appearance in
                            Label(appearance.displayTitle, systemImage: appearance.systemImage)
                                .tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .groupBoxStyle(WordNoteGroupBoxStyle())

                if let captureShortcut { CaptureShortcutSettings(controller: captureShortcut) }

                #if WORDNOTE_V3_VALIDATION
                GroupBox("Learning") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Group size: \(reviewTarget)", value: $reviewTarget, in: 5...100, step: 5)
                        Stepper("Daily new-card limit: \(reviewNewLimit)", value: $reviewNewLimit, in: 0...50)
                    }.padding(.vertical, 4)
                }.groupBoxStyle(WordNoteGroupBoxStyle())
                #endif

                GroupBox("Defaults") {
                    if let captureContext {
                        CaptureContextFields(controller: captureContext, scope: .defaults)
                            .frame(maxWidth: 420, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
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
                }
                .groupBoxStyle(WordNoteGroupBoxStyle())

                GroupBox("DeepSeek") {
                    VStack(alignment: .leading, spacing: 14) {
                        SecureField("API Key", text: $apiKey)
                            .textContentType(.password)
                            .frame(maxWidth: 520)

                        HStack {
                            Button {
                                saveAPIKey()
                            } label: {
                                Label("Save to Env File", systemImage: "doc.badge.gearshape")
                            }
                            .disabled(TextNormalizer.isBlank(apiKey))

                            Button(role: .destructive) {
                                deleteAPIKey()
                            } label: {
                                Label("Delete Env File", systemImage: "trash")
                            }
                        }

                        if let keyStatusMessage {
                            StatusBanner(message: keyStatusMessage, kind: .success)
                        }

                        if let keyErrorMessage {
                            StatusBanner(message: keyErrorMessage, kind: .warning)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text("The app reads DEEPSEEK_API_KEY from this environment file first, then falls back to the process environment.")
                            Text(environmentFileStore.fileURL.path)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .groupBoxStyle(WordNoteGroupBoxStyle())

                DataManagementView()
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear(perform: loadKeyStatus)
        .onChange(of: appearanceRawValue) { dataProtection.noteDataChanged() }
        .onChange(of: defaultSourceType) { dataProtection.noteDataChanged() }
    }

    private func loadKeyStatus() {
        keyErrorMessage = nil

        if environmentFileStore.load() != nil {
            keyStatusMessage = "DeepSeek key is saved in the environment file."
        } else if !AppRuntime.isUITest, DeepSeekAPIKeyResolver.resolve() != nil {
            keyStatusMessage = "Using DEEPSEEK_API_KEY from the process environment."
        } else {
            keyStatusMessage = nil
        }
    }

    private func saveAPIKey() {
        do {
            try environmentFileStore.save(apiKey)
            apiKey = ""
            keyErrorMessage = nil
            keyStatusMessage = "DeepSeek key saved to the environment file."
        } catch {
            keyStatusMessage = nil
            keyErrorMessage = error.localizedDescription
        }
    }

    private func deleteAPIKey() {
        do {
            try environmentFileStore.delete()
            keyStatusMessage = "DeepSeek environment file removed."
            keyErrorMessage = nil
        } catch {
            keyStatusMessage = nil
            keyErrorMessage = error.localizedDescription
        }
    }
}
