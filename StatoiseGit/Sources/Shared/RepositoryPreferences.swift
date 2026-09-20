import Foundation

/// Represents a monitored Git repository
struct MonitoredRepository: Codable, Equatable {
    let path: String
    var isEnabled: Bool = true
    var bookmarkData: Data?
    
    init(path: String, isEnabled: Bool = true, bookmarkData: Data? = nil) {
        self.path = path
        self.isEnabled = isEnabled
        self.bookmarkData = bookmarkData
    }
}

/// Cached git file status entry for sharing between App and Extension
struct CachedFileStatus: Codable {
    let path: String
    let status: String // GitFileStatus rawValue
}

/// Manages user preferences shared between the app and the Finder extension
/// via standard defaults plus a shared filesystem cache directory.
class RepositoryPreferences {
    
    static let shared = RepositoryPreferences()
    private static let appDefaultsDomain = "com.statoisegit.app"

    private static let sharedDirectoryPath = "/Users/Shared/StatoiseGitShared"
    private static let legacyPreferenceSuites = [
        "group.com.statoisegit"
    ]
    
    private let defaults: UserDefaults
    private let sharedDirectoryURL: URL
    
    private enum Keys {
        static let repositories = "monitoredRepositories"
        static let gitPath = "gitExecutablePath"
        static let externalDiffTool = "externalDiffToolPath"
    }

    private var repositoriesFileURL: URL {
        sharedDirectoryURL.appendingPathComponent("repositories.json")
    }
    
    init() {
        defaults = UserDefaults.standard
        sharedDirectoryURL = URL(fileURLWithPath: Self.sharedDirectoryPath, isDirectory: true)

        try? FileManager.default.createDirectory(at: sharedDirectoryURL, withIntermediateDirectories: true)
        migrateLegacyDefaultsIfNeeded()
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
            guard let data = repositoriesData(),
                  let repos = try? JSONDecoder().decode([MonitoredRepository].self, from: data) else {
                return []
            }
            return repos
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                try? data.write(to: repositoriesFileURL, options: .atomic)
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

    func fallbackEnabledRepositoryPathsForExtension() -> [String] {
        repositories.filter(\.isEnabled).map(\.path)
    }

    func makeMonitoredRepository(from url: URL) -> MonitoredRepository {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        return MonitoredRepository(
            path: resolvedURL.path,
            bookmarkData: makeBookmarkData(for: resolvedURL)
        )
    }

    func withSecurityScopedAccess<T>(to path: String, _ body: (URL) throws -> T) rethrows -> T {
        let resolvedURL = resolvedURL(for: path)
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try body(resolvedURL)
    }

    func withSecurityScopedAccess<T>(to path: String, _ body: (URL) async throws -> T) async rethrows -> T {
        let resolvedURL = resolvedURL(for: path)
        let didAccess = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }
        return try await body(resolvedURL)
    }

    private func resolvedURL(for path: String) -> URL {
        if let repo = repositories.first(where: { $0.path == path }) {
            if let url = resolveBookmark(for: repo) {
                return url
            }

            let fallbackURL = URL(fileURLWithPath: path)
            if let bookmarkData = makeBookmarkData(for: fallbackURL) {
                updateRepositoryBookmark(path: path, bookmarkData: bookmarkData)
            }
            return fallbackURL
        }

        return URL(fileURLWithPath: path)
    }

    private func resolveBookmark(for repo: MonitoredRepository) -> URL? {
        guard let bookmarkData = repo.bookmarkData else { return nil }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale, let refreshedData = makeBookmarkData(for: resolvedURL) {
            updateRepositoryBookmark(path: repo.path, bookmarkData: refreshedData)
        }

        return resolvedURL
    }

    private func makeBookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func updateRepositoryBookmark(path: String, bookmarkData: Data) {
        var repos = repositories
        guard let index = repos.firstIndex(where: { $0.path == path }) else { return }
        repos[index].bookmarkData = bookmarkData
        repositories = repos
    }
    
    // MARK: - Git Status Cache (shared file directory)
    
    private func statusCacheURL(forRepoPath repoPath: String) -> URL? {
        let statusDir = sharedDirectoryURL.appendingPathComponent("StatusCache", isDirectory: true)
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
        let url = sharedDirectoryURL.appendingPathComponent("repo_roots.json")
        if let data = try? JSONEncoder().encode(roots) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    /// Read monitored repo roots (called by Extension)
    func readMonitoredRepoRoots() -> [String] {
        let url = sharedDirectoryURL.appendingPathComponent("repo_roots.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func migrateLegacyDefaultsIfNeeded() {
        guard repositoriesData() == nil else { return }

        for suiteName in Self.legacyPreferenceSuites {
            guard let legacyDefaults = UserDefaults(suiteName: suiteName) else { continue }

            if let repositories = legacyDefaults.data(forKey: Keys.repositories) {
                try? repositories.write(to: repositoriesFileURL, options: .atomic)
                defaults.set(repositories, forKey: Keys.repositories)
            }
            if let gitPath = legacyDefaults.string(forKey: Keys.gitPath) {
                defaults.set(gitPath, forKey: Keys.gitPath)
            }
            if let externalDiffTool = legacyDefaults.string(forKey: Keys.externalDiffTool) {
                defaults.set(externalDiffTool, forKey: Keys.externalDiffTool)
            }
            defaults.synchronize()

            if repositoriesData() != nil {
                break
            }
        }

        if repositoriesData() == nil, let currentDefaultsRepositories = defaults.data(forKey: Keys.repositories) {
            try? currentDefaultsRepositories.write(to: repositoriesFileURL, options: .atomic)
        }
    }

    private func repositoriesData() -> Data? {
        if let data = try? Data(contentsOf: repositoriesFileURL) {
            return data
        }
        defaults.synchronize()
        return defaults.data(forKey: Keys.repositories)
    }
}
