#if WORDNOTE_V2_VALIDATION || WORDNOTE_V3_VALIDATION
import SwiftUI
import WordNoteCore

struct V2ConfirmationGroupView: View {
    let plan: WordNoteV2ConfirmationPlan
    let group: WordNoteV2ConfirmationPlan.Group
    @Binding var choices: WordNoteV2ConfirmationChoices
    let conflict: String?

    private var active: [WordNoteV2ConfirmationPlan.Candidate] {
        group.candidates.filter { !choices.ignoredCandidateIDs.contains($0.id) }
    }
    private var choice: WordNoteV2ConfirmationChoices.Group { choices.groups[group.id] ?? .init() }
    private var target: WordNoteV2ConfirmationPlan.Target? {
        group.existingTerms.first { $0.id == choice.existingTermID }
            ?? (group.existingTerms.count == 1 ? group.existingTerms[0] : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(group.candidates.first?.content.term ?? group.id).font(.headline)
                Spacer()
                Text(active.isEmpty ? "Ignore" : (group.existingTerms.isEmpty ? "New term" : "Link existing"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                candidateRow(candidate, number: index + 1)
            }
            if !active.isEmpty {
                if group.existingTerms.count > 1 {
                    Picker("Existing term", selection: Binding(get: { choice.existingTermID }, set: { id in
                        do { try choices.setExistingTarget(id, groupID: group.id, in: plan) }
                        catch { assertionFailure(error.localizedDescription) }
                    })) {
                        Text("Choose target").tag(UUID?.none)
                        ForEach(Array(group.existingTerms.enumerated()), id: \.element.id) { index, term in
                            Text("\(index + 1). \(term.content.term): \((term.content.chineseMeaning ?? term.content.englishDefinition ?? "").prefix(60))")
                                .tag(Optional(term.id))
                        }
                    }
                } else if group.existingTerms.isEmpty, active.count > 1 {
                    Picker("Content to keep", selection: groupBinding(\.preferredCandidateID)) {
                        Text(active.allSatisfy { $0.values == active.first?.values } ? "Identical content" : "Choose candidate")
                            .tag(UUID?.none)
                        ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                            if !choices.ignoredCandidateIDs.contains(candidate.id) {
                                Text("Candidate \(index + 1)").tag(Optional(candidate.id))
                            }
                        }
                    }
                }
                if let target {
                    ForEach(WordNoteV2ConfirmationField.allCases) { field in
                        fieldRow(field, target: target)
                    }
                }
            }
            if let conflict { StatusBanner(message: conflict, kind: .warning) }
        }
    }

    private func candidateRow(_ candidate: WordNoteV2ConfirmationPlan.Candidate, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Ignore candidate \(number)", isOn: Binding(
                get: { choices.ignoredCandidateIDs.contains(candidate.id) },
                set: { ignored in
                    // The row's ID comes from this frozen plan, so this cannot be an unknown selection.
                    do { try choices.setIgnored(ignored, candidateID: candidate.id, in: plan) }
                    catch { assertionFailure(error.localizedDescription) }
                }
            )).toggleStyle(.checkbox)
            Text("Candidate \(number): \(candidate.content.term)").font(.subheadline.bold())
            Text(candidate.content.chineseMeaning ?? candidate.content.englishDefinition ?? AppLocalization.text("No definition"))
                .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Candidate Details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(candidate.content.termTypeRaw), \(candidate.content.categoryRaw), \(candidate.content.importanceRaw)")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(WordNoteV2ConfirmationField.allCases) { field in
                        if let value = candidate.values[field] { valueColumn(field.title, value) }
                    }
                    if let source = plan.sourceText(for: candidate.id) { valueColumn("Source", source) }
                }.padding(.vertical, 8)
            }
            .font(.subheadline)
        }.opacity(choices.ignoredCandidateIDs.contains(candidate.id) ? 0.6 : 1)
    }

    private func fieldRow(_ field: WordNoteV2ConfirmationField, target: WordNoteV2ConfirmationPlan.Target) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(AppLocalization.text(field.title)).font(.subheadline.bold())
                Spacer()
                Picker(AppLocalization.text(field.title), selection: Binding(
                    get: { choice.fieldSources[field] },
                    set: { choices.groups[group.id, default: .init()].fieldSources[field] = $0 }
                )) {
                    Text("Keep stored").tag(UUID?.none)
                    ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                        if !choices.ignoredCandidateIDs.contains(candidate.id), candidate.values[field] != nil {
                            Text("Use candidate \(index + 1)").tag(Optional(candidate.id))
                        }
                    }
                }.labelsHidden().frame(width: 180)
            }
            if let id = choice.fieldSources[field], let value = active.first(where: { $0.id == id })?.values[field] {
                HStack(alignment: .top, spacing: 16) {
                    valueColumn("Stored", target.values[field] ?? AppLocalization.text("(Empty)"))
                    valueColumn("Selected", value)
                }
            } else {
                Text(target.values[field] ?? AppLocalization.text("(Empty)")).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 6)
    }

    private func valueColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppLocalization.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupBinding(_ keyPath: WritableKeyPath<WordNoteV2ConfirmationChoices.Group, UUID?>) -> Binding<UUID?> {
        Binding(get: { choice[keyPath: keyPath] }, set: { choices.groups[group.id, default: .init()][keyPath: keyPath] = $0 })
    }
}
#endif
