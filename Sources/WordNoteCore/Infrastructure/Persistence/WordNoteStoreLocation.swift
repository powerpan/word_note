import Foundation

public struct WordNoteStoreMigrationResult: Equatable {
    public let storeURL: URL
    public let migratedLegacyStore: Bool
    public let backupDirectoryURL: URL?

    public init(storeURL: URL, migratedLegacyStore: Bool, backupDirectoryURL: URL?) {
        self.storeURL = storeURL
        self.migratedLegacyStore = migratedLegacyStore
        self.backupDirectoryURL = backupDirectoryURL
    }
}

public struct WordNoteStoreLocationManager {
    public let storeURL: URL
    public let legacyStoreURL: URL
    public let backupRootURL: URL

    private let fileManager: FileManager

    public init(
        applicationSupportURL: URL = Self.defaultApplicationSupportURL,
        fileManager: FileManager = .default
    ) {
        let appDirectory = applicationSupportURL.appending(path: "WordNote", directoryHint: .isDirectory)
        storeURL = appDirectory.appending(path: "WordNote.store")
        legacyStoreURL = applicationSupportURL.appending(path: "default.store")
        backupRootURL = appDirectory.appending(path: "Backups", directoryHint: .isDirectory)
        self.fileManager = fileManager
    }

    public func prepareStoreLocation() throws -> WordNoteStoreMigrationResult {
        try createPrivateDirectory(storeURL.deletingLastPathComponent())

        if fileManager.fileExists(atPath: storeURL.path) {
            try secureStoreFiles()
            return WordNoteStoreMigrationResult(
                storeURL: storeURL,
                migratedLegacyStore: false,
                backupDirectoryURL: nil
            )
        }

        guard fileManager.fileExists(atPath: legacyStoreURL.path) else {
            return WordNoteStoreMigrationResult(
                storeURL: storeURL,
                migratedLegacyStore: false,
                backupDirectoryURL: nil
            )
        }

        try createPrivateDirectory(backupRootURL)
        let backupDirectoryURL = backupRootURL.appending(
            path: "legacy-default-store-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try createPrivateDirectory(backupDirectoryURL)

        let suffixes = ["", "-wal", "-shm"]
        var destinationFiles: [URL] = []

        do {
            for suffix in suffixes {
                let sourceURL = URL(fileURLWithPath: legacyStoreURL.path + suffix)
                guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

                let backupURL = backupDirectoryURL.appending(path: legacyStoreURL.lastPathComponent + suffix)
                try fileManager.copyItem(at: sourceURL, to: backupURL)
                try setPrivateFilePermissions(backupURL)

                let destinationURL = URL(fileURLWithPath: storeURL.path + suffix)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                destinationFiles.append(destinationURL)
                try setPrivateFilePermissions(destinationURL)
            }
        } catch {
            for destinationURL in destinationFiles {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw error
        }

        return WordNoteStoreMigrationResult(
            storeURL: storeURL,
            migratedLegacyStore: true,
            backupDirectoryURL: backupDirectoryURL
        )
    }

    public func secureStoreFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            try setPrivateFilePermissions(fileURL)
        }
    }

    public static var defaultApplicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func setPrivateFilePermissions(_ url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
