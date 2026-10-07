import Darwin
import Foundation

enum PrivateFileIO {
    enum Checkpoint: Sendable {
        case beforeWrite
        case beforeCommit
    }

    typealias FaultInjection = @Sendable (Checkpoint) throws -> Void

    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o700) == 0 else { throw posixError() }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw WordNoteSnapshotError.sizeLimit }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WordNoteSnapshotError.invalidDocument }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw WordNoteSnapshotError.sizeLimit }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, maximumBytes + 1))
        while true {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw WordNoteSnapshotError.sizeLimit }
        }
        return data
    }

    @discardableResult
    static func secureExistingFile(_ url: URL) throws -> Bool {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return false }
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WordNoteSnapshotError.invalidDocument }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        return true
    }

    static func write(
        _ data: Data, to url: URL, replaceExisting: Bool = true,
        fault: FaultInjection? = nil
    ) throws {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        let name = url.lastPathComponent
        var targetInfo = stat()
        if fstatat(parent, name, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            guard targetInfo.st_mode & S_IFMT == S_IFREG else { throw WordNoteSnapshotError.invalidDocument }
        } else if errno != ENOENT {
            throw posixError()
        }
        try fault?(.beforeWrite)
        let temporaryName = ".wordnote-\(UUID().uuidString).tmp"
        let descriptor = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer {
            close(descriptor)
            unlinkat(parent, temporaryName, 0)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posixError() }
        try fault?(.beforeCommit)
        // Both names are relative to one opened directory, so a symlink cannot redirect the commit.
        let result = renameatx_np(parent, temporaryName, parent, name, replaceExisting ? 0 : UInt32(RENAME_EXCL))
        guard result == 0 else { throw posixError() }
        guard fsync(parent) == 0 else { throw posixError() }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
