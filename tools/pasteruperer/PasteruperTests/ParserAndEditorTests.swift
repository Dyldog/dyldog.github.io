import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Pasteruperer

@MainActor
struct ParserAndEditorTests {
    /// Every real post in the blog survives being opened and saved again: same Markdown, nothing
    /// re-exported, nothing deleted.
    @Test func realPostsRoundTrip() throws {
        let repo = try #require(BlogRepo.defaultLocation().map(BlogRepo.init(root:)))
        let posts = PostParser.posts(in: "_posts", of: repo)
        #expect(posts.count >= 5)

        for post in posts {
            let text = try String(contentsOf: repo.url(post.path), encoding: .utf8)
            let draft = PostParser.parse(path: post.path, text: text, repo: repo)
            let plan = try PostBuilder(draft: draft, siteTimeZone: repo.siteTimeZone(), exists: repo.exists, repoRoot: repo.root).build()

            #expect(plan.post.path == post.path)
            #expect(plan.images.isEmpty, "\(post.path) re-exports images")
            #expect(plan.audio.isEmpty, "\(post.path) copies audio")
            #expect(plan.deletions.isEmpty)
            #expect(normalised(plan.post.contents) == normalised(text), "\(post.path) changed")
        }
    }

    /// Opening a post twice gives the same content (new ids aside), so untouched drafts can be cleaned up.
    @Test func unchangedPostsHaveTheSameSignature() throws {
        let repo = try #require(BlogRepo.defaultLocation().map(BlogRepo.init(root:)))
        for post in PostParser.posts(in: "_posts", of: repo) {
            let text = try String(contentsOf: repo.url(post.path), encoding: .utf8)
            let first = PostParser.parse(path: post.path, text: text, repo: repo)
            var second = PostParser.parse(path: post.path, text: text, repo: repo)
            #expect(first != second)
            #expect(first.contentSignature == second.contentSignature, "\(post.path)")
            // Survives being saved and loaded as a draft.
            let saved = try JSONDecoder().decode(PostDraft.self, from: JSONEncoder().encode(first))
            #expect(saved.contentSignature == second.contentSignature)
            second.title += "!"
            #expect(first.contentSignature != second.contentSignature)
        }
    }

    @Test func parsesHandWrittenFrontMatter() throws {
        let repo = BlogRepo(root: URL(filePath: "/nonexistent"))
        let text = """
        ---
        layout: post
        title:  'It''s "here"'
        date:   2026-04-22 12:03:30 +1000
        categories: [advice, isaac]
        tags:
          - one
          - two
        ---

        Hi.
        ![missing]({{ site.baseurl }}/images/nope.jpg)
        """
        let draft = PostParser.parse(path: "_posts/2026-04-22-my_post.md", text: text, repo: repo)
        #expect(draft.title == "It's \"here\"")
        #expect(draft.categories == ["advice", "isaac"])
        #expect(draft.customSlug == "my_post")
        #expect(draft.extraFrontMatter == ["tags:", "  - one", "  - two"])
        #expect(PostBuilder.format(draft.date, "yyyy-MM-dd'T'HH:mm:ssZ", TimeZone(identifier: "Australia/Brisbane")!) == "2026-04-22T12:03:30+1000")
        // An image that isn't in the repo stays as Markdown text.
        #expect(draft.blocks.first?.content == .text("Hi.\n![missing]({{ site.baseurl }}/images/nope.jpg)"))
    }

    @Test func formattingActions() {
        let controller = MarkdownEditorController()
        let textView = NSTextView(usingTextLayoutManager: false)
        controller.textView = textView

        func run(_ text: String, select range: NSRange, _ action: MarkdownAction) -> (String, NSRange) {
            textView.string = text
            textView.setSelectedRange(range)
            controller.apply(action)
            return (textView.string, textView.selectedRange())
        }

        #expect(run("make this bold", select: NSRange(location: 5, length: 4), .bold) == ("make **this** bold", NSRange(location: 7, length: 4)))
        #expect(run("make **this** bold", select: NSRange(location: 7, length: 4), .bold).0 == "make this bold")
        #expect(run("an *em*", select: NSRange(location: 3, length: 4), .italic).0 == "an em")
        #expect(run("Title", select: NSRange(location: 2, length: 0), .heading(2)) == ("## Title", NSRange(location: 8, length: 0)))
        #expect(run("### Title", select: NSRange(location: 0, length: 0), .heading(2)).0 == "## Title")
        #expect(run("## Title", select: NSRange(location: 0, length: 0), .heading(2)).0 == "Title")
        #expect(run("a\nb\n\nc", select: NSRange(location: 0, length: 6), .numberedList).0 == "1. a\n2. b\n\n3. c")
        #expect(run("- a\n- b", select: NSRange(location: 0, length: 7), .bulletList).0 == "a\nb")
        #expect(run("x https://example.com y", select: NSRange(location: 2, length: 19), .link).0 == "x [](https://example.com) y")
    }

    /// Re-layouts (like hovering a block) probe narrower sizes; the text must still wrap at its real width.
    @Test func textKeepsItsWidthAfterLayoutProbes() throws {
        let text = String(repeating: "Some words that wrap across a few lines. ", count: 20)
        let editor = MarkdownTextView(text: .constant(text), controller: MarkdownEditorController(), onFocusChange: { _ in }, onPasteMedia: { _, _ in })
        let controller = NSHostingController(rootView: editor.frame(maxWidth: .infinity))
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(findTextView(in: host))
        let height = textView.frame.height

        // Ask the same view tree how big it would be at a narrower width, as SwiftUI does while laying out.
        _ = controller.sizeThatFits(in: NSSize(width: 200, height: 10_000))
        // Then lay out again at the same size, as when hovering redraws the block.
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        #expect(textView.frame.width == 600)
        #expect(textView.textContainer?.containerSize.width == 600)
        #expect(textView.frame.height == height)
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews { if let found = findTextView(in: subview) { return found } }
        return nil
    }

    @Test func pastedImageDataIsStoredButTextWins() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pasteruperer-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        let urls = try #require(MediaStore.media(from: pasteboard))
        #expect(urls.count == 1)
        #expect(urls[0].pathExtension == "png")
        #expect(try Data(contentsOf: urls[0]) == png)
        try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent())

        // Copied text that happens to carry a picture of itself pastes as text.
        pasteboard.clearContents()
        pasteboard.setString("Some words", forType: .string)
        pasteboard.setData(png, forType: .png)
        #expect(MediaStore.media(from: pasteboard) == nil)
    }

    /// Ignores spacing differences in front matter and trailing whitespace.
    private func normalised(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                var line = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                if let colon = line.firstIndex(of: ":"), line.first?.isLetter == true {
                    line = line[..<colon] + ": " + line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                return line
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
