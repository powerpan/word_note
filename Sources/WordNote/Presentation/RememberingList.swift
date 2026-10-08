import SwiftUI

private struct ListRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct ListCoordinateSpace: EnvironmentKey { static let defaultValue: UUID? = nil }

/// Remember the top visible row, independently of keyboard selection.
struct RememberingList<Content: View>: View {
    @Binding var selection: UUID?
    @Binding var anchor: UUID?
    let ids: [UUID]
    @ViewBuilder var content: Content
    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) { content }
                .modifier(RowScrollMemory(anchor: $anchor, ids: ids, proxy: proxy))
        }
    }
}

struct RememberingScrollView<Content: View>: View {
    @Binding var anchor: UUID?
    let ids: [UUID]
    @ViewBuilder var content: Content
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .modifier(RowScrollMemory(anchor: $anchor, ids: ids, proxy: proxy))
        }
    }
}

private struct RowScrollMemory: ViewModifier {
    @Binding var anchor: UUID?
    let ids: [UUID]
    let proxy: ScrollViewProxy
    @State private var coordinateSpace = UUID()
    @State private var restored = false
    @State private var reportedAnchor: UUID?

    func body(content: Content) -> some View {
            content
                .environment(\.listCoordinateSpace, coordinateSpace)
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(ListRowFrames.self) { frames in
                    guard restored else { return }
                    if let row = frames.filter({ $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY }) {
                        reportedAnchor = row.key
                        anchor = row.key
                    }
                }
                .task(id: ids.isEmpty) {
                    guard !ids.isEmpty, !restored else { return }
                    let target = anchor.flatMap { ids.contains($0) ? $0 : nil }
                    await Task.yield()
                    if let target { proxy.scrollTo(target, anchor: .top) }
                    await Task.yield()
                    reportedAnchor = target
                    restored = true
                }
                .onChange(of: anchor) {
                    guard restored, anchor != reportedAnchor, let anchor, ids.contains(anchor) else { return }
                    proxy.scrollTo(anchor, anchor: .top)
                }
    }
}

private extension EnvironmentValues {
    var listCoordinateSpace: UUID? {
        get { self[ListCoordinateSpace.self] }
        set { self[ListCoordinateSpace.self] = newValue }
    }
}

private struct RememberListRow: ViewModifier {
    @Environment(\.listCoordinateSpace) private var coordinateSpace
    let id: UUID
    func body(content: Content) -> some View {
        content.id(id).background {
            if let coordinateSpace {
                GeometryReader { proxy in
                    Color.clear.preference(key: ListRowFrames.self, value: [id: proxy.frame(in: .named(coordinateSpace))])
                }
            }
        }
    }
}

extension View {
    func rememberListRow(_ id: UUID) -> some View { modifier(RememberListRow(id: id)) }
}
