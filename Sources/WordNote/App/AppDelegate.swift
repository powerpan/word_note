import AppKit
import WordNoteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var dataProtection: WordNoteDataProtection?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        dataProtection?.restorePhase == .preparing ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        dataProtection?.stopAutomaticBackups()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
