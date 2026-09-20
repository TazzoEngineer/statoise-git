import Cocoa
import FinderSync
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.statoisegit.app.FinderExtension", category: "FinderSync")

class FinderSyncExtension: FIFinderSync {

    /// Everything under the user's home is monitored, so a repository is picked up by
    /// browsing to it — no registration needed. Repositories elsewhere (other volumes)
    /// still have to be listed, and get an entry of their own.
    private static let homeDirectoryURL = URL(fileURLWithPath: RepositoryLocator.homeDirectory, isDirectory: true)

    private var statusCache: [String: GitFileStatus] = [:]
    private var monitoredDirectories: Set<URL> = []
    private var refreshTimer: Timer?

    /// Per directory Finder is showing: the repository it lives in, and the repository
    /// folders drawn inside it. Published to the app so it knows what to run git status
    /// on — and which of those the user is actually working in.
    private var insideRepositoryRoots: [String: String] = [:]
    private var listedRepositoryRoots: [String: Set<String>] = [:]
    private var publishedRepositories = ObservedRepositories()
    private var lastPublishedAt = Date.distantPast

    /// Repository roots whose status cache has already been merged into `statusCache`,
    /// so a folder of clean files does not re-read the same JSON once per item.
    private var loadedRepositoryRoots: Set<String> = []

    /// Directory path -> repository root (nil means "not in a repository"), so the walk
    /// up the tree happens once per directory instead of once per drawn item.
    private var repositoryRootCache: [String: String?] = [:]
    private var repositoryRootCacheStamp = Date()
    
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

        // Finder does not launch the extension unless at least one directory is monitored.
        FIFinderSyncController.default().directoryURLs = [Self.homeDirectoryURL]
        
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
            self?.publishObservedRoots()
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
        var dirs: Set<URL> = [Self.homeDirectoryURL]

        // Repositories outside the home directory need an explicit entry, plus their
        // parent so that the repository folder itself can be badged.
        let homePrefix = RepositoryLocator.homeDirectory + "/"
        for root in RepositoryPreferences.shared.readMonitoredRepoRoots() where !root.hasPrefix(homePrefix) {
            let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL
            dirs.insert(rootURL)

            let parentPath = (rootURL.path as NSString).deletingLastPathComponent
            if !parentPath.isEmpty && parentPath != "/" {
                dirs.insert(URL(fileURLWithPath: parentPath).standardizedFileURL)
            }
        }

        guard dirs != monitoredDirectories else { return }
        monitoredDirectories = dirs
        FIFinderSyncController.default().directoryURLs = dirs
        logger.notice("Monitoring \(self.monitoredDirectories.count) directories: \(self.monitoredDirectories.map(\.path).joined(separator: ", "))")
    }

    // MARK: - Repository Lookup

    /// The repository root an item belongs to, resolved per directory and cached.
    private func repositoryRoot(forItemAt path: String) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        if let root = cachedRepositoryRoot(forDirectory: parent) {
            return root
        }

        // A repository folder listed inside a directory that is not itself under git:
        // one stat for its own .git is far cheaper than walking up from every sibling.
        if RepositoryLocator.isRepositoryRoot(path) {
            noteRepository(path, drawnIn: parent)
            return path
        }
        return nil
    }

    private func cachedRepositoryRoot(forDirectory directory: String) -> String? {
        // Repositories get cloned and deleted while Finder stays open, so the cache is
        // a short-lived optimisation rather than a permanent answer.
        if Date().timeIntervalSince(repositoryRootCacheStamp) > 30 {
            repositoryRootCache.removeAll()
            repositoryRootCacheStamp = Date()
        }

        if let cached = repositoryRootCache[directory] {
            return cached
        }

        let root = RepositoryLocator.repositoryRoot(containing: directory)
        repositoryRootCache[directory] = root
        return root
    }

    /// Record a repository that is visible in a directory Finder is showing, so the app
    /// keeps its status fresh.
    private func noteRepository(_ root: String, drawnIn directory: String) {
        guard var roots = listedRepositoryRoots[directory] else { return }
        guard roots.insert(root).inserted else { return }
        listedRepositoryRoots[directory] = roots
        publishObservedRoots()
    }

    private var observedRepositoryRoots: Set<String> {
        Set(insideRepositoryRoots.values).union(listedRepositoryRoots.values.joined())
    }

    private func publishObservedRoots() {
        let inside = Set(insideRepositoryRoots.values)
        let observed = ObservedRepositories(
            inside: inside.sorted(),
            listed: Set(listedRepositoryRoots.values.joined()).subtracting(inside).sorted()
        )

        let changed = observed.inside != publishedRepositories.inside
            || observed.listed != publishedRepositories.listed
        // Re-stamp even when nothing changed: the app treats an unrefreshed file as
        // "the extension is gone" and falls back to the always-watched list.
        let stale = Date().timeIntervalSince(lastPublishedAt) > 15
        guard changed || stale else { return }

        publishedRepositories = observed
        lastPublishedAt = Date()
        RepositoryPreferences.shared.writeObservedRepositories(observed)
        if changed {
            logger.notice("Observing \(observed.inside.count) repositories, \(observed.listed.count) listed")
        }
    }
    
    @objc private func preferencesChanged() {
        reloadMonitoredDirectories()
    }
    
    // MARK: - Icon Overlays (Badges)
    
    override func beginObservingDirectory(at url: URL) {
        logger.notice("beginObservingDirectory: \(url.path)")

        let directory = url.path
        if let root = cachedRepositoryRoot(forDirectory: directory) {
            insideRepositoryRoots[directory] = root
            loadStatusCache(forRepositoryRoot: root)
        }
        if listedRepositoryRoots[directory] == nil {
            listedRepositoryRoots[directory] = []
        }
        publishObservedRoots()
    }
    
    override func endObservingDirectory(at url: URL) {
        // Clean up cached status for this directory
        let prefix = url.path
        statusCache = statusCache.filter { !$0.key.hasPrefix(prefix) }

        insideRepositoryRoots.removeValue(forKey: url.path)
        listedRepositoryRoots.removeValue(forKey: url.path)
        publishObservedRoots()
    }
    
    override func requestBadgeIdentifier(for url: URL) {
        let path = url.path

        // Finder asks about every item it draws, most of which have nothing to do with
        // git, so the cheap rejections come first.
        guard !RepositoryLocator.isExcluded(path) else { return }

        if let cachedStatus = statusCache[path] {
            setBadge(for: url, status: cachedStatus)
            return
        }

        guard let repositoryRoot = repositoryRoot(forItemAt: path) else { return }

        if let parentStatus = findParentDirectoryStatus(for: path) {
            statusCache[path] = parentStatus
            setBadge(for: url, status: parentStatus)
            return
        }

        applyBadge(for: url, repositoryRoot: repositoryRoot)
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
    
    /// Merge one repository's cached status, at most once per refresh cycle.
    @discardableResult
    private func loadStatusCache(forRepositoryRoot root: String) -> Bool {
        if loadedRepositoryRoots.contains(root) { return true }
        guard let cached = RepositoryPreferences.shared.readStatusCache(repoPath: root) else {
            // The app has not reported on this repository yet. It will once it picks up
            // the observation request, and the refresh timer re-badges then.
            return false
        }

        loadedRepositoryRoots.insert(root)
        for entry in cached {
            if let fileStatus = GitFileStatus(rawValue: entry.status) {
                statusCache[entry.path] = fileStatus
            }
        }
        logger.notice("Loaded \(cached.count) cached statuses for \(root)")
        return true
    }

    private func applyBadge(for url: URL, repositoryRoot root: String) {
        guard loadStatusCache(forRepositoryRoot: root) else { return }

        let path = url.path
        if let fileStatus = statusCache[path] {
            setBadge(for: url, status: fileStatus)
        } else if let parentStatus = findParentDirectoryStatus(for: path) {
            // File inside an untracked/ignored directory inherits parent status
            statusCache[path] = parentStatus
            setBadge(for: url, status: parentStatus)
        } else {
            // File not in status output = tracked and unmodified
            setBadge(for: url, status: .unmodified)
        }
    }
    
    private func reloadAllStatusFromCache() {
        let prefs = RepositoryPreferences.shared
        let repoRoots = observedRepositoryRoots
        var newCache: [String: GitFileStatus] = [:]
        var loaded: Set<String> = []
        
        for root in repoRoots {
            if let cached = prefs.readStatusCache(repoPath: root) {
                loaded.insert(root)
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
            loadedRepositoryRoots = loaded
            // Touch the directories Finder is showing to force it to re-request badges
            for dir in listedRepositoryRoots.keys {
                FIFinderSyncController.default().setBadgeIdentifier("", for: URL(fileURLWithPath: dir))
            }
            logger.notice("Refreshed status cache: \(newCache.count) entries")
        }
    }
    
    /// Check if a file's parent directory has a status (e.g. untracked directory)
    private func findParentDirectoryStatus(for path: String) -> GitFileStatus? {
        // Walk up the path checking if any parent directory is in the status cache
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" {
            if let status = statusCache[current] {
                // Only untracked/ignored directories are reported by git as a single
                // entry whose children genuinely share the status. Other statuses
                // (notably a `modified` submodule pointer in a superproject) must NOT
                // be propagated to their children, otherwise every file inside a
                // clean submodule would be incorrectly badged as modified.
                if status == .untracked || status == .ignored {
                    return status
                }
                return nil
            }
            // Also check with trailing slash removed (git status may report without)
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
    
    // MARK: - Context Menu

    /// The path a menu action should act on: the targeted URL when it belongs to a
    /// repository, otherwise the first selected item that does. `nil` means nothing in
    /// the current Finder context is under git control.
    private func repositoryTargetPath() -> String? {
        let controller = FIFinderSyncController.default()
        var candidates: [String] = []
        if let target = controller.targetedURL() {
            candidates.append(target.path)
        }
        candidates.append(contentsOf: (controller.selectedItemURLs() ?? []).map(\.path))
        return candidates.first { RepositoryLocator.repositoryRoot(containing: $0) != nil }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        logger.notice("menu(for:) called, menuKind=\(String(describing: menuKind))")
        let menu = NSMenu(title: "Statoise Git")
        
        guard let target = FIFinderSyncController.default().targetedURL() else {
            return menu
        }

        // Finder hands us whole directory trees, so this is called for plenty of folders
        // that have nothing to do with git. Offering Pull/Push/Reset there is noise at
        // best and an error dialog at worst, so build no menu at all.
        guard repositoryTargetPath() != nil else {
            logger.notice("menu(for:) skipped, not a git repository: \(target.path)")
            return menu
        }

        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        let targetIsInRepository = RepositoryLocator.repositoryRoot(containing: target.path) != nil
        
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
        
        // Git Add passes names relative to the targeted container, so it only makes
        // sense when that container is itself inside a repository.
        if !selectedItems.isEmpty && targetIsInRepository {
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
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "pull", path: path)
    }
    
    @objc func gitPush(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "push", path: path)
    }
    
    @objc func gitCommit(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "commit", path: path)
    }
    
    @objc func gitFetch(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "fetch", path: path)
    }
    
    @objc func gitDiff(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        // In some Finder contexts selectedItemURLs can be empty even when invoking
        // the context menu on a concrete item. Fall back to the resolved repository
        // path so App can resolve the correct diff target path.
        let filePath = selectedItems.first?.path ?? path
        let encodedFile = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        openMainApp(action: "diff", path: path, extraParams: "&file=\(encodedFile)")
    }
    
    @objc func gitLog(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "log", path: path)
    }
    
    @objc func gitAdd(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        let files = selectedItems.map(\.lastPathComponent).joined(separator: ",")
        let encodedFiles = files.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        openMainApp(action: "add", path: target.path, extraParams: "&files=\(encodedFiles)")
    }
    
    @objc func gitStashSave(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "stash-save-prompt", path: path)
    }

    @objc func gitSubmoduleUpdate(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "submodule-update", path: path)
    }

    @objc func gitResetHard(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "reset-hard", path: path)
    }

    @objc func gitCleanAll(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "clean-xdf", path: path)
    }
    
    @objc func gitStashPop(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "stash-pop", path: path)
    }
    
    @objc func gitStashList(_ sender: AnyObject?) {
        guard let path = repositoryTargetPath() else { return }
        openMainApp(action: "stash-list", path: path)
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
