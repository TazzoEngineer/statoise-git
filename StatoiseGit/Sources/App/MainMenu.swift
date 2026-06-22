import Cocoa

extension AppDelegate {
    
    /// Build the main menu programmatically (no storyboard)
    static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        
        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Statoise Git", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences…", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Statoise Git", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        
        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Git Clone…", action: #selector(AppDelegate.gitClone(_:)), keyEquivalent: "n")
        fileMenuItem.submenu = fileMenu

        // Git menu
        let gitMenuItem = NSMenuItem()
        mainMenu.addItem(gitMenuItem)
        let gitMenu = NSMenu(title: "Git")
        gitMenu.addItem(withTitle: "Stash Save (include untracked)…", action: #selector(AppDelegate.menuStashSave(_:)), keyEquivalent: "")
        gitMenu.addItem(NSMenuItem.separator())
        gitMenu.addItem(withTitle: "Submodule Update --init", action: #selector(AppDelegate.menuSubmoduleUpdate(_:)), keyEquivalent: "")
        gitMenu.addItem(NSMenuItem.separator())
        gitMenu.addItem(withTitle: "Reset --hard HEAD", action: #selector(AppDelegate.menuResetHard(_:)), keyEquivalent: "")
        gitMenu.addItem(withTitle: "Clean -xdf", action: #selector(AppDelegate.menuCleanAll(_:)), keyEquivalent: "")
        gitMenuItem.submenu = gitMenu
        
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
