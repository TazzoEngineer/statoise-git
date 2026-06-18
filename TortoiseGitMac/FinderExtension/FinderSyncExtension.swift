import Cocoa
import FinderSync

class FinderSyncExtension: FIFinderSync {
    
    private var statusCache: [String: GitFileStatus] = [:]
    private var monitoredDirectories: Set<URL> = []
    
    override init() {
        super.init()
        
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
                NSLog("TortoiseGitMac: Failed to load badge icon: \(badge.iconName)")
            }
        }
    }
    
    private func loadOverlayImage(named name: String) -> NSImage? {
        // Load from the extension bundle's Resources/OverlayIcons
        guard let bundlePath = Bundle(for: type(of: self)).path(forResource: name, ofType: "png", inDirectory: "OverlayIcons") else {
            // Fallback: try without subdirectory
            guard let path = Bundle(for: type(of: self)).path(forResource: name, ofType: "png") else {
                return nil
            }
            return NSImage(contentsOfFile: path)
        }
        return NSImage(contentsOfFile: bundlePath)
    }
    
    // MARK: - Monitored Directories
    
    private func reloadMonitoredDirectories() {
        let repos = RepositoryPreferences.shared.enabledRepositoryPaths
        monitoredDirectories = Set(repos.compactMap { URL(fileURLWithPath: $0) })
        
        FIFinderSyncController.default().directoryURLs = monitoredDirectories
    }
    
    @objc private func preferencesChanged() {
        reloadMonitoredDirectories()
    }
    
    // MARK: - Icon Overlays (Badges)
    
    override func beginObservingDirectory(at url: URL) {
        // Start watching the directory for Git status changes
        Task {
            await refreshStatusForDirectory(url)
        }
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
        } else {
            // Refresh status async
            Task {
                await refreshStatusForFile(url)
            }
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
    
    private func refreshStatusForDirectory(_ url: URL) async {
        let runner = GitCommandRunner.shared
        
        guard await runner.isGitRepository(at: url.path) else { return }
        
        do {
            let entries = try await runner.status(at: url.path)
            let repoRoot = try await runner.repositoryRoot(at: url.path)
            
            for entry in entries {
                let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                statusCache[fullPath] = entry.displayStatus
            }
            
            // Request badge refresh for visible items
            for entry in entries {
                let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                let fileURL = URL(fileURLWithPath: fullPath)
                setBadge(for: fileURL, status: entry.displayStatus)
            }
        } catch {
            NSLog("TortoiseGitMac: Failed to get status for \(url.path): \(error)")
        }
    }
    
    private func refreshStatusForFile(_ url: URL) async {
        // Find repository root for this file
        let dir = url.deletingLastPathComponent().path
        let runner = GitCommandRunner.shared
        
        guard await runner.isGitRepository(at: dir) else { return }
        
        do {
            let repoRoot = try await runner.repositoryRoot(at: dir)
            let entries = try await runner.status(at: repoRoot)
            
            for entry in entries {
                let fullPath = (repoRoot as NSString).appendingPathComponent(entry.filePath)
                statusCache[fullPath] = entry.displayStatus
            }
            
            if let cachedStatus = statusCache[url.path] {
                setBadge(for: url, status: cachedStatus)
            } else {
                // File is tracked and unmodified
                setBadge(for: url, status: .unmodified)
            }
        } catch {
            NSLog("TortoiseGitMac: Failed to refresh status for \(url.path): \(error)")
        }
    }
    
    // MARK: - Context Menu
    
    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "TortoiseGitMac")
        
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
        
        // Stash submenu
        let stashMenu = NSMenu(title: "Stash")
        stashMenu.addItem(NSMenuItem(title: "Stash Save…", action: #selector(gitStashSave(_:)), keyEquivalent: ""))
        stashMenu.addItem(NSMenuItem(title: "Stash Pop", action: #selector(gitStashPop(_:)), keyEquivalent: ""))
        stashMenu.addItem(NSMenuItem(title: "Stash List", action: #selector(gitStashList(_:)), keyEquivalent: ""))
        
        let stashItem = NSMenuItem(title: "Stash", action: nil, keyEquivalent: "")
        stashItem.submenu = stashMenu
        menu.addItem(stashItem)
        
        return menu
    }
    
    // MARK: - Menu Actions
    
    @objc func gitPull(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        Task {
            do {
                try await GitCommandRunner.shared.pull(at: target.path)
                await refreshStatusForDirectory(target)
                showNotification(title: "Git Pull", message: "Pull completed successfully.")
            } catch {
                showError(error)
            }
        }
    }
    
    @objc func gitPush(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        Task {
            do {
                try await GitCommandRunner.shared.push(at: target.path)
                showNotification(title: "Git Push", message: "Push completed successfully.")
            } catch {
                showError(error)
            }
        }
    }
    
    @objc func gitCommit(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        // Open commit dialog in the main app
        let url = URL(string: "tortoisegitmac://commit?path=\(target.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
        NSWorkspace.shared.open(url)
    }
    
    @objc func gitFetch(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        Task {
            do {
                try await GitCommandRunner.shared.fetch(at: target.path)
                showNotification(title: "Git Fetch", message: "Fetch completed successfully.")
            } catch {
                showError(error)
            }
        }
    }
    
    @objc func gitDiff(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        
        let filePath = selectedItems.first?.path ?? ""
        let encodedPath = target.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedFile = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        
        if let url = URL(string: "tortoisegitmac://diff?path=\(encodedPath)&file=\(encodedFile)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func gitLog(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        let encodedPath = target.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "tortoisegitmac://log?path=\(encodedPath)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc func gitAdd(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        let selectedItems = FIFinderSyncController.default().selectedItemURLs() ?? []
        
        let files = selectedItems.map(\.lastPathComponent)
        guard !files.isEmpty else { return }
        
        Task {
            do {
                try await GitCommandRunner.shared.add(at: target.path, files: files)
                await refreshStatusForDirectory(target)
                showNotification(title: "Git Add", message: "Files staged successfully.")
            } catch {
                showError(error)
            }
        }
    }
    
    @objc func gitStashSave(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        Task {
            do {
                try await GitCommandRunner.shared.stashSave(at: target.path, message: nil)
                await refreshStatusForDirectory(target)
                showNotification(title: "Git Stash", message: "Changes stashed successfully.")
            } catch {
                showError(error)
            }
        }
    }
    
    @objc func gitStashPop(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        Task {
            do {
                try await GitCommandRunner.shared.stashPop(at: target.path)
                await refreshStatusForDirectory(target)
                showNotification(title: "Git Stash Pop", message: "Stash applied successfully.")
            } catch {
                showError(error)
            }
        }
    }
    
    @objc func gitStashList(_ sender: AnyObject?) {
        guard let target = FIFinderSyncController.default().targetedURL() else { return }
        
        let encodedPath = target.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "tortoisegitmac://stash-list?path=\(encodedPath)") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Helpers
    
    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    private func showError(_ error: Error) {
        showNotification(title: "TortoiseGitMac Error", message: error.localizedDescription)
    }
}
