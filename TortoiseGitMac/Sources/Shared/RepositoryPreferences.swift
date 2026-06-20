import Foundation

/// Represents a monitored Git repository
struct MonitoredRepository: Codable, Equatable {
    let path: String
    var isEnabled: Bool = true
    
    init(path: String, isEnabled: Bool = true) {
        self.path = path
        self.isEnabled = isEnabled
    }
}

/// Cached git file status entry for sharing between App and Extension
struct CachedFileStatus: Codable {
    let path: String
    let status: String // GitFileStatus rawValue
}

/// Manages user preferences shared between the app and the Finder extension
/// via App Group (UserDefaults suite)
class RepositoryPreferences {
    
    static let shared = RepositoryPreferences()
    
    /// App Group identifier for sharing data between app and extension
    /// Matches $(TeamIdentifierPrefix)com.tortoisegitmac in entitlements
    static let appGroupIdentifier = "7H8HPZ8M25.com.tortoisegitmac"
    
    private let defaults: UserDefaults
    
    /// Shared container directory for App Group file exchange
    private let containerURL: URL?
    
    private enum Keys {
        static let repositories = "monitoredRepositories"
        static let gitPath = "gitExecutablePath"
        static let externalDiffTool = "externalDiffToolPath"
    }
    
    init() {
        defaults = UserDefaults(suiteName: RepositoryPreferences.appGroupIdentifier)
            ?? UserDefaults.standard
        containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RepositoryPreferences.appGroupIdentifier
        )
    }
    
    // MARK: - Git Path
    
    /// Returns the real git binary path, avoiding /usr/bin/git which is an xcrun shim
    /// that doesn't work in App Sandbox.
    private static let defaultGitPath: String = {
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return "/usr/bin/git"
    }()
    
    var gitPath: String {
        get {
            defaults.string(forKey: Keys.gitPath) ?? Self.defaultGitPath
        }
        set {
            defaults.set(newValue, forKey: Keys.gitPath)
        }
    }
    
    /// External diff tool path (e.g., /Applications/DiffMerge.app, /usr/local/bin/meld)
    var externalDiffTool: String {
        get {
            defaults.string(forKey: Keys.externalDiffTool) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Keys.externalDiffTool)
        }
    }
    
    // MARK: - Repositories
    
    var repositories: [MonitoredRepository] {
        get {
            defaults.synchronize()
            guard let data = defaults.data(forKey: Keys.repositories),
                  let repos = try? JSONDecoder().decode([MonitoredRepository].self, from: data) else {
                return []
            }
            return repos
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.repositories)
                defaults.synchronize()
            }
        }
    }
    
    func addRepository(_ repo: MonitoredRepository) {
        var repos = repositories
        guard !repos.contains(where: { $0.path == repo.path }) else { return }
        repos.append(repo)
        repositories = repos
    }
    
    func removeRepository(at index: Int) {
        var repos = repositories
        guard index >= 0, index < repos.count else { return }
        repos.remove(at: index)
        repositories = repos
    }
    
    /// Returns paths of all enabled repositories
    var enabledRepositoryPaths: [String] {
        repositories.filter(\.isEnabled).map(\.path)
    }
    
    // MARK: - Git Status Cache (App Group shared file)
    
    private func statusCacheURL(forRepoPath repoPath: String) -> URL? {
        guard let container = containerURL else { return nil }
        let statusDir = container.appendingPathComponent("StatusCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
        // Use full hex encoding of repo path as filename
        let hash = repoPath.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()
        return statusDir.appendingPathComponent("\(hash).json")
    }
    
    /// Write git status cache (called by main App)
    func writeStatusCache(repoPath: String, entries: [CachedFileStatus]) {
        guard let url = statusCacheURL(forRepoPath: repoPath) else { return }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    /// Read git status cache (called by Finder Extension)
    func readStatusCache(repoPath: String) -> [CachedFileStatus]? {
        guard let url = statusCacheURL(forRepoPath: repoPath) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CachedFileStatus].self, from: data)
    }
    
    /// Write all repo roots being monitored so Extension can find them
    func writeMonitoredRepoRoots(_ roots: [String]) {
        guard let container = containerURL else { return }
        let url = container.appendingPathComponent("repo_roots.json")
        if let data = try? JSONEncoder().encode(roots) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    /// Read monitored repo roots (called by Extension)
    func readMonitoredRepoRoots() -> [String] {
        guard let container = containerURL else { return [] }
        let url = container.appendingPathComponent("repo_roots.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
