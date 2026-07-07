import Foundation

public enum DeepSeekAPIKeyStoreError: LocalizedError, Equatable {
    case writeFailed(String)
    case deleteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let summary):
            return "Failed to write DeepSeek environment file: \(summary)"
        case .deleteFailed(let summary):
            return "Failed to delete DeepSeek environment file: \(summary)"
        }
    }
}

public struct DeepSeekEnvironmentFileStore {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = DeepSeekAPIKeyResolver.defaultEnvironmentFileURL,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() -> String? {
        DeepSeekAPIKeyResolver.resolveFromEnvironmentFile(fileURL, fileManager: fileManager)
    }

    public func save(_ apiKey: String) throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedKey) else { return }

        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let content = "\(DeepSeekAPIKeyResolver.environmentVariableName)=\(Self.envQuoted(trimmedKey))\n"
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw DeepSeekAPIKeyStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func delete() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw DeepSeekAPIKeyStoreError.deleteFailed(error.localizedDescription)
        }
    }

    private static func envQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }
}

public enum DeepSeekAPIKeyResolver {
    public static let environmentVariableName = "DEEPSEEK_API_KEY"
    public static let environmentFileOverrideVariableName = "WORD_NOTE_ENV_FILE"
    public static let defaultEnvironmentFileName = "deepseek.env"

    public static var defaultEnvironmentFileURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (baseURL ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support"))
            .appending(path: "WordNote", directoryHint: .isDirectory)
            .appending(path: defaultEnvironmentFileName)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        for fileURL in environmentFileCandidates(environment: environment, fileManager: fileManager) {
            if let value = resolveFromEnvironmentFile(fileURL, fileManager: fileManager) {
                return value
            }
        }

        let environmentValue = environment[environmentVariableName]
        guard let environmentValue, !TextNormalizer.isBlank(environmentValue) else {
            return nil
        }
        return environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resolveFromEnvironmentFile(
        _ fileURL: URL,
        fileManager: FileManager = .default
    ) -> String? {
        guard fileManager.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return nil
        }

        return parseEnvironment(content: content)[environmentVariableName]
    }

    public static func environmentFileCandidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        var urls: [URL] = []

        if let overridePath = environment[environmentFileOverrideVariableName],
           !TextNormalizer.isBlank(overridePath) {
            urls.append(URL(fileURLWithPath: expandedPath(overridePath)))
        }

        urls.append(defaultEnvironmentFileURL)
        urls.append(fileManager.currentDirectoryPathURL.appending(path: ".env.local"))
        urls.append(fileManager.currentDirectoryPathURL.appending(path: ".env"))

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            if seen.contains(path) {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    static func parseEnvironment(content: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in content.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }

            guard let separatorIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            let value = unquote(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !TextNormalizer.isBlank(value) else { continue }
            values[key] = value
        }

        return values
    }

    private static func expandedPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.hasPrefix("~/") else { return trimmedPath }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return homePath + String(trimmedPath.dropFirst())
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\$", with: "$")
                .replacingOccurrences(of: "\\`", with: "`")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }

        return value
    }
}

private extension FileManager {
    var currentDirectoryPathURL: URL {
        URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
    }
}
