import Foundation

/// A Jekyll blog checkout on disk.
struct BlogRepo: Sendable, Equatable {
    let root: URL

    static func isBlog(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.appending(path: "_config.yml").path)
            && manager.fileExists(atPath: url.appending(path: "_posts").path)
    }

    /// The blog this app's source lives in (two folders above the project), found at build time.
    static func defaultLocation() -> URL? {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.pathComponents.count > 1 {
            if isBlog(url) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    var displayName: String { root.lastPathComponent }

    // MARK: Site config

    /// Simple top-level `key: value` pairs from `_config.yml`.
    func config() -> [String: String] {
        guard let text = try? String(contentsOf: url("_config.yml"), encoding: .utf8) else { return [:] }
        return Self.topLevelValues(in: text)
    }

    static func topLevelValues(in yaml: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in yaml.components(separatedBy: .newlines) {
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...])
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            values[key] = unquote(value)
        }
        return values
    }

    /// Jekyll builds post URLs in the site's `timezone`. GitHub Pages builds in UTC when none is set.
    func siteTimeZone() -> TimeZone {
        config()["timezone"].flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
    }

    /// e.g. "https://dyldog.github.io"
    func siteURL() -> String? {
        let config = config()
        guard let url = config["url"], !url.isEmpty else { return nil }
        let base = config["baseurl"] ?? ""
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + base
    }

    // MARK: Categories

    func existingCategories() -> [String] {
        let postsURL = url("_posts")
        let files = (try? FileManager.default.contentsOfDirectory(at: postsURL, includingPropertiesForKeys: nil)) ?? []
        var categories = Set<String>()
        for file in files where ["md", "markdown", "html"].contains(file.pathExtension.lowercased()) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            categories.formUnion(Self.categories(inPost: text))
        }
        return categories.sorted()
    }

    static func categories(inPost text: String) -> [String] {
        let lines = frontMatter(of: text)
        var result: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let value = value(of: line, forKeys: ["categories", "category"]) else { continue }
            if value.isEmpty {
                // Block-style YAML list.
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard item.hasPrefix("-") else { break }
                    result.append(unquote(String(item.dropFirst())))
                    index += 1
                }
            } else if value.hasPrefix("[") {
                result += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { unquote(String($0)) }
            } else {
                result += unquote(value).split(whereSeparator: \.isWhitespace).map(String.init)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    static func frontMatter(of text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        let rest = lines.dropFirst()
        guard let end = rest.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return [] }
        return Array(rest[..<end])
    }

    private static func value(of line: String, forKeys keys: [String]) -> String? {
        for key in keys where line.hasPrefix(key + ":") {
            return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
