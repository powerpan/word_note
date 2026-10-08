import Carbon
import XCTest
import WordNoteCore
@testable import WordNote

@MainActor
final class CarbonCaptureShortcutTests: XCTestCase {
    func testEverySupportedKeyHasUniqueNativeMapping() {
        XCTAssertEqual(Set(CaptureShortcut.Key.allCases.map(\.carbonKeyCode)).count, CaptureShortcut.Key.allCases.count)
        XCTAssertEqual(CaptureShortcut.Key.space.carbonKeyCode, UInt32(kVK_Space))
        XCTAssertEqual(CaptureShortcut.Key.n.carbonKeyCode, UInt32(kVK_ANSI_N))
    }

    func testNativeExclusiveRegistrationConflictAndRelease() throws {
        guard ProcessInfo.processInfo.environment["RUN_NATIVE_HOTKEY_TESTS"] == "1" else {
            throw XCTSkip("Opt in with RUN_NATIVE_HOTKEY_TESTS=1 to briefly register a synthetic macOS shortcut.")
        }
        let first = CarbonCaptureShortcutBackend(), second = CarbonCaptureShortcutBackend()
        defer { try? first.unregister(1); try? second.unregister(1) }
        let shortcut = CaptureShortcut(key: .f12, modifiers: .all)
        try first.register(shortcut, id: 1) { _ in }
        XCTAssertThrowsError(try second.register(shortcut, id: 1) { _ in }) {
            XCTAssertEqual($0 as? CaptureShortcutError, .registrationFailed(OSStatus(eventHotKeyExistsErr)))
        }
        try first.unregister(1)
        try second.register(shortcut, id: 1) { _ in }
        try second.unregister(1)
        XCTAssertNoThrow(try second.unregister(1))
        do {
            let temporary = CarbonCaptureShortcutBackend()
            try temporary.register(shortcut, id: 1) { _ in }
            withExtendedLifetime(temporary) {}
        }
        XCTAssertNoThrow(try first.register(shortcut, id: 2) { _ in })
        try first.unregister(2)
    }
}
