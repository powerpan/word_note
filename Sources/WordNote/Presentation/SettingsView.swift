import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultSourceType") private var defaultSourceType = "other"

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Default source", selection: $defaultSourceType) {
                    Text("Class").tag("class")
                    Text("Paper").tag("paper")
                    Text("Slides").tag("slides")
                    Text("Assignment").tag("assignment")
                    Text("Book").tag("book")
                    Text("Other").tag("other")
                }
                .pickerStyle(.menu)
            }

            Section("DeepSeek") {
                Text("API key storage and connectivity testing will be implemented in M3.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
