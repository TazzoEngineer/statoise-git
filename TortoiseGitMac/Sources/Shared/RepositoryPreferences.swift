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

/// Manages user preferences shared between the app and the Finder extension
/// via App Group (UserDefaults suite)
class RepositoryPreferences {
    
    static let shared = RepositoryPreferences()
    
    /// App Group identifier for sharing data between app and extension
    static let appGroupIdentifier = "group.com.tortoisegitmac"
    
    private let defaults: UserDefaults
    
    private enum Keys {
        static let repositories = "monitoredRepositories"
        static let gitPath = "gitExecutablePath"
    }
    
    init() {
        defaults = UserDefaults(suiteName: RepositoryPreferences.appGroupIdentifier)
            ?? UserDefaults.standard
    }
    
    // MARK: - Git Path
    
    var gitPath: String {
        get {
            defaults.string(forKey: Keys.gitPath) ?? "/usr/bin/git"
        }
        set {
            defaults.set(newValue, forKey: Keys.gitPath)
        }
    }
    
    // MARK: - Repositories
    
    var repositories: [MonitoredRepository] {
        get {
            guard let data = defaults.data(forKey: Keys.repositories),
                  let repos = try? JSONDecoder().decode([MonitoredRepository].self, from: data) else {
                return []
            }
            return repos
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.repositories)
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
}
