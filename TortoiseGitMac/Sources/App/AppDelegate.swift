import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var preferencesWindowController: PreferencesWindowController?
    private var commitWindowControllers: [CommitWindowController] = []
    private var logWindowControllers: [LogWindowController] = []
    private var diffWindowControllers: [DiffWindowController] = []
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppDelegate.buildMainMenu()
        showPreferences(nil)
        
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
              url.scheme == "tortoisegitmac" else { return }
        
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
        default:
            break
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
        let controller = DiffWindowController(repositoryPath: repositoryPath, file: file)
        diffWindowControllers.append(controller)
        controller.showWindow(self)
    }
}
