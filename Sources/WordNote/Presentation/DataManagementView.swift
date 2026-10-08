import AppKit
import SwiftUI
import WordNoteCore

struct DataManagementView: View {
    @Environment(WordNoteDataProtection.self) private var protection
    @State private var preview: WordNoteVersionedRestorePreview?
    @State private var localError: String?
    @State private var deletingBackup: WordNoteBackupSummary?
    @State private var confirmResume = false
    @State private var resumeCount = 0

    var body: some View {
        GroupBox("Data & Backups") {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                .disabled(protection.isWorking || protection.isRestoring)

                if protection.isWorking { ProgressView().controlSize(.small) }
                if let message = protection.statusMessage { StatusBanner(message: message, kind: .success) }
                if let message = protection.errorMessage { StatusBanner(message: message, kind: .warning) }
                if let localError { StatusBanner(message: localError, kind: .warning) }
                if protection.unreadableBackupCount > 0 {
                    StatusBanner(message: "\(protection.unreadableBackupCount) backup files could not be verified and were left untouched.", kind: .warning)
                }
                if protection.catalogNeedsRepair {
                    StatusBanner(message: "The backup catalog is damaged. Verified backup files remain available.", kind: .warning)
                }
                if protection.analysisRequiresResume {
                    HStack {
                        Label("Pending analysis is paused", systemImage: "pause.circle")
                        Spacer()
                        Button {
                            do {
                                resumeCount = try protection.pendingAnalysisCount()
                                localError = nil
                                confirmResume = true
                            } catch { localError = error.localizedDescription }
                        } label: { Label("Resume", systemImage: "play.fill") }
                        .disabled(protection.isWorking || protection.isRestoring)
                    }
                }

                HStack {
                    Text("Saved Backups").font(.headline)
                    Spacer()
                    Button { NSWorkspace.shared.open(protection.backupDirectoryURL) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Open backup folder")
                    .accessibilityLabel("Open backup folder")
                }
                if protection.snapshots.isEmpty {
                    Text("No backups yet").foregroundStyle(.secondary)
                } else {
                    ForEach(protection.snapshots) { backup in
                        Divider()
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: backup.kind == .automatic ? "clock.arrow.circlepath" : "externaldrive")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.subheadline.weight(.medium))
                                Text("\(kindTitle(backup.kind)) · \(backup.counts.terms) terms · \(backup.counts.inputRecords) records")
                                    .font(.caption).foregroundStyle(.secondary)
                                if backup.schemaVersion != .v1 {
                                    Text("Schema \(backup.schemaVersion.rawValue)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Menu {
                                Button("Restore…", systemImage: "arrow.counterclockwise") {
                                    Task { preview = try? await protection.previewVersionedRestore(id: backup.id) }
                                }
                                Button("Export JSON…", systemImage: "square.and.arrow.up") {
                                    Task {
                                        guard let url = await DataFilePicker.exportURL() else { return }
                                        try? await protection.exportBackup(to: url, id: backup.id)
                                    }
                                }
                                Divider()
                                Button("Delete Backup…", systemImage: "trash", role: .destructive) { deletingBackup = backup }
                            } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Backup actions")
                            .accessibilityLabel("Backup actions")
                            .disabled(protection.isWorking || protection.isRestoring)
                        }
                    }
                }
                Text("Backups may retain previously deleted learning data. Files are private to your account, not additionally encrypted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .groupBoxStyle(WordNoteGroupBoxStyle())
        .task { await protection.refresh() }
        .sheet(item: $preview) { preview in
            RestorePreviewView(preview: preview) { self.preview = nil }
        }
        .alert("Delete This Backup?", isPresented: Binding(
            get: { deletingBackup != nil }, set: { if !$0 { deletingBackup = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let backup = deletingBackup else { return }
                Task { try? await protection.deleteBackup(id: backup.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the selected backup file. Active vocabulary is unchanged.")
        }
        .alert("Resume Pending Analysis?", isPresented: $confirmResume) {
            Button("Resume") { try? protection.resumeAnalysis() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(resumeCount) pending requests may be sent to DeepSeek and incur API charges. Previously interrupted requests may already have been billed.")
        }
    }

    @ViewBuilder private var actions: some View {
        Button { Task { try? await protection.createBackup() } } label: {
            Label("Back Up Now", systemImage: "externaldrive.badge.plus")
        }
        Button {
            Task {
                guard let url = await DataFilePicker.exportURL() else { return }
                try? await protection.exportBackup(to: url)
            }
        } label: { Label("Export JSON…", systemImage: "square.and.arrow.up") }
        Button {
            Task {
                guard let url = await DataFilePicker.importURL() else { return }
                preview = try? await protection.previewVersionedRestore(url: url)
            }
        } label: { Label("Restore…", systemImage: "arrow.counterclockwise") }
    }

    private func kindTitle(_ kind: WordNoteBackupKind) -> String {
        switch kind {
        case .automatic: "Automatic"
        case .manual: "Manual"
        case .beforeMigration: "Before migration"
        case .beforeRestore: "Before restore"
        }
    }
}

private struct RestorePreviewView: View {
    @Environment(WordNoteDataProtection.self) private var protection
    let preview: WordNoteVersionedRestorePreview
    let onCancel: () -> Void
    @State private var replacementAcknowledged = false

    private var formatVersion: Int {
        switch preview.snapshot {
        case .v1(let snapshot): snapshot.document.formatVersion
        case .v2(let snapshot): snapshot.document.formatVersion
        case .v3(let snapshot): snapshot.document.formatVersion
        }
    }

    var body: some View {
        let document = preview.snapshot.summary
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Backup").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("Created"); Text(document.createdAt, format: .dateTime.year().month().day().hour().minute()) }
                GridRow { Text("Schema / Format"); Text("\(document.schemaVersion.rawValue) / \(formatVersion)") }
                GridRow { Text("App Version"); Text(document.appVersion) }
                GridRow { Text("Vocabulary"); Text("\(document.counts.terms)") }
                GridRow { Text("Input Records"); Text("\(document.counts.inputRecords)") }
                GridRow { Text("Candidates"); Text("\(document.counts.candidates)") }
                GridRow { Text("Courses"); Text("\(document.counts.courses)") }
                GridRow { Text("Review Events"); Text("\(document.counts.reviewEvents)") }
                if document.schemaVersion != .v1 {
                    GridRow { Text("Sources"); Text("\(document.counts.occurrences)") }
                    GridRow { Text("Course Links"); Text("\(document.counts.courseLinks)") }
                    GridRow { Text("Lookup Events"); Text("\(document.counts.lookupEvents)") }
                }
                if document.schemaVersion == .v3 {
                    GridRow { Text("Review Cards"); Text("\(document.counts.cards)") }
                    GridRow { Text("Review Sessions"); Text("\(document.counts.sessions)") }
                    GridRow { Text("Session Items"); Text("\(document.counts.sessionItems)") }
                }
            }
            Text("This replaces all learning data, not a merge. A safety backup is required first. Word Note will quit; the replacement opens on its next launch. Unfinished AI requests will remain paused.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Replace current data and discard unsaved forms in all windows", isOn: $replacementAcknowledged)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Restore and Quit", role: .destructive) {
                    onCancel()
                    Task {
                        do {
                            try await protection.prepareRestore(preview)
                            NSApp.terminate(nil)
                        } catch { /* The shared data panel retains the actionable error. */ }
                    }
                }
                .disabled(!replacementAcknowledged || protection.isWorking)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
