import SwiftData
import XCTest
@testable import WordNoteCore

@MainActor
final class CourseServiceTests: XCTestCase {
    func testCreateAndUpdateCoursePersist() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = CourseService(modelContext: context)

        let course = try service.create(
            courseName: " Machine Learning ",
            courseCode: " COMP 5212 ",
            instructor: " Prof. Lee ",
            semester: " Fall 2026 ",
            description: " Core ML course "
        )

        XCTAssertEqual(course.courseName, "Machine Learning")
        XCTAssertEqual(course.courseCode, "COMP 5212")

        try service.update(
            course,
            courseName: "Deep Learning",
            courseCode: "COMP 5213",
            instructor: nil,
            semester: "Spring 2027",
            description: nil
        )

        XCTAssertEqual(course.courseName, "Deep Learning")
        XCTAssertEqual(course.courseCode, "COMP 5213")
        XCTAssertNil(course.instructor)

        let courses = try context.fetch(FetchDescriptor<CourseModel>())
        XCTAssertEqual(courses.count, 1)
    }

    func testBlankCourseNameRejected() throws {
        let context = ModelContext(try makeInMemoryContainer())
        let service = CourseService(modelContext: context)

        XCTAssertThrowsError(
            try service.create(courseName: "  ", courseCode: nil, instructor: nil, semester: nil, description: nil)
        ) { error in
            XCTAssertEqual(error as? CourseServiceError, .blankCourseName)
        }
    }

    func testDeleteReferencedCourseIsRejected() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = CourseService(modelContext: context)
        let course = try service.create(
            courseName: "Machine Learning",
            courseCode: nil,
            instructor: nil,
            semester: nil,
            description: nil
        )
        context.insert(InputRecordModel(rawText: "regularization", courseID: course.id, sourceType: .class))
        try context.save()

        XCTAssertThrowsError(try service.delete(course)) { error in
            XCTAssertEqual(error as? CourseServiceError, .courseInUse)
        }
    }

    func testDeleteUnusedCourseRemovesIt() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)
        let service = CourseService(modelContext: context)
        let course = try service.create(
            courseName: "Unused",
            courseCode: nil,
            instructor: nil,
            semester: nil,
            description: nil
        )

        try service.delete(course)

        let courses = try context.fetch(FetchDescriptor<CourseModel>())
        XCTAssertTrue(courses.isEmpty)
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            CourseModel.self,
            InputRecordModel.self,
            CandidateTermModel.self,
            TermModel.self,
            ReviewEventModel.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
