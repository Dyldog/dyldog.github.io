import Foundation

struct GitError: LocalizedError {
    var command: String
    var output: String
    var errorDescription: String? {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "\(command) failed." : "\(command) failed:\n\(output)"
    }
}

struct Git: Sendable {
    let repo: URL

    /// Runs git in the repo and returns its combined output, throwing if it exits non-zero.
    /// There's no terminal, so anything that needs a prompt (an SSH passphrase, a password)
    /// fails instead of hanging.
    @discardableResult
    func run(_ arguments: [String]) async throws -> String {
        let repo = repo
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/env")
                process.arguments = ["git"] + arguments
                process.currentDirectoryURL = repo
                var environment = ProcessInfo.processInfo.environment
                // Apps launched from Finder get a minimal PATH; prefer a Homebrew git if there is one.
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: GitError(command: "git \(arguments.first ?? "")", output: output))
                }
            }
        }
    }

    func currentBranch() async -> String? {
        try? await run(["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasUpstream() async -> Bool {
        (try? await run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])) != nil
    }
}
