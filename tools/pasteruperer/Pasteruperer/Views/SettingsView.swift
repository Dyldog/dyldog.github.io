import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Defaults.imageMaxWidth) private var maxWidth = 1600
    @AppStorage(Defaults.imageQuality) private var quality = 0.82

    var body: some View {
        Form {
            Section("Blog") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.repo?.root.path ?? "Not set")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseRepo() }
                    }
                }
            }
            Section("New images") {
                LabeledContent("Max width") {
                    HStack {
                        TextField("Max width", value: $maxWidth, format: .number.grouping(.never))
                            .labelsHidden()
                            .frame(width: 70)
                        Text("px")
                    }
                }
                LabeledContent("JPEG quality") {
                    HStack {
                        Slider(value: $quality, in: 0.4...1, step: 0.02)
                        Text("\(Int((quality * 100).rounded()))%").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
