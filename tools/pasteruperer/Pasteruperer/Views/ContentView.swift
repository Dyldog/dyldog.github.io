import SwiftUI
import PhotosUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.repo != nil {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 360)
                } detail: {
                    EditorView()
                }
            } else {
                ContentUnavailableView {
                    Label("Choose Your Blog", systemImage: "folder")
                } description: {
                    Text("Pick the folder that contains your Jekyll blog's _config.yml and _posts.")
                } actions: {
                    Button("Choose Folder…") { model.chooseRepo() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $model.isPublishing) {
            PublishSheet()
        }
        .sheet(item: $model.postToDelete) { post in
            DeleteSheet(post: post)
        }
        .confirmationDialog(
            "Discard “\(model.draftToDiscard?.displayTitle ?? "")”?",
            isPresented: Binding(get: { model.draftToDiscard != nil }, set: { if !$0 { model.draftToDiscard = nil } })
        ) {
            Button("Discard Draft", role: .destructive) {
                if let draft = model.draftToDiscard { model.discard(draft) }
            }
        } message: {
            Text(model.draftToDiscard?.origin == nil
                 ? "This draft only exists in Pasteruperer and can't be recovered."
                 : "Your unsaved edits are thrown away. The version in the repo isn't changed.")
        }
    }
}

struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let origin = model.draft.origin {
                    EditingBanner(origin: origin)
                }
                // The post is a poster pasted on the wall.
                PasteUp(seed: Int(truncatingIfNeeded: Theme.stableHash(model.draft.id.uuidString))) {
                    VStack(alignment: .leading, spacing: 24) {
                        PostHeaderView()
                        Rectangle()
                            .fill(Theme.ink)
                            .frame(height: 3)
                        BlockListView()
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 46)
                    .padding(.bottom, 40)
                }
                .overlay(alignment: .top) {
                    HStack {
                        Tape(angle: .degrees(-6))
                        Spacer()
                        Tape(angle: .degrees(5))
                    }
                    .padding(.horizontal, 24)
                    .offset(y: -8)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        // Rebuild the editors when switching drafts so text views don't carry over.
        .id(model.draft.id)
        .background(ConcreteBackground())
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.cyan, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .neonGlow(Theme.cyan)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let media = urls.filter { $0.isImageFile || $0.isAudioFile }
            model.insertFiles(media, after: model.draft.blocks.last?.id)
            return !media.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .photosPicker(isPresented: $model.isPickingPhotos, selection: $photoItems, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoItems) {
            let items = photoItems
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                var urls: [URL] = []
                for item in items {
                    if let picked = try? await item.loadTransferable(type: PickedImage.self) { urls.append(picked.url) }
                }
                model.insertPhotos(urls)
            }
        }
        .navigationTitle(model.draft.displayTitle)
        .navigationSubtitle(model.repo.map { repo in [repo.displayName, model.branch].compactMap { $0 }.joined(separator: " · ") } ?? "")
        .toolbar {
            ToolbarItemGroup {
                ControlGroup {
                    Button { model.format(.bold) } label: { Label("Bold", systemImage: "bold") }
                        .help("Bold (⌘B)")
                    Button { model.format(.italic) } label: { Label("Italic", systemImage: "italic") }
                        .help("Italic (⌘I)")
                    Button { model.format(.link) } label: { Label("Link", systemImage: "link") }
                        .help("Link (⌘K)")
                    Menu {
                        FormatMenuItems()
                    } label: {
                        Label("More Formatting", systemImage: "textformat")
                    }
                    .help("Headings, lists, quotes and code")
                }
                .disabled(!model.isEditingText)

                Menu {
                    InsertMenuItems(after: model.draft.blocks.last?.id)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add text, images or audio at the end")

                Button { openWindow(id: "preview") } label: {
                    Label("Preview", systemImage: "eye")
                }
                .help("Preview the post with the site's own Jekyll (⌥⌘P)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.isPublishing = true } label: {
                    Label("Post", systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(StickerButtonStyle(color: Theme.acid))
                .help("Review, commit and push the post (⌘↩)")
            }
        }
    }
}

private struct EditingBanner: View {
    @Environment(AppModel.self) private var model
    let origin: PostOrigin

    var body: some View {
        let viewing = model.isViewingPost
        HStack(spacing: 0) {
            HazardStripes(color: viewing ? Theme.cyan : Theme.acid)
                .frame(width: 30)
            HStack(spacing: 10) {
                Text(viewing
                     ? (origin.isJekyllDraft ? "Draft in the repo" : "Published post")
                     : (origin.isJekyllDraft ? "Editing a repo draft" : "Editing a published post"))
                    .font(Theme.display(13))
                    .foregroundStyle(viewing ? Theme.cyan : Theme.acid)
                    .neonGlow(viewing ? Theme.cyan : Theme.acid, radius: 3)
                Text(origin.path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if viewing {
                    Text("make a change to start a draft")
                        .font(Theme.marker(14))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Button("Discard") { model.draftToDiscard = model.draft }
                        .buttonStyle(StickerButtonStyle(color: Theme.pink, tilt: .degrees(1.5)))
                        .help("Throw away these changes")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 42)
        .background(Theme.ink.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.08)))
    }
}

struct InsertMenuItems: View {
    @Environment(AppModel.self) private var model
    let after: UUID?

    var body: some View {
        Button { model.insertText(after: after) } label: { Label("Text", systemImage: "text.alignleft") }
        Divider()
        Button { model.insertImages(after: after) } label: { Label("Images from Files…", systemImage: "photo") }
        Button { model.pickPhotos(after: after) } label: { Label("Images from Photos…", systemImage: "photo.on.rectangle") }
        Button { model.pasteMedia(after: after) } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
        Divider()
        Button { model.insertAudio(after: after) } label: { Label("Audio…", systemImage: "music.note.list") }
    }
}

struct FormatMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Bold") { model.format(.bold) }
            .keyboardShortcut("b")
        Button("Italic") { model.format(.italic) }
            .keyboardShortcut("i")
        Button("Code") { model.format(.code) }
            .keyboardShortcut("`", modifiers: [.command])
        Button("Link") { model.format(.link) }
            .keyboardShortcut("k")
        Divider()
        Button("Heading") { model.format(.heading(2)) }
            .keyboardShortcut("2", modifiers: [.command, .option])
        Button("Subheading") { model.format(.heading(3)) }
            .keyboardShortcut("3", modifiers: [.command, .option])
        Divider()
        Button("Bulleted List") { model.format(.bulletList) }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        Button("Numbered List") { model.format(.numberedList) }
            .keyboardShortcut("l", modifiers: [.command, .option])
        Button("Quote") { model.format(.quote) }
            .keyboardShortcut("'", modifiers: [.command, .shift])
    }
}
