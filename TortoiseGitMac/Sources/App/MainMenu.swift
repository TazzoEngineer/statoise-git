import Cocoa

extension AppDelegate {
    
    /// Build the main menu programmatically (no storyboard)
    static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TortoiseGitMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit TortoiseGitMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        
        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Git Clone…", action: #selector(AppDelegate.gitClone(_:)), keyEquivalent: "n")
        fileMenuItem.submenu = fileMenu
        
        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        
        return mainMenu
    }
}

/// Custom NSApplication subclass to set up main menu without storyboard
class TortoiseGitApplication: NSApplication {
    override init() {
        super.init()
        mainMenu = AppDelegate.buildMainMenu()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}
