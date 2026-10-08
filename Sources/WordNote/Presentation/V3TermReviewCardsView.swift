#if WORDNOTE_V3_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V3TermReviewCardsView: View {
    @Environment(\.modelContext) private var context
    @Environment(WordNoteDataProtection.self) private var protection
    let term: TermModel
    let requestedCardID: UUID?
    @Query private var cards: [AppSchema.ReviewCardModel]
    @State private var errorMessage: String?
    @State private var showsCloze = false

    init(term: TermModel, requestedCardID: UUID? = nil) {
        self.term = term
        self.requestedCardID = requestedCardID
        let id = term.id
        _cards = Query(filter: #Predicate<AppSchema.ReviewCardModel> { $0.termID == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Review Cards").font(.headline)
                Spacer()
                Menu {
                    Button("English to Chinese") { enable(.englishToChinese) }
                    Button("Chinese to English") { enable(.chineseToEnglish) }
                    Divider()
                    Button("Original Sentence Cloze", systemImage: "text.quote") { showsCloze = true }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().frame(width: 28)
                    .help("Enable an independent review direction").accessibilityLabel("Enable review direction")
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning) }
            if cards.isEmpty { Text("No review cards").foregroundStyle(.secondary) }
            if let requestedCardID, !cards.contains(where: { $0.id == requestedCardID }) {
                StatusBanner(message: "The linked review card is no longer available.", kind: .warning)
            }
            ForEach(cards.sorted { ($0.modeRaw, $0.id.uuidString) < ($1.modeRaw, $1.id.uuidString) }, id: \.id) { card in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(AppLocalization.text(ReviewMode(rawValue: card.modeRaw)?.displayTitle ?? card.modeRaw)).fontWeight(.semibold)
                        Spacer()
                        if card.phaseRaw != ReviewCardPhase.suspended.rawValue {
                            Button("Suspend", systemImage: "pause.circle") { suspend(card) }.labelStyle(.iconOnly).help("Suspend this card")
                        } else {
                            Button("Enable", systemImage: "play.circle") { resume(card) }.labelStyle(.iconOnly).help("Enable this card")
                        }
                    }
                    LabeledContent("State", value: AppLocalization.text(card.phaseRaw.capitalized))
                    LabeledContent("Mastery", value: AppLocalization.text(MasteryLevel(rawValue: card.masteryLevelRaw)?.displayTitle ?? card.masteryLevelRaw))
                    LabeledContent("Next review", value: card.nextReviewAt?.formatted(date: .abbreviated, time: .shortened) ?? AppLocalization.text("Not scheduled"))
                    if let until = card.buriedUntil, until > Date() {
                        LabeledContent("Deferred until", value: until.formatted(date: .abbreviated, time: .shortened))
                    }
                    if card.priorityRequestedAt != nil { Label("Priority requested", systemImage: "arrow.up") }
                }.font(.subheadline).padding(.vertical, 8).padding(.horizontal, 8)
                    .background(card.id == requestedCardID ? WordNoteTheme.brand.opacity(0.08) : .clear)
                    .id(card.id)
            }
            DisclosureGroup("Historical counters") {
                LabeledContent("Legacy reviews", value: String(term.reviewCount))
                LabeledContent("Legacy wrong / re-query count", value: String(term.wrongCount))
            }.font(.caption).foregroundStyle(.secondary)
        }.disabled(protection.isRestoring)
        .sheet(isPresented: $showsCloze) { V3ClozeCardSheet(term: term) }
    }

    private func enable(_ mode: ReviewMode) {
        do {
            _ = try AppContentService(container: context.container).enableReviewDirection(termID: term.id,
                expectedTermRevision: term.revision, mode: mode, studyTimeZoneID: TimeZone.current.identifier)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func suspend(_ card: AppSchema.ReviewCardModel) {
        do {
            try AppContentService(container: context.container).suspendReviewCard(card.id, expectedRevision: card.revision)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func resume(_ card: AppSchema.ReviewCardModel) {
        guard card.modeRaw == ReviewMode.contextCloze.rawValue else {
            if let mode = ReviewMode(rawValue: card.modeRaw) { enable(mode) }
            return
        }
        do {
            _ = try AppContentService(container: context.container).resumeClozeCard(card.id,
                expectedRevision: card.revision, studyTimeZoneID: TimeZone.current.identifier)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
#endif
