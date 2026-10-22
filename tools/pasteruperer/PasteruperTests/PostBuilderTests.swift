import Foundation
import CoreGraphics
import Testing
@testable import Pasteruperer

struct PostBuilderTests {
    private let melbourne = TimeZone(identifier: "Australia/Melbourne")!
    private let utc = TimeZone(identifier: "UTC")!

    /// 2026-10-22T08:23:07+1100, the date of the "Sexy’s Back" post.
    private var sexysBackDate: Date {
        ISO8601DateFormatter().date(from: "2026-10-22T08:23:07+11:00")!
    }

    private func builder(_ draft: PostDraft, existing: Set<String> = []) -> PostBuilder {
        PostBuilder(draft: draft, siteTimeZone: utc, localTimeZone: melbourne, exists: { existing.contains($0) }, sourceExists: { _ in true })
    }

    @Test func slugsMatchExistingPosts() {
        #expect(Slug.make("Sexy’s Back") == "sexys-back")
        #expect(Slug.make("Some other jams") == "some-other-jams")
        #expect(Slug.make("get a dog") == "get-a-dog")
        #expect(Slug.make("  Café — Crème! ") == "cafe-creme")
        #expect(Slug.fileStem("IMG_5015") == "IMG_5015")
        #expect(Slug.fileStem("My Photo (1)") == "My-Photo-1")
    }

    @Test func textPostMatchesHandWrittenFormat() throws {
        var draft = PostDraft()
        draft.title = "Sexy’s Back"
        draft.date = sexysBackDate
        draft.categories = ["art", "music"]
        draft.blocks = [Block(.text("\n\nIt needs to be a bit faster.  \n\n"))]

        let plan = try builder(draft).build()
        #expect(plan.post.path == "_posts/2026-10-22-sexys-back.md")
        #expect(plan.post.contents == """
        ---
        layout: post
        title: "Sexy’s Back"
        date: 2026-10-22T08:23:07+1100
        categories: art music
        ---

        It needs to be a bit faster.

        """)
    }

    @Test func postURLUsesSiteTimeZone() {
        var draft = PostDraft()
        draft.title = "Sexy’s Back"
        draft.date = sexysBackDate
        draft.categories = ["art", "music"]
        // GitHub Pages builds in UTC, where this post is still on the 21st.
        #expect(builder(draft).postURL == "/art/music/2026/10/21/sexys-back.html")
    }

    @Test func imagesAndAudioBecomeFilesAndSnippets() throws {
        var draft = PostDraft()
        draft.title = "Jams & Dogs"
        draft.date = sexysBackDate
        draft.categories = ["music"]
        var small = ImageItem(source: URL(filePath: "/tmp/IMG_1.HEIC"))
        small.alt = "a [good] dog"
        small.displayPercent = 50
        draft.blocks = [
            Block(.image(ImageItem(source: URL(filePath: "/tmp/IMG_1.HEIC")))),
            Block(.image(small)),
            Block(.audio(AudioPlaylist(tracks: [AudioTrack(source: URL(filePath: "/tmp/no_idea.wav"))]))),
            Block(.audio(AudioPlaylist(label: "Say \"hi\"", tracks: [AudioTrack(source: URL(filePath: "/tmp/Whomp.m4a"))]))),
        ]

        let plan = try builder(draft, existing: ["art/music/no_idea.m4a", "_data/jams-dogs.yml"]).build()

        #expect(plan.images.map(\.path) == ["images/jams-dogs/IMG_1.jpeg", "images/jams-dogs/IMG_1-2.jpeg"])
        #expect(plan.audio.map(\.path) == ["art/music/no_idea_2.m4a", "art/music/whomp.m4a"])
        #expect(plan.dataFiles.map(\.path) == ["_data/jams-dogs-2.yml", "_data/jams-dogs-3.yml"])
        #expect(plan.dataFiles[0].contents == """
        - title: "No Idea"
          src: /art/music/no_idea_2.m4a
          post: /music/2026/10/21/jams-dogs.html

        """)
        #expect(plan.post.contents.hasSuffix("""
        ---

        ![]({{ site.baseurl }}/images/jams-dogs/IMG_1.jpeg)

        ![a \\[good\\] dog]({{ site.baseurl }}/images/jams-dogs/IMG_1-2.jpeg){: style="width: 50%"}

        {% include music-player.html tracks=site.data.jams-dogs-2 label=page.title %}

        {% include music-player.html tracks=site.data.jams-dogs-3 label="Say \\"hi\\"" %}

        """))
    }

    @Test func tracksAlreadyInTheRepoAreLinkedNotCopied() throws {
        var draft = PostDraft()
        draft.title = "Old jams"
        draft.date = sexysBackDate
        draft.blocks = [Block(.audio(AudioPlaylist(tracks: [
            AudioTrack(source: URL(filePath: "/blog/art/music/whomp.m4a")),
            AudioTrack(source: URL(filePath: "/elsewhere/whomp.m4a")),
        ])))]
        var builder = builder(draft, existing: ["art/music/whomp.m4a"])
        builder.repoRoot = URL(filePath: "/blog")
        let plan = try builder.build()
        #expect(plan.audio.map(\.path) == ["art/music/whomp_2.m4a"])
        #expect(plan.dataFiles[0].contents.contains("src: /art/music/whomp.m4a\n"))
        #expect(plan.dataFiles[0].contents.contains("src: /art/music/whomp_2.m4a\n"))
    }

    @Test func aspectCropIsCentredAndFits() {
        // A square crop of a 4000 × 2000 image is half the width, centred.
        let crop = CropMath.fitted(ratio: 1, around: CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: CGSize(width: 4000, height: 2000))
        #expect(crop == CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        // Centred on a crop near the edge, it's pushed back inside the image.
        let edge = CropMath.fitted(ratio: 1, around: CGRect(x: 0.9, y: 0, width: 0.1, height: 1), imageSize: CGSize(width: 4000, height: 2000))
        #expect(edge == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
    }

    @Test func reportsProblems() {
        var draft = PostDraft()
        draft.date = sexysBackDate
        draft.blocks = [Block(.audio(AudioPlaylist()))]
        let problems = builder(draft).problems()
        #expect(problems.contains("Give the post a title."))
        #expect(problems.contains("An audio block has no tracks."))

        draft.title = "hi"
        draft.blocks = [Block(.text("Hi."))]
        #expect(builder(draft, existing: ["_posts/2026-10-22-hi.md"]).problems() == ["_posts/2026-10-22-hi.md already exists. Change the slug or the date."])
    }

    @Test func readsCategoriesFromFrontMatter() {
        #expect(BlogRepo.categories(inPost: "---\nlayout: post\ncategories: advice isaac\n---\nbody") == ["advice", "isaac"])
        #expect(BlogRepo.categories(inPost: "---\ncategories: [art, \"music\"]\n---\n") == ["art", "music"])
        #expect(BlogRepo.categories(inPost: "---\ncategories:\n  - art\n  - music\ntitle: x\n---\n") == ["art", "music"])
        #expect(BlogRepo.categories(inPost: "no front matter\ncategories: nope") == [])
    }

    @Test func readsConfig() {
        let config = BlogRepo.topLevelValues(in: "title: Dylan\nurl: \"https://dyldog.github.io\" # site\ntheme_config:\n  date_format: x\n")
        #expect(config["url"] == "https://dyldog.github.io")
        #expect(config["date_format"] == nil)
    }

    @Test func outputSizeNeverUpscales() {
        var image = ImageItem(source: URL(filePath: "/tmp/a.jpg"))
        image.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        image.maxWidth = 1600
        #expect(image.outputSize(sourceSize: CGSize(width: 4000, height: 3000)) == CGSize(width: 1600, height: 1200))
        #expect(image.outputSize(sourceSize: CGSize(width: 1000, height: 800)) == CGSize(width: 500, height: 400))
    }
}
