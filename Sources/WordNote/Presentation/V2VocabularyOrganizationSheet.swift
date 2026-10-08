#if WORDNOTE_V2_VALIDATION
import SwiftData
import SwiftUI
import WordNoteCore

struct V2VocabularyOrganizationSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.savedChangeHistory) private var undoHistory
    @Environment(\.dismiss) private var dismiss
    @Query private var courses: [CourseModel]
    @Query private var terms: [TermModel]
    let termIDs: Set<UUID>
    let onCommitted: (WordNoteV2OrganizationPlan.Counts) -> Void
    @State private var changes = WordNoteV2OrganizationChanges()
    @State private var tagInput = ""
    @State private var preview: WordNoteV2OrganizationPlan?
    @State private var errorMessage: String?
    @State private var needsRefresh = false

    private var activePreview: WordNoteV2OrganizationPlan? {
        TextNormalizer.isBlank(tagInput) && preview?.changes == changes ? preview : nil
    }
    private var tags: [WordNoteTags.Option] { WordNoteTags.options(terms.filter { termIDs.contains($0.id) }.flatMap(\.tags)) }
    private var hasChanges: Bool {
        !changes.coursesToAdd.isEmpty || !changes.coursesToRemove.isEmpty || !changes.tagsToAdd.isEmpty
            || !changes.tagsToRemove.isEmpty || !TextNormalizer.isBlank(tagInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organize Vocabulary").font(.title2.bold())
                    Text("\(termIDs.count) selected terms").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Changes", systemImage: "arrow.counterclockwise") {
                    changes = .init(); preview = nil; tagInput = ""; errorMessage = nil; needsRefresh = false
                }.labelStyle(.iconOnly).help("Reset changes")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    courseChanges
                    Divider()
                    tagChanges
                    if let plan = activePreview {
                        Divider()
                        V2OrganizationPreviewRows(plan: plan)
                    }
                }.padding(20)
            }
            if let errorMessage { StatusBanner(message: errorMessage, kind: .warning).padding(.horizontal, 20) }
            Divider().padding(.top, 10)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(activePreview == nil ? "Preview" : "Refresh Preview", systemImage: "arrow.clockwise", action: makePreview)
                    .disabled(!hasChanges)
                Button("Apply", systemImage: "checkmark", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(needsRefresh || (activePreview?.counts.changedTerms ?? 0) == 0)
            }.padding(20)
        }
        .frame(width: 660, height: 580).background(WordNoteTheme.canvas)
        .interactiveDismissDisabled()
    }

    private var courseChanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Courses").font(.headline)
            if courses.isEmpty { Text("No courses").foregroundStyle(.secondary) }
            ForEach(courses.sorted { $0.courseName < $1.courseName }, id: \.id) { course in
                HStack {
                    Text(course.courseName).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Picker(course.courseName, selection: Binding(
                        get: { changes.coursesToAdd.contains(course.id) ? "add" : (changes.coursesToRemove.contains(course.id) ? "remove" : "keep") },
                        set: { mode in
                            changes.coursesToAdd.remove(course.id)
                            changes.coursesToRemove.remove(course.id)
                            if mode == "add" { changes.coursesToAdd.insert(course.id) }
                            if mode == "remove" { changes.coursesToRemove.insert(course.id) }
                        }
                    )) {
                        Text("No change").tag("keep")
                        Text("Add").tag("add")
                        Text("Remove").tag("remove")
                    }.labelsHidden().frame(width: 140)
                }
            }
        }
    }

    private var tagChanges: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.headline)
            HStack {
                TextField("New tag", text: $tagInput).textFieldStyle(.roundedBorder).onSubmit(addTag)
                Button("Add Tag", systemImage: "plus", action: addTag)
                    .labelStyle(.iconOnly).help("Add tag to changes").disabled(TextNormalizer.isBlank(tagInput))
            }
            ForEach(changes.tagsToAdd, id: \.self) { tag in
                HStack {
                    Label(tag, systemImage: "plus").fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Remove Proposed Tag", systemImage: "xmark") { changes.tagsToAdd.removeAll { $0 == tag } }
                        .labelStyle(.iconOnly).help("Remove proposed tag")
                }
            }
            ForEach(tags) { tag in
                Toggle("Remove \(tag.label)", isOn: Binding(
                    get: { changes.tagsToRemove.map(WordNoteTags.key).contains(tag.id) },
                    set: { remove in
                        changes.tagsToRemove.removeAll { WordNoteTags.key($0) == tag.id }
                        if remove { changes.tagsToRemove.append(tag.label) }
                    }
                )).toggleStyle(.checkbox)
            }
        }
    }

    private func addTag() {
        do {
            try includePendingTag()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func includePendingTag() throws {
        guard !TextNormalizer.isBlank(tagInput) else { return }
        let tag = try WordNoteTags.newLabel(tagInput)
        if !changes.tagsToAdd.map(WordNoteTags.key).contains(WordNoteTags.key(tag)) { changes.tagsToAdd.append(tag) }
        tagInput = ""
    }

    private func makePreview() {
        do {
            try includePendingTag()
            preview = try WordNoteV2ContentService(container: modelContext.container).makeOrganizationPlan(termIDs: termIDs, changes: changes)
            needsRefresh = false
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    private func commit() {
        guard let plan = activePreview else { return }
        do {
            let result = try WordNoteV2ContentService(container: modelContext.container, undoHistory: undoHistory).commitOrganizationPlan(plan)
            dismiss()
            onCommitted(result)
        } catch {
            errorMessage = error.localizedDescription
            if error as? WordNoteV2OrganizationError == .stalePlan { needsRefresh = true }
        }
    }
}

private struct V2OrganizationPreviewRows: View {
    let plan: WordNoteV2OrganizationPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview").font(.headline)
            Text("\(plan.counts.changedTerms) / \(plan.counts.selectedTerms) terms changed")
            Text("Courses: +\(plan.counts.coursesAdded) / -\(plan.counts.coursesRemoved), tags: +\(plan.counts.tagsAdded) / -\(plan.counts.tagsRemoved)")
                .foregroundStyle(.secondary).font(.subheadline)
            ForEach(plan.entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.before.term).font(.subheadline.bold()).fixedSize(horizontal: false, vertical: true)
                    if !entry.hasChanges { Text("No change").foregroundStyle(.secondary) }
                    ForEach(entry.addedCourseIDs, id: \.self) { id in Text("+ Course: \(courseName(id))") }
                    ForEach(entry.removedCourseIDs, id: \.self) { id in Text("- Course: \(courseName(id))") }
                    ForEach(entry.addedTags, id: \.self) { tag in Text("+ Tag: \(tag)") }
                    ForEach(entry.removedTags, id: \.self) { tag in Text("- Tag: \(tag)") }
                }.font(.subheadline).textSelection(.enabled)
            }
        }
    }

    private func courseName(_ id: UUID) -> String { plan.courses.first { $0.id == id }?.courseName ?? "Unavailable course" }
}
#endif
