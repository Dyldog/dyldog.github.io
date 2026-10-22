import Foundation
import Testing
@testable import Pasteruperer

/// Runs the blog's real Jekyll against a clone of the site and checks the draft renders and updates.
@MainActor
struct PreviewServerTests {
    @Test(.timeLimit(.minutes(1)))
    func rendersAndUpdatesTheDraft() async throws {
        let repo = try #require(BlogRepo.defaultLocation().map(BlogRepo.init(root:)))
        let cache = URL.temporaryDirectory.appending(path: "pasteruperer-preview-\(UUID().uuidString)")
        let server = PreviewServer(cacheDirectory: cache)
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: cache)
        }

        var draft = PostDraft()
        draft.title = "Preview check"
        draft.categories = ["test"]
        draft.blocks = [Block(.text("First **version**."))]
        await server.start(repo: repo, draft: draft)

        let url = try #require(server.pageURL)
        #expect(url.path().hasSuffix("/preview-check.html"))
        try await waitFor(server, "Jekyll to start") { $0.status == .ready }
        let first = try await page(url)
        #expect(first.contains("Preview check"))
        #expect(first.contains("<strong>version</strong>"))

        // Edits are written into the clone and Jekyll rebuilds.
        let token = server.reloadToken
        draft.blocks = [Block(.text("Second version."))]
        server.update(draft)
        try await waitFor(server, "a rebuild") { $0.reloadToken > token }
        #expect(try await page(url).contains("Second version."))

        // The real repo was never touched.
        #expect(!repo.exists("_posts/\(PostBuilder.format(Date(), "yyyy-MM-dd", .current))-preview-check.md"))
    }

    private func waitFor(_ server: PreviewServer, _ what: String, _ condition: (PreviewServer) -> Bool) async throws {
        for _ in 0..<400 {
            if condition(server) { return }
            if case .failed(let message) = server.status {
                Issue.record("Preview failed: \(message)\n\(server.log)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("Timed out waiting for \(what).\n\(server.log)")
        throw CancellationError()
    }

    private func page(_ url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }
}
