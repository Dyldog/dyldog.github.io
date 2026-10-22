import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Pasteruperer

/// Posts into a throwaway clone with a local bare "origin", end to end.
@MainActor
struct PublisherTests {
    @Test func postsCommitsAndPushesOnlyThePostsFiles() async throws {
        let sandbox = URL.temporaryDirectory.appending(path: "pasteruperer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let origin = sandbox.appending(path: "origin.git")
        let blog = sandbox.appending(path: "blog")
        try FileManager.default.createDirectory(at: blog.appending(path: "_posts"), withIntermediateDirectories: true)

        let git = Git(repo: blog)
        try await Git(repo: sandbox).run(["init", "-q", "--bare", "-b", "master", origin.path])
        try await git.run(["init", "-q", "-b", "master"])
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
        try "title: Test\nurl: \"https://example.com\"\n".write(to: blog.appending(path: "_config.yml"), atomically: true, encoding: .utf8)
        try "---\ncategories: art\n---\n".write(to: blog.appending(path: "_posts/2026-01-01-old.md"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-q", "-m", "init"])
        try await git.run(["remote", "add", "origin", origin.path])
        try await git.run(["push", "-q", "-u", "origin", "master"])
        // An unrelated local change that must not end up in the post's commit.
        try "draft".write(to: blog.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let photo = sandbox.appending(path: "Photo 1.png")
        try makeImage(width: 3000, height: 2000, opaque: true, at: photo, type: .png)
        let song = sandbox.appending(path: "my_song.wav")
        try makeSine(seconds: 1, at: song)

        let repo = BlogRepo(root: blog)
        #expect(repo.existingCategories() == ["art"])

        var draft = PostDraft()
        draft.title = "Test post"
        draft.categories = ["art", "music"]
        var image = ImageItem(source: photo)
        image.crop = CGRect(x: 0.25, y: 0, width: 0.5, height: 1) // 1500 × 2000 px
        image.maxWidth = 600
        draft.blocks = [
            Block(.text("Hello.")),
            Block(.image(image)),
            Block(.audio(AudioPlaylist(tracks: [AudioTrack(source: song)]))),
        ]
        let plan = try PostBuilder(draft: draft, siteTimeZone: repo.siteTimeZone(), exists: repo.exists, repoRoot: repo.root).build()

        let publisher = Publisher()
        await publisher.publish(plan, to: repo, message: "POST: Test post", push: true)
        #expect(publisher.errorMessage == nil)
        #expect(publisher.phase == .succeeded)
        #expect(publisher.pushed)

        // The image was cropped, scaled to 600 px wide, and kept PNG.
        let imagePath = try #require(plan.images.first?.path)
        #expect(imagePath.hasSuffix("/Photo-1.png"))
        #expect(ImageProcessing.uprightPixelSize(of: repo.url(imagePath)) == CGSize(width: 600, height: 800))

        // The WAV was converted to a playable m4a.
        let audioPath = try #require(plan.audio.first?.path)
        #expect(audioPath == "art/music/my_song.m4a")
        let duration = try await AVURLAsset(url: repo.url(audioPath)).load(.duration)
        #expect(abs(duration.seconds - 1) < 0.2)

        // Origin has exactly the post's files in one commit; the unrelated file stayed local.
        let pushed = try await Git(repo: origin).run(["show", "--name-only", "--format=%s", "master"])
        let lines = pushed.split(separator: "\n").map(String.init)
        #expect(lines.first == "POST: Test post")
        #expect(Set(lines.dropFirst()) == Set(plan.paths))
        #expect(try await git.run(["status", "--porcelain"]).trimmingCharacters(in: .whitespacesAndNewlines) == "?? notes.txt")
    }

    @Test func failedPostLeavesNoFilesBehind() async throws {
        let sandbox = URL.temporaryDirectory.appending(path: "pasteruperer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox.appending(path: "_posts"), withIntermediateDirectories: true)
        try "title: Test\n".write(to: sandbox.appending(path: "_config.yml"), atomically: true, encoding: .utf8)
        let photo = sandbox.appending(path: "in.jpg")
        try makeImage(width: 40, height: 40, opaque: true, at: photo, type: .jpeg)

        var draft = PostDraft()
        draft.title = "Nope"
        draft.blocks = [Block(.image(ImageItem(source: photo)))]
        let repo = BlogRepo(root: sandbox)
        let plan = try PostBuilder(draft: draft, siteTimeZone: .gmt, exists: repo.exists, repoRoot: repo.root).build()

        // Not a git repo, so the first step fails.
        let publisher = Publisher()
        await publisher.publish(plan, to: repo, message: "x", push: false)
        #expect(publisher.phase == .failed(committed: false))
        #expect(plan.paths.allSatisfy { !repo.exists($0) })
        #expect(!repo.exists("images"))
    }

    @Test func editingRenamesThePostAndRemovesUnusedPlaylists() async throws {
        let (sandbox, blog, origin) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = BlogRepo(root: blog)
        let song = sandbox.appending(path: "tune.wav")
        try makeSine(seconds: 0.5, at: song)

        var draft = PostDraft()
        draft.title = "First title"
        draft.categories = ["music"]
        draft.blocks = [Block(.text("Hello.")), Block(.audio(AudioPlaylist(tracks: [AudioTrack(source: song)])))]
        let first = try builder(draft, repo).build()
        await Publisher().publish(first, to: repo, message: "POST: First", push: true)
        #expect(repo.exists("_posts/\(Self.today)-first-title.md"))
        #expect(repo.exists("_data/first-title.yml"))

        // Open it again, rename it and drop the playlist.
        let path = "_posts/\(Self.today)-first-title.md"
        var edited = PostParser.parse(path: path, text: try String(contentsOf: repo.url(path), encoding: .utf8), repo: repo)
        #expect(edited.origin == PostOrigin(path: path, dataKeys: ["first-title"]))
        #expect(edited.title == "First title")
        #expect(edited.categories == ["music"])
        guard case .audio(let playlist) = edited.blocks[1].content else { Issue.record("no playlist"); return }
        #expect(playlist.tracks.map(\.title) == ["Tune"])
        #expect(playlist.tracks.first?.source.path.hasSuffix("art/music/tune.m4a") == true)

        edited.title = "Better title"
        edited.blocks.removeAll { if case .audio = $0.content { true } else { false } }
        let second = try builder(edited, repo).build()
        #expect(second.deletions == [path, "_data/first-title.yml"])

        let publisher = Publisher()
        await publisher.publish(second, to: repo, message: "EDIT: Better", push: true)
        #expect(publisher.phase == .succeeded)
        #expect(!repo.exists(path))
        #expect(!repo.exists("_data/first-title.yml"))
        #expect(repo.exists("_posts/\(Self.today)-better-title.md"))
        let pushed = try await Git(repo: origin).run(["show", "--name-status", "--format=%s", "master"])
        #expect(pushed.contains("EDIT: Better"))
        #expect(pushed.contains("D\t_data/first-title.yml"))
        #expect(pushed.contains("R100\t\(path)") || pushed.contains("D\t\(path)"))
    }

    @Test func draftsKeepAudioOutOfTheSiteUntilPublished() async throws {
        let (sandbox, blog, _) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = BlogRepo(root: blog)
        let song = sandbox.appending(path: "wip.wav")
        try makeSine(seconds: 0.5, at: song)

        var draft = PostDraft()
        draft.title = "Work in progress"
        draft.blocks = [Block(.audio(AudioPlaylist(tracks: [AudioTrack(source: song)])))]
        var builder = builder(draft, repo)
        builder.target = .draft
        await Publisher().publish(try builder.build(), to: repo, message: "DRAFT", push: false)
        #expect(repo.exists("_drafts/work-in-progress.md"))
        #expect(repo.exists("art/drafts/wip.m4a"))
        #expect(!repo.exists("art/music/wip.m4a"))
        #expect(PostParser.posts(in: "_drafts", of: repo).map(\.title) == ["Work in progress"])

        let reopened = PostParser.parse(path: "_drafts/work-in-progress.md", text: try String(contentsOf: repo.url("_drafts/work-in-progress.md"), encoding: .utf8), repo: repo)
        let plan = try self.builder(reopened, repo).build()
        #expect(plan.audio.map(\.path) == ["art/music/wip.m4a"])
        #expect(Set(plan.deletions) == ["_drafts/work-in-progress.md", "art/drafts/wip.m4a"])
        let publisher = Publisher()
        await publisher.publish(plan, to: repo, message: "POST", push: false)
        #expect(publisher.phase == .succeeded)
        #expect(repo.exists("art/music/wip.m4a"))
        #expect(!repo.exists("art/drafts/wip.m4a"))
        #expect(!repo.exists("_drafts/work-in-progress.md"))
        #expect(try String(contentsOf: repo.url("_data/work-in-progress.yml"), encoding: .utf8).contains("src: /art/music/wip.m4a"))
    }

    @Test func deletingAPostRemovesItsFilesButKeepsSharedMedia() async throws {
        let (sandbox, blog, origin) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let repo = BlogRepo(root: blog)
        let photo = sandbox.appending(path: "dog.png")
        try makeImage(width: 200, height: 100, opaque: true, at: photo, type: .png)
        let song = sandbox.appending(path: "song.wav")
        try makeSine(seconds: 0.5, at: song)

        var draft = PostDraft()
        draft.title = "Doomed"
        draft.blocks = [Block(.image(ImageItem(source: photo))), Block(.audio(AudioPlaylist(tracks: [AudioTrack(source: song)])))]
        await Publisher().publish(try builder(draft, repo).build(), to: repo, message: "POST", push: true)
        // Another post shares the image.
        try "---\ntitle: Other\n---\n![]({{ site.baseurl }}/images/doomed/dog.png)\n".write(to: repo.url("_posts/2026-01-02-other.md"), atomically: true, encoding: .utf8)

        let path = "_posts/\(Self.today)-doomed.md"
        let plan = try DeletionPlan.make(for: path, in: repo)
        #expect(plan.dataFiles == ["_data/doomed.yml"])
        #expect(plan.media == ["art/music/song.m4a"])
        #expect(plan.sharedMedia == ["images/doomed/dog.png"])

        let publisher = Publisher()
        await publisher.delete(plan.paths(includingMedia: true), from: repo, message: "DELETE: Doomed", push: true)
        #expect(publisher.phase == .succeeded)
        #expect(!repo.exists(path))
        #expect(!repo.exists("_data/doomed.yml"))
        #expect(!repo.exists("art/music/song.m4a"))
        #expect(repo.exists("images/doomed/dog.png"))
        let pushed = try await Git(repo: origin).run(["show", "--name-status", "--format=%s", "master"])
        #expect(pushed.split(separator: "\n").filter { $0.hasPrefix("D\t") }.count == 3)
    }

    @Test func failedEditPutsTheOriginalBack() async throws {
        let sandbox = URL.temporaryDirectory.appending(path: "pasteruperer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox.appending(path: "_posts"), withIntermediateDirectories: true)
        try "title: Test\n".write(to: sandbox.appending(path: "_config.yml"), atomically: true, encoding: .utf8)
        let original = "---\ntitle: \"Old\"\n---\n\nOriginal text.\n"
        try original.write(to: sandbox.appending(path: "_posts/2026-01-01-old.md"), atomically: true, encoding: .utf8)
        let repo = BlogRepo(root: sandbox)

        var draft = PostParser.parse(path: "_posts/2026-01-01-old.md", text: original, repo: repo)
        draft.title = "New"
        let plan = try PostBuilder(draft: draft, siteTimeZone: .gmt, exists: repo.exists, repoRoot: repo.root).build()
        // Not a git repo, so committing fails after the files have been changed.
        let publisher = Publisher()
        await publisher.publish(plan, to: repo, message: "x", push: false)
        #expect(publisher.phase == .failed(committed: false))
        #expect(try String(contentsOf: repo.url("_posts/2026-01-01-old.md"), encoding: .utf8) == original)
        #expect(!repo.exists("_posts/2026-01-01-new.md"))
    }

    // MARK: Helpers

    private static var today: String { PostBuilder.format(Date(), "yyyy-MM-dd", .current) }

    private func builder(_ draft: PostDraft, _ repo: BlogRepo) -> PostBuilder {
        PostBuilder(draft: draft, siteTimeZone: repo.siteTimeZone(), exists: repo.exists, repoRoot: repo.root)
    }

    /// A blog checkout with a local bare "origin" to push to.
    private func makeRepo() async throws -> (sandbox: URL, blog: URL, origin: URL) {
        let sandbox = URL.temporaryDirectory.appending(path: "pasteruperer-\(UUID().uuidString)")
        let origin = sandbox.appending(path: "origin.git")
        let blog = sandbox.appending(path: "blog")
        try FileManager.default.createDirectory(at: blog.appending(path: "_posts"), withIntermediateDirectories: true)
        let git = Git(repo: blog)
        try await Git(repo: sandbox).run(["init", "-q", "--bare", "-b", "master", origin.path])
        try await git.run(["init", "-q", "-b", "master"])
        try await git.run(["config", "user.email", "test@example.com"])
        try await git.run(["config", "user.name", "Test"])
        try "title: Test\n".write(to: blog.appending(path: "_config.yml"), atomically: true, encoding: .utf8)
        try await git.run(["add", "."])
        try await git.run(["commit", "-q", "-m", "init"])
        try await git.run(["remote", "add", "origin", origin.path])
        try await git.run(["push", "-q", "-u", "origin", "master"])
        return (sandbox, blog, origin)
    }

    private func makeImage(width: Int, height: Int, opaque: Bool, at url: URL, type: UTType) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func makeSine(seconds: Double, at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100) * 0.3) }
        try file.write(from: buffer)
    }
}
