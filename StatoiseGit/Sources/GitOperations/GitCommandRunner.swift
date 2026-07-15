import Foundation
import os.log

private let gitLogger = Logger(subsystem: "com.statoisegit.app", category: "GitCommandRunner")

/// Parsed commit entry for the log view
struct LogEntry {
    let hash: String
    let shortHash: String
    let author: String
    let date: String
    let subject: String
    let refs: String
    let parents: [String]  // parent commit hashes
}

/// Represents a Git file status
enum GitFileStatus: String {
    case unmodified = " "
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case untracked = "?"
    case ignored = "!"
    case conflicted = "U"
}

/// Represents a file with its Git status
struct GitStatusEntry {
    let indexStatus: GitFileStatus
    let workTreeStatus: GitFileStatus
    let filePath: String
    let originalPath: String?
    
    /// Overall status for display purposes
    var displayStatus: GitFileStatus {
        if workTreeStatus == .untracked { return .untracked }
        if indexStatus == .conflicted || workTreeStatus == .conflicted { return .conflicted }
        if workTreeStatus != .unmodified { return workTreeStatus }
        return indexStatus
    }
}

/// Represents basic branch info
struct GitBranchInfo {
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
}

struct GitTreeEntry {
    let mode: String
    let type: String
    let object: String
    let path: String

    var isSubmodule: Bool {
        mode == "160000" || type == "commit"
    }
}

/// Runs git commands via the system git binary
actor GitCommandRunner {
    
    static let shared = GitCommandRunner()
    
    private var gitPath: String {
        RepositoryPreferences.shared.gitPath
    }

    private func runGitProcess(arguments: [String], workingDirectoryURL: URL? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments

        if let workingDirectoryURL {
            process.currentDirectoryURL = workingDirectoryURL
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            gitLogger.error("Process.run() failed for git \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            gitLogger.error("git \(arguments.joined(separator: " "), privacy: .public) failed (exit \(process.terminationStatus)): \(errorOutput, privacy: .public)")
            throw GitError.commandFailed(
                command: "git \(arguments.joined(separator: " "))",
                exitCode: Int(process.terminationStatus),
                stderr: errorOutput
            )
        }

        return output
    }
    
    // MARK: - Core Execution
    
    private func runGit(arguments: [String], workingDirectory: String? = nil) async throws -> String {
        if let dir = workingDirectory {
            return try await RepositoryPreferences.shared.withSecurityScopedAccess(to: dir) { scopedURL in
                try await self.runGitProcess(arguments: arguments, workingDirectoryURL: scopedURL)
            }
        }

        return try await runGitProcess(arguments: arguments)
    }
    
    // MARK: - Status
    
    func status(at path: String) async throws -> [GitStatusEntry] {
        let root = try await repositoryRoot(at: path)
        let output = try await runGit(
            arguments: ["status", "--porcelain=v1", "-z", "-uall"],
            workingDirectory: root
        )
        return parseStatus(output)
    }
    
    /// List all tracked files in the repository
    func listTrackedFiles(at path: String) async throws -> [String] {
        let root = try await repositoryRoot(at: path)
        let output = try await runGit(
            arguments: ["ls-files", "-z"],
            workingDirectory: root
        )
        return output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
    
    private func parseStatus(_ output: String) -> [GitStatusEntry] {
        var entries: [GitStatusEntry] = []
        let items = output.split(separator: "\0", omittingEmptySubsequences: false)
        
        var i = 0
        while i < items.count {
            let item = String(items[i])
            guard item.count >= 3 else {
                i += 1
                continue
            }
            
            let indexChar = item[item.startIndex]
            let workTreeChar = item[item.index(after: item.startIndex)]
            let filePath = String(item.dropFirst(3))
            
            let indexStatus = GitFileStatus(rawValue: String(indexChar)) ?? .unmodified
            let workTreeStatus = GitFileStatus(rawValue: String(workTreeChar)) ?? .unmodified
            
            var originalPath: String? = nil
            if indexStatus == .renamed || indexStatus == .copied {
                i += 1
                if i < items.count {
                    originalPath = String(items[i])
                }
            }
            
            entries.append(GitStatusEntry(
                indexStatus: indexStatus,
                workTreeStatus: workTreeStatus,
                filePath: filePath,
                originalPath: originalPath
            ))
            
            i += 1
        }
        
        return entries
    }
    
    // MARK: - Branch Operations
    
    func currentBranch(at path: String) async throws -> String {
        let output = try await runGit(
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: path
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func branches(at path: String) async throws -> [GitBranchInfo] {
        let output = try await runGit(
            arguments: ["branch", "-a", "--format=%(refname:short)\t%(HEAD)"],
            workingDirectory: path
        )
        
        return output
            .split(separator: "\n")
            .map { line -> GitBranchInfo in
                let parts = line.split(separator: "\t", maxSplits: 1)
                let name = String(parts[0])
                let isCurrent = parts.count > 1 && parts[1] == "*"
                let isRemote = name.hasPrefix("origin/")
                return GitBranchInfo(name: name, isRemote: isRemote, isCurrent: isCurrent)
            }
    }
    
    // MARK: - Basic Operations
    
    func clone(repositoryURL: String, destination: String) async throws {
        _ = try await runGit(arguments: ["clone", "--progress", repositoryURL, destination])
    }
    
    func commit(at path: String, message: String) async throws {
        _ = try await runGit(arguments: ["commit", "-m", message], workingDirectory: path)
    }
    
    func add(at path: String, files: [String]) async throws {
        // Status/tracked file paths are relative to the repository root, so run
        // `git add` from the root to avoid double-prefixing when `path` is a subdirectory.
        let root = try await repositoryRoot(at: path)
        _ = try await runGit(arguments: ["add"] + files, workingDirectory: root)
    }

    func revert(at path: String, files: [String]) async throws {
        // File paths are relative to the repository root; run from the root.
        let root = try await repositoryRoot(at: path)
        _ = try await runGit(arguments: ["checkout", "HEAD", "--"] + files, workingDirectory: root)
    }

    func pull(at path: String) async throws {
        _ = try await runGit(arguments: ["pull", "--progress"], workingDirectory: path)
    }
    
    func push(at path: String) async throws {
        _ = try await runGit(arguments: ["push", "--progress"], workingDirectory: path)
    }
    
    func fetch(at path: String) async throws {
        _ = try await runGit(arguments: ["fetch", "--all", "--prune"], workingDirectory: path)
    }
    
    func log(at path: String, maxCount: Int = 50) async throws -> String {
        return try await runGit(
            arguments: [
                "log",
                "--oneline",
                "--graph",
                "--decorate",
                "-n", String(maxCount)
            ],
            workingDirectory: path
        )
    }
    
    /// Get structured log entries for the table view
    func logEntries(at path: String, maxCount: Int = 50) async throws -> [LogEntry] {
        let separator = "---LOG_SEP---"
        // Format: hash|short_hash|author|date|subject|refs|parents
        let format = "%H\(separator)%h\(separator)%an\(separator)%ad\(separator)%s\(separator)%D\(separator)%P"
        let output = try await runGit(
            arguments: [
                "log",
                "--format=\(format)",
                "--date=short",
                "-n", String(maxCount)
            ],
            workingDirectory: path
        )
        
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 5 else { return nil }
            let parentStr = parts.count > 6 ? parts[6] : ""
            let parents = parentStr.split(separator: " ").map(String.init)
            return LogEntry(
                hash: parts[0],
                shortHash: parts[1],
                author: parts[2],
                date: parts[3],
                subject: parts[4],
                refs: parts.count > 5 ? parts[5] : "",
                parents: parents
            )
        }
    }
    
    /// Get full commit message for a given hash
    func commitMessage(at path: String, hash: String) async throws -> String {
        return try await runGit(
            arguments: ["log", "-1", "--format=%B", hash],
            workingDirectory: path
        )
    }
    
    /// Get list of changed files for a given commit (format: "M\tpath")
    func commitFiles(at path: String, hash: String) async throws -> [String] {
        let root = try await repositoryRoot(at: path)
        // Use diff-tree with --root to handle initial commit
        let output = try await runGit(
            arguments: ["diff-tree", "--no-commit-id", "--root", "-r", "--name-status", hash],
            workingDirectory: root
        )
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
    
    /// Get diff for a specific file at a specific commit (vs parent)
    func commitFileDiff(at path: String, hash: String, file: String) async throws -> String {
        let root = try await repositoryRoot(at: path)
        return try await runGit(
            arguments: ["diff", "--submodule=log", "\(hash)~1", hash, "--", file],
            workingDirectory: root
        )
    }
    
    func commitDiff(at path: String, hash: String) async throws -> String {
        let root = try await repositoryRoot(at: path)
        return try await runGit(
            arguments: ["diff", "--submodule=log", "\(hash)~1", hash],
            workingDirectory: root
        )
    }

    /// Export a file at a specific revision to a temp file, returns the temp file path
    func exportFileAtRevision(at path: String, hash: String, file: String) async throws -> String {
        let root = try await repositoryRoot(at: path)

        if let entry = try await treeEntry(at: root, revision: hash, file: file), entry.isSubmodule {
            let content = makeSubmoduleRevisionSummary(path: entry.path, revisionLabel: hash, object: entry.object)
            return try writeTempDiffContent(content, file: file, suffix: "_\(hash.prefix(7))", preferredExtension: "txt")
        }

        let content = try await runGit(
            arguments: ["show", "\(hash):\(file)"],
            workingDirectory: root
        )

        return try writeTempDiffContent(content, file: file, suffix: "_\(hash.prefix(7))")
    }
    
    /// Export file at parent revision
    func exportFileAtParentRevision(at path: String, hash: String, file: String) async throws -> String {
        let root = try await repositoryRoot(at: path)

        if let entry = try await treeEntry(at: root, revision: "\(hash)~1", file: file), entry.isSubmodule {
            let content = makeSubmoduleRevisionSummary(path: entry.path, revisionLabel: "\(hash)~1", object: entry.object)
            return try writeTempDiffContent(content, file: file, suffix: "_\(hash.prefix(7))~1", preferredExtension: "txt")
        }

        let content: String
        do {
            content = try await runGit(
                arguments: ["show", "\(hash)~1:\(file)"],
                workingDirectory: root
            )
        } catch {
            // File might not exist in parent (new file)
            content = ""
        }

        return try writeTempDiffContent(content, file: file, suffix: "_\(hash.prefix(7))~1")
    }
    
    /// Get log entries for a specific file
    func fileLogEntries(at path: String, file: String, maxCount: Int = 100) async throws -> [LogEntry] {
        let root = try await repositoryRoot(at: path)
        let separator = "---LOG_SEP---"
        let format = "%H\(separator)%h\(separator)%an\(separator)%ad\(separator)%s\(separator)%D\(separator)%P"
        let output = try await runGit(
            arguments: [
                "log",
                "--format=\(format)",
                "--date=short",
                "-n", String(maxCount),
                "--follow",
                "--", file
            ],
            workingDirectory: root
        )
        
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.components(separatedBy: separator)
            guard parts.count >= 5 else { return nil }
            let parentStr = parts.count > 6 ? parts[6] : ""
            let parents = parentStr.split(separator: " ").map(String.init)
            return LogEntry(
                hash: parts[0],
                shortHash: parts[1],
                author: parts[2],
                date: parts[3],
                subject: parts[4],
                refs: parts.count > 5 ? parts[5] : "",
                parents: parents
            )
        }
    }
    
    func diff(at path: String, file: String? = nil) async throws -> String {
        var args = ["diff", "--submodule=log"]
        if let file = file {
            args += ["--", file]
        }
        return try await runGit(arguments: args, workingDirectory: path)
    }

    /// Diff working tree + staged changes against HEAD (shows all uncommitted changes)
    func diffAgainstHEAD(at path: String, file: String? = nil) async throws -> String {
        var args = ["diff", "HEAD", "--submodule=log"]
        if let file = file {
            args += ["--", file]
        }
        return try await runGit(arguments: args, workingDirectory: path)
    }

    /// Create an empty temp file for diff comparison (used for new files with no HEAD version)
    nonisolated func createEmptyTempFile(for file: String, suffix: String) throws -> String {
        let tempPath = Self.tempDiffPath(for: file, suffix: suffix, preferredExtension: nil)
        try "".write(toFile: tempPath, atomically: true, encoding: .utf8)
        return tempPath
    }

    /// Build a temp file path for diff/export content.
    ///
    /// Handles dot-files (names beginning with a period such as `.gitignore`) so the
    /// generated temp file is not itself hidden and keeps a recognizable name/extension.
    nonisolated static func tempDiffPath(for file: String, suffix: String, preferredExtension: String?) -> String {
        let fileName = (file as NSString).lastPathComponent

        // Strip any leading dots so the temp file is not hidden (e.g. ".gitignore").
        let leadingDotsStripped = String(fileName.drop(while: { $0 == "." }))
        let nameForParsing = leadingDotsStripped.isEmpty ? fileName : leadingDotsStripped

        let existingExtension = (nameForParsing as NSString).pathExtension
        let baseName: String
        let ext: String
        if let preferredExtension {
            baseName = existingExtension.isEmpty ? nameForParsing : (nameForParsing as NSString).deletingPathExtension
            ext = preferredExtension
        } else if existingExtension.isEmpty {
            // Pure dot-file like ".gitignore" / ".env": keep the name as the extension so
            // syntax-aware tools still recognize it (e.g. "gitignore_HEAD.gitignore").
            baseName = nameForParsing
            ext = nameForParsing
        } else {
            baseName = (nameForParsing as NSString).deletingPathExtension
            ext = existingExtension
        }

        return ("/tmp" as NSString).appendingPathComponent("\(baseName)\(suffix).\(ext)")
    }

    func exportWorkingTreeItemForDiff(at path: String, file: String) async throws -> String {
        let root = try await repositoryRoot(at: path)

        if let headEntry = try await treeEntry(at: root, revision: "HEAD", file: file), headEntry.isSubmodule {
            let summary = await makeWorkingTreeSubmoduleSummary(at: root, file: file, headObject: headEntry.object)
            return try writeTempDiffContent(summary, file: file, suffix: "_working", preferredExtension: "txt")
        }

        if let indexEntry = try await indexEntry(at: root, file: file), indexEntry.isSubmodule {
            let summary = await makeWorkingTreeSubmoduleSummary(at: root, file: file, headObject: indexEntry.object)
            return try writeTempDiffContent(summary, file: file, suffix: "_working", preferredExtension: "txt")
        }

        return (root as NSString).appendingPathComponent(file)
    }

    func treeEntry(at root: String, revision: String, file: String) async throws -> GitTreeEntry? {
        let output = try await runGit(
            arguments: ["ls-tree", revision, "--", file],
            workingDirectory: root
        )
        return parseTreeEntry(output)
    }

    private func indexEntry(at root: String, file: String) async throws -> GitTreeEntry? {
        let output = try await runGit(
            arguments: ["ls-files", "--stage", "--", file],
            workingDirectory: root
        )
        return parseIndexEntry(output)
    }

    private func parseTreeEntry(_ output: String) -> GitTreeEntry? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first,
              let tabIndex = line.firstIndex(of: "\t") else {
            return nil
        }

        let metadata = line[..<tabIndex].split(separator: " ")
        guard metadata.count >= 3 else { return nil }

        return GitTreeEntry(
            mode: String(metadata[0]),
            type: String(metadata[1]),
            object: String(metadata[2]),
            path: String(line[line.index(after: tabIndex)...])
        )
    }

    private func parseIndexEntry(_ output: String) -> GitTreeEntry? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first,
              let tabIndex = line.firstIndex(of: "\t") else {
            return nil
        }

        let metadata = line[..<tabIndex].split(separator: " ")
        guard metadata.count >= 3 else { return nil }

        return GitTreeEntry(
            mode: String(metadata[0]),
            type: String(metadata[0]) == "160000" ? "commit" : "blob",
            object: String(metadata[1]),
            path: String(line[line.index(after: tabIndex)...])
        )
    }

    private func makeSubmoduleRevisionSummary(path: String, revisionLabel: String, object: String) -> String {
        return """
        Submodule: \(path)
        Revision: \(revisionLabel)
        Commit: \(object)

        This path is a Git submodule entry (gitlink), so it does not have file contents to export with git show.
        Use the built-in diff view to inspect the submodule commit transition and nested log.
        """
    }

    private func makeWorkingTreeSubmoduleSummary(at root: String, file: String, headObject: String) async -> String {
        let submodulePath = (root as NSString).appendingPathComponent(file)
        let rawStatus = (try? await runGit(
            arguments: ["submodule", "status", "--", file],
            workingDirectory: root
        ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "(unavailable)"

        let currentHead = (try? await runGitProcess(
            arguments: ["rev-parse", "HEAD"],
            workingDirectoryURL: URL(fileURLWithPath: submodulePath)
        ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "(unavailable)"

        return """
        Submodule: \(file)
        HEAD commit in superproject: \(headObject)
        Working tree commit: \(currentHead)
        Submodule status: \(rawStatus)

        This path is a Git submodule entry (gitlink), so external diff compares the referenced commit IDs instead of file contents.
        """
    }

    private func writeTempDiffContent(_ content: String, file: String, suffix: String, preferredExtension: String? = nil) throws -> String {
        let tempPath = Self.tempDiffPath(for: file, suffix: suffix, preferredExtension: preferredExtension)
        try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
        return tempPath
    }
    
    func stashList(at path: String) async throws -> String {
        let root = try await repositoryRoot(at: path)
        return try await runGit(arguments: ["stash", "list"], workingDirectory: root)
    }
    
    func stashSave(at path: String, message: String?, includeUntracked: Bool = false) async throws {
        let root = try await repositoryRoot(at: path)
        var args = ["stash", "push"]
        if includeUntracked {
            args.append("--include-untracked")
        }
        if let message = message, !message.isEmpty {
            args += ["-m", message]
        }
        _ = try await runGit(arguments: args, workingDirectory: root)
    }
    
    func stashPop(at path: String) async throws {
        let root = try await repositoryRoot(at: path)
        _ = try await runGit(arguments: ["stash", "pop"], workingDirectory: root)
    }

    func resetHard(at path: String) async throws {
        let root = try await repositoryRoot(at: path)
        _ = try await runGit(arguments: ["reset", "--hard", "HEAD"], workingDirectory: root)
    }

    func cleanAll(at path: String) async throws {
        let root = try await repositoryRoot(at: path)
        _ = try await runGit(arguments: ["clean", "-xdf"], workingDirectory: root)
    }

    func submoduleUpdate(at path: String) async throws {
        let root = try await repositoryRoot(at: path)
        _ = try await runGit(arguments: ["submodule", "update", "--init"], workingDirectory: root)
    }
    
    // MARK: - Repository Detection
    
    func isGitRepository(at path: String) async -> Bool {
        // First try filesystem check (works in sandbox)
        if isGitRepositoryByFilesystem(at: path) {
            return true
        }
        // Then try git command
        do {
            _ = try await runGit(
                arguments: ["rev-parse", "--is-inside-work-tree"],
                workingDirectory: path
            )
            return true
        } catch {
            return false
        }
    }
    
    /// Check if a path is inside a git repository by looking for .git directory
    nonisolated func isGitRepositoryByFilesystem(at path: String) -> Bool {
        let fm = FileManager.default
        var current = path
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current, isDirectory: &isDir), !isDir.boolValue {
            current = (current as NSString).deletingLastPathComponent
        }
        while current != "/" && !current.isEmpty {
            let gitDir = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir) {
                return true
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Check if a path itself is a Git repository root.
    nonisolated func isGitRepositoryRootByFilesystem(at path: String) -> Bool {
        let gitDir = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir)
    }
    
    /// Find repository root by walking up the directory tree
    nonisolated func repositoryRootByFilesystem(at path: String) -> String? {
        let fm = FileManager.default
        var current = path
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: current, isDirectory: &isDir), !isDir.boolValue {
            current = (current as NSString).deletingLastPathComponent
        }
        while current != "/" && !current.isEmpty {
            let gitDir = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
    
    func repositoryRoot(at path: String) async throws -> String {
        let output = try await runGit(
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: path
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func repositoryHead(at path: String) async throws -> String {
        let output = try await runGit(
            arguments: ["rev-parse", "HEAD"],
            workingDirectory: path
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Errors

enum GitError: LocalizedError {
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case notARepository(path: String)
    
    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let exitCode, let stderr):
            return "Git command failed (\(exitCode)): \(command)\n\(stderr)"
        case .notARepository(let path):
            return "Not a Git repository: \(path)"
        }
    }
}
