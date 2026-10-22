import SwiftUI

@main
struct PasteruperApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model: AppModel

    init() {
        Theme.registerFonts()
        // The whole app lives on a dark concrete wall.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Pasteruperer", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1120, height: 860)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Post") { model.newDraft() }
                    .keyboardShortcut("n")
            }
            CommandMenu("Format") {
                FormatMenuItems()
                    .environment(model)
                    .disabled(!model.isEditingText)
            }
            CommandMenu("Post") {
                PostMenuItems()
                    .environment(model)
            }
        }

        Window("Preview", id: "preview") {
            PreviewWindow()
                .environment(model)
        }
        .defaultSize(width: 760, height: 900)
        // Opening it starts Jekyll, so only when asked.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

private struct PostMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let last = model.draft.blocks.last?.id
        Button("Add Text") { model.insertText(after: last) }
            .keyboardShortcut("t", modifiers: [.command, .option])
        Button("Add Images…") { model.insertImages(after: last) }
            .keyboardShortcut("i", modifiers: [.command, .option])
        Button("Add Images from Photos…") { model.pickPhotos(after: last) }
        Button("Paste Image") { model.pasteMedia(after: last) }
            .keyboardShortcut("v", modifiers: [.command, .option])
        Button("Add Audio…") { model.insertAudio(after: last) }
            .keyboardShortcut("a", modifiers: [.command, .option])
        Divider()
        Button("Preview") { openWindow(id: "preview") }
            .keyboardShortcut("p", modifiers: [.command, .option])
        Button("Post…") { model.isPublishing = true }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.repo == nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave Jekyll running after the app quits.
        PreviewServer.stopAll()
    }
}
