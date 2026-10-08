import AppKit
import UniformTypeIdentifiers

@MainActor
enum DataFilePicker {
    static func exportURL(csvCount: Int? = nil) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = csvCount == nil ? [.json] : [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = csvCount == nil ? "WordNote-Backup.json" : "WordNote-Vocabulary.csv"
        panel.message = csvCount.map {
            AppLocalization.format("Export %lld vocabulary entries as CSV. This is not a full backup. The file contains private learning content and is not encrypted.", $0)
        } ?? AppLocalization.text("Export all learning data as JSON. The file contains private learning content and is not encrypted. API keys are excluded.")
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    static func importURL() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = AppLocalization.text("Choose a complete Word Note JSON backup. Nothing is replaced until you confirm.")
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
