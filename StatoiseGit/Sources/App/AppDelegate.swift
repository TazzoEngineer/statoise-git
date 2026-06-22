import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var preferencesWindowController: PreferencesWindowController?
    private var commitWindowControllers: [CommitWindowController] = []
    private var logWindowControllers: [LogWindowController] = []
    private var diffWindowControllers: [DiffWindowController] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppDelegate.buildMainMenu()
        showPreferences(nil)
        
        // Start background git status service for Finder Extension
        GitStatusService.shared.start()
        
        // Register URL scheme handler
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPreferences(nil)
        }
        return true
    }
    
    // MARK: - Menu Actions
    
    @IBAction func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Git Menu Actions

    @IBAction func menuResetHard(_ sender: Any?) {
        guard let repo = selectRepository(prompt: "Select repository for Reset --hard HEAD") else { return }

        let alert = NSAlert()
        alert.messageText = "Reset --hard HEAD"
        alert.informativeText = "This will discard ALL uncommitted changes (staged and unstaged) in:\n\(repo)\n\nThis cannot be undone. Continue?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runGitAction(title: "Git Reset --hard HEAD", path: repo) {
            try await GitCommandRunner.shared.resetHard(at: repo)
        }
    }

    @IBAction func menuCleanAll(_ sender: Any?) {
        guard let repo = selectRepository(prompt: "Select repository for Clean -xdf") else { return }

        let alert = NSAlert()
        alert.messageText = "Clean -xdf"
        alert.informativeText = "This will permanently delete ALL untracked and ignored files in:\n\(repo)\n\nThis includes build outputs, caches, etc. This cannot be undone. Continue?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clean")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runGitAction(title: "Git Clean -xdf", path: repo) {
            try await GitCommandRunner.shared.cleanAll(at: repo)
        }
    }

    @IBAction func menuSubmoduleUpdate(_ sender: Any?) {
        guard let repo = selectRepository(prompt: "Select repository for Submodule Update") else { return }

        runGitAction(title: "Git Submodule Update --init", path: repo) {
            try await GitCommandRunner.shared.submoduleUpdate(at: repo)
        }
    }

    @IBAction func menuStashSave(_ sender: Any?) {
        guard let repo = selectRepository(prompt: "Select repository for Stash Save") else { return }

        let alert = NSAlert()
        alert.messageText = "Stash Save (include untracked)"
        alert.informativeText = "Enter a stash message (optional):"
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputField.placeholderString = "WIP on feature..."
        alert.accessoryView = inputField
        alert.addButton(withTitle: "Stash")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = inputField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        runGitAction(title: "Git Stash Save", path: repo) {
            try await GitCommandRunner.shared.stashSave(at: repo, message: message.isEmpty ? nil : message, includeUntracked: true)
        }
    }

    private func selectRepository(prompt: String) -> String? {
        let repos = RepositoryPreferences.shared.repositories
        guard !repos.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Repositories"
            alert.informativeText = "Add a repository in Preferences first."
            alert.runModal()
            return nil
        }
        if repos.count == 1 {
            return repos[0].path
        }

        let alert = NSAlert()
        alert.messageText = prompt
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 350, height: 26), pullsDown: false)
        for repo in repos {
            popup.addItem(withTitle: URL(fileURLWithPath: repo.path).lastPathComponent)
            popup.lastItem?.representedObject = repo.path as NSString
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.selectedItem?.representedObject as? String ?? repos[0].path
    }

    @IBAction func gitClone(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Destination"
        
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            
            let alert = NSAlert()
            alert.messageText = "Clone Repository"
            alert.informativeText = "Enter the repository URL:"
            
            let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
            inputField.placeholderString = "https://github.com/user/repo.git"
            alert.accessoryView = inputField
            alert.addButton(withTitle: "Clone")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                let repoURL = inputField.stringValue
                guard !repoURL.isEmpty else { return }
                
                Task {
                    do {
                        try await GitCommandRunner.shared.clone(
                            repositoryURL: repoURL,
                            destination: url.path
                        )
                    } catch {
                        await MainActor.run {
                            let errorAlert = NSAlert(error: error)
                            errorAlert.runModal()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - URL Scheme Handler
    
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "statoisegit" else { return }
        
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value else { return }
        
        let file = components.queryItems?.first(where: { $0.name == "file" })?.value
        
        NSApp.activate(ignoringOtherApps: true)
        
        switch url.host {
        case "commit":
            showCommitWindow(repositoryPath: path)
        case "log":
            showLogWindow(repositoryPath: path)
        case "diff":
            showDiffWindow(repositoryPath: path, file: file)
        case "stash-list":
            showStashList(repositoryPath: path)
        case "pull":
            runGitAction(title: "Git Pull", path: path) { try await GitCommandRunner.shared.pull(at: path) }
        case "push":
            runGitAction(title: "Git Push", path: path) { try await GitCommandRunner.shared.push(at: path) }
        case "fetch":
            runGitAction(title: "Git Fetch", path: path) { try await GitCommandRunner.shared.fetch(at: path) }
        case "add":
            let files = components.queryItems?.first(where: { $0.name == "files" })?.value?
                .components(separatedBy: ",") ?? []
            if !files.isEmpty {
                runGitAction(title: "Git Add", path: path) { try await GitCommandRunner.shared.add(at: path, files: files) }
            }
        case "stash-save":
            runGitAction(title: "Git Stash Save", path: path) { try await GitCommandRunner.shared.stashSave(at: path, message: nil, includeUntracked: true) }
        case "stash-save-prompt":
            showStashSavePrompt(repositoryPath: path)
        case "stash-pop":
            runGitAction(title: "Git Stash Pop", path: path) { try await GitCommandRunner.shared.stashPop(at: path) }
        case "reset-hard":
            showResetHardConfirmation(repositoryPath: path)
        case "clean-xdf":
            showCleanConfirmation(repositoryPath: path)
        case "submodule-update":
            runGitAction(title: "Git Submodule Update --init", path: path) { try await GitCommandRunner.shared.submoduleUpdate(at: path) }
        default:
            break
        }
    }
    
    private func runGitAction(title: String, path: String, action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                // Refresh status cache after git operation
                await GitStatusService.shared.refreshRepository(at: path)
                
                // Show success notification
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = "Completed successfully."
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "\(title) Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    private func showResetHardConfirmation(repositoryPath: String) {
        let alert = NSAlert()
        alert.messageText = "Reset --hard HEAD"
        alert.informativeText = "This will discard ALL uncommitted changes (staged and unstaged) in:\n\(repositoryPath)\n\nThis cannot be undone. Continue?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runGitAction(title: "Git Reset --hard HEAD", path: repositoryPath) {
            try await GitCommandRunner.shared.resetHard(at: repositoryPath)
        }
    }

    private func showCleanConfirmation(repositoryPath: String) {
        let alert = NSAlert()
        alert.messageText = "Clean -xdf"
        alert.informativeText = "This will permanently delete ALL untracked and ignored files in:\n\(repositoryPath)\n\nThis includes build outputs, caches, etc. This cannot be undone. Continue?"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clean")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runGitAction(title: "Git Clean -xdf", path: repositoryPath) {
            try await GitCommandRunner.shared.cleanAll(at: repositoryPath)
        }
    }

    private func showStashSavePrompt(repositoryPath: String) {
        let alert = NSAlert()
        alert.messageText = "Stash Save (include untracked)"
        alert.informativeText = "Enter a stash message (optional):"
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        inputField.placeholderString = "WIP on feature..."
        alert.accessoryView = inputField
        alert.addButton(withTitle: "Stash")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = inputField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let message = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        runGitAction(title: "Git Stash Save", path: repositoryPath) {
            try await GitCommandRunner.shared.stashSave(at: repositoryPath, message: message.isEmpty ? nil : message, includeUntracked: true)
        }
    }

    private func showStashList(repositoryPath: String) {
        Task {
            do {
                let output = try await GitCommandRunner.shared.stashList(at: repositoryPath)
                let alert = NSAlert()
                alert.messageText = "Git Stash List"
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    alert.informativeText = "No stashes found."
                } else {
                    alert.informativeText = output
                }
                alert.alertStyle = .informational
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Git Stash List Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    private func showCommitWindow(repositoryPath: String) {
        let controller = CommitWindowController(repositoryPath: repositoryPath)
        commitWindowControllers.append(controller)
        controller.showWindow(self)
    }
    
    private func showLogWindow(repositoryPath: String) {
        let controller = LogWindowController(repositoryPath: repositoryPath)
        logWindowControllers.append(controller)
        controller.showWindow(self)
    }
    
    private func showDiffWindow(repositoryPath: String, file: String?) {
        let externalTool = RepositoryPreferences.shared.externalDiffTool

        if let selectedPath = file, !selectedPath.isEmpty {
            Task {
                do {
                    let runner = GitCommandRunner.shared
                    let superRoot = try await runner.repositoryRoot(at: repositoryPath)
                    let normalizedSelectedPath = URL(fileURLWithPath: selectedPath).resolvingSymlinksInPath().standardizedFileURL.path

                    // Selected submodule directory itself: show SHA diff summary in built-in viewer.
                    if runner.isGitRepositoryRootByFilesystem(at: normalizedSelectedPath),
                       let superRelative = relativePath(from: superRoot, to: normalizedSelectedPath),
                       !superRelative.isEmpty {
                        // Get recorded SHA in parent index
                        let indexSHA: String
                        if let entry = try? await runner.treeEntry(at: superRoot, revision: "HEAD", file: superRelative) {
                            indexSHA = entry.object
                        } else {
                            indexSHA = "(unknown)"
                        }
                        // Get actual HEAD of submodule
                        let submoduleHead = (try? await runner.repositoryHead(at: normalizedSelectedPath)) ?? "(unknown)"
                        // Get diff log
                        let diffLog = (try? await runner.diff(at: superRoot, file: superRelative)) ?? ""

                        let summary = """
                        Submodule: \(superRelative)
                        Parent expects: \(indexSHA)
                        Submodule HEAD: \(submoduleHead)
                        \(indexSHA == submoduleHead ? "(commits match)" : "(commits differ)")

                        \(diffLog.isEmpty ? "(No staged/unstaged commit pointer change)" : diffLog)
                        """

                        await MainActor.run {
                            let controller = DiffWindowController(
                                repositoryPath: superRoot,
                                diffContent: summary,
                                title: superRelative
                            )
                            self.diffWindowControllers.append(controller)
                            controller.showWindow(self)
                        }
                        return
                    }

                    // Path inside a nested repository (submodule): use nested repo root and file-relative path.
                    var isDir: ObjCBool = false
                    let selectedDir: String
                    if FileManager.default.fileExists(atPath: normalizedSelectedPath, isDirectory: &isDir), isDir.boolValue {
                        selectedDir = normalizedSelectedPath
                    } else {
                        selectedDir = (normalizedSelectedPath as NSString).deletingLastPathComponent
                    }
                    let selectedRepoRoot = try await runner.repositoryRoot(at: selectedDir)
                    if selectedRepoRoot != superRoot,
                       let nestedRelative = relativePath(from: selectedRepoRoot, to: normalizedSelectedPath),
                       !nestedRelative.isEmpty {
                        if !externalTool.isEmpty {
                            let headContent = try await runner.exportFileAtRevision(
                                at: selectedRepoRoot, hash: "HEAD", file: nestedRelative
                            )
                            let workingFile = try await runner.exportWorkingTreeItemForDiff(
                                at: selectedRepoRoot, file: nestedRelative
                            )
                            await MainActor.run {
                                ExternalDiffLauncher.launch(tool: externalTool, oldFile: headContent, newFile: workingFile)
                            }
                        } else {
                            await MainActor.run {
                                let controller = DiffWindowController(repositoryPath: selectedRepoRoot, file: nestedRelative)
                                self.diffWindowControllers.append(controller)
                                controller.showWindow(self)
                            }
                        }
                        return
                    }

                    // Normal superproject path: resolve absolute path to superproject-relative path.
                    let superRelativePath = relativePath(from: superRoot, to: normalizedSelectedPath) ?? selectedPath

                    if !externalTool.isEmpty {
                        let headContent = try await runner.exportFileAtRevision(
                            at: superRoot, hash: "HEAD", file: superRelativePath
                        )
                        let workingFile = try await runner.exportWorkingTreeItemForDiff(
                            at: superRoot, file: superRelativePath
                        )
                        await MainActor.run {
                            ExternalDiffLauncher.launch(tool: externalTool, oldFile: headContent, newFile: workingFile)
                        }
                    } else {
                        await MainActor.run {
                            let controller = DiffWindowController(repositoryPath: superRoot, file: superRelativePath)
                            self.diffWindowControllers.append(controller)
                            controller.showWindow(self)
                        }
                    }
                } catch {
                    await MainActor.run {
                        let controller = DiffWindowController(repositoryPath: repositoryPath, file: selectedPath)
                        self.diffWindowControllers.append(controller)
                        controller.showWindow(self)
                    }
                }
            }
        } else {
            let controller = DiffWindowController(repositoryPath: repositoryPath, file: file)
            diffWindowControllers.append(controller)
            controller.showWindow(self)
        }
    }

    private func relativePath(from root: String, to path: String) -> String? {
        let normalizedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path

        if normalizedPath == normalizedRoot {
            return ""
        }

        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedPath.hasPrefix(prefix) else {
            return nil
        }

        return String(normalizedPath.dropFirst(prefix.count))
    }
}
