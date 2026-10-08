import AppKit
import WordNoteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var dataProtection: WordNoteDataProtection?
    var captureShortcut: CaptureShortcutController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if dataProtection?.restorePhase == .preparing { return .terminateCancel }
        #if WORDNOTE_V2_VALIDATION
        if dataProtection?.restorePhase != .readyToQuit {
            return EditProtectionWindows.shared.shouldTerminate(sender)
        }
        #endif
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureShortcut?.stop()
        dataProtection?.stopAutomaticBackups()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
