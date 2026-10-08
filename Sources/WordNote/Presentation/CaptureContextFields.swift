import SwiftData
import SwiftUI
import WordNoteCore

private struct CaptureContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: CaptureContextController? = nil
}

extension EnvironmentValues {
    var captureContext: CaptureContextController? {
        get { self[CaptureContextEnvironmentKey.self] }
        set { self[CaptureContextEnvironmentKey.self] = newValue }
    }
}

extension LookupIntent {
    var displayTitle: String {
        switch self {
        case .auto: "Automatic"
        case .englishToChinese: "English to Chinese"
        case .chineseToEnglish: "Chinese to English"
        }
    }
}

struct CaptureContextFields: View {
    enum Scope { case current, defaults }
    let controller: CaptureContextController
    var scope: Scope = .current
    @Query private var storedCourses: [CourseModel]
    @State private var errorMessage: String?

    private var courseIDs: Set<UUID> { Set(storedCourses.map(\.id)) }
    private var selection: CaptureContextSelection { scope == .defaults ? controller.defaultContext : controller.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(scope == .defaults ? "Default course" : "Course", selection: courseBinding) {
                Text("No Course").tag(UUID?.none)
                ForEach(storedCourses.sorted { $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending }, id: \.id) { course in
                    Text(course.courseName).tag(Optional(course.id))
                }
            }
            Picker(scope == .defaults ? "Default source" : "Source", selection: sourceBinding) {
                ForEach(SourceType.allCases) { source in Text(source.displayTitle).tag(source) }
            }
            Picker(scope == .defaults ? "Default direction" : "Direction", selection: intentBinding) {
                ForEach(LookupIntent.allCases, id: \.self) { intent in Text(intent.displayTitle).tag(intent) }
            }
            if scope == .current {
                HStack {
                    Text(controller.isUsingDefaults ? "Using defaults" : "Current capture context")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Defaults", systemImage: "arrow.counterclockwise") {
                        controller.useDefaults()
                        errorMessage = nil
                    }
                    .labelStyle(.iconOnly).help("Use capture defaults")
                    .disabled(controller.isUsingDefaults && controller.courseWarning == nil)
                }
            }
            if let warning = errorMessage ?? controller.courseWarning ?? controller.preferenceWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pickerStyle(.menu)
        .onAppear { controller.reconcileCourses(courseIDs) }
        .onChange(of: courseIDs) { controller.reconcileCourses(courseIDs) }
    }

    private var courseBinding: Binding<UUID?> {
        Binding(get: { selection.courseID }, set: { id in
            update {
                if scope == .defaults {
                    var value = selection
                    value.courseID = id
                    try controller.updateDefaults(value)
                } else { try controller.selectCourse(id) }
            }
        })
    }

    private var sourceBinding: Binding<SourceType> {
        Binding(get: { selection.sourceType }, set: { source in
            update {
                if scope == .defaults {
                    var value = selection
                    value.sourceType = source
                    try controller.updateDefaults(value)
                } else { controller.selectSource(source) }
            }
        })
    }

    private var intentBinding: Binding<LookupIntent> {
        Binding(get: { selection.intent }, set: { intent in
            update {
                if scope == .defaults {
                    var value = selection
                    value.intent = intent
                    try controller.updateDefaults(value)
                } else { controller.selectIntent(intent) }
            }
        })
    }

    private func update(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

extension CaptureContextController {
    func request(rawText: String, note: String? = nil, capturedVia: CaptureSurface, modelContext: ModelContext) throws -> WordNoteCaptureRequest {
        try request(
            rawText: rawText, note: note, capturedVia: capturedVia,
            availableCourseIDs: Set(modelContext.fetch(FetchDescriptor<CourseModel>()).map(\.id))
        )
    }
}
