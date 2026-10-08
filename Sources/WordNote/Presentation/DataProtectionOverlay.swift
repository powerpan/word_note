import AppKit
import SwiftUI
import WordNoteCore

struct DataProtectionOverlay: ViewModifier {
    let protection: WordNoteDataProtection

    func body(content: Content) -> some View {
        content
            .disabled(protection.isRestoring)
            .overlay {
                if protection.isRestoring {
                    ZStack {
                        WordNoteTheme.canvas.opacity(0.96)
                        VStack(spacing: 16) {
                            if protection.restorePhase == .preparing {
                                ProgressView()
                                Text("Preparing Restore").font(.headline)
                                Text("Saving a safety backup and verifying the replacement store.")
                            } else {
                                Image(systemName: "externaldrive.badge.checkmark").font(.title)
                                Text(protection.restorePhase == .readyToQuit ? "Restore Ready" : "Restore Needs Attention")
                                    .font(.headline)
                                Text(AppLocalization.text(protection.errorMessage ?? "Data changes are paused until Word Note quits."))
                                HStack {
                                    if protection.restorePhase == .readyToQuit {
                                        Button("Cancel Restore", role: .cancel) { try? protection.cancelRestore() }
                                    }
                                    Button { NSApp.terminate(nil) } label: {
                                        Label("Quit Word Note", systemImage: "power")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .multilineTextAlignment(.center)
                        .padding(28)
                        .frame(maxWidth: 520)
                    }
                }
            }
    }
}

struct CaptureProtectionModifier: ViewModifier {
    let protection: WordNoteDataProtection?
    func body(content: Content) -> some View {
        content.disabled(protection?.isRestoring == true)
    }
}
