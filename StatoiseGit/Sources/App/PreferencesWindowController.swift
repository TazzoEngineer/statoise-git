import Cocoa

class PreferencesWindowController: NSWindowController {
    
    private var repositoryListView: NSTableView!
    private var repositories: [MonitoredRepository] = []
    private var diffToolField: NSTextField!
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Statoise Git Preferences"
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
        scrollView.hasHorizontalScroller = true
        
        repositoryListView = NSTableView()
        repositoryListView.delegate = self
        repositoryListView.dataSource = self
        
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Repository"
        nameColumn.width = 180
        repositoryListView.addTableColumn(nameColumn)

        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Parent Path"
        pathColumn.width = 360
        repositoryListView.addTableColumn(pathColumn)
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
        
        // External Diff Tool
        let diffToolLabel = NSTextField(labelWithString: "External Diff Tool:")
        diffToolLabel.frame = NSRect(x: 20, y: 250, width: 150, height: 20)
        view.addSubview(diffToolLabel)
        
        diffToolField = NSTextField(frame: NSRect(x: 180, y: 248, width: 280, height: 24))
        diffToolField.stringValue = RepositoryPreferences.shared.externalDiffTool
        diffToolField.placeholderString = "/Applications/DiffMerge.app or empty for built-in"
        diffToolField.target = self
        diffToolField.action = #selector(diffToolChanged(_:))
        view.addSubview(diffToolField)
        
        let diffToolBrowse = NSButton(title: "Browse...", target: self, action: #selector(browseDiffTool(_:)))
        diffToolBrowse.frame = NSRect(x: 465, y: 247, width: 80, height: 26)
        diffToolBrowse.bezelStyle = .rounded
        view.addSubview(diffToolBrowse)
        
        let diffToolHint = NSTextField(labelWithString: "Leave empty to use built-in diff viewer. Supports .app bundles and command-line tools.")
        diffToolHint.frame = NSRect(x: 180, y: 225, width: 370, height: 20)
        diffToolHint.font = NSFont.systemFont(ofSize: 10)
        diffToolHint.textColor = .secondaryLabelColor
        view.addSubview(diffToolHint)
        
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
            guard response == .OK else { return }
            guard let selectedURL = panel.urls.first ?? panel.url else { return }
            let resolvedPath = selectedURL.resolvingSymlinksInPath().standardizedFileURL.path
            let runner = GitCommandRunner.shared

            guard runner.isGitRepositoryRootByFilesystem(at: resolvedPath) else {
                self?.showRepositorySelectionError(for: resolvedPath)
                return
            }
            
            let repo = RepositoryPreferences.shared.makeMonitoredRepository(from: selectedURL)
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
    
    @objc private func diffToolChanged(_ sender: NSTextField) {
        RepositoryPreferences.shared.externalDiffTool = sender.stringValue
    }
    
    @objc private func browseDiffTool(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application, .executable]
        panel.prompt = "Select Diff Tool"
        
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            RepositoryPreferences.shared.externalDiffTool = url.path
            self?.diffToolField.stringValue = url.path
        }
    }
    
    private func loadRepositories() {
        repositories = RepositoryPreferences.shared.repositories
        repositoryListView?.reloadData()
    }

    private func repositoryName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func repositoryParentPath(for path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private func showRepositorySelectionError(for path: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Select a Git Repository Root"
        alert.informativeText = "\(path) is not a Git repository root. Select the folder that directly contains .git."
        alert.runModal()
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension PreferencesWindowController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return repositories.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let cellIdentifier = tableColumn.identifier
        
        let cell: NSTextField
        if let existingCell = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? NSTextField {
            cell = existingCell
        } else {
            cell = NSTextField()
            cell.identifier = cellIdentifier
            cell.isBordered = false
            cell.isEditable = false
            cell.drawsBackground = false
            cell.lineBreakMode = .byTruncatingHead
            cell.maximumNumberOfLines = 1
            cell.usesSingleLineMode = true
        }
        
        switch tableColumn.identifier.rawValue {
        case "name":
            cell.stringValue = repositoryName(for: repositories[row].path)
        case "path":
            cell.stringValue = repositoryParentPath(for: repositories[row].path)
        default:
            cell.stringValue = repositories[row].path
        }
        cell.toolTip = repositories[row].path
        return cell
    }
}
