import Foundation

public struct WordNoteManualSourceValues: Equatable, Sendable {
    public let id: UUID
    public let rawText: String
    public let note: String
    public let courseID: UUID?
    public let source: String
    public let direction: String
    public let status: String
    public let queueState: String
    public let generation: Int

    @MainActor
    public init(_ record: WordNoteSchemaV2.InputRecordModel) {
        id = record.id; rawText = record.rawText; note = record.note ?? ""; courseID = record.courseID
        source = record.sourceTypeRaw; direction = record.resolvedLookupDirectionRaw
        status = record.statusRaw; queueState = record.queueStateRaw; generation = record.analysisGeneration
    }

    public static func comparisonFields(courseNames: [UUID: String] = [:]) -> [WordNoteEditField<Self>] {
        [
            .init("text", title: "Source Text", value: { $0.rawText }, display: { $0 }),
            .init("note", title: "Source Note", value: { $0.note }, display: { $0 }),
            .init("course", title: "Source Course", value: { $0.courseID }, display: { id in
                id.map { courseNames[$0] ?? "Missing course [\($0.uuidString.prefix(8))]" } ?? "No Course"
            }),
            .init("source", title: "Source Type", value: { $0.source }, display: { SourceType(rawValue: $0)?.displayTitle ?? $0 }),
            .init("direction", title: "Lookup Direction", value: { $0.direction }, display: { LookupDirection(rawValue: $0)?.displayTitle ?? $0 }),
            .init("status", title: "Record Status", value: { $0.status }, display: { InputRecordStatus(rawValue: $0)?.displayTitle ?? $0 }),
            .init("queue", title: "Analysis Status", value: { $0.queueState }, display: queueTitle),
            .init("generation", title: "Analysis Generation", value: { $0.generation }, display: String.init)
        ]
    }

    private static func queueTitle(_ value: String) -> String {
        switch AnalysisQueueState(rawValue: value) {
        case .some(.none): "Not queued"
        case .queued: "Queued"
        case .running: "Analyzing"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case nil: value
        }
    }
}
