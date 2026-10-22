import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// A post being written or edited. Every draft autosaves, so nothing is lost between launches.
struct PostDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var modified = Date()
    /// Set when this draft edits a post or `_drafts` file that's already in the repo.
    var origin: PostOrigin?
    var title = ""
    /// Empty means "derive from the title".
    var customSlug = ""
    var date = Date()
    /// The UTC offset an existing post's date was written with, kept so editing doesn't rewrite it.
    var timeZoneOffset: Int?
    /// In selection order — Jekyll uses this order for the post's URL.
    var categories: [String] = []
    /// Front matter lines this app doesn't edit (e.g. `tags:`), kept as they were.
    var extraFrontMatter: [String] = []
    var blocks: [Block] = [Block(.text(""))]

    init() {}

    init(from decoder: Decoder) throws {
        // Every field is optional so drafts saved by older versions still load.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        modified = try container.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        origin = try container.decodeIfPresent(PostOrigin.self, forKey: .origin)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        customSlug = try container.decodeIfPresent(String.self, forKey: .customSlug) ?? ""
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        timeZoneOffset = try container.decodeIfPresent(Int.self, forKey: .timeZoneOffset)
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        extraFrontMatter = try container.decodeIfPresent([String].self, forKey: .extraFrontMatter) ?? []
        blocks = try container.decodeIfPresent([Block].self, forKey: .blocks) ?? [Block(.text(""))]
    }

    var autoSlug: String { Slug.make(title) }

    var effectiveSlug: String {
        customSlug.isEmpty ? autoSlug : Slug.make(customSlug, keeping: ["_"])
    }

    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    var isEmpty: Bool {
        origin == nil && title.isEmpty && categories.isEmpty && blocks.allSatisfy { $0.content == .text("") }
    }

    private static let nullID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The draft with identity and timestamps blanked out, for comparing content.
    var contentSignature: PostDraft {
        var copy = self
        copy.id = PostDraft.nullID
        copy.modified = .distantPast
        copy.origin?.dataKeys = []
        copy.blocks = blocks.map { block in
            var block = block
            block.id = PostDraft.nullID
            if case .audio(var playlist) = block.content {
                playlist.tracks = playlist.tracks.map { track in
                    var track = track
                    track.id = PostDraft.nullID
                    return track
                }
                block.content = .audio(playlist)
            }
            return block
        }
        return copy
    }

    /// Every file this draft points at, for tidying up pasted media.
    var sourceFiles: [URL] {
        blocks.flatMap { block -> [URL] in
            switch block.content {
            case .text: []
            case .image(let image): [image.source]
            case .audio(let playlist): playlist.tracks.map(\.source)
            }
        }
    }
}

/// The repo file a draft was opened from.
struct PostOrigin: Codable, Equatable, Hashable {
    /// Repo-relative, e.g. "_posts/2026-04-23-get-a-dog.md" or "_drafts/ideas.md".
    var path: String
    /// `_data` playlists the post used, so ones that are removed can be deleted.
    var dataKeys: [String] = []

    var isJekyllDraft: Bool { path.hasPrefix("_drafts/") }
}

/// Where a draft is committed to.
enum PostTarget: String, Codable, CaseIterable, Identifiable {
    /// `_posts/`, live on the site.
    case post
    /// `_drafts/`, committed but not published.
    case draft

    var id: Self { self }
}

struct Block: Codable, Equatable, Identifiable {
    var id = UUID()
    var content: Content

    init(_ content: Content) {
        self.content = content
    }

    enum Content: Codable, Equatable {
        case text(String)
        case image(ImageItem)
        case audio(AudioPlaylist)
    }

    // Typed accessors for bindings. Setters ignore writes of the wrong kind, which keeps a stale
    // binding (e.g. during a deletion animation) from turning a block into something else.

    var text: String {
        get { if case .text(let text) = content { text } else { "" } }
        set { if case .text = content { content = .text(newValue) } }
    }

    var image: ImageItem {
        get { if case .image(let image) = content { image } else { ImageItem(source: URL(filePath: "/")) } }
        set { if case .image = content { content = .image(newValue) } }
    }

    var audio: AudioPlaylist {
        get { if case .audio(let audio) = content { audio } else { AudioPlaylist() } }
        set { if case .audio = content { content = .audio(newValue) } }
    }
}

struct ImageItem: Codable, Equatable {
    var source: URL
    var alt = ""
    /// Normalised (0...1) crop rectangle, top-left origin, in the image's upright orientation.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var aspect: CropAspect = .free
    /// Exported images are scaled down to at most this many pixels wide (never up).
    var maxWidth = 1600
    /// How wide the image is shown in the post, as a percentage of the text column.
    var displayPercent = 100
    var quality = 0.82

    var outputFormat: ImageOutputFormat { ImageOutputFormat(source: source) }

    var isFullFrame: Bool {
        crop.minX <= 0.0001 && crop.minY <= 0.0001 && crop.width >= 0.9999 && crop.height >= 0.9999
    }

    /// Pixel size of the exported file for a source of the given (upright) pixel size.
    func outputSize(sourceSize: CGSize) -> CGSize {
        let cropWidth = max(1, (crop.width * sourceSize.width).rounded())
        let cropHeight = max(1, (crop.height * sourceSize.height).rounded())
        let width = min(CGFloat(maxWidth), cropWidth)
        return CGSize(width: width, height: max(1, (cropHeight * width / cropWidth).rounded()))
    }
}

enum ImageOutputFormat: String, Codable, Sendable {
    case jpeg, png

    /// PNGs stay PNGs (they may have transparency); everything else, including HEIC, becomes JPEG.
    init(source: URL) {
        let type = UTType(filenameExtension: source.pathExtension)
        self = type?.conforms(to: .png) == true ? .png : .jpeg
    }

    var fileExtension: String { rawValue }
    var typeIdentifier: String { self == .png ? UTType.png.identifier : UTType.jpeg.identifier }
    var label: String { self == .png ? "PNG" : "JPEG" }
}

enum CropAspect: String, Codable, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeFour, threeTwo, twoThree, sixteenNine, nineSixteen

    var id: Self { self }

    var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeFour: "3:4"
        case .threeTwo: "3:2"
        case .twoThree: "2:3"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }

    /// Width / height in pixels, or nil for a free crop.
    func ratio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: imageSize.width / imageSize.height
        case .square: 1
        case .fourThree: 4 / 3
        case .threeFour: 3 / 4
        case .threeTwo: 3 / 2
        case .twoThree: 2 / 3
        case .sixteenNine: 16 / 9
        case .nineSixteen: 9 / 16
        }
    }
}

struct AudioPlaylist: Codable, Equatable {
    /// Shown as the player's label; empty uses the post title.
    var label = ""
    var tracks: [AudioTrack] = []
    /// The `_data` file this playlist was loaded from, which is updated in place.
    var dataKey: String?

    init(label: String = "", tracks: [AudioTrack] = [], dataKey: String? = nil) {
        self.label = label
        self.tracks = tracks
        self.dataKey = dataKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        tracks = try container.decodeIfPresent([AudioTrack].self, forKey: .tracks) ?? []
        dataKey = try container.decodeIfPresent(String.self, forKey: .dataKey)
    }
}

struct AudioTrack: Codable, Equatable, Identifiable {
    var id = UUID()
    var source: URL
    var title: String

    init(source: URL, title: String) {
        self.source = source
        self.title = title
    }

    init(source: URL) {
        self.source = source
        self.title = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    /// Non-m4a files are converted so the site's random mini player picks them up.
    var needsConversion: Bool { source.pathExtension.lowercased() != "m4a" }
}

extension URL {
    var isImageFile: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .image) == true }
    var isAudioFile: Bool { UTType(filenameExtension: pathExtension)?.conforms(to: .audio) == true }
}
