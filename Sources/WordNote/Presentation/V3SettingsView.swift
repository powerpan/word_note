#if WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct V3SettingsView: View {
    @Environment(WordNoteDataProtection.self) private var protection
    @Environment(\.captureContext) private var captureContext
    @Environment(\.captureShortcut) private var captureShortcut
    @AppStorage(AppAppearancePreference.storageKey) private var appearance = "system"
    @AppStorage(WordNoteLearningPreferences.targetStorageKey) private var target = 20
    @AppStorage(WordNoteLearningPreferences.newLimitStorageKey) private var newLimit = 10
    @State private var preferenceError: String?
    @State private var selection = Section.general

    private enum Section: Hashable { case general, capture, learning, ai, data }

    var body: some View {
        TabView(selection: $selection) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(Section.general)
            capture.tabItem { Label("Capture", systemImage: "plus.square") }.tag(Section.capture)
            learning.tabItem { Label("Learning", systemImage: "rectangle.stack") }.tag(Section.learning)
            AIProviderSettingsView().tabItem { Label("AI", systemImage: "sparkles") }.tag(Section.ai)
            ScrollView {
                DataManagementView().padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.tabItem { Label("Data", systemImage: "externaldrive") }.tag(Section.data)
        }
        .padding(16)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 560)
        .tint(WordNoteTheme.brand)
        .onChange(of: appearance) { protection.noteDataChanged() }
        .onChange(of: target) { validatePreferences(); protection.noteDataChanged() }
        .onChange(of: newLimit) { validatePreferences(); protection.noteDataChanged() }
        .onChange(of: captureContext?.defaultContext) { validatePreferences(); protection.noteDataChanged() }
        .onAppear(perform: validatePreferences)
    }

    private var general: some View {
        Form {
            SwiftUI.Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearancePreference.allCases) { item in
                        Label(item.displayTitle, systemImage: item.systemImage).tag(item.rawValue)
                    }
                }.pickerStyle(.segmented)
            }
        }.formStyle(.grouped)
    }

    private var capture: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let captureContext {
                    CaptureContextFields(controller: captureContext, scope: .defaults)
                    Button("Reset Capture Defaults", systemImage: "arrow.counterclockwise") {
                        do { try captureContext.updateDefaults(.init()); validatePreferences() }
                        catch { preferenceError = error.localizedDescription }
                    }
                }
                if let captureShortcut { CaptureShortcutSettings(controller: captureShortcut) }
                preferenceWarning
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var learning: some View {
        Form {
            SwiftUI.Section("New Groups") {
                Stepper("Group size: \(target)", value: $target, in: 5...100)
                Stepper("Daily new-card limit: \(newLimit)", value: $newLimit, in: 0...50)
                Button("Reset Learning Defaults", systemImage: "arrow.counterclockwise") {
                    UserDefaults.standard.set(20, forKey: WordNoteLearningPreferences.targetStorageKey)
                    UserDefaults.standard.set(10, forKey: WordNoteLearningPreferences.newLimitStorageKey)
                    validatePreferences()
                    protection.noteDataChanged()
                }
            }
            preferenceWarning
        }.formStyle(.grouped)
    }

    @ViewBuilder private var preferenceWarning: some View {
        if let preferenceError { Label(preferenceError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
    }

    private func validatePreferences() {
        do { _ = try WordNoteLearningPreferences.capture(from: .standard); preferenceError = nil }
        catch { preferenceError = error.localizedDescription }
    }
}
#endif
