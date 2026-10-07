import XCTest
@testable import WordNoteCore

@MainActor
final class WordNoteEditComparisonTests: XCTestCase {
    private struct Value: Equatable {
        var chinese = "original"
        var english = "definition"
        var courses: Set<UUID> = []
        var sourceRevision = 0
    }

    private var fields: [WordNoteEditField<Value>] {
        [
            .init("chinese", title: "Chinese", keyPath: \.chinese, display: { $0 }),
            .init("english", title: "English", keyPath: \.english, display: { $0 }),
            .init("courses", title: "Courses", keyPath: \.courses, display: { _ in "Same display names" }),
            .init("source", title: "Source revision", value: { $0.sourceRevision }, display: String.init)
        ]
    }

    func testNonOverlappingChangesAreRebasedWithoutOverwritingEitherSide() throws {
        let draft = WordNoteEditDraft(Value(), revision: 2)
        draft.value.chinese = "我的釋義"
        var stored = Value()
        stored.english = "An updated definition"
        stored.sourceRevision = 7
        let current = WordNoteDraftVersion(stored, revision: 3)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertEqual(comparison.unresolvedCount(choices: [:]), 0)
        try comparison.apply(to: draft, latest: current, choices: [:])
        XCTAssertEqual(draft.value.chinese, "我的釋義")
        XCTAssertEqual(draft.value.english, stored.english)
        XCTAssertEqual(draft.value.sourceRevision, 7)
        XCTAssertEqual(draft.baseline, stored)
        XCTAssertEqual(draft.revision, 3)
        XCTAssertTrue(draft.isDirty)
    }

    func testIdenticalEditsNeedNoChoiceAndBecomeClean() throws {
        let draft = WordNoteEditDraft(Value())
        draft.value.chinese = "共同修改"
        let current = WordNoteDraftVersion(draft.value, revision: 1)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertFalse(try XCTUnwrap(comparison.differences.first).isConflict)
        try comparison.apply(to: draft, latest: current, choices: [:])
        XCTAssertFalse(draft.isDirty)
    }

    func testDivergentEditsRequireExplicitChoiceAndSupportEitherValue() throws {
        let draft = WordNoteEditDraft(Value())
        draft.value.chinese = "Mine"
        var stored = Value(); stored.chinese = "Stored"
        let current = WordNoteDraftVersion(stored, revision: 1)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertEqual(comparison.unresolvedCount(choices: [:]), 1)
        XCTAssertThrowsError(try comparison.resolvedValue(choices: [:])) { XCTAssertEqual($0 as? WordNoteEditComparisonError, .unresolvedFields) }
        XCTAssertEqual(try comparison.resolvedValue(choices: ["chinese": .mine]).chinese, "Mine")
        XCTAssertEqual(try comparison.resolvedValue(choices: ["chinese": .stored]).chinese, "Stored")
        XCTAssertEqual(draft.value.chinese, "Mine", "Preview must not mutate the draft")
    }

    func testEmptyAndWhitespaceAreRealValuesNotMissingSelections() throws {
        let draft = WordNoteEditDraft(Value())
        draft.value.chinese = ""
        var stored = Value(); stored.chinese = "  "
        let comparison = try WordNoteEditComparison(draft: draft, current: .init(stored, revision: 1), fields: fields)
        XCTAssertTrue(try XCTUnwrap(comparison.differences.first).requiresChoice)
        XCTAssertEqual(try comparison.resolvedValue(choices: ["chinese": .mine]).chinese, "")
        XCTAssertEqual(try comparison.resolvedValue(choices: ["chinese": .stored]).chinese, "  ")
    }

    func testCourseIdentityUsesTypedEqualityAndDoesNotSilentlyUnionSets() throws {
        let shared = UUID(), mine = UUID(), remote = UUID()
        let draft = WordNoteEditDraft(Value(courses: [shared]))
        draft.value.courses = [mine]
        let current = WordNoteDraftVersion(Value(courses: [remote]), revision: 1)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        let row = try XCTUnwrap(comparison.differences.first)
        XCTAssertEqual(row.mine, row.stored)
        XCTAssertTrue(row.requiresChoice)
        XCTAssertEqual(try comparison.resolvedValue(choices: ["courses": .mine]).courses, [mine])
        XCTAssertEqual(try comparison.resolvedValue(choices: ["courses": .stored]).courses, [remote])
    }

    func testReadOnlyFieldsKeepCurrentMetadataAndCannotBeSelected() throws {
        let draft = WordNoteEditDraft(Value())
        draft.value.sourceRevision = 1
        let current = WordNoteDraftVersion(Value(sourceRevision: 2), revision: 2)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertEqual(try comparison.resolvedValue(choices: [:]).sourceRevision, 2)
        XCTAssertThrowsError(try comparison.resolvedValue(choices: ["source": .mine])) { XCTAssertEqual($0 as? WordNoteEditComparisonError, .invalidChoice) }
    }

    func testUnknownChoicesAreRejected() throws {
        let draft = WordNoteEditDraft(Value())
        let comparison = try WordNoteEditComparison(draft: draft, current: .init(Value(), revision: 0), fields: fields)
        XCTAssertThrowsError(try comparison.resolvedValue(choices: ["unknown": .stored])) { XCTAssertEqual($0 as? WordNoteEditComparisonError, .invalidChoice) }
    }

    func testRevisionOnlyChangeCanRebaseWithoutChangingValues() throws {
        let draft = WordNoteEditDraft(Value(), revision: 2)
        let current = WordNoteDraftVersion(Value(), revision: 5)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertTrue(comparison.differences.isEmpty)
        try comparison.apply(to: draft, latest: current, choices: [:])
        XCTAssertEqual(draft.revision, 5)
        XCTAssertFalse(draft.isDirty)
    }

    func testLastKeystrokeInvalidatesPreviewWithoutLosingTheKeystroke() throws {
        let draft = WordNoteEditDraft(Value())
        draft.value.chinese = "Before"
        let current = WordNoteDraftVersion(Value(), revision: 1)
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        draft.value.chinese = "Last keystroke"
        XCTAssertThrowsError(try comparison.apply(to: draft, latest: current, choices: [:])) { XCTAssertEqual($0 as? WordNoteEditComparisonError, .draftChanged) }
        XCTAssertEqual(draft.value.chinese, "Last keystroke")
        XCTAssertEqual(draft.revision, 0)
    }

    func testChangingBaselineOrRevisionInvalidatesPreview() throws {
        for changeRevision in [false, true] {
            let draft = WordNoteEditDraft(Value())
            let current = WordNoteDraftVersion(Value(), revision: 1)
            let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
            if changeRevision { draft.revision = 7 } else { draft.baseline.english = "New baseline" }
            XCTAssertThrowsError(try comparison.apply(to: draft, latest: current, choices: [:])) { XCTAssertEqual($0 as? WordNoteEditComparisonError, .draftChanged) }
        }
    }

    func testStoredChangeWithOrWithoutRevisionInvalidatesPreview() throws {
        for changeRevision in [false, true] {
            let draft = WordNoteEditDraft(Value())
            draft.value.chinese = "Local"
            let current = WordNoteDraftVersion(Value(), revision: 1)
            let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
            var next = current.value
            if !changeRevision { next.english = "Changed without revision" }
            let latest = WordNoteDraftVersion(next, revision: changeRevision ? 2 : 1)
            XCTAssertThrowsError(try comparison.apply(to: draft, latest: latest, choices: [:])) { XCTAssertEqual($0 as? WordNoteEditComparisonError, .storedChanged) }
            XCTAssertEqual(draft.revision, 0)
            XCTAssertEqual(draft.value.chinese, "Local")
        }
    }

    func testBlockedComparisonRemainsReadableButCannotRebase() throws {
        let draft = WordNoteEditDraft(Value())
        draft.value.chinese = "Local"
        let current = WordNoteDraftVersion(Value(), revision: 1, blockingMessage: "Already confirmed")
        let comparison = try WordNoteEditComparison(draft: draft, current: current, fields: fields)
        XCTAssertFalse(comparison.differences.isEmpty)
        XCTAssertThrowsError(try comparison.apply(to: draft, latest: current, choices: [:])) {
            XCTAssertEqual($0 as? WordNoteEditComparisonError, .unavailable("Already confirmed"))
        }
        XCTAssertEqual(draft.revision, 0)
        XCTAssertTrue(draft.isDirty)
    }

    func testNewBlockAfterPreviewCannotBeBypassed() throws {
        let draft = WordNoteEditDraft(Value())
        let comparison = try WordNoteEditComparison(draft: draft, current: .init(Value(), revision: 0), fields: fields)
        XCTAssertThrowsError(try comparison.apply(to: draft, latest: .init(Value(), revision: 0, blockingMessage: "Analysis started"), choices: [:])) {
            XCTAssertEqual($0 as? WordNoteEditComparisonError, .storedChanged)
        }
    }

    func testDuplicateFieldIDsAreRejected() throws {
        let draft = WordNoteEditDraft(Value())
        XCTAssertThrowsError(try WordNoteEditComparison(draft: draft, current: .init(Value(), revision: 0), fields: fields + [fields[0]])) {
            XCTAssertEqual($0 as? WordNoteEditComparisonError, .duplicateField)
        }
    }

    func testTermComparisonCoversEveryEditableFieldAndPreservesCaptureCourse() throws {
        let baseline = WordNoteTermEditValues()
        let draft = WordNoteEditDraft(baseline)
        let oldCaptureCourse = UUID(), currentCaptureCourse = UUID()
        draft.value = WordNoteTermEditValues(termText: "updated phrase", termType: .phrase, chineseMeaning: "更新",
                                             englishDefinition: "Changed", aiContextExplanation: "Context", exampleSentence: "Example",
                                             contextSentence: "Original source", courseID: oldCaptureCourse, courseIDs: [UUID()],
                                             sourceType: SourceType.allCases.first(where: { $0 != .other })!,
                                             category: TermCategory.allCases.first(where: { $0 != .general })!,
                                             importance: .high, masteryLevel: MasteryLevel.allCases.first(where: { $0 != .new })!)
        var stored = baseline; stored.courseID = currentCaptureCourse
        let comparison = try WordNoteEditComparison(draft: draft, current: .init(stored, revision: 1),
                                                    fields: WordNoteTermEditValues.comparisonFields(courseNames: [:]))
        XCTAssertEqual(Set(comparison.differences.map(\.id)), ["term", "type", "chinese", "english", "technical", "example", "context", "courses", "source", "category", "importance", "mastery"])
        var expected = draft.value; expected.courseID = currentCaptureCourse
        XCTAssertEqual(try comparison.resolvedValue(choices: [:]), expected)
    }

    func testCourseComparisonCoversAllFiveFields() throws {
        let draft = WordNoteEditDraft(WordNoteCourseEditValues())
        draft.value = .init(courseName: "CS", courseCode: "101", instructor: "Teacher", semester: "Autumn", description: "Synthetic")
        let comparison = try WordNoteEditComparison(draft: draft, current: .init(.init(), revision: 1), fields: WordNoteCourseEditValues.comparisonFields)
        XCTAssertEqual(Set(comparison.differences.map(\.id)), ["name", "code", "instructor", "semester", "description"])
        XCTAssertEqual(try comparison.resolvedValue(choices: [:]), draft.value)
    }
}
