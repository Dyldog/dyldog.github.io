import Foundation
import CoreGraphics

struct TextFile: Sendable, Equatable {
    var path: String
    var contents: String
}

struct ImageJob: Sendable, Equatable {
    var source: URL
    var path: String
    var crop: CGRect
    var maxWidth: Int
    var quality: Double
    var format: ImageOutputFormat
}

struct AudioJob: Sendable, Equatable {
    var source: URL
    var path: String
}

/// Everything that committing a draft changes in the repo. All paths are relative to the repo root.
struct PostPlan: Sendable {
    var title: String
    var target: PostTarget
    var post: TextFile
    var dataFiles: [TextFile]
    var images: [ImageJob]
    var audio: [AudioJob]
    /// Files to remove: the old post file after a rename, playlists that were removed, and audio moved
    /// out of `art/drafts`.
    var deletions: [String]
    /// Existing files this plan deliberately replaces (an edited post and its playlists).
    var overwrites: Set<String>
    /// Site-relative URL of the published post, e.g. "/art/music/2026/10/21/sexys-back.html".
    var postURL: String

    var writtenPaths: [String] { [post.path] + dataFiles.map(\.path) + images.map(\.path) + audio.map(\.path) }
    var paths: [String] { writtenPaths + deletions }
}

struct PlanError: LocalizedError {
    var problems: [String]
    var errorDescription: String? { problems.joined(separator: "\n") }
}

/// Turns a draft into the same files the blog's hand-written posts use:
/// `_posts/<date>-<slug>.md` (or `_drafts/<slug>.md`), images under `images/<slug>/`, audio under
/// `art/music/` (`art/drafts/` for drafts, so the site's random player doesn't pick it up), and a
/// `_data/<key>.yml` playlist per audio block rendered by `_includes/music-player.html`.
struct PostBuilder {
    var draft: PostDraft
    var target: PostTarget = .post
    var siteTimeZone: TimeZone
    var localTimeZone: TimeZone = .current
    /// Whether a repo-relative path already exists.
    var exists: (String) -> Bool
    /// The blog checkout, so files already inside it can be referenced instead of copied.
    var repoRoot: URL?
    var sourceExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    var pixelSize: (URL) -> CGSize? = { ImageProcessing.uprightPixelSize(of: $0) }

    static let publishedAudioDirectory = "art/music"
    static let draftAudioDirectory = "art/drafts"

    var slug: String { draft.effectiveSlug }

    /// Where the date is written: the post's original offset when editing, otherwise this Mac's zone.
    private var writtenTimeZone: TimeZone {
        draft.timeZoneOffset.flatMap(TimeZone.init(secondsFromGMT:)) ?? localTimeZone
    }

    var postPath: String {
        switch target {
        case .post: "_posts/\(Self.format(draft.date, "yyyy-MM-dd", writtenTimeZone))-\(slug).md"
        case .draft: "_drafts/\(slug).md"
        }
    }

    private var audioDirectory: String { target == .post ? Self.publishedAudioDirectory : Self.draftAudioDirectory }

    var postURL: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = siteTimeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: draft.date)
        var seen = Set<String>()
        let categories = draft.categories.map { $0.lowercased() }.filter { seen.insert($0).inserted }
        let date = [String(format: "%04d", parts.year ?? 0), String(format: "%02d", parts.month ?? 0), String(format: "%02d", parts.day ?? 0)]
        return "/" + (categories + date + ["\(slug).html"]).joined(separator: "/")
    }

    func repoRelativePath(of url: URL) -> String? {
        guard let repoRoot else { return nil }
        return Self.relativePath(of: url, in: repoRoot)
    }

    static func relativePath(of url: URL, in root: URL) -> String? {
        let root = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
    }

    func problems() -> [String] {
        var problems: [String] = []
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("Give the post a title.") }
        if slug.isEmpty {
            problems.append("The post needs a slug (letters or numbers) for its file name and URL.")
        } else if exists(postPath) && postPath.lowercased() != draft.origin?.path.lowercased() {
            problems.append("\(postPath) already exists. Change the slug or the date.")
        }

        let hasContent = draft.blocks.contains { block in
            if case .text(let text) = block.content { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } else { true }
        }
        if !hasContent { problems.append("The post is empty.") }

        for block in draft.blocks {
            switch block.content {
            case .text:
                break
            case .image(let image):
                if !sourceExists(image.source) { problems.append("Can't find the image \(image.source.path).") }
            case .audio(let playlist):
                if playlist.tracks.isEmpty { problems.append("An audio block has no tracks.") }
                for track in playlist.tracks {
                    if !sourceExists(track.source) { problems.append("Can't find the audio file \(track.source.path).") }
                    if track.title.trimmingCharacters(in: .whitespaces).isEmpty {
                        problems.append("Every track needs a title (\(track.source.lastPathComponent) doesn't have one).")
                    }
                }
            }
        }
        return problems
    }

    /// Things worth knowing that don't stop the post.
    func warnings(now: Date = Date()) -> [String] {
        var warnings: [String] = []
        if target == .post && draft.date > now {
            warnings.append("The date is in the future. GitHub Pages skips future posts, so it won't appear until the site is rebuilt after that time.")
        }
        let missingAlt = draft.blocks.filter { block in
            if case .image(let image) = block.content { image.alt.trimmingCharacters(in: .whitespaces).isEmpty } else { false }
        }.count
        if missingAlt > 0 {
            warnings.append(missingAlt == 1 ? "An image has no alt text." : "\(missingAlt) images have no alt text.")
        }
        return warnings
    }

    /// - Parameter validate: false for previews, which render whatever is there.
    func build(validate: Bool = true) throws -> PostPlan {
        if validate {
            let problems = problems()
            guard problems.isEmpty else { throw PlanError(problems: problems) }
        }

        let postPath = postPath
        var reserved: Set<String> = [postPath.lowercased()]
        var reservedKeys = Set<String>()
        var deletions: [String] = []
        var overwrites = Set<String>()

        if let origin = draft.origin {
            if origin.path.lowercased() == postPath.lowercased() {
                if exists(postPath) { overwrites.insert(postPath) }
            } else if exists(origin.path) {
                deletions.append(origin.path)
            }
        }

        func unique(_ directory: String, _ stem: String, _ ext: String, separator: String) -> String {
            var candidate = "\(directory)/\(stem).\(ext)"
            var number = 2
            while exists(candidate) || reserved.contains(candidate.lowercased()) {
                candidate = "\(directory)/\(stem)\(separator)\(number).\(ext)"
                number += 1
            }
            reserved.insert(candidate.lowercased())
            return candidate
        }
        func uniqueDataKey(_ base: String) -> String {
            var key = base
            var number = 2
            while ["yml", "yaml", "json", "csv", "tsv"].contains(where: { exists("_data/\(key).\($0)") }) || reservedKeys.contains(key) {
                key = "\(base)-\(number)"
                number += 1
            }
            reservedKeys.insert(key)
            return key
        }

        let postURL = postURL
        // `site.data.<key>` must be a plain Liquid identifier, so no leading digit.
        var dataKeyBase = Slug.make(slug)
        if dataKeyBase.isEmpty { dataKeyBase = "playlist" }
        if dataKeyBase.first?.isNumber == true { dataKeyBase = "post-" + dataKeyBase }

        var parts: [String] = []
        var images: [ImageJob] = []
        var audio: [AudioJob] = []
        var dataFiles: [TextFile] = []

        for block in draft.blocks {
            switch block.content {
            case .text(let text):
                let trimmed = Self.trimmed(text)
                if !trimmed.isEmpty { parts.append(trimmed) }

            case .image(let image):
                if let existing = reusablePath(for: image) {
                    parts.append(Self.imageMarkdown(alt: image.alt, path: existing, displayPercent: image.displayPercent))
                    continue
                }
                let format = image.outputFormat
                let stem = Slug.fileStem(image.source.deletingPathExtension().lastPathComponent)
                let path = unique("images/\(slug.isEmpty ? "untitled" : slug)", stem.isEmpty ? "image" : stem, format.fileExtension, separator: "-")
                images.append(ImageJob(source: image.source, path: path, crop: image.crop, maxWidth: image.maxWidth, quality: image.quality, format: format))
                parts.append(Self.imageMarkdown(alt: image.alt, path: path, displayPercent: image.displayPercent))

            case .audio(let playlist):
                let key: String
                if let existing = playlist.dataKey, !reservedKeys.contains(existing) {
                    key = existing
                    reservedKeys.insert(existing)
                    if exists("_data/\(key).yml") { overwrites.insert("_data/\(key).yml") }
                } else {
                    key = uniqueDataKey(dataKeyBase)
                }

                var entries: [(title: String, src: String)] = []
                for track in playlist.tracks {
                    let title = track.title.trimmingCharacters(in: .whitespaces)
                    if let existing = repoRelativePath(of: track.source), track.source.pathExtension.lowercased() == "m4a" {
                        if target == .post && existing.hasPrefix(Self.draftAudioDirectory + "/") {
                            // Publishing a draft: move its audio to where the site's players look.
                            let stem = Slug.make(track.source.deletingPathExtension().lastPathComponent, separator: "_")
                            let path = unique(Self.publishedAudioDirectory, stem.isEmpty ? "track" : stem, "m4a", separator: "_")
                            audio.append(AudioJob(source: track.source, path: path))
                            deletions.append(existing)
                            entries.append((title, "/" + path))
                        } else {
                            // Already in the repo (e.g. a playlist of older tracks): link it rather than copying it.
                            entries.append((title, "/" + existing))
                        }
                        continue
                    }
                    var stem = Slug.make(track.title, separator: "_")
                    if stem.isEmpty { stem = Slug.make(track.source.deletingPathExtension().lastPathComponent, separator: "_") }
                    let path = unique(audioDirectory, stem.isEmpty ? "track" : stem, "m4a", separator: "_")
                    audio.append(AudioJob(source: track.source, path: path))
                    entries.append((title, "/" + path))
                }
                dataFiles.append(TextFile(path: "_data/\(key).yml", contents: Self.playlistYAML(entries, postURL: postURL)))
                parts.append(Self.musicPlayerInclude(dataKey: key, label: playlist.label))
            }
        }

        // Playlists the edited post no longer uses.
        for key in draft.origin?.dataKeys ?? [] where !reservedKeys.contains(key) && exists("_data/\(key).yml") {
            deletions.append("_data/\(key).yml")
        }

        var seen = Set<String>()
        deletions = deletions.filter { seen.insert($0).inserted }

        let contents = frontMatter() + "\n" + parts.joined(separator: "\n\n") + "\n"
        return PostPlan(
            title: draft.title,
            target: target,
            post: TextFile(path: postPath, contents: contents),
            dataFiles: dataFiles,
            images: images,
            audio: audio,
            deletions: deletions,
            overwrites: overwrites,
            postURL: postURL
        )
    }

    /// An image that's already in the repo and hasn't been cropped or shrunk is linked where it is.
    private func reusablePath(for image: ImageItem) -> String? {
        guard image.isFullFrame,
              ["jpg", "jpeg", "png", "gif", "webp", "svg"].contains(image.source.pathExtension.lowercased()),
              let path = repoRelativePath(of: image.source) else { return nil }
        if let size = pixelSize(image.source), CGFloat(image.maxWidth) < size.width { return nil }
        return path
    }

    func frontMatter() -> String {
        var lines = ["---"]
        if !draft.extraFrontMatter.contains(where: { $0.hasPrefix("layout:") }) { lines.append("layout: post") }
        lines += [
            "title: \(Self.yamlString(draft.title.trimmingCharacters(in: .whitespacesAndNewlines)))",
            "date: \(Self.format(draft.date, "yyyy-MM-dd'T'HH:mm:ssZ", writtenTimeZone))",
        ]
        if !draft.categories.isEmpty { lines.append("categories: \(draft.categories.joined(separator: " "))") }
        lines += draft.extraFrontMatter
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Snippets

    static func imageMarkdown(alt: String, path: String, displayPercent: Int) -> String {
        let alt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        var markdown = "![\(alt)]({{ site.baseurl }}/\(path))"
        // kramdown attribute list; GitHub Pages renders it as an inline style on the <img>.
        if displayPercent < 100 { markdown += "{: style=\"width: \(displayPercent)%\"}" }
        return markdown
    }

    static func musicPlayerInclude(dataKey: String, label: String) -> String {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelArgument = label.isEmpty ? "page.title" : "\"\(label.replacingOccurrences(of: "\"", with: "\\\""))\""
        return "{% include music-player.html tracks=site.data.\(dataKey) label=\(labelArgument) %}"
    }

    static func playlistYAML(_ entries: [(title: String, src: String)], postURL: String) -> String {
        entries.map { entry in
            "- title: \(yamlString(entry.title))\n  src: \(entry.src)\n  post: \(postURL)\n"
        }.joined()
    }

    static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    /// Drops blank lines at the start and trailing whitespace at the end, keeping leading indentation.
    static func trimmed(_ text: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    static func format(_ date: Date, _ format: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
