#if WORDNOTE_V2_VALIDATION
import SwiftUI
import WordNoteCore

struct V2InputRecordDetailView: View {
    let record: InputRecordModel
    let course: CourseModel?
    let candidates: [CandidateTermModel]
    let onAnalyze: () -> Void
    let onIgnore: () -> Void
    let onDelete: () -> Void
    let onConfirm: (Set<UUID>) -> Void
    let onIgnoreCandidates: (Set<UUID>) -> Void
    let onManualSave: () -> Void
    var advancesAfterConfirmation = true
    @State private var sourceExpanded = false
    @State private var deletePresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Input Record").font(WordNoteTheme.editorialFont(size: 25, weight: .semibold))
                        Text([record.visibleStatusTitle, course?.courseName].compactMap { $0 }.joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(record.analysisFailed ? "Retry" : "Analyze", systemImage: "sparkles", action: onAnalyze)
                        .labelStyle(.iconOnly).help(record.analysisFailed ? "Retry analysis" : "Add to analysis queue")
                        .disabled(record.analysisPending || record.status == .completed)
                    Menu {
                        Button("Ignore Input Record", systemImage: "archivebox", action: onIgnore)
                            .disabled(record.analysisPending || record.status == .completed)
                        Button("Delete Input Record", systemImage: "trash", role: .destructive) { deletePresented = true }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: 28, height: 28)
                    .help("Input record actions").accessibilityLabel("Input record actions")
                }
                DisclosureGroup(isExpanded: $sourceExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(record.rawText).font(.system(size: 15)).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        if let note = record.note, !TextNormalizer.isBlank(note) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Note").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                Text(note).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        LabeledContent("Source", value: record.sourceType.displayTitle)
                        LabeledContent("Course", value: course?.courseName ?? "No course")
                        LabeledContent("Direction", value: record.resolvedDirection.displayTitle)
                        LabeledContent("Created", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }.textSelection(.enabled).padding(.top, 10)
                } label: { Text("Input & Source").font(.subheadline.weight(.semibold)) }
                if let meaning = record.sentenceMeaning, !TextNormalizer.isBlank(meaning) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.resolvedDirection == .chineseToEnglish ? "English Rendering" : "Sentence Meaning")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text(meaning).textSelection(.enabled).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if record.analysisFailed, let error = record.aiErrorSummary { StatusBanner(message: error, kind: .warning) }
                Divider()
                V2CandidateReviewView(record: record, candidates: candidates, onConfirm: onConfirm,
                                      onIgnore: onIgnoreCandidates, onManualSave: onManualSave,
                                      advancesAfterConfirmation: advancesAfterConfirmation)
                    .disabled(record.analysisPending)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WordNoteTheme.canvas)
        .onAppear { sourceExpanded = candidates.isEmpty }
        .confirmationDialog("Delete this input record?", isPresented: $deletePresented) {
            Button("Delete Input Record", role: .destructive, action: onDelete)
        } message: { Text("Its candidates will be deleted. Saved vocabulary and captured source snapshots will be kept. Deletion cannot be undone here.") }
    }
}
#endif
