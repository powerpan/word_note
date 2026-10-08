#if WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V3ClozeCardSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(WordNoteDataProtection.self) private var protection
    let term: TermModel
    @Query private var sources: [AppSchema.TermOccurrenceModel]
    @State private var sourceID: UUID?
    @State private var answerForm: String
    @State private var acceptedForms = ""
    @State private var selectedRange: ReviewTextRange?
    @State private var draft: WordNoteV3ClozeDraft?
    @State private var errorMessage: String?

    init(term: TermModel) {
        self.term = term
        let id = term.id
        _sources = Query(filter: #Predicate<AppSchema.TermOccurrenceModel> { $0.termID == id })
        _answerForm = State(initialValue: term.term)
    }

    private var source: AppSchema.TermOccurrenceModel? { sources.first { $0.id == sourceID } }
    private var ranges: [ReviewTextRange] {
        guard let source else { return [] }
        return (try? ReviewTextMasking.ranges(in: source.rawTextSnapshot, forms: [answerForm])) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Original Sentence Cloze").font(.title2.weight(.semibold))
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).help("Close cloze preview")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(term.term).font(.headline)
                    Picker("Source", selection: $sourceID) {
                        Text("Choose original capture").tag(UUID?.none)
                        ForEach(sources.sorted { $0.occurredAt > $1.occurredAt }, id: \.id) {
                            Text(String($0.rawTextSnapshot.prefix(70))).tag(Optional($0.id))
                        }
                    }
                    if let source {
                        Text(source.rawTextSnapshot).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Answer form in this source", text: $answerForm).textFieldStyle(.roundedBorder)
                        Picker("Occurrence", selection: $selectedRange) {
                            Text(ranges.isEmpty ? "No complete match" : "Choose a match").tag(ReviewTextRange?.none)
                            ForEach(ranges, id: \.self) { range in
                                Text("\(range.start + 1): \((try? range.text(in: source.rawTextSnapshot)) ?? "")").tag(Optional(range))
                            }
                        }
                        TextField("Accepted answers (one per line)", text: $acceptedForms, axis: .vertical)
                            .lineLimit(2...5).textFieldStyle(.roundedBorder)
                        Button("Preview", systemImage: "eye", action: preview).disabled(selectedRange == nil)
                    } else if sources.isEmpty { Text("No original captures available").foregroundStyle(.secondary) }
                    if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
                    if let draft {
                        Divider()
                        Text("Question").font(.subheadline.weight(.semibold))
                        Text(draft.preview.prompt).lineSpacing(5).textSelection(.enabled)
                        LabeledContent("Answer", value: draft.preview.target.answer)
                        if !draft.preview.target.acceptedAnswers.isEmpty {
                            LabeledContent("Also accepted", value: draft.preview.target.acceptedAnswers.joined(separator: ", "))
                        }
                    }
                }.padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create Card", systemImage: "plus", action: create)
                    .buttonStyle(.borderedProminent).disabled(draft == nil)
            }
        }.padding(24).frame(width: 620, height: 560).disabled(protection.isRestoring)
        .onChange(of: sourceID) { selectedRange = nil; invalidate() }
        .onChange(of: answerForm) { selectedRange = nil; invalidate() }
        .onChange(of: selectedRange) { invalidate() }
        .onChange(of: acceptedForms) { invalidate() }
    }

    private func invalidate() { draft = nil; errorMessage = nil }

    private func preview() {
        guard let sourceID, let selectedRange else { return }
        do {
            draft = try AppContentService(container: context.container).previewClozeCard(termID: term.id,
                occurrenceID: sourceID, selectedRange: selectedRange,
                acceptedAnswers: acceptedForms.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            errorMessage = nil
        } catch { draft = nil; errorMessage = error.localizedDescription }
    }

    private func create() {
        guard let draft else { return }
        do {
            _ = try AppContentService(container: context.container).createClozeCard(draft, studyTimeZoneID: TimeZone.current.identifier)
            dismiss()
        } catch { self.draft = nil; errorMessage = error.localizedDescription }
    }
}
#endif
