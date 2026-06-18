import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Set up main menu before run
app.mainMenu = AppDelegate.buildMainMenu()

app.run()
