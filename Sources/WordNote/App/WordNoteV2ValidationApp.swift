#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

@main
@MainActor
struct WordNoteValidationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppAppearancePreference.storageKey) private var appearance = "system"
    @State private var runtime = VersionedValidationRuntime()

    var body: some Scene {
        WindowGroup(VersionedAppConfiguration.title, id: "main") {
            Group {
                if let ready = runtime.ready {
                    EditProtectionHost { ContentView().modifier(SavedChangeUndoControls(history: ready.undoHistory)) }
                        .modelContainer(ready.session.container)
                        .environment(ready.queue)
                        .environment(ready.protection)
                        .environment(\.savedChangeHistory, ready.undoHistory)
                        .environment(\.captureShortcut, ready.shortcut)
                        .environment(\.captureContext, ready.captureContext)
                        .environment(\.captureNavigator, ready.captureNavigator)
                        .modifier(DataProtectionOverlay(protection: ready.protection))
                        .task {
                            ready.protection.startAutomaticBackups()
                            appDelegate.dataProtection = ready.protection
                            appDelegate.captureShortcut = ready.shortcut
                        }
                } else {
                    VersionedValidationStartupView(runtime: runtime)
                }
            }
            .preferredColorScheme(AppAppearancePreference.resolved(from: appearance).preferredColorScheme)
            .task { await runtime.start() }
        }
        .defaultSize(width: 1320, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .undoRedo) { SavedChangeUndoCommand() }
            CommandMenu("Capture") {
                Button("Quick Add", systemImage: "plus.circle") { runtime.ready?.panel.toggle() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(runtime.ready == nil || runtime.ready?.protection.isRestoring == true)
            }
        }

        MenuBarExtra {
            if let ready = runtime.ready {
                WordNoteMenuBarMenu(analysisQueue: ready.queue, quickAddPanelController: ready.panel, captureAvailable: !ready.protection.isRestoring)
            } else { Text("Word Note is not ready") }
        } label: {
            if let ready = runtime.ready { WordNoteMenuBarLabel(analysisQueue: ready.queue) }
            else { Image(systemName: "book.closed") }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            Group {
                if let ready = runtime.ready {
                    SettingsView()
                        .modelContainer(ready.session.container)
                        .environment(ready.protection)
                        .environment(\.captureShortcut, ready.shortcut)
                        .environment(\.captureContext, ready.captureContext)
                        .modifier(DataProtectionOverlay(protection: ready.protection))
                } else { VersionedValidationStartupView(runtime: runtime) }
            }
            .preferredColorScheme(AppAppearancePreference.resolved(from: appearance).preferredColorScheme)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
    }
}

private struct VersionedValidationStartupView: View {
    let runtime: VersionedValidationRuntime
    @State private var confirmRepair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(VersionedAppConfiguration.title).font(.title2.bold())
            if runtime.isLoading { ProgressView("Preparing isolated data...") }
            if let message = runtime.errorMessage {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await runtime.start(retry: true) } }
                    Button("Inspect Data", systemImage: "doc.text.magnifyingglass") { Task { await runtime.inspectRepair() } }
                }
                .disabled(runtime.isLoading)
            }
            #if WORDNOTE_V3_VALIDATION
            if let report = runtime.startup?.v3RepairReport {
                Text("\(report.detachableReferenceCount) missing optional references; \(report.issues.count) findings")
                if report.requiresManualResolution { Text("Manual resolution required. No data was changed.") }
                Button("Repair References", systemImage: "wrench.and.screwdriver") { confirmRepair = true }
                    .disabled(!report.canPrepareRepair || runtime.isLoading)
            }
            #else
            if let report = runtime.startup?.repairReport {
                Text("\(report.detachableReferenceCount) missing optional references; \(report.issues.count) findings")
                if report.requiresManualResolution { Text("Manual resolution required. No data was changed.") }
                Button("Repair References", systemImage: "wrench.and.screwdriver") { confirmRepair = true }
                    .disabled(!report.canPrepareRepair || runtime.isLoading)
            }
            #endif
        }
        .padding(32)
        .frame(minWidth: 600, minHeight: 300)
        .confirmationDialog("Repair missing optional references?", isPresented: $confirmRepair) {
            Button("Repair") { Task { await runtime.repair() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The original store and repair evidence will be retained. No vocabulary entries will be deleted.") }
    }
}
#endif
