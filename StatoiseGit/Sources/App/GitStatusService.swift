import Foundation
import os.log

private let logger = Logger(subsystem: "com.statoisegit.app", category: "GitStatusService")

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

        do {
            try await RepositoryPreferences.shared.withSecurityScopedAccess(to: path) { scopedURL in
                let scopedPath = scopedURL.path
                guard await runner.isGitRepository(at: scopedPath) else { return }

                let repoRoot = try await runner.repositoryRoot(at: scopedPath)
                let entries = try await runner.status(at: repoRoot)

                let cached = entries.map { entry in
                    let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                    return CachedFileStatus(path: fullPath, status: entry.displayStatus.rawValue)
                }

                RepositoryPreferences.shared.writeStatusCache(repoPath: repoRoot, entries: cached)
            }
        } catch {
            // Silently continue
        }
    }
    
    private func refreshAll() async {
        let prefs = RepositoryPreferences.shared
        let repos = prefs.enabledRepositoryPaths
        guard !repos.isEmpty else {
            logger.notice("No repositories configured; skipping filesystem scan")
            prefs.writeMonitoredRepoRoots([])
            return
        }
        
        let pathsToCheck = repos
        logger.notice("Using \(repos.count) configured repos")
        
        var repoRoots: [String] = []
        
        for repoPath in pathsToCheck {
            let runner = GitCommandRunner.shared

            do {
                try await prefs.withSecurityScopedAccess(to: repoPath) { scopedURL in
                    let scopedPath = scopedURL.path
                    let isRepo = await runner.isGitRepository(at: scopedPath)
                    guard isRepo else { return }

                    let repoRoot: String
                    if let root = try? await runner.repositoryRoot(at: scopedPath) {
                        repoRoot = root
                    } else if let root = runner.repositoryRootByFilesystem(at: scopedPath) {
                        repoRoot = root
                    } else {
                        return
                    }

                    repoRoots.append(repoRoot)

                    let entries = try await runner.status(at: repoRoot)

                    let cached = entries.map { entry in
                        let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                        return CachedFileStatus(path: fullPath, status: entry.displayStatus.rawValue)
                    }

                    prefs.writeStatusCache(repoPath: repoRoot, entries: cached)
                }
            } catch {
                logger.error("Failed to get status for \(repoPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        prefs.writeMonitoredRepoRoots(repoRoots)
    }
    
}
