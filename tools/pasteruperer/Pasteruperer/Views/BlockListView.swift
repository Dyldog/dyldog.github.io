import SwiftUI

struct BlockListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InsertBar(after: nil)
            ForEach(model.draft.blocks) { block in
                BlockContainer(id: block.id)
                InsertBar(after: block.id)
            }
        }
    }
}

/// Hover controls (move, delete) around one block.
private struct BlockContainer: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var isHovering = false

    var body: some View {
        let block = model.block(id)
        let isFirst = model.draft.blocks.first?.id == id
        let isLast = model.draft.blocks.last?.id == id

        // The controls sit in the page's right margin so they never cover or squeeze the content.
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch block.wrappedValue.content {
                case .text:
                    TextBlockView(id: id, text: block.text)
                case .image:
                    ImageBlockView(image: block.image)
                case .audio:
                    AudioBlockView(playlist: block.audio)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                Button { model.move(id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(isFirst)
                    .help("Move up")
                Button { model.move(id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(isLast)
                    .help("Move down")
                Button(role: .destructive) { model.remove(id) } label: { Image(systemName: "trash") }
                    .help("Remove")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.ink.opacity(0.7))
            .frame(width: Self.gutter - 8)
            .opacity(isHovering ? 1 : 0)
        }
        // Hover is tracked over the whole row, margin included, so the buttons stay up while you reach them.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .padding(.trailing, -Self.gutter)
    }

    private static let gutter: CGFloat = 32
}

/// A thin gap between blocks that reveals an "add" menu on hover.
private struct InsertBar: View {
    let after: UUID?
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.pink.opacity(isHovering ? 0.8 : 0))
                .frame(height: 2)
            Menu {
                InsertMenuItems(after: after)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.pink)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering ? 1 : 0)
            .help("Insert here")
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

struct TextBlockView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @Binding var text: String
    @State private var controller = MarkdownEditorController()

    var body: some View {
        MarkdownTextView(
            text: $text,
            controller: controller,
            onFocusChange: { focused in
                if focused { model.editorDidFocus(controller) } else { model.editorDidBlur(controller) }
            },
            onPasteMedia: { urls, offset in
                model.insert(model.mediaBlocks(urls), splitting: id, at: offset)
            }
        )
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text("write something… markdown works, and you can paste images straight in")
                    .font(Theme.marker(17))
                    .foregroundStyle(Theme.ink.opacity(0.3))
                    .padding(.top, MarkdownTextView.inset.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 40, alignment: .top)
    }
}
