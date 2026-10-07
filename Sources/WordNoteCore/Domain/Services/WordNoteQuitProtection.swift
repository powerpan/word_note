import Foundation

/// Resolves window-scoped drafts without letting one window bypass another's decision.
@MainActor
public final class WordNoteQuitProtection {
    public private(set) var isActive = false
    private var protections: (() -> [WordNoteEditProtection])?
    private var activate: ((WordNoteEditProtection) -> Void)?
    private var completion: ((Bool) -> Void)?

    public init() {}

    @discardableResult
    public func request(
        protections: @escaping () -> [WordNoteEditProtection],
        activate: @escaping (WordNoteEditProtection) -> Void = { _ in },
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isActive, !protections().contains(where: \.hasPendingTransition) else { return false }
        isActive = true
        self.protections = protections
        self.activate = activate
        self.completion = completion
        resolveNext()
        return true
    }

    private func resolveNext() {
        let current = protections?() ?? []
        guard !current.contains(where: \.hasPendingTransition) else { finish(false); return }
        guard let next = current.first(where: \.hasUnsavedChanges) else { finish(true); return }
        activate?(next)
        if !next.request(proceed: { [weak self] in self?.resolveNext() }, cancel: { [weak self] in self?.finish(false) }) {
            finish(false)
        }
    }

    private func finish(_ allowed: Bool) {
        guard isActive else { return }
        let callback = completion
        isActive = false
        protections = nil
        activate = nil
        completion = nil
        callback?(allowed)
    }
}
