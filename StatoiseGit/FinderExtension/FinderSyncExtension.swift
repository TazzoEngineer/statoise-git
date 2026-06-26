import Cocoa
import FinderSync
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.statoisegit.app.FinderExtension", category: "FinderSync")

class FinderSyncExtension: FIFinderSync {

    private static let bootstrapDirectoryURL = URL(fileURLWithPath: "/Users/Shared")
    
    private var statusCache: [String: GitFileStatus] = [:]
    private var monitoredDirectories: Set<URL> = []
    private var refreshTimer: Timer?
    
    // MARK: - Toolbar Item
    
    override var toolbarItemName: String {
        return "Statoise Git"
    }
    
    override var toolbarItemToolTip: String {
        return "Statoise Git Operations"
    }
    
    override var toolbarItemImage: NSImage {
        return NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Statoise Git")
            ?? NSImage(named: NSImage.networkName)!
    }
    
    override init() {
        super.init()
        
        logger.notice("FinderSyncExtension init() started")

        // Finder may not launch the extension unless at least one directory is monitored.
        // Use a benign system-wide directory to bootstrap startup without triggering Documents prompts.
        FIFinderSyncController.default().directoryURLs = [Self.bootstrapDirectoryURL]
        
        // Register badge icons for Finder overlays
        registerBadgeIcons()
        
        // Load monitored repositories from shared preferences
        reloadMonitoredDirectories()
        
        // Observe preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        
        logger.notice("FinderSyncExtension init() completed")
        
        // Periodically refresh from App Group cache
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.reloadMonitoredDirectories()
            self?.reloadAllStatusFromCache()
        }
    }
    
    deinit {
        refreshTimer?.invalidate()
    }
    
    // MARK: - Badge Registration
    
    private func registerBadgeIcons() {
        let badgeDefinitions: [(identifier: String, iconName: String, label: String)] = [
            ("Normal",      "NormalIcon",       "Up to date"),
            ("Modified",    "ModifiedIcon",     "Modified"),
            ("Added",       "AddedIcon",        "Added"),
            ("Deleted",     "DeletedIcon",      "Deleted"),
            ("Conflict",    "ConflictIcon",     "Conflict"),
            ("Unversioned", "UnversionedIcon",  "Unversioned"),
            ("Ignored",     "IgnoredIcon",      "Ignored"),
            ("Locked",      "LockedIcon",       "Locked"),
            ("ReadOnly",    "ReadOnlyIcon",     "Read Only"),
        ]
        
        let controller = FIFinderSyncController.default()
        
        for badge in badgeDefinitions {
            if let image = loadOverlayImage(named: badge.iconName) {
                controller.setBadgeImage(image, label: badge.label, forBadgeIdentifier: badge.identifier)
            } else {
                logger.error("Failed to load badge icon: \(badge.iconName, privacy: .public)")
            }
        }
    }
    
    private func loadOverlayImage(named name: String) -> NSImage? {
        let bundle = Bundle(for: type(of: self))
        
        // Xcode combines @1x/@2x PNGs into TIFF with COMBINE_HIDPI_IMAGES
        if let path = bundle.path(forResource: name, ofType: "tiff") {
            return NSImage(contentsOfFile: path)
        }
        if let path = bundle.path(forResource: name, ofType: "tiff", inDirectory: "OverlayIcons") {
            return NSImage(contentsOfFile: path)
        }
        // Fallback to PNG
        if let path = bundle.path(forResource: name, ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        if let path = bundle.path(forResource: name, ofType: "png", inDirectory: "OverlayIcons") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
    
    // MARK: - Monitored Directories
    
    private func reloadMonitoredDirectories() {
        let prefs = RepositoryPreferences.shared
        let publishedRoots = prefs.readMonitoredRepoRoots()
        let fallbackRoots = prefs.fallbackEnabledRepositoryPathsForExtension()
        let roots = publishedRoots.isEmpty ? fallbackRoots : publishedRoots
        let effectiveDirs: Set<URL>
        if roots.isEmpty {
            effectiveDirs = [Self.bootstrapDirectoryURL]
        } else {
            var dirs = Set<URL>()
            for root in roots {
                let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
                dirs.insert(rootURL)

                let parentPath = (rootURL.path as NSString).deletingLastPathComponent
                if !parentPath.isEmpty && parentPath != "/" {
                    dirs.insert(URL(fileURLWithPath: parentPath).standardizedFileURL)
                }
            }
            effectiveDirs = dirs
        }
        
        // Only update if changed
        if effectiveDirs != monitoredDirectories {
            monitoredDirectories = effectiveDirs
            FIFinderSyncController.default().directoryURLs = monitoredDirectories
            logger.notice("Monitoring \(self.monitoredDirectories.count) directories: \(self.monitoredDirectories.map(\.path).joined(separator: ", "))")
        }
    }
    
    @objc private func preferencesChanged() {
        reloadMonitoredDirectories()
    }
    
    // MARK: - Icon Overlays (Badges)
    
    override func beginObservingDirectory(at url: URL) {
        logger.notice("beginObservingDirectory: \(url.path)")
        // Load cached status from App Group
        loadStatusCacheForDirectory(url)
    }
    
    override func endObservingDirectory(at url: URL) {
        // Clean up cached status for this directory
        let prefix = url.path
        statusCache = statusCache.filter { !$0.key.hasPrefix(prefix) }
    }
    
    override func requestBadgeIdentifier(for url: URL) {
        let path = url.path
        
        if let cachedStatus = statusCache[path] {
            setBadge(for: url, status: cachedStatus)
        } else if let parentStatus = findParentDirectoryStatus(for: path) {
            statusCache[path] = parentStatus
            setBadge(for: url, status: parentStatus)
        } else {
            loadStatusFromAppGroup(for: url)
        }
    }
    
    private func setBadge(for url: URL, status: GitFileStatus) {
        let badgeIdentifier: String
        switch status {
        case .unmodified:
            badgeIdentifier = "Normal"
        case .modified:
            badgeIdentifier = "Modified"
        case .added:
            badgeIdentifier = "Added"
        case .deleted:
            badgeIdentifier = "Deleted"
        case .conflicted:
            badgeIdentifier = "Conflict"
        case .untracked:
            badgeIdentifier = "Unversioned"
        case .ignored:
            badgeIdentifier = "Ignored"
        default:
            badgeIdentifier = "Normal"
        }
        
        FIFinderSyncController.default().setBadgeIdentifier(badgeIdentifier, for: url)
    }
    
    // MARK: - Status from App Group Cache
    
    private func loadStatusCacheForDirectory(_ url: URL) {
        let prefs = RepositoryPreferences.shared
        let repoRoots = prefs.readMonitoredRepoRoots()
        let dirPath = url.path
        
        for root in repoRoots {
            if dirPath.hasPrefix(root + "/") || dirPath == root {
                if let cached = prefs.readStatusCache(repoPath: root) {
                    for entry in cached {
                        if let fileStatus = GitFileStatus(rawValue: entry.status) {
                            statusCache[entry.path] = fileStatus
                        }
                    }
                    logger.notice("Loaded \(cached.count) cached statuses from App Group for \(root)")
                }
                return
            }
        }
    }
    
    private func reloadAllStatusFromCache() {
        let prefs = RepositoryPreferences.shared
        let repoRoots = prefs.readMonitoredRepoRoots()
        var newCache: [String: GitFileStatus] = [:]
        
        for root in repoRoots {
            if let cached = prefs.readStatusCache(repoPath: root) {
                for entry in cached {
                    if let fileStatus = GitFileStatus(rawValue: entry.status) {
                        newCache[entry.path] = fileStatus
                    }
                }
            }
        }
        
        // Only update if there's a change
        if newCache != statusCache {
            statusCache = newCache
            // Re-apply badges for monitored directories
            for dir in monitoredDirectories {
                // Touch the directory to force Finder to re-request badges
                FIFinderSyncController.default().setBadgeIdentifier("", for: dir)
            }
            logger.notice("Refreshed status cache: \(newCache.count) entries")
        }
    }
    
    /// Find git repository root by walking up the directory tree looking for .git
    private func findGitRoot(from path: String) -> String? {
        let fm = FileManager.default
        var current = path
        
        // If path is a file, start from its directory
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
    
    /// Load status from the App Group shared cache written by the main app
    private func loadStatusFromAppGroup(for url: URL) {
        // Try to find repo root from known roots
        let prefs = RepositoryPreferences.shared
        let repoRoots = prefs.readMonitoredRepoRoots()
        
        // Find which repo root this file belongs to
        let filePath = url.path
        var matchingRoot: String?
        for root in repoRoots {
            if filePath.hasPrefix(root + "/") || filePath == root {
                matchingRoot = root
                break
            }
        }
        
        // Also try finding .git directory locally
        if matchingRoot == nil {
            matchingRoot = findGitRoot(from: filePath)
        }
        
        guard let repoRoot = matchingRoot else {
            return
        }
        
        // Read cached status
        if let cached = prefs.readStatusCache(repoPath: repoRoot) {
            // Populate status cache
            for entry in cached {
                if let fileStatus = GitFileStatus(rawValue: entry.status) {
                    statusCache[entry.path] = fileStatus
                }
            }
            
            if let fileStatus = statusCache[filePath] {
                setBadge(for: url, status: fileStatus)
            } else if let parentStatus = findParentDirectoryStatus(for: filePath) {
                // File inside an untracked/ignored directory inherits parent status
                statusCache[filePath] = parentStatus
                setBadge(for: url, status: parentStatus)
            } else {
                // File not in status output = tracked and unmodified
                setBadge(for: url, status: .unmodified)
            }
            
            logger.notice("Loaded \(cached.count) cached statuses for repo \(repoRoot)")
        }
    }
    
    /// Check if a file's parent directory has a status (e.g. untracked directory)
    private func findParentDirectoryStatus(for path: String) -> GitFileStatus? {
        // Walk up the path checking if any parent directory is in the status cache
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" {
            if let status = statusCache[current] {
                return status
            }
            // Also check with trailing slash removed (git status may report without)
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
    
    // MARK: - Context Menu
    
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        logger.notice("menu(for:) called, menuKind=\(String(describing: menuKind))")
        let menu = NSMenu(title: "Statoise Git")
        
        guard let target = FIFinderSyncController.default().targetedURL() else {
            return menu
        }
        
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        let path = target.path
        
        // Git Pull
        let pullItem = NSMenuItem(title: "Git Pull…", action: #selector(gitPull(_:)), keyEquivalent: "")
        pullItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Pull")
        menu.addItem(pullItem)
        
        // Git Push
        let pushItem = NSMenuItem(title: "Git Push…", action: #selector(gitPush(_:)), keyEquivalent: "")
        pushItem.image = NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: "Push")
        menu.addItem(pushItem)
        
        // Git Commit
        let commitItem = NSMenuItem(title: "Git Commit…", action: #selector(gitCommit(_:)), keyEquivalent: "")
        commitItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Commit")
        menu.addItem(commitItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Git Fetch
        let fetchItem = NSMenuItem(title: "Git Fetch…", action: #selector(gitFetch(_:)), keyEquivalent: "")
        fetchItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Fetch")
        menu.addItem(fetchItem)
        
        // Git Diff
        let diffItem = NSMenuItem(title: "Git Diff", action: #selector(gitDiff(_:)), keyEquivalent: "")
        diffItem.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Diff")
        menu.addItem(diffItem)
        
        // Git Log
        let logItem = NSMenuItem(title: "Git Log", action: #selector(gitLog(_:)), keyEquivalent: "")
        logItem.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Log")
        menu.addItem(logItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Git Add
        if !selectedItems.isEmpty {
            let addItem = NSMenuItem(title: "Git Add", action: #selector(gitAdd(_:)), keyEquivalent: "")
            addItem.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add")
            menu.addItem(addItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Stash submenu
        let stashMenu = NSMenu(title: "Stash")
        stashMenu.addItem(NSMenuItem(title: "Stash Save (include untracked)…", action: #selector(gitStashSave(_:)), keyEquivalent: ""))
        stashMenu.addItem(NSMenuItem(title: "Stash Pop", action: #selector(gitStashPop(_:)), keyEquivalent: ""))
        stashMenu.addItem(NSMenuItem(title: "Stash List", action: #selector(gitStashList(_:)), keyEquivalent: ""))
        
        let stashItem = NSMenuItem(title: "Stash", action: nil, keyEquivalent: "")
        stashItem.submenu = stashMenu
        menu.addItem(stashItem)
        // Submodule Update
        let submoduleItem = NSMenuItem(title: "Submodule Update --init", action: #selector(gitSubmoduleUpdate(_:)), keyEquivalent: "")
        submoduleItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Submodule")
        menu.addItem(submoduleItem)
        // Dangerous operations
        let resetItem = NSMenuItem(title: "Reset --hard HEAD", action: #selector(gitResetHard(_:)), keyEquivalent: "")
        resetItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Reset")
        menu.addItem(resetItem)
        let cleanItem = NSMenuItem(title: "Clean -xdf", action: #selector(gitCleanAll(_:)), keyEquivalent: "")
        cleanItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clean")
        menu.addItem(cleanItem)

        return menu
    }
    
    // MARK: - Menu Actions (delegate to main app via URL scheme)
    
    private func openMainApp(action: String, path: String, extraParams: String = "") {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "statoisegit://\(action)?path=\(encodedPath)\(extraParams)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func gitPull(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "pull", path: target.path)
    }
    
    @objc func gitPush(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "push", path: target.path)
    }
    
    @objc func gitCommit(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "commit", path: target.path)
    }
    
    @objc func gitFetch(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "fetch", path: target.path)
    }
    
    @objc func gitDiff(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        // In some Finder contexts selectedItemURLs can be empty even when invoking
        // the context menu on a concrete item. Fall back to targetedURL so App can
        // resolve the correct diff target path.
        let filePath = selectedItems.first?.path ?? target.path
        let encodedFile = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        openMainApp(action: "diff", path: target.path, extraParams: "&file=\(encodedFile)")
    }
    
    @objc func gitLog(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "log", path: target.path)
    }
    
    @objc func gitAdd(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        let files = selectedItems.map(\.lastPathComponent).joined(separator: ",")
        let encodedFiles = files.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        openMainApp(action: "add", path: target.path, extraParams: "&files=\(encodedFiles)")
    }
    
    @objc func gitStashSave(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "stash-save-prompt", path: target.path)
    }

    @objc func gitSubmoduleUpdate(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "submodule-update", path: target.path)
    }

    @objc func gitResetHard(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "reset-hard", path: target.path)
    }

    @objc func gitCleanAll(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "clean-xdf", path: target.path)
    }
    
    @objc func gitStashPop(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "stash-pop", path: target.path)
    }
    
    @objc func gitStashList(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        openMainApp(action: "stash-list", path: target.path)
    }
    
    // MARK: - Helpers
    
    private func showNotification(title: String, message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }
    
    private func showError(_ error: Error) {
        showNotification(title: "Statoise Git Error", message: error.localizedDescription)
    }
}
