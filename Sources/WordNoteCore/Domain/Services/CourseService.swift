import Foundation
import SwiftData

public enum CourseServiceError: LocalizedError, Equatable {
    case blankCourseName
    case courseInUse

    public var errorDescription: String? {
        switch self {
        case .blankCourseName:
            return "Course name cannot be empty."
        case .courseInUse:
            return "This course is used by records or terms and cannot be deleted."
        }
    }
}

@MainActor
public struct CourseService {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    public func create(
        courseName: String,
        courseCode: String?,
        instructor: String?,
        semester: String?,
        description: String?
    ) throws -> CourseModel {
        let trimmedName = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedName) else {
            throw CourseServiceError.blankCourseName
        }

        let course = CourseModel(
            courseName: trimmedName,
            courseCode: normalizedOptional(courseCode),
            instructor: normalizedOptional(instructor),
            semester: normalizedOptional(semester),
            courseDescription: normalizedOptional(description)
        )

        modelContext.insert(course)
        try modelContext.save()
        return course
    }

    public func update(
        _ course: CourseModel,
        courseName: String,
        courseCode: String?,
        instructor: String?,
        semester: String?,
        description: String?
    ) throws {
        let trimmedName = courseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !TextNormalizer.isBlank(trimmedName) else {
            throw CourseServiceError.blankCourseName
        }

        course.courseName = trimmedName
        course.courseCode = normalizedOptional(courseCode)
        course.instructor = normalizedOptional(instructor)
        course.semester = normalizedOptional(semester)
        course.courseDescription = normalizedOptional(description)
        course.touch()
        try modelContext.save()
    }

    public func delete(_ course: CourseModel) throws {
        let courseID = course.id
        let inputDescriptor = FetchDescriptor<InputRecordModel>(
            predicate: #Predicate { record in
                record.courseID == courseID
            }
        )
        let termDescriptor = FetchDescriptor<TermModel>(
            predicate: #Predicate { term in
                term.courseID == courseID
            }
        )

        let inputCount = try modelContext.fetchCount(inputDescriptor)
        let termCount = try modelContext.fetchCount(termDescriptor)
        guard inputCount == 0, termCount == 0 else {
            throw CourseServiceError.courseInUse
        }

        modelContext.delete(course)
        try modelContext.save()
    }

    private func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == true ? nil : trimmed
    }
}
