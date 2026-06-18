import Cocoa

class PreferencesWindowController: NSWindowController {
    
    private var repositoryListView: NSTableView!
    private var repositories: [MonitoredRepository] = []
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TortoiseGitMac Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        setupUI()
        loadRepositories()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    private func setupUI() {
        guard let window = window else { return }
        
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Tab View
        let tabView = NSTabView(frame: contentView.bounds.insetBy(dx: 10, dy: 10))
        tabView.autoresizingMask = [.width, .height]
        
        // Repositories Tab
        let repoTab = NSTabViewItem(identifier: "repositories")
        repoTab.label = "Repositories"
        repoTab.view = createRepositoriesView()
        tabView.addTabViewItem(repoTab)
        
        // Git Settings Tab
        let gitTab = NSTabViewItem(identifier: "git")
        gitTab.label = "Git Settings"
        gitTab.view = createGitSettingsView()
        tabView.addTabViewItem(gitTab)
        
        contentView.addSubview(tabView)
        window.contentView = contentView
    }
    
    private func createRepositoriesView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 340))
        
        // Table View
        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 50, width: 560, height: 280))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        
        repositoryListView = NSTableView()
        repositoryListView.delegate = self
        repositoryListView.dataSource = self
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Repository Path"
        column.width = 540
        repositoryListView.addTableColumn(column)
        repositoryListView.headerView = NSTableHeaderView()
        
        scrollView.documentView = repositoryListView
        view.addSubview(scrollView)
        
        // Add/Remove buttons
        let addButton = NSButton(title: "+", target: self, action: #selector(addRepository))
        addButton.frame = NSRect(x: 10, y: 10, width: 30, height: 30)
        view.addSubview(addButton)
        
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeRepository))
        removeButton.frame = NSRect(x: 45, y: 10, width: 30, height: 30)
        view.addSubview(removeButton)
        
        return view
    }
    
    private func createGitSettingsView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 340))
        
        let gitPathLabel = NSTextField(labelWithString: "Git Executable Path:")
        gitPathLabel.frame = NSRect(x: 20, y: 290, width: 150, height: 20)
        view.addSubview(gitPathLabel)
        
        let gitPathField = NSTextField(frame: NSRect(x: 180, y: 288, width: 350, height: 24))
        gitPathField.stringValue = RepositoryPreferences.shared.gitPath
        gitPathField.target = self
        gitPathField.action = #selector(gitPathChanged(_:))
        view.addSubview(gitPathField)
        
        return view
    }
    
    // MARK: - Actions
    
    @objc private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            
            let repo = MonitoredRepository(path: url.path)
            RepositoryPreferences.shared.addRepository(repo)
            self?.loadRepositories()
        }
    }
    
    @objc private func removeRepository() {
        let selectedRow = repositoryListView.selectedRow
        guard selectedRow >= 0, selectedRow < repositories.count else { return }
        
        RepositoryPreferences.shared.removeRepository(at: selectedRow)
        loadRepositories()
    }
    
    @objc private func gitPathChanged(_ sender: NSTextField) {
        RepositoryPreferences.shared.gitPath = sender.stringValue
    }
    
    private func loadRepositories() {
        repositories = RepositoryPreferences.shared.repositories
        repositoryListView?.reloadData()
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return repositories.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellIdentifier = NSUserInterfaceItemIdentifier("PathCell")
        
        let cell: NSTextField
        if let existingCell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
            cell = existingCell
        } else {
            cell = NSTextField()
            cell.identifier = cellIdentifier
            cell.isBordered = false
            cell.isEditable = false
            cell.drawsBackground = false
        }
        
        cell.stringValue = repositories[row].path
        return cell
    }
}
