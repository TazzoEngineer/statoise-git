import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var preferencesWindowController: PreferencesWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppDelegate.buildMainMenu()
        showPreferences(nil)
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
}
