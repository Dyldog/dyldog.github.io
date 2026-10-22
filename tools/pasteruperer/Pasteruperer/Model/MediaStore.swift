import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreTransferable

/// Keeps pasted and Photos images on disk (drafts refer to files by URL) until no draft needs them.
enum MediaStore {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Pasteruperer/Media")
    }

    /// A fresh location that keeps the original file name, e.g. Media/<uuid>/IMG_1234.HEIC.
    static func newURL(named name: String) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: name)
    }

    /// Deletes stored media that none of `drafts` refer to.
    static func removeUnused(keeping drafts: [PostDraft]) {
        let used = Set(drafts.flatMap(\.sourceFiles).map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !used.contains(folder.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Clipboard

    /// Images or audio on the pasteboard: copied files, or image data (e.g. a screenshot or "Copy Image").
    /// Returns nil when the pasteboard holds ordinary text, which should be pasted as text.
    @MainActor
    static func media(from pasteboard: NSPasteboard) -> [URL]? {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let media = files.filter { $0.isImageFile || $0.isAudioFile }
        if !media.isEmpty { return media }
        if !files.isEmpty { return nil }

        // Apps that copy text often add a picture of it too, so text wins unless it's just a link.
        if let string = pasteboard.string(forType: .string), URL.webURL(from: string) == nil { return nil }

        let types: [(NSPasteboard.PasteboardType, UTType)] = [
            (NSPasteboard.PasteboardType(UTType.jpeg.identifier), .jpeg),
            (NSPasteboard.PasteboardType(UTType.heic.identifier), .heic),
            (.png, .png),
            (.tiff, .tiff),
        ]
        for (pasteboardType, type) in types {
            guard let data = pasteboard.data(forType: pasteboardType),
                  let ext = type.preferredFilenameExtension else { continue }
            let name = "pasted-\(PostBuilder.format(Date(), "yyyyMMdd-HHmmss", .current)).\(ext)"
            guard let url = try? newURL(named: name), (try? data.write(to: url)) != nil else { return nil }
            return [url]
        }
        return nil
    }
}

/// An image picked from Photos, copied into the media store with its original name.
struct PickedImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = try MediaStore.newURL(named: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedImage(url: url)
        }
    }
}

extension URL {
    /// An http(s) URL if the string is nothing but one.
    static func webURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return nil }
        return url
    }
}
