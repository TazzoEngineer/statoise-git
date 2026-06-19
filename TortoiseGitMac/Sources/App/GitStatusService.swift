import Foundation
import os.log

private let logger = Logger(subsystem: "com.tortoisegitmac.app", category: "GitStatusService")

/// Background service that periodically runs git status on monitored repositories
/// and writes the results to the App Group shared container for the Finder Extension to read.
class GitStatusService {
    
    static let shared = GitStatusService()
    
    private var timer: Timer?
    private let interval: TimeInterval = 3.0 // Refresh every 3 seconds
    
    func start() {
        // Run immediately
        Task { await refreshAll() }
        
        // Schedule periodic refresh
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Refresh a specific repository immediately (e.g., after a git operation)
    func refreshRepository(at path: String) async {
        let runner = GitCommandRunner.shared
        guard await runner.isGitRepository(at: path) else { return }
        
        do {
            let repoRoot = try await runner.repositoryRoot(at: path)
            let entries = try await runner.status(at: repoRoot)
            
            let cached = entries.map { entry in
                let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                return CachedFileStatus(path: fullPath, status: entry.displayStatus.rawValue)
            }
            
            RepositoryPreferences.shared.writeStatusCache(repoPath: repoRoot, entries: cached)
        } catch {
            // Silently continue
        }
    }
    
    private func refreshAll() async {
        let prefs = RepositoryPreferences.shared
        let repos = prefs.enabledRepositoryPaths
        
        // If no repos configured, scan common development directories
        let pathsToCheck: [String]
        if repos.isEmpty {
            // In sandbox, NSHomeDirectory() returns container path
            // Use the real home directory from pw database
            let realHome = ProcessInfo.processInfo.environment["HOME"]
                ?? NSHomeDirectory()
            logger.notice("No repos configured, scanning from: \(realHome)")
            let commonDirs = [
                realHome,
                (realHome as NSString).appendingPathComponent("EXGITHUB"),
                (realHome as NSString).appendingPathComponent("Documents"),
                (realHome as NSString).appendingPathComponent("Developer"),
                (realHome as NSString).appendingPathComponent("Projects"),
                (realHome as NSString).appendingPathComponent("src"),
                (realHome as NSString).appendingPathComponent("repos"),
            ]
            var found: [String] = []
            for dir in commonDirs {
                let repos = findGitRepos(in: dir, maxDepth: 2)
                if !repos.isEmpty {
                    logger.notice("Found \(repos.count) repos in \(dir)")
                }
                found.append(contentsOf: repos)
            }
            pathsToCheck = found
            logger.notice("Total repos found: \(found.count)")
        } else {
            pathsToCheck = repos
            logger.notice("Using \(repos.count) configured repos")
        }
        
        var repoRoots: [String] = []
        
        for repoPath in pathsToCheck {
            let runner = GitCommandRunner.shared
            let isRepo = await runner.isGitRepository(at: repoPath)
            guard isRepo else { continue }
            
            do {
                // Try git command first, fall back to filesystem
                let repoRoot: String
                if let root = try? await runner.repositoryRoot(at: repoPath) {
                    repoRoot = root
                } else if let root = runner.repositoryRootByFilesystem(at: repoPath) {
                    repoRoot = root
                } else {
                    continue
                }
                
                repoRoots.append(repoRoot)
                
                let entries = try await runner.status(at: repoRoot)
                
                let cached = entries.map { entry in
                    let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                    return CachedFileStatus(path: fullPath, status: entry.displayStatus.rawValue)
                }
                
                prefs.writeStatusCache(repoPath: repoRoot, entries: cached)
            } catch {
                logger.error("Failed to get status for \(repoPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        prefs.writeMonitoredRepoRoots(repoRoots)
    }
    
    private func findGitRepos(in directory: String, maxDepth: Int) -> [String] {
        let fm = FileManager.default
        var repos: [String] = []
        
        // Check if directory itself is a git repo
        let gitDir = (directory as NSString).appendingPathComponent(".git")
        if fm.fileExists(atPath: gitDir) {
            repos.append(directory)
            return repos // Don't recurse into git repos
        }
        
        guard maxDepth > 0 else { return repos }
        
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return repos }
        
        for item in contents {
            guard !item.hasPrefix(".") else { continue } // Skip hidden dirs
            let fullPath = (directory as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                repos.append(contentsOf: findGitRepos(in: fullPath, maxDepth: maxDepth - 1))
            }
        }
        
        return repos
    }
}
