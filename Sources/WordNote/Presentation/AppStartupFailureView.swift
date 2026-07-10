import SwiftUI

struct AppStartupIssue {
    let message: String
    let storePath: String
    let backupPath: String
}

struct AppStartupFailureView: View {
    let issue: AppStartupIssue

    var body: some View {
        ContentUnavailableView {
            Label("Word Note Storage Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text(issue.message)
                Text("Your existing data has not been deleted. Restore from the backup directory or repair the store before continuing.")
            }
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
                pathRow("Store", issue.storePath)
                pathRow("Backups", issue.backupPath)
            }
            .frame(maxWidth: 620, alignment: .leading)
        }
        .padding(32)
    }

    private func pathRow(_ title: String, _ path: String) -> some View {
        LabeledContent(title) {
            Text(path)
                .monospaced()
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }
}
