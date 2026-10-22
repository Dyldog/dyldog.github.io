import SwiftUI
import AppKit

enum MarkdownAction {
    case bold, italic, code, link, heading(Int), bulletList, numberedList, quote
}

/// Lets the Format menu and toolbar act on whichever text block is being typed in.
@MainActor
final class MarkdownEditorController {
    weak var textView: NSTextView?

    func apply(_ action: MarkdownAction) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        switch action {
        case .bold: toggleWrap("**", in: textView)
        case .italic: toggleWrap("*", in: textView)
        case .code: toggleWrap("`", in: textView)
        case .link: insertLink(in: textView)
        case .heading(let level): toggleLinePrefix(String(repeating: "#", count: level) + " ", strip: #"^#{1,6}\s+"#, in: textView)
        case .bulletList: toggleLinePrefix("- ", strip: #"^([-*+]|\d+\.)\s+"#, in: textView)
        case .numberedList: toggleLinePrefix("1. ", strip: #"^([-*+]|\d+\.)\s+"#, numbered: true, in: textView)
        case .quote: toggleLinePrefix("> ", strip: #"^>\s?"#, in: textView)
        }
    }

    /// Wraps the selection in `marker`, or unwraps it if it's already wrapped.
    private func toggleWrap(_ marker: String, in textView: NSTextView) {
        let text = textView.string as NSString
        let range = textView.selectedRange()
        let length = (marker as NSString).length
        let selected = text.substring(with: range)

        if range.location >= length, NSMaxRange(range) + length <= text.length,
           text.substring(with: NSRange(location: range.location - length, length: length)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(range), length: length)) == marker {
            let outer = NSRange(location: range.location - length, length: range.length + length * 2)
            replace(outer, with: selected, select: NSRange(location: outer.location, length: range.length), in: textView)
        } else if selected.count > marker.count * 2, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            replace(range, with: inner, select: NSRange(location: range.location, length: (inner as NSString).length), in: textView)
        } else {
            replace(range, with: marker + selected + marker, select: NSRange(location: range.location + length, length: range.length), in: textView)
        }
    }

    /// `[selection](url)`, using a link on the clipboard if there is one.
    private func insertLink(in textView: NSTextView) {
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        let clipboardURL = NSPasteboard.general.string(forType: .string).flatMap(URL.webURL(from:))?.absoluteString

        if let url = URL.webURL(from: selected) {
            let replacement = "[](\(url.absoluteString))"
            replace(range, with: replacement, select: NSRange(location: range.location + 1, length: 0), in: textView)
            return
        }
        let label = selected.isEmpty ? "link text" : selected
        let url = clipboardURL ?? "https://"
        let replacement = "[\(label)](\(url))"
        let labelLength = (label as NSString).length
        let selection = selected.isEmpty
            ? NSRange(location: range.location + 1, length: labelLength)
            : clipboardURL == nil
                ? NSRange(location: range.location + labelLength + 3, length: (url as NSString).length)
                : NSRange(location: range.location + (replacement as NSString).length, length: 0)
        replace(range, with: replacement, select: selection, in: textView)
    }

    /// Adds `prefix` to every selected line, or removes it if they all have it already.
    private func toggleLinePrefix(_ prefix: String, strip pattern: String, numbered: Bool = false, in textView: NSTextView) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = text.lineRange(for: selection)
        var block = text.substring(with: lineRange)
        let endsWithNewline = block.hasSuffix("\n")
        if endsWithNewline { block.removeLast() }

        let lines = block.components(separatedBy: "\n")
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let isApplied = !content.isEmpty && content.allSatisfy { line in
            numbered ? line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil : line.hasPrefix(prefix)
        }

        var number = 0
        let updated = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
            let bare = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            if isApplied { return bare }
            number += 1
            return (numbered ? "\(number). " : prefix) + bare
        }
        let replacement = updated.joined(separator: "\n")
        let length = (replacement as NSString).length
        let newSelection = selection.length == 0 && lines.count == 1
            ? NSRange(location: lineRange.location + length, length: 0)
            : NSRange(location: lineRange.location, length: length)
        replace(NSRange(location: lineRange.location, length: lineRange.length - (endsWithNewline ? 1 : 0)), with: replacement, select: newSelection, in: textView)
    }

    /// Replaces text through the text view so it's undoable and the binding hears about it.
    private func replace(_ range: NSRange, with string: String, select selection: NSRange, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: textView.typingAttributes))
        textView.didChangeText()
        textView.setSelectedRange(selection)
    }
}

final class MarkdownNSTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// Called with pasted images/audio and the UTF-16 offset of the cursor.
    var onPasteMedia: (([URL], Int) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func paste(_ sender: Any?) {
        if let onPasteMedia, let media = MediaStore.media(from: .general), !media.isEmpty {
            onPasteMedia(media, selectedRange().location)
            return
        }
        // Pasting a link over selected text makes a Markdown link.
        let range = selectedRange()
        if range.length > 0,
           let string = NSPasteboard.general.string(forType: .string),
           let url = URL.webURL(from: string) {
            let selected = (self.string as NSString).substring(with: range)
            if URL.webURL(from: selected) == nil && !selected.contains("\n") {
                insertText("[\(selected)](\(url.absoluteString))", replacementRange: range)
                return
            }
        }
        super.paste(sender)
    }
}

/// A plain-text Markdown editor that grows with its content.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var onFocusChange: (Bool) -> Void
    var onPasteMedia: ([URL], Int) -> Void

    static let font = NSFont.systemFont(ofSize: 15)
    static let inset = NSSize(width: 0, height: 3)

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }

    static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: Theme.inkNS]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> MarkdownNSTextView {
        let textView = MarkdownNSTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = Theme.inkNS
        textView.insertionPointColor = Theme.inkNS
        textView.appearance = NSAppearance(named: .aqua)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(red: 1, green: 0.176, blue: 0.541, alpha: 0.3)]
        // Straight quotes and dashes matter in Markdown.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = Self.inset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.attributes
        textView.string = text
        textView.textStorage?.setAttributes(Self.attributes, range: NSRange(location: 0, length: (text as NSString).length))
        textView.delegate = context.coordinator
        controller.textView = textView
        update(textView)
        return textView
    }

    func updateNSView(_ textView: MarkdownNSTextView, context: Context) {
        context.coordinator.text = $text
        update(textView)
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.textStorage?.setAttributes(Self.attributes, range: NSRange(location: 0, length: length))
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    private func update(_ textView: MarkdownNSTextView) {
        textView.onFocusChange = onFocusChange
        textView.onPasteMedia = onPasteMedia
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: MarkdownNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // Measure with a separate layout: SwiftUI probes narrower widths during layout, and resizing the
        // live text container for those would leave the text wrapped too narrowly.
        let height = context.coordinator.measure(textView.string, width: width) + Self.inset.height * 2
        return CGSize(width: width, height: ceil(height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        private let storage = NSTextStorage()
        private let layoutManager = NSLayoutManager()
        private let container = NSTextContainer()

        init(text: Binding<String>) {
            self.text = text
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
        }

        func measure(_ string: String, width: CGFloat) -> CGFloat {
            storage.setAttributedString(NSAttributedString(string: string, attributes: MarkdownTextView.attributes))
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
            return max(layoutManager.usedRect(for: container).height, layoutManager.defaultLineHeight(for: MarkdownTextView.font))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
