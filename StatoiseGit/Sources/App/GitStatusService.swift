import Foundation
import os.log

private let logger = Logger(subsystem: "com.statoisegit.app", category: "GitStatusService")

/// Background service that periodically runs git status on monitored repositories
/// and writes the results to the shared cache directory for the Finder Extension to read.
///
/// An actor with a single refresh loop rather than a timer: a cycle can easily outlast its
/// own interval (a directory of clones publishes dozens of repositories at once), and two
/// cycles running at the same time corrupt the bookkeeping they share.
actor GitStatusService {
    
    static let shared = GitStatusService()
    
    private var refreshTask: Task<Void, Never>?
    /// One folder can list dozens of repositories (a directory of clones), and running
    /// git status on all of them every cycle costs more CPU than the badges are worth.
    /// Those get a slower cadence and a per-cycle budget; the repository being browsed
    /// into still refreshes every cycle.
    private let listedRefreshInterval: TimeInterval = 30.0
    private let maxListedRefreshesPerCycle = 6
    private let observationTimeout: TimeInterval = 45.0
    private var lastRefreshed: [String: Date] = [:]
    
    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                // Sleeping after the work keeps slow cycles from stacking up.
                try? await Task.sleep(nanoseconds: UInt64(3.0 * 1_000_000_000))
            }
        }
    }
    
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
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
        // The configured repositories are watched at all times; the rest is whatever the
        // Finder extension reports it is showing, so browsing to a repository is enough.
        let alwaysWatched = prefs.enabledRepositoryPaths
        // Finder shuts the extension down when no window needs it, leaving its last
        // request behind; anything that stopped being re-stamped is not being shown.
        let published = prefs.readObservedRepositories()
        let observed = published.isFresh(within: observationTimeout) ? published : ObservedRepositories()

        let urgent = Set(alwaysWatched + observed.inside)
        let now = Date()
        let due = observed.listed
            .filter { !urgent.contains($0) }
            .filter { now.timeIntervalSince(lastRefreshed[$0] ?? .distantPast) >= listedRefreshInterval }
            .prefix(maxListedRefreshesPerCycle)

        let known = urgent.union(observed.listed)
        let pathsToCheck = urgent.sorted() + due

        guard !known.isEmpty else {
            logger.notice("Nothing to watch; skipping filesystem scan")
            prefs.writeMonitoredRepoRoots([])
            prefs.pruneStatusCaches(keeping: [])
            lastRefreshed.removeAll()
            return
        }

        lastRefreshed = lastRefreshed.filter { known.contains($0.key) }
        logger.notice("Refreshing \(pathsToCheck.count) of \(known.count) repos")
        
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
                    lastRefreshed[repoPath] = Date()

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
        
        // Everything known stays cached; only this cycle's slice was recomputed.
        prefs.writeMonitoredRepoRoots(known.union(repoRoots).sorted())
        prefs.pruneStatusCaches(keeping: Array(known.union(repoRoots)))
    }
    
}
