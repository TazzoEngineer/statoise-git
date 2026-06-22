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
            showLogWindow(repositoryPath: path) // Reuse log viewer for now
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
            runGitAction(title: "Git Stash Save", path: path) { try await GitCommandRunner.shared.stashSave(at: path, message: nil) }
        case "stash-pop":
            runGitAction(title: "Git Stash Pop", path: path) { try await GitCommandRunner.shared.stashPop(at: path) }
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
