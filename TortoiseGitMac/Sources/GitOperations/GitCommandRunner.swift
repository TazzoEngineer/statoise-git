import Foundation
import os.log

private let gitLogger = Logger(subsystem: "com.tortoisegitmac.app", category: "GitCommandRunner")

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

/// Runs git commands via the system git binary
actor GitCommandRunner {
    
    static let shared = GitCommandRunner()
    
    private var gitPath: String {
        RepositoryPreferences.shared.gitPath
    }
    
    // MARK: - Core Execution
    
    private func runGit(arguments: [String], workingDirectory: String? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        
        if let dir = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
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
        
        // Read data BEFORE waiting for exit to avoid deadlock
        // (pipe buffer can fill up with large output, blocking the process)
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
        _ = try await runGit(arguments: ["add"] + files, workingDirectory: path)
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
            arguments: ["diff", "\(hash)~1", hash, "--", file],
            workingDirectory: root
        )
    }
    
    func commitDiff(at path: String, hash: String) async throws -> String {
        let root = try await repositoryRoot(at: path)
        return try await runGit(
            arguments: ["diff", "\(hash)~1", hash],
            workingDirectory: root
        )
    }

    /// Export a file at a specific revision to a temp file, returns the temp file path
    func exportFileAtRevision(at path: String, hash: String, file: String) async throws -> String {
        let root = try await repositoryRoot(at: path)
        let content = try await runGit(
            arguments: ["show", "\(hash):\(file)"],
            workingDirectory: root
        )
        
        let fileName = (file as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension
        let baseName = (fileName as NSString).deletingPathExtension
        let tempDir = "/tmp"
        let tempPath = (tempDir as NSString).appendingPathComponent("\(baseName)_\(hash.prefix(7)).\(ext)")
        try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
        return tempPath
    }
    
    /// Export file at parent revision
    func exportFileAtParentRevision(at path: String, hash: String, file: String) async throws -> String {
        let root = try await repositoryRoot(at: path)
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
        
        let fileName = (file as NSString).lastPathComponent
        let ext = (fileName as NSString).pathExtension
        let baseName = (fileName as NSString).deletingPathExtension
        let tempDir = "/tmp"
        let tempPath = (tempDir as NSString).appendingPathComponent("\(baseName)_\(hash.prefix(7))~1.\(ext)")
        try content.write(toFile: tempPath, atomically: true, encoding: .utf8)
        return tempPath
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
        var args = ["diff"]
        if let file = file { args.append(file) }
        return try await runGit(arguments: args, workingDirectory: path)
    }
    
    func stashList(at path: String) async throws -> String {
        return try await runGit(arguments: ["stash", "list"], workingDirectory: path)
    }
    
    func stashSave(at path: String, message: String?) async throws {
        var args = ["stash", "push"]
        if let message = message {
            args += ["-m", message]
        }
        _ = try await runGit(arguments: args, workingDirectory: path)
    }
    
    func stashPop(at path: String) async throws {
        _ = try await runGit(arguments: ["stash", "pop"], workingDirectory: path)
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
