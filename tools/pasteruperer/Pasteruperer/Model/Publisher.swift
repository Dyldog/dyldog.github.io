import Foundation
import Observation

/// Applies changes to the repo, commits exactly those files, and pushes.
@MainActor
@Observable
final class Publisher {
    struct Step: Identifiable {
        enum State { case running, done, failed }
        let id = UUID()
        var title: String
        var state: State
    }

    enum Phase: Equatable {
        case ready, running, succeeded
        /// `committed` is true when the commit exists locally and only pushing failed.
        case failed(committed: Bool)
    }

    private(set) var phase: Phase = .ready
    private(set) var steps: [Step] = []
    private(set) var errorMessage: String?
    private(set) var commit: String?
    private(set) var pushed = false

    /// Writes a post (new, edited, or moved between `_drafts` and `_posts`) and commits it.
    func publish(_ plan: PostPlan, to repo: BlogRepo, message: String, push: Bool) async {
        await run(in: repo, message: message, push: push, paths: plan.paths) { changes in
            try await self.step("Checking the repo") {
                let taken = plan.writtenPaths.filter { repo.exists($0) && !plan.overwrites.contains($0) }
                if !taken.isEmpty {
                    throw ProcessingError(errorDescription: "These files already exist: \(taken.joined(separator: ", "))")
                }
                for path in plan.overwrites.sorted() + plan.deletions { try changes.backUp(path) }
            }

            if !plan.images.isEmpty {
                try await self.step(plan.images.count == 1 ? "Cropping and resizing the image" : "Cropping and resizing \(plan.images.count) images") {
                    for job in plan.images {
                        let destination = try changes.prepare(job.path)
                        try await Task.detached(priority: .userInitiated) { try ImageProcessing.export(job, to: destination) }.value
                    }
                }
            }

            if !plan.audio.isEmpty {
                let converting = plan.audio.contains { $0.source.pathExtension.lowercased() != "m4a" }
                try await self.step(converting ? "Converting audio to m4a" : "Copying audio") {
                    for job in plan.audio {
                        try await AudioProcessing.export(job, to: try changes.prepare(job.path))
                    }
                }
            }

            try await self.step("Writing \(plan.post.path)") {
                for file in plan.dataFiles + [plan.post] {
                    try file.contents.write(to: try changes.prepare(file.path), atomically: true, encoding: .utf8)
                }
            }

            if !plan.deletions.isEmpty {
                try await self.step("Removing \(plan.deletions.count) old file\(plan.deletions.count == 1 ? "" : "s")") {
                    for path in plan.deletions { try FileManager.default.removeItem(at: repo.url(path)) }
                }
            }
        }
    }

    /// Removes a post and its files and commits that.
    func delete(_ paths: [String], from repo: BlogRepo, message: String, push: Bool) async {
        await run(in: repo, message: message, push: push, paths: paths) { changes in
            try await self.step("Removing \(paths.count) file\(paths.count == 1 ? "" : "s")") {
                for path in paths {
                    try changes.backUp(path)
                    try FileManager.default.removeItem(at: repo.url(path))
                }
            }
        }
    }

    func push(_ repo: BlogRepo) async {
        phase = .running
        errorMessage = nil
        let git = Git(repo: repo.root)
        do {
            if await git.hasUpstream() {
                try await step("Pulling the latest changes") {
                    try await git.run(["pull", "--rebase", "--autostash"])
                }
                try await step("Pushing") {
                    try await git.run(["push"])
                }
            } else {
                try await step("Pushing") {
                    try await git.run(["push", "-u", "origin", "HEAD"])
                }
            }
            pushed = true
            phase = .succeeded
        } catch {
            fail(error, committed: true)
        }
    }

    /// Makes the changes, commits only `paths`, then pushes. If anything fails before the commit, every
    /// change is undone so the repo is as it was.
    private func run(in repo: BlogRepo, message: String, push: Bool, paths: [String], apply: (Changes) async throws -> Void) async {
        phase = .running
        steps = []
        errorMessage = nil
        let git = Git(repo: repo.root)
        let changes = Changes(repo: repo)
        defer { changes.discardBackups() }
        var committedPaths = paths

        do {
            try await git.run(["rev-parse", "--is-inside-work-tree"])
            try await apply(changes)
            try await step("Committing") {
                // Removed files that git never knew about don't need committing (and would make git fail).
                var tracked: [String] = []
                for path in paths {
                    if repo.exists(path) {
                        tracked.append(path)
                    } else if (try? await git.run(["ls-files", "--error-unmatch", "--", path])) != nil {
                        tracked.append(path)
                    }
                }
                committedPaths = tracked
                try await git.run(["add", "-A", "--"] + tracked)
                let staged = try await git.run(["diff", "--cached", "--name-only", "--"] + tracked)
                if staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ProcessingError(errorDescription: "Nothing has changed, so there's nothing to commit.")
                }
                // Commit only these files, leaving anything else in the working tree alone.
                try await git.run(["commit", "-m", message, "--"] + tracked)
                commit = try await git.run(["rev-parse", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            _ = try? await git.run(["reset", "-q", "--"] + committedPaths)
            changes.rollBack()
            fail(error, committed: false)
            return
        }

        if push {
            await self.push(repo)
        } else {
            phase = .succeeded
        }
    }

    private func step(_ title: String, _ work: () async throws -> Void) async throws {
        steps.append(Step(title: title, state: .running))
        let index = steps.count - 1
        do {
            try await work()
            steps[index].state = .done
        } catch {
            steps[index].state = .failed
            throw error
        }
    }

    private func fail(_ error: Error, committed: Bool) {
        errorMessage = error.localizedDescription
        phase = .failed(committed: committed)
    }
}

/// Tracks what a publish changed on disk so it can be undone.
@MainActor
final class Changes {
    let repo: BlogRepo
    private let backupDirectory = FileManager.default.temporaryDirectory.appending(path: "pasteruperer-backup-\(UUID().uuidString)")
    private var created: [URL] = []
    private var backups: [(original: URL, copy: URL)] = []

    init(repo: BlogRepo) {
        self.repo = repo
    }

    /// Keeps a copy of an existing file before it's replaced or removed.
    func backUp(_ path: String) throws {
        let original = repo.url(path)
        guard FileManager.default.fileExists(atPath: original.path),
              !backups.contains(where: { $0.original == original }) else { return }
        let copy = backupDirectory.appending(path: path)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: copy)
        backups.append((original, copy))
    }

    /// Returns where to write `path`, creating its folders and remembering anything new.
    func prepare(_ path: String) throws -> URL {
        let url = repo.url(path)
        var missing: [URL] = []
        var directory = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path) {
            missing.insert(directory, at: 0)
            directory.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        created += missing
        if !FileManager.default.fileExists(atPath: url.path) { created.append(url) }
        return url
    }

    func rollBack() {
        for url in created.reversed() { try? FileManager.default.removeItem(at: url) }
        for backup in backups {
            try? FileManager.default.createDirectory(at: backup.original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: backup.original)
            try? FileManager.default.copyItem(at: backup.copy, to: backup.original)
        }
    }

    func discardBackups() {
        try? FileManager.default.removeItem(at: backupDirectory)
    }
}
