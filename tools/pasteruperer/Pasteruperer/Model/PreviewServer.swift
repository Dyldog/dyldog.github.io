import Foundation
import Observation
import CryptoKit
import Darwin

/// Renders the current draft with the blog's own Jekyll setup.
///
/// The site is cloned (APFS clones, so it's instant and takes no space) into a cache folder, the
/// draft's files are written into the clone, and `jekyll serve` watches it. Edits to the draft are
/// written again, Jekyll regenerates, and the preview reloads. The real repo is never touched.
@MainActor
@Observable
final class PreviewServer {
    enum Status: Equatable {
        case idle, preparing, starting, building, ready
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var log = ""
    /// Set when the last build reported an error; cleared by the next good build.
    private(set) var buildError: String?
    private(set) var pageURL: URL?
    /// Bumped whenever Jekyll finishes a rebuild.
    private(set) var reloadToken = 0

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var repo: BlogRepo?
    @ObservationIgnored private var port = 0
    @ObservationIgnored private var pendingDraft: PostDraft?
    @ObservationIgnored private var isWriting = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// What the preview currently has in place of the repo's own files.
    @ObservationIgnored private var written: [String: String] = [:]
    @ObservationIgnored private var removed: Set<String> = []

    /// Every running Jekyll, so they can be stopped when the app quits.
    private static var processes: [ObjectIdentifier: Process] = [:]

    /// Fully resolved: GitHub Pages' safe mode rejects includes reached through a symlink (like /var → /private/var).
    @ObservationIgnored private let cacheDirectory: URL
    private var siteDirectory: URL { cacheDirectory.appending(path: "site") }
    private var mediaDirectory: URL { cacheDirectory.appending(path: "media") }

    init(cacheDirectory: URL = URL.cachesDirectory.appending(path: "Pasteruperer/Preview")) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Foundation's resolvingSymlinksInPath keeps /var rather than /private/var, so ask the kernel.
        if let resolved = realpath(cacheDirectory.path, nil) {
            self.cacheDirectory = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
            free(resolved)
        } else {
            self.cacheDirectory = cacheDirectory
        }
    }

    var isRunning: Bool { process != nil }

    // MARK: Lifecycle

    func start(repo: BlogRepo, draft: PostDraft) async {
        stop()
        self.repo = repo
        status = .preparing
        log = ""
        buildError = nil
        pageURL = nil
        written = [:]
        removed = []

        let site = siteDirectory
        do {
            try await Task.detached { try Self.cloneSite(from: repo.root, to: site) }.value
        } catch {
            status = .failed("Couldn't copy the site: \(error.localizedDescription)")
            return
        }
        port = Self.freePort()
        await write(draft)
        launch()
    }

    func stop() {
        debounce?.cancel()
        guard let process else { return }
        stopping = true
        process.terminate()
        Self.processes[ObjectIdentifier(self)] = nil
        self.process = nil
        status = .idle
    }

    static func stopAll() {
        for process in processes.values where process.isRunning { process.terminate() }
        processes = [:]
    }

    /// Writes the draft into the preview after a short pause in typing.
    func update(_ draft: PostDraft) {
        guard repo != nil, status != .idle else { return }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await write(draft)
        }
    }

    // MARK: Site

    nonisolated private static func cloneSite(from root: URL, to site: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: site)
        try manager.createDirectory(at: site, withIntermediateDirectories: true)
        let skipped: Set<String> = [".git", "_site", ".jekyll-cache", ".jekyll-metadata", ".sass-cache", "tools", ".DS_Store"]
        for item in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !skipped.contains(item.lastPathComponent) {
            try manager.copyItem(at: item, to: site.appending(path: item.lastPathComponent))
        }
    }

    /// Puts the draft's post, playlists and media into the cloned site, undoing the previous version.
    private func write(_ draft: PostDraft) async {
        guard let repo else { return }
        if isWriting {
            pendingDraft = draft
            return
        }
        isWriting = true
        defer {
            isWriting = false
            if let next = pendingDraft {
                pendingDraft = nil
                Task { await write(next) }
            }
        }

        var draft = draft
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = "Untitled" }
        // Local Jekyll uses this Mac's time zone unless the site sets one.
        let timeZone = repo.config()["timezone"].flatMap(TimeZone.init(identifier:)) ?? .current
        let builder = PostBuilder(draft: draft, siteTimeZone: timeZone, exists: repo.exists, repoRoot: repo.root)
        guard let plan = try? builder.build(validate: false) else { return }

        var files: [String: String] = [:]   // path → content key
        var sources: [String: URL] = [:]
        for file in plan.dataFiles + [plan.post] {
            files[file.path] = Self.hash(file.contents)
        }
        do {
            for job in plan.images {
                let key = Self.hash("\(job.source.path)|\(Self.modified(job.source))|\(job.crop)|\(job.maxWidth)|\(job.quality)")
                let cached = mediaDirectory.appending(path: "\(key).\(job.format.fileExtension)")
                if !FileManager.default.fileExists(atPath: cached.path) {
                    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                    try await Task.detached { try ImageProcessing.export(job, to: cached) }.value
                }
                files[job.path] = key
                sources[job.path] = cached
            }
            for job in plan.audio {
                let key = Self.hash("\(job.source.path)|\(Self.modified(job.source))")
                let cached = mediaDirectory.appending(path: "\(key).m4a")
                if !FileManager.default.fileExists(atPath: cached.path) {
                    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                    try await AudioProcessing.export(job, to: cached)
                }
                files[job.path] = key
                sources[job.path] = cached
            }
        } catch {
            buildError = "Couldn't prepare media: \(error.localizedDescription)"
        }

        let manager = FileManager.default
        // Put back anything the previous version replaced or removed that this one doesn't.
        for path in Set(written.keys).subtracting(files.keys).union(removed.subtracting(plan.deletions)) {
            let destination = siteDirectory.appending(path: path)
            try? manager.removeItem(at: destination)
            if repo.exists(path) { try? manager.copyItem(at: repo.url(path), to: destination) }
        }
        for path in plan.deletions {
            try? manager.removeItem(at: siteDirectory.appending(path: path))
        }
        for (path, key) in files where written[path] != key {
            let destination = siteDirectory.appending(path: path)
            try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            if let source = sources[path] {
                try? manager.copyItem(at: source, to: destination)
            } else if let text = (plan.dataFiles + [plan.post]).first(where: { $0.path == path })?.contents {
                try? text.write(to: destination, atomically: true, encoding: .utf8)
            }
        }
        written = files
        removed = Set(plan.deletions)

        let url = URL(string: "http://127.0.0.1:\(port)\(plan.postURL)")
        if url != pageURL { pageURL = url }
    }

    // MARK: Jekyll

    private func launch() {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "bundle", "exec", "jekyll", "serve",
            "--source", siteDirectory.path,
            "--destination", siteDirectory.appending(path: "_site").path,
            "--host", "127.0.0.1", "--port", String(port),
            "--future", "--drafts",
        ]
        process.currentDirectoryURL = siteDirectory
        process.environment = Self.rubyEnvironment(gemfile: siteDirectory.appending(path: "Gemfile"))
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.handleOutput(text) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.handleExit(status) }
        }

        do {
            try process.run()
        } catch {
            status = .failed("Couldn't run Jekyll: \(error.localizedDescription)")
            return
        }
        self.process = process
        stopping = false
        Self.processes[ObjectIdentifier(self)] = process
        status = .starting
    }

    private func handleOutput(_ text: String) {
        log += text
        if log.count > 200_000 { log = String(log.suffix(150_000)) }

        for line in text.components(separatedBy: .newlines) {
            if line.contains("Server running") {
                status = .ready
                reloadToken += 1
            } else if line.contains("Regenerating:") {
                if status == .ready { status = .building }
            } else if line.contains("...done in") {
                buildError = nil
                if status == .building || status == .ready {
                    status = .ready
                    reloadToken += 1
                }
            } else if line.contains("Error:") || line.contains("Liquid Exception") || line.contains("Could not locate Gemfile") || line.contains("command not found") {
                buildError = line.trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func handleExit(_ code: Int32) {
        process = nil
        Self.processes[ObjectIdentifier(self)] = nil
        if stopping {
            stopping = false
            return
        }
        var message = "Jekyll stopped (exit code \(code))."
        if log.contains("bundle install") || log.contains("Could not find") {
            message += " Try running `bundle install` in the blog folder."
        }
        status = .failed(message)
    }

    /// GUI apps don't get the shell's PATH, so add the usual Ruby version-manager shims.
    nonisolated static func rubyEnvironment(gemfile: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.rbenv/shims", "\(home)/.asdf/shims", "\(home)/.local/share/mise/shims",
            "/opt/homebrew/opt/ruby/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ]
        environment["PATH"] = (paths + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["BUNDLE_GEMFILE"] = gemfile.path
        // Jekyll reads files as US-ASCII without a UTF-8 locale.
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        if environment["LC_ALL"] == nil { environment["LC_ALL"] = "en_US.UTF-8" }
        environment["JEKYLL_ENV"] = "development"
        return environment
    }

    private static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return 4123 }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                bind(socket, address, length) == 0 && getsockname(socket, address, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 4123
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func modified(_ url: URL) -> TimeInterval {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast).timeIntervalSince1970
    }
}
