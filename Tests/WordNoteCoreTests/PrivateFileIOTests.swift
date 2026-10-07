import Darwin
import XCTest
@testable import WordNoteCore

final class PrivateFileIOTests: XCTestCase {
    func testPrivateDirectoryAndAtomicFilePermissions() throws {
        try withDirectory { root in
            let url = root.appending(path: "backup.json")
            try PrivateFileIO.write(Data("first".utf8), to: url)
            XCTAssertEqual(try permissions(root), 0o700)
            XCTAssertEqual(try permissions(url), 0o600)
            try PrivateFileIO.write(Data("second".utf8), to: url)
            XCTAssertEqual(try PrivateFileIO.read(url, maximumBytes: 6), Data("second".utf8))
            XCTAssertEqual(try permissions(url), 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["backup.json"])
        }
    }

    func testExclusiveWriteCannotOverwriteExistingBackup() throws {
        try withDirectory { root in
            let url = root.appending(path: "backup.json")
            try PrivateFileIO.write(Data("old".utf8), to: url, replaceExisting: false)
            XCTAssertThrowsError(try PrivateFileIO.write(Data("new".utf8), to: url, replaceExisting: false))
            XCTAssertEqual(try PrivateFileIO.read(url, maximumBytes: 20), Data("old".utf8))
        }
    }

    func testInterruptedWritePreservesOldFileAndRemovesTemporaryFile() throws {
        try withDirectory { root in
            let url = root.appending(path: "backup.json")
            try PrivateFileIO.write(Data("old".utf8), to: url)
            XCTAssertThrowsError(try PrivateFileIO.write(Data("new".utf8), to: url) { checkpoint in
                if checkpoint == .beforeCommit { throw POSIXError(.ENOSPC) }
            })
            XCTAssertEqual(try PrivateFileIO.read(url, maximumBytes: 20), Data("old".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["backup.json"])
        }
    }

    func testRejectsFileAndDirectorySymlinksWithoutTouchingTarget() throws {
        try withDirectory { root in
            let target = root.appending(path: "target")
            try PrivateFileIO.write(Data("unchanged".utf8), to: target)
            let link = root.appending(path: "link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try PrivateFileIO.read(link, maximumBytes: 100))
            XCTAssertThrowsError(try PrivateFileIO.write(Data("changed".utf8), to: link))
            XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
            let directoryLink = root.appending(path: "directory-link")
            try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
            XCTAssertThrowsError(try PrivateFileIO.prepareDirectory(directoryLink))
            XCTAssertThrowsError(try PrivateFileIO.read(directoryLink.appending(path: "target"), maximumBytes: 100))
            XCTAssertThrowsError(try PrivateFileIO.secureExistingFile(directoryLink.appending(path: "target")))
            XCTAssertThrowsError(try PrivateFileIO.write(Data(), to: directoryLink.appending(path: "unexpected")))
        }
    }

    func testRejectsNonRegularAndOversizedImportsWithoutBlocking() throws {
        try withDirectory { root in
            let url = root.appending(path: "large")
            try PrivateFileIO.write(Data(repeating: 1, count: 100), to: url)
            XCTAssertThrowsError(try PrivateFileIO.read(url, maximumBytes: 99))
            XCTAssertThrowsError(try PrivateFileIO.read(root, maximumBytes: 100))
            let pipe = root.appending(path: "pipe")
            XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
            XCTAssertThrowsError(try PrivateFileIO.read(pipe, maximumBytes: 100))
        }
    }

    func testExportDoesNotChangeChosenParentDirectoryPermissions() throws {
        try withDirectory { root in
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try PrivateFileIO.write(Data(), to: root.appending(path: "export.json"))
            XCTAssertEqual(try permissions(root), 0o755)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "private-io-\(UUID().uuidString)")
        try PrivateFileIO.prepareDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }
}
