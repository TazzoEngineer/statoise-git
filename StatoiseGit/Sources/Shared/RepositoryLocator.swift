import Foundation

/// Finds the git repository a path belongs to.
///
/// Both the app and the Finder extension need this, and the extension asks it for every
/// item Finder draws, so the lookup deliberately stays metadata-only: it never opens a
/// file, which matters because a sandboxed extension may stat paths whose contents it is
/// not allowed to read.
enum RepositoryLocator {

    /// The user's real home directory. `NSHomeDirectory()` is the sandbox container
    /// inside the extension, which is never what we want here.
    static let homeDirectory: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    /// Directory names that never hold anything worth badging, and that would make
    /// browsing them needlessly expensive.
    static let excludedDirectoryNames: Set<String> = [
        ".git",
        ".Trash",
        "node_modules",
        "Pods",
        ".build",
        "DerivedData"
    ]

    /// True when the path lies inside a directory we never badge.
    static func isExcluded(_ path: String) -> Bool {
        if path.hasPrefix(homeDirectory + "/Library/") {
            return true
        }
        return (path as NSString).pathComponents.contains { excludedDirectoryNames.contains($0) }
    }

    /// True when `path` is itself the root of a repository. A submodule's `.git` is a
    /// file rather than a directory, so both are accepted.
    static func isRepositoryRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// The root of the repository containing `path`, or nil when there is none.
    /// A path inside a submodule resolves to the submodule, which is what git itself
    /// reports and what the status cache is keyed by.
    static func repositoryRoot(containing path: String) -> String? {
        let fileManager = FileManager.default
        var current = path

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: current, isDirectory: &isDirectory), !isDirectory.boolValue {
            current = (current as NSString).deletingLastPathComponent
        }

        while current != "/" && !current.isEmpty {
            if isRepositoryRoot(current) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
