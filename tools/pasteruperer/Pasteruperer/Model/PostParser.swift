import Foundation

/// A post or Jekyll draft file in the repo.
struct RepoPost: Identifiable, Hashable, Sendable {
    /// Repo-relative, e.g. "_posts/2026-04-23-get-a-dog.md".
    var path: String
    var title: String
    var date: Date?

    var id: String { path }
    var isJekyllDraft: Bool { path.hasPrefix("_drafts/") }
}

/// Reads posts written by hand or by this app back into editable drafts.
enum PostParser {
    // MARK: Listing

    static func posts(in folder: String, of repo: BlogRepo) -> [RepoPost] {
        let directory = repo.url(folder)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var posts: [RepoPost] = []
        for file in files where ["md", "markdown"].contains(file.pathExtension.lowercased()) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let path = "\(folder)/\(file.lastPathComponent)"
            let header = header(of: text)
            posts.append(RepoPost(path: path, title: header.title ?? slug(fromPath: path), date: header.date ?? filenameDate(path)))
        }
        return posts.sorted { first, second in
            let firstDate = first.date ?? .distantPast
            let secondDate = second.date ?? .distantPast
            return firstDate == secondDate ? first.path > second.path : firstDate > secondDate
        }
    }

    // MARK: Parsing

    static func parse(path: String, text: String, repo: BlogRepo) -> PostDraft {
        var draft = PostDraft()
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var bodyLines = lines

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let frontMatter = Array(lines[1..<end])
            bodyLines = Array(lines[(end + 1)...])
            readFrontMatter(frontMatter, into: &draft)
        }
        if draft.title.isEmpty { draft.title = slug(fromPath: path).replacingOccurrences(of: "-", with: " ") }
        if !lines.contains(where: { $0.hasPrefix("date:") }), let date = filenameDate(path) { draft.date = date }

        let slug = slug(fromPath: path)
        draft.customSlug = slug == draft.autoSlug ? "" : slug

        var blocks: [Block] = []
        var dataKeys: [String] = []
        var buffer: [String] = []
        func flush() {
            let text = PostBuilder.trimmed(buffer.joined(separator: "\n"))
            if !text.isEmpty { blocks.append(Block(.text(text))) }
            buffer = []
        }
        for line in bodyLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let image = image(in: trimmed, repo: repo) {
                flush()
                blocks.append(Block(.image(image)))
            } else if let playlist = playlist(in: trimmed, repo: repo) {
                flush()
                blocks.append(Block(.audio(playlist)))
                if let key = playlist.dataKey { dataKeys.append(key) }
            } else {
                buffer.append(line)
            }
        }
        flush()
        // Somewhere to carry on writing.
        if blocks.last.map({ if case .text = $0.content { false } else { true } }) ?? true {
            blocks.append(Block(.text("")))
        }

        draft.blocks = blocks
        draft.origin = PostOrigin(path: path, dataKeys: dataKeys)
        return draft
    }

    private static func readFrontMatter(_ lines: [String], into draft: inout PostDraft) {
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            // Indented lines and list items belong to the key above them.
            var continuation: [String] = []
            while index < lines.count, let first = lines[index].first, first == " " || first == "\t" || first == "-" {
                continuation.append(lines[index])
                index += 1
            }
            guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { draft.extraFrontMatter += [line] + continuation }
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "layout" where scalar(value) == "post":
                break
            case "title":
                draft.title = scalar(value)
            case "date":
                if let date = date(from: scalar(value)) {
                    draft.date = date
                    draft.timeZoneOffset = offset(in: scalar(value))
                } else {
                    draft.extraFrontMatter += [line] + continuation
                }
            case "categories", "category":
                draft.categories += BlogRepo.categories(inPost: (["---", line] + continuation + ["---"]).joined(separator: "\n"))
            default:
                draft.extraFrontMatter += [line] + continuation
            }
        }
    }

    /// Title and date only, for listing.
    private static func header(of text: String) -> (title: String?, date: Date?) {
        var title: String?
        var date: Date?
        for line in BlogRepo.frontMatter(of: text) {
            if line.hasPrefix("title:") { title = scalar(String(line.dropFirst(6))) }
            if line.hasPrefix("date:") { date = Self.date(from: scalar(String(line.dropFirst(5)))) }
        }
        return (title, date)
    }

    // MARK: Blocks

    /// `![alt]({{ site.baseurl }}/images/x.jpeg){: style="width: 50%"}` pointing at a file in the repo.
    static func image(in line: String, repo: BlogRepo) -> ImageItem? {
        let pattern = #/^!\[((?:[^\]\\]|\\.)*)\]\((?:\{\{\s*site\.baseurl\s*\}\})?([^)\s]+)\)(?:\{:\s*style="width:\s*(\d+)%;?"\s*\})?$/#
        guard let match = line.wholeMatch(of: pattern) else { return nil }
        let rawPath = String(match.2)
        guard !rawPath.contains("://") else { return nil }
        let path = (rawPath.removingPercentEncoding ?? rawPath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard repo.exists(path) else { return nil }

        let source = repo.url(path)
        var image = ImageItem(source: source)
        image.alt = String(match.1).replacingOccurrences(of: "\\[", with: "[").replacingOccurrences(of: "\\]", with: "]")
        image.displayPercent = match.3.flatMap { Int($0) } ?? 100
        // Matching the file's own width means "unchanged", so it's linked in place rather than re-exported.
        image.maxWidth = ImageProcessing.uprightPixelSize(of: source).map { Int($0.width) } ?? image.maxWidth
        return image
    }

    /// `{% include music-player.html tracks=site.data.<key> label=… %}` with its `_data/<key>.yml`.
    static func playlist(in line: String, repo: BlogRepo) -> AudioPlaylist? {
        guard let include = line.wholeMatch(of: #/^\{%-?\s*include\s+music-player\.html\s+(.*?)\s*-?%\}$/#) else { return nil }
        let arguments = String(include.1)
        guard let tracks = arguments.firstMatch(of: #/tracks=site\.data\.([\w-]+)/#) else { return nil }
        let key = String(tracks.1)
        guard let yaml = try? String(contentsOf: repo.url("_data/\(key).yml"), encoding: .utf8) else { return nil }

        var label = ""
        if let match = arguments.firstMatch(of: #/label="((?:[^"\\]|\\.)*)"/#) {
            label = String(match.1).replacingOccurrences(of: "\\\"", with: "\"")
        } else if let match = arguments.firstMatch(of: #/label='([^']*)'/#) {
            label = String(match.1)
        }

        let tracksList = playlistEntries(yaml).compactMap { entry -> AudioTrack? in
            guard let src = entry["src"] else { return nil }
            let path = src.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let url = repo.url(path)
            return AudioTrack(source: url, title: entry["title"] ?? url.deletingPathExtension().lastPathComponent)
        }
        return AudioPlaylist(label: label, tracks: tracksList, dataKey: key)
    }

    /// The `- title: …\n  src: …` entries of a playlist data file.
    static func playlistEntries(_ yaml: String) -> [[String: String]] {
        var entries: [[String: String]] = []
        for line in yaml.components(separatedBy: .newlines) {
            var content = line.trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("- ") {
                entries.append([:])
                content.removeFirst(2)
            }
            guard !entries.isEmpty, let colon = content.firstIndex(of: ":") else { continue }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            entries[entries.count - 1][key] = scalar(String(content[content.index(after: colon)...]))
        }
        return entries
    }

    // MARK: Values

    /// A YAML scalar: double-quoted (with escapes), single-quoted, or plain.
    static func scalar(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var result = ""
            var escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let comment = value.range(of: " #") { return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return value
    }

    static func date(from value: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mm Z", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// Seconds from GMT for a date ending in "+1000", "+10:00", "Z" and so on.
    static func offset(in value: String) -> Int? {
        if value.hasSuffix("Z") { return 0 }
        guard let match = value.firstMatch(of: #/([+-])(\d{2}):?(\d{2})$/#),
              let hours = Int(match.2), let minutes = Int(match.3) else { return nil }
        return (match.1 == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// "_posts/2026-04-23-get-a-dog.md" → "get-a-dog"; "_drafts/ideas.md" → "ideas".
    static func slug(fromPath path: String) -> String {
        let name = URL(filePath: path).deletingPathExtension().lastPathComponent
        guard path.hasPrefix("_posts/"), let match = name.firstMatch(of: #/^\d{4}-\d{2}-\d{2}-/#) else { return name }
        return String(name[match.range.upperBound...])
    }

    static func filenameDate(_ path: String) -> Date? {
        let name = URL(filePath: path).lastPathComponent
        guard let match = name.firstMatch(of: #/^\d{4}-\d{2}-\d{2}/#) else { return nil }
        return date(from: String(match.0))
    }
}

/// What deleting a post removes.
struct DeletionPlan: Sendable {
    var title: String
    var postPath: String
    /// The post's playlist files.
    var dataFiles: [String]
    /// Images and audio no other post or playlist refers to.
    var media: [String]
    /// Media the post uses that something else also uses, so it stays.
    var sharedMedia: [String]

    func paths(includingMedia: Bool) -> [String] {
        [postPath] + dataFiles + (includingMedia ? media : [])
    }

    static func make(for path: String, in repo: BlogRepo) throws -> DeletionPlan {
        let text = try String(contentsOf: repo.url(path), encoding: .utf8)
        let draft = PostParser.parse(path: path, text: text, repo: repo)
        let dataFiles = (draft.origin?.dataKeys ?? []).map { "_data/\($0).yml" }.filter(repo.exists)

        var media: [String] = []
        for source in draft.sourceFiles {
            guard let relative = PostBuilder.relativePath(of: source, in: repo.root),
                  repo.exists(relative), !media.contains(relative) else { continue }
            media.append(relative)
        }

        // Everything else that could refer to a media file.
        var others: [String] = []
        for folder in ["_posts", "_drafts", "_data", "_includes", "_layouts"] {
            let files = (try? FileManager.default.contentsOfDirectory(at: repo.url(folder), includingPropertiesForKeys: nil)) ?? []
            for file in files where "\(folder)/\(file.lastPathComponent)" != path && !dataFiles.contains("\(folder)/\(file.lastPathComponent)") {
                if let contents = try? String(contentsOf: file, encoding: .utf8) { others.append(contents) }
            }
        }
        for page in (try? FileManager.default.contentsOfDirectory(at: repo.root, includingPropertiesForKeys: nil)) ?? []
        where ["md", "markdown", "html"].contains(page.pathExtension.lowercased()) {
            if let contents = try? String(contentsOf: page, encoding: .utf8) { others.append(contents) }
        }

        let shared = media.filter { file in others.contains { $0.contains(file) } }
        return DeletionPlan(
            title: draft.displayTitle,
            postPath: path,
            dataFiles: dataFiles,
            media: media.filter { !shared.contains($0) },
            sharedMedia: shared
        )
    }
}
