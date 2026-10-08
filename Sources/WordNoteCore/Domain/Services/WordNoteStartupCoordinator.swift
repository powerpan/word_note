import Foundation
import Observation
import SwiftData

public enum WordNoteStartupMigrationError: LocalizedError, Equatable {
    case busy
    case recoveryRequired
    case sourceChanged
    case protectionMismatch
    case repairUnavailable

    public var errorDescription: String? {
        switch self {
        case .busy: "Data initialization is already in progress."
        case .recoveryRequired: "Data initialization did not complete. The original store is retained. Review the error before explicitly retrying."
        case .sourceChanged: "The original data changed while migration was being prepared. The original store is retained; retry from its latest state."
        case .protectionMismatch: "The protection file does not match the original data. The data switch was stopped."
        case .repairUnavailable: "Inspect the current data first. Only missing optional relationships can be repaired automatically."
        }
    }
}

/// Run before constructing views, form bindings, analysis workers, or any other store writer.
@MainActor
@Observable
public final class WordNoteStartupCoordinator {
    public enum Phase: Equatable { case idle, opening, inspecting, backingUp, staging, activating, ready, recoveryRequired }

    public private(set) var phase = Phase.idle
    public private(set) var errorMessage: String?
    public private(set) var protectionBackup: WordNoteBackupSummary?
    public private(set) var migrationIssues: [WordNoteV1ToV2Migration.Issue] = []
    public private(set) var cardMigrationIssues: [WordNoteV2ToV3Migration.Issue] = []
    public private(set) var session: WordNoteStoreSession?
    public private(set) var repairReport: WordNoteV2IntegrityReport?
    public private(set) var repairEvidence: WordNoteRepairEvidenceSummary?
    public private(set) var v3RepairReport: WordNoteV3IntegrityReport?
    public private(set) var v3RepairEvidence: WordNoteV3RepairEvidenceSummary?

    @ObservationIgnored private let store: WordNoteRestoreStore
    @ObservationIgnored private let vault: WordNoteBackupVault
    @ObservationIgnored private let preferences: @MainActor () -> WordNoteSnapshotPayload.Preferences
    @ObservationIgnored private let evidenceVault: WordNoteRepairEvidenceVault
    @ObservationIgnored private let v3EvidenceVault: WordNoteV3RepairEvidenceVault
    @ObservationIgnored private var repairPlan: RepairPlan?
    @ObservationIgnored private var sourceWriteTicket: WordNoteWriteGate.Ticket?
    @ObservationIgnored private(set) var sourceSession: WordNoteStoreSession?

    public init(
        store: WordNoteRestoreStore, vault: WordNoteBackupVault,
        preferences: @escaping @MainActor () -> WordNoteSnapshotPayload.Preferences,
        evidenceVault: WordNoteRepairEvidenceVault? = nil,
        v3EvidenceVault: WordNoteV3RepairEvidenceVault? = nil
    ) {
        self.store = store
        self.vault = vault
        self.preferences = preferences
        self.evidenceVault = evidenceVault ?? WordNoteRepairEvidenceVault(directoryURL: vault.directoryURL.appending(path: "RepairEvidence"))
        self.v3EvidenceVault = v3EvidenceVault ?? WordNoteV3RepairEvidenceVault(directoryURL: vault.directoryURL.appending(path: "RepairEvidenceV3"))
    }

    @discardableResult
    public func open(retryMigration: Bool = false) async throws -> WordNoteStoreSession {
        if phase == .ready, let session { return session }
        guard phase == .idle || phase == .recoveryRequired else { throw WordNoteStartupMigrationError.busy }
        guard store.targetSchema != .v1 else { throw WordNoteSnapshotError.unsupportedSchema }
        phase = .opening
        errorMessage = nil
        protectionBackup = nil
        migrationIssues = []
        cardMigrationIssues = []
        repairReport = nil
        repairPlan = nil
        repairEvidence = nil
        v3RepairReport = nil
        v3RepairEvidence = nil
        session = nil
        sourceSession = nil
        sourceWriteTicket = nil
        var preparedGeneration: WordNoteStoreGeneration?

        do {
            try Task.checkCancellation()
            let opened = try store.open()
            sourceSession = opened
            let frozenPreferences = opened.preferencesToApply ?? preferences()
            if opened.schemaVersion == store.targetSchema {
                _ = try await capture(opened, preferences: frozenPreferences)
                session = opened
                sourceSession = nil
                phase = .ready
                return opened
            }
            guard retryMigration || (opened.recoveryRequired == nil && opened.restoreOutcome != .rolledBack) else {
                throw WordNoteStartupMigrationError.recoveryRequired
            }
            let context = opened.container.mainContext
            guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
            try blockSourceWrites(context)
            // A failed backup or a process exit before staging must not trigger an automatic retry next launch.
            try store.beginMigration(replacing: opened.generation)
            let original = try await capture(opened, preferences: frozenPreferences)
            phase = .backingUp
            let result = try await vault.create(original, kind: .beforeMigration)
            try Task.checkCancellation()
            let verified = try await vault.readVersionedSnapshot(id: result.snapshot.id)
            guard verified.payload == original, verified.summary == result.snapshot,
                  verified.summary.kind == .beforeMigration else {
                throw WordNoteStartupMigrationError.protectionMismatch
            }
            protectionBackup = result.snapshot
            try await validateSource(opened, matches: original, preferences: frozenPreferences)
            phase = .staging
            let prepared = try await store.prepareMigration(verified, replacing: opened.generation)
            preparedGeneration = prepared.generation
            migrationIssues = prepared.migrationIssues
            try await validateSource(opened, matches: original, preferences: frozenPreferences)
            guard try store.preparedGeneration(for: opened.generation) == prepared.generation else {
                throw WordNoteRestoreError.staleGeneration
            }
            try Task.checkCancellation()
            phase = .activating
            let upgraded = try store.open()
            guard upgraded.schemaVersion == store.targetSchema, upgraded.generation == prepared.generation,
                  upgraded.restoreOutcome == .migrated else { throw WordNoteStartupMigrationError.recoveryRequired }
            session = upgraded
            // No source context is ever attached to UI; retained references must remain write-blocked.
            sourceSession = nil
            phase = .ready
            return upgraded
        } catch {
            cancelOwnPreparation(preparedGeneration)
            if case WordNoteV2ToV3Migration.MigrationError.preflightFailed(let issues) = error {
                cardMigrationIssues = issues
            }
            errorMessage = error.localizedDescription
            phase = .recoveryRequired
            throw error
        }
    }

    /// A read-only preview. Calling open never opts the user into a repair.
    @discardableResult
    public func inspectRepair(at date: Date = Date()) async throws -> WordNoteV2IntegrityReport {
        guard store.targetSchema == .v2, phase == .recoveryRequired, let sourceSession, sourceSession.schemaVersion == .v2 else {
            throw WordNoteStartupMigrationError.repairUnavailable
        }
        phase = .inspecting
        repairPlan = nil
        repairReport = nil
        defer { phase = .recoveryRequired }
        do {
            guard case .v2(let source) = try await captureForRepair(sourceSession) else { throw WordNoteSnapshotError.unsupportedSchema }
            let report = WordNoteV2IntegrityService.inspect(source)
            repairReport = report
            if report.canPrepareRepair { repairPlan = .v2(try WordNoteV2IntegrityService.prepareRepair(source, at: date)) }
            return report
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    public func inspectV3Repair(at date: Date = Date()) async throws -> WordNoteV3IntegrityReport {
        guard store.targetSchema == .v3, phase == .recoveryRequired, let sourceSession, sourceSession.schemaVersion == .v3 else {
            throw WordNoteStartupMigrationError.repairUnavailable
        }
        phase = .inspecting
        repairPlan = nil
        v3RepairReport = nil
        defer { phase = .recoveryRequired }
        do {
            guard case .v3(let source) = try await captureForRepair(sourceSession) else { throw WordNoteSnapshotError.unsupportedSchema }
            let report = WordNoteV3IntegrityService.inspect(source)
            v3RepairReport = report
            if report.canPrepareRepair { repairPlan = .v3(try WordNoteV3IntegrityService.prepareRepair(source, at: date)) }
            return report
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Explicitly confirmed startup recovery only, before any views or workers use the source container.
    @discardableResult
    public func repair() async throws -> WordNoteStoreSession {
        guard store.targetSchema != .v1, phase == .recoveryRequired, let sourceSession,
              sourceSession.schemaVersion == store.targetSchema, let repairPlan else {
            throw WordNoteStartupMigrationError.repairUnavailable
        }
        self.repairPlan = nil
        phase = .backingUp
        errorMessage = nil
        repairEvidence = nil
        v3RepairEvidence = nil
        var preparedGeneration: WordNoteStoreGeneration?
        do {
            try Task.checkCancellation()
            let context = sourceSession.container.mainContext
            guard !context.hasChanges else { throw WordNoteV2ContentError.unsavedChanges }
            try blockSourceWrites(context)
            try store.beginRepair(replacing: sourceSession.generation)
            let source = try await captureForRepair(sourceSession)
            try repairPlan.validate(source)
            let protection = try await protectForRepair(source, generation: sourceSession.generation)
            try repairPlan.validate(await captureForRepair(sourceSession))
            phase = .staging
            let prepared = try await prepareRepair(repairPlan, protection: protection, replacing: sourceSession.generation)
            preparedGeneration = prepared.generation
            try repairPlan.validate(await captureForRepair(sourceSession))
            guard try store.preparedGeneration(for: sourceSession.generation) == prepared.generation else {
                throw WordNoteRestoreError.staleGeneration
            }
            try Task.checkCancellation()
            phase = .activating
            let repaired = try store.open()
            guard repaired.schemaVersion == store.targetSchema, repaired.generation == prepared.generation,
                  repaired.restoreOutcome == .repaired else { throw WordNoteStartupMigrationError.recoveryRequired }
            session = repaired
            self.sourceSession = nil
            phase = .ready
            return repaired
        } catch {
            cancelOwnPreparation(preparedGeneration)
            errorMessage = error.localizedDescription
            phase = .recoveryRequired
            throw error
        }
    }

    private func cancelOwnPreparation(_ generation: WordNoteStoreGeneration?) {
        guard let generation, let sourceSession else { return }
        // Do not cancel a different operation that won a race with this startup.
        if (try? store.preparedGeneration(for: sourceSession.generation)) == generation {
            try? store.cancelPreparedRestore(replacing: sourceSession.generation, expectedPending: generation)
        }
    }

    private func blockSourceWrites(_ context: ModelContext) throws {
        if sourceWriteTicket == nil { sourceWriteTicket = try WordNoteWriteGate.beginRestore(context) }
        context.autosaveEnabled = false
    }

    private enum RepairPlan {
        case v2(WordNoteV2IntegrityRepairPlan)
        case v3(WordNoteV3IntegrityRepairPlan)

        func validate(_ source: WordNoteVersionedPayload) throws {
            switch (self, source) {
            case (.v2(let plan), .v2(let payload)): _ = try plan.validatedPayload(matching: payload)
            case (.v3(let plan), .v3(let payload)): _ = try plan.validatedPayload(matching: payload)
            default: throw WordNoteSnapshotError.unsupportedSchema
            }
        }
    }

    private enum RepairProtection {
        case v2(VerifiedWordNoteRepairEvidence)
        case v3(VerifiedWordNoteV3RepairEvidence)
    }

    private func protectForRepair(_ source: WordNoteVersionedPayload,
                                  generation: WordNoteStoreGeneration) async throws -> RepairProtection {
        switch source {
        case .v2(let payload):
            let saved = try await evidenceVault.create(payload, generation: generation)
            try Task.checkCancellation()
            let verified = try await evidenceVault.read(id: saved.summary.id)
            guard verified.summary == saved.summary, verified.payload == payload else { throw WordNoteStartupMigrationError.protectionMismatch }
            repairEvidence = verified.summary
            return .v2(verified)
        case .v3(let payload):
            let saved = try await v3EvidenceVault.create(payload, generation: generation)
            try Task.checkCancellation()
            let verified = try await v3EvidenceVault.read(id: saved.summary.id)
            guard verified.summary == saved.summary, verified.payload == payload else { throw WordNoteStartupMigrationError.protectionMismatch }
            v3RepairEvidence = verified.summary
            return .v3(verified)
        case .v1: throw WordNoteSnapshotError.unsupportedSchema
        }
    }

    private func prepareRepair(_ plan: RepairPlan, protection: RepairProtection,
                               replacing generation: WordNoteStoreGeneration) async throws -> WordNotePreparedStore {
        switch (plan, protection) {
        case (.v2(let plan), .v2(let evidence)): return try await store.prepareRepair(plan, protectedBy: evidence, replacing: generation)
        case (.v3(let plan), .v3(let evidence)): return try await store.prepareRepair(plan, protectedBy: evidence, replacing: generation)
        default: throw WordNoteSnapshotError.unsupportedSchema
        }
    }

    private func captureForRepair(_ source: WordNoteStoreSession) async throws -> WordNoteVersionedPayload {
        let frozenPreferences = source.preferencesToApply ?? preferences()
        let payload = try await WordNoteSnapshotCapture.captureVersionedForIntegrityInspection(
            container: source.container, preferences: frozenPreferences
        )
        guard frozenPreferences == (source.preferencesToApply ?? preferences()) else {
            if source.schemaVersion == .v3 { throw WordNoteV3IntegrityError.staleRepairPlan }
            throw WordNoteV2IntegrityError.staleRepairPlan
        }
        return payload
    }

    private func capture(
        _ source: WordNoteStoreSession, preferences: WordNoteSnapshotPayload.Preferences
    ) async throws -> WordNoteVersionedPayload {
        try await WordNoteSnapshotCapture(container: source.container)
            .captureVersioned(preferences: preferences, requireCleanContext: true)
    }

    private func validateSource(
        _ source: WordNoteStoreSession, matches original: WordNoteVersionedPayload,
        preferences: WordNoteSnapshotPayload.Preferences
    ) async throws {
        guard try await capture(source, preferences: preferences) == original else { throw WordNoteStartupMigrationError.sourceChanged }
    }
}
