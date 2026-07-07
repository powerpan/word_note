import SwiftData
import SwiftUI
import WordNoteCore

struct CoursesOverviewView: View {
    @Query(sort: \CourseModel.courseName) private var courses: [CourseModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Courses")
                .font(.largeTitle.bold())

            if courses.isEmpty {
                ContentUnavailableView(
                    "No Courses",
                    systemImage: "graduationcap",
                    description: Text("M5 will add course creation and editing.")
                )
            } else {
                List(courses) { course in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.courseName)
                            .font(.headline)
                        if let courseCode = course.courseCode {
                            Text(courseCode)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(28)
    }
}
