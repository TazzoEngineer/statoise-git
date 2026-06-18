import Foundation

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
        
        try process.run()
        process.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        
        if process.terminationStatus != 0 {
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
        let output = try await runGit(
            arguments: ["status", "--porcelain=v1", "-z"],
            workingDirectory: path
        )
        return parseStatus(output)
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
