import Cocoa

class LogWindowController: NSWindowController {
    
    private let repositoryPath: String
    private var logEntries: [LogEntry] = []
    private var filteredEntries: [LogEntry] = []
    private var commitTableView: NSTableView!
    private var messageTextView: NSTextView!
    private var fileTableView: NSTableView!
    private var changedFiles: [String] = []  // "M\tpath/to/file" format
    private var maxCount = 50
    private var selectedCommitHash: String?
    private var splitView: NSSplitView!
    private var fileLogWindows: [FileLogWindowController] = []
    private var graphData: [GraphRowInfo] = []
    private var graphColumn: NSTableColumn!
    private var searchField: NSSearchField!
    private var searchText: String = ""
    
    init(repositoryPath: String) {
        self.repositoryPath = repositoryPath
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Log - \(URL(fileURLWithPath: repositoryPath).lastPathComponent)"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        
        super.init(window: window)
        setupUI()
        loadLog()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Toolbar (top bar)
        let toolbarHeight: CGFloat = 35
        let toolbarY = contentView.bounds.height - toolbarHeight
        
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        refreshButton.frame = NSRect(x: 10, y: toolbarY + 4, width: 80, height: 28)
        refreshButton.autoresizingMask = [.maxXMargin, .minYMargin]
        refreshButton.bezelStyle = .rounded
        contentView.addSubview(refreshButton)
        
        let countLabel = NSTextField(labelWithString: "Entries:")
        countLabel.frame = NSRect(x: 100, y: toolbarY + 7, width: 50, height: 20)
        countLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(countLabel)
        
        let countField = NSPopUpButton(frame: NSRect(x: 155, y: toolbarY + 4, width: 80, height: 28))
        countField.addItems(withTitles: ["25", "50", "100", "200", "500"])
        countField.selectItem(withTitle: "50")
        countField.target = self
        countField.action = #selector(countChanged(_:))
        countField.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(countField)
        
        // Search field (right-aligned)
        searchField = NSSearchField(frame: NSRect(x: contentView.bounds.width - 220, y: toolbarY + 4, width: 210, height: 28))
        searchField.placeholderString = "Search message, author, hash..."
        searchField.autoresizingMask = [.minXMargin, .minYMargin]
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        contentView.addSubview(searchField)
        
        // Main split view (vertical split: top=commits, bottom=details)
        splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: contentView.bounds.height - toolbarHeight))
        splitView.isVertical = false  // horizontal divider
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.delegate = self
        
        // --- Top pane: Commit list ---
        let commitScrollView = NSScrollView()
        commitScrollView.hasVerticalScroller = true
        commitScrollView.borderType = .noBorder
        commitScrollView.autoresizingMask = [.width, .height]
        
        commitTableView = NSTableView()
        commitTableView.delegate = self
        commitTableView.dataSource = self
        commitTableView.allowsMultipleSelection = false
        commitTableView.rowHeight = 20
        commitTableView.usesAlternatingRowBackgroundColors = true
        
        graphColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("graph"))
        graphColumn.title = ""
        graphColumn.width = 50
        graphColumn.minWidth = 30
        graphColumn.maxWidth = 200
        commitTableView.addTableColumn(graphColumn)
        
        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "Message"
        subjectCol.width = 350
        subjectCol.minWidth = 150
        commitTableView.addTableColumn(subjectCol)
        
        let authorCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("author"))
        authorCol.title = "Author"
        authorCol.width = 160
        authorCol.minWidth = 80
        commitTableView.addTableColumn(authorCol)
        
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Date"
        dateCol.width = 100
        dateCol.minWidth = 80
        commitTableView.addTableColumn(dateCol)
        
        let hashCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hash"))
        hashCol.title = "Hash"
        hashCol.width = 80
        hashCol.minWidth = 60
        commitTableView.addTableColumn(hashCol)
        
        commitTableView.headerView = NSTableHeaderView()
        commitTableView.doubleAction = #selector(commitDoubleClicked(_:))
        commitTableView.target = self
        commitScrollView.documentView = commitTableView
        
        // --- Bottom pane: Details (message + files side by side) ---
        let bottomPane = NSView()
        bottomPane.autoresizingMask = [.width, .height]
        
        // Use another split view for message/files (left-right)
        let detailSplit = NSSplitView()
        detailSplit.isVertical = true  // vertical divider (left-right)
        detailSplit.dividerStyle = .thin
        detailSplit.autoresizingMask = [.width, .height]
        
        // Message scroll view
        let msgScrollView = NSScrollView()
        msgScrollView.hasVerticalScroller = true
        msgScrollView.borderType = .bezelBorder
        msgScrollView.autoresizingMask = [.width, .height]
        
        messageTextView = NSTextView()
        messageTextView.isEditable = false
        messageTextView.isRichText = false
        messageTextView.font = NSFont.systemFont(ofSize: 12)
        messageTextView.isVerticallyResizable = true
        messageTextView.isHorizontallyResizable = false
        messageTextView.autoresizingMask = [.width]
        messageTextView.textContainer?.widthTracksTextView = true
        messageTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        msgScrollView.documentView = messageTextView
        
        // Files scroll view
        let filesScrollView = NSScrollView()
        filesScrollView.hasVerticalScroller = true
        filesScrollView.borderType = .bezelBorder
        filesScrollView.autoresizingMask = [.width, .height]
        
        fileTableView = NSTableView()
        fileTableView.delegate = self
        fileTableView.dataSource = self
        fileTableView.rowHeight = 18
        fileTableView.doubleAction = #selector(fileDoubleClicked(_:))
        fileTableView.target = self
        
        // Context menu for file table
        let fileMenu = NSMenu()
        fileMenu.addItem(NSMenuItem(title: "Show Diff", action: #selector(showFileDiff(_:)), keyEquivalent: ""))
        fileMenu.addItem(NSMenuItem(title: "Show File Log", action: #selector(showFileLog(_:)), keyEquivalent: ""))
        fileTableView.menu = fileMenu
        
        let fileStatusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileStatus"))
        fileStatusCol.title = "S"
        fileStatusCol.width = 25
        fileStatusCol.minWidth = 25
        fileStatusCol.maxWidth = 25
        fileTableView.addTableColumn(fileStatusCol)
        
        let filePathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filePath"))
        filePathCol.title = "File"
        filePathCol.width = 350
        filePathCol.minWidth = 100
        fileTableView.addTableColumn(filePathCol)
        
        fileTableView.headerView = NSTableHeaderView()
        filesScrollView.documentView = fileTableView
        
        detailSplit.addSubview(msgScrollView)
        detailSplit.addSubview(filesScrollView)
        
        bottomPane.addSubview(detailSplit)
        detailSplit.frame = bottomPane.bounds
        
        // Add to main split
        splitView.addSubview(commitScrollView)
        splitView.addSubview(bottomPane)
        
        contentView.addSubview(splitView)
        window.contentView = contentView
        
        // Set initial split position after layout
        DispatchQueue.main.async {
            self.splitView.setPosition(self.splitView.bounds.height * 0.55, ofDividerAt: 0)
            detailSplit.setPosition(detailSplit.bounds.width * 0.45, ofDividerAt: 0)
        }
    }
    
    // MARK: - Data Loading
    
    private func loadLog() {
        Task {
            do {
                let entries = try await GitCommandRunner.shared.logEntries(at: repositoryPath, maxCount: maxCount)
                
                await MainActor.run {
                    self.logEntries = entries
                    self.applyFilter()
                }
            } catch {
                await MainActor.run {
                    self.messageTextView.string = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func applyFilter() {
        if searchText.isEmpty {
            filteredEntries = logEntries
        } else {
            let query = searchText.lowercased()
            filteredEntries = logEntries.filter { entry in
                entry.subject.lowercased().contains(query) ||
                entry.author.lowercased().contains(query) ||
                entry.shortHash.lowercased().contains(query) ||
                entry.hash.lowercased().contains(query) ||
                entry.refs.lowercased().contains(query)
            }
        }
        graphData = GitGraphCalculator.computeGraph(entries: filteredEntries)
        let maxLanes = graphData.map(\.totalLanes).max() ?? 1
        graphColumn.width = GitGraphCellView.widthForLanes(maxLanes)
        commitTableView.reloadData()
        if !filteredEntries.isEmpty {
            commitTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadCommitDetails(hash: filteredEntries[0].hash)
        } else {
            messageTextView.string = ""
            changedFiles = []
            fileTableView.reloadData()
        }
    }
    
    private func loadCommitDetails(hash: String) {
        selectedCommitHash = hash
        Task {
            do {
                let message = try await GitCommandRunner.shared.commitMessage(at: repositoryPath, hash: hash)
                let files = try await GitCommandRunner.shared.commitFiles(at: repositoryPath, hash: hash)
                
                await MainActor.run {
                    self.messageTextView.string = message
                    self.changedFiles = files
                    self.fileTableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.messageTextView.string = "Error: \(error.localizedDescription)"
                    self.changedFiles = []
                    self.fileTableView.reloadData()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    @objc private func refresh(_ sender: Any?) {
        loadLog()
    }
    
    @objc private func countChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let count = Int(title) {
            maxCount = count
            loadLog()
        }
    }
    
    @objc private func searchChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        applyFilter()
    }
    
    @objc private func fileDoubleClicked(_ sender: Any?) {
        showDiffForSelectedFile()
    }
    
    @objc private func commitDoubleClicked(_ sender: Any?) {
        let row = commitTableView.clickedRow
        guard row >= 0, row < filteredEntries.count else { return }
        let entry = filteredEntries[row]
        
        Task {
            do {
                let diff = try await GitCommandRunner.shared.commitDiff(
                    at: repositoryPath, hash: entry.hash
                )
                await MainActor.run {
                    let diffWindow = DiffWindowController(
                        repositoryPath: self.repositoryPath,
                        diffContent: diff,
                        title: "\(entry.subject) (\(entry.shortHash))"
                    )
                    diffWindow.showWindow(nil)
                    diffWindow.window?.makeKeyAndOrderFront(nil)
                }
            } catch {
                await MainActor.run {
                    GitErrorAlert.present(error, title: "Diff failed", window: self.window)
                }
            }
        }
    }
    
    @objc private func showFileDiff(_ sender: Any?) {
        showDiffForSelectedFile()
    }
    
    @objc private func showFileLog(_ sender: Any?) {
        let row = fileTableView.clickedRow >= 0 ? fileTableView.clickedRow : fileTableView.selectedRow
        guard row >= 0, row < changedFiles.count else { return }
        let filePath = filePathFromEntry(changedFiles[row])
        
        // Open a new log window filtered by this file
        let fileLogWindow = FileLogWindowController(repositoryPath: repositoryPath, filePath: filePath)
        fileLogWindows.append(fileLogWindow)
        fileLogWindow.showWindow(nil)
        fileLogWindow.window?.makeKeyAndOrderFront(nil)
    }
    
    private func showDiffForSelectedFile() {
        let row = fileTableView.clickedRow >= 0 ? fileTableView.clickedRow : fileTableView.selectedRow
        guard row >= 0, row < changedFiles.count,
              let hash = selectedCommitHash else {
            return
        }
        let filePath = filePathFromEntry(changedFiles[row])
        
        let externalTool = RepositoryPreferences.shared.externalDiffTool
        
        if !externalTool.isEmpty {
            // Use external diff tool
            Task {
                do {
                    let oldFile = try await GitCommandRunner.shared.exportFileAtParentRevision(
                        at: repositoryPath, hash: hash, file: filePath
                    )
                    let newFile = try await GitCommandRunner.shared.exportFileAtRevision(
                        at: repositoryPath, hash: hash, file: filePath
                    )
                    await MainActor.run {
                        self.launchExternalDiffTool(externalTool, oldFile: oldFile, newFile: newFile)
                    }
                } catch {
                    // Submodules (gitlinks) and other non-blob paths cannot always be exported
                    // as files for external tools. Fall back to built-in textual diff.
                    do {
                        let diff = try await GitCommandRunner.shared.commitFileDiff(
                            at: repositoryPath, hash: hash, file: filePath
                        )
                        await MainActor.run {
                            let diffWindow = DiffWindowController(
                                repositoryPath: self.repositoryPath,
                                diffContent: diff,
                                title: "\(filePath) @ \(String(hash.prefix(7)))"
                            )
                            diffWindow.showWindow(nil)
                            diffWindow.window?.makeKeyAndOrderFront(nil)
                        }
                    } catch {
                        await MainActor.run {
                            GitErrorAlert.present(error, title: "Diff failed", window: self.window)
                        }
                    }
                }
            }
        } else {
            // Use built-in diff viewer
            Task {
                do {
                    let diff = try await GitCommandRunner.shared.commitFileDiff(
                        at: repositoryPath, hash: hash, file: filePath
                    )
                    await MainActor.run {
                        let diffWindow = DiffWindowController(
                            repositoryPath: self.repositoryPath,
                            diffContent: diff,
                            title: "\(filePath) @ \(String(hash.prefix(7)))"
                        )
                        diffWindow.showWindow(nil)
                        diffWindow.window?.makeKeyAndOrderFront(nil)
                    }
                } catch {
                    await MainActor.run {
                        GitErrorAlert.present(error, title: "Diff failed", window: self.window)
                    }
                }
            }
        }
    }
    
    private func launchExternalDiffTool(_ tool: String, oldFile: String, newFile: String) {
        ExternalDiffLauncher.launch(tool: tool, oldFile: oldFile, newFile: newFile)
    }
    
    private func filePathFromEntry(_ entry: String) -> String {
        let parts = entry.split(separator: "\t", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : entry
    }
}

// MARK: - Table View

extension LogWindowController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == commitTableView {
            return filteredEntries.count
        } else {
            return changedFiles.count
        }
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == commitTableView {
            return commitCellView(for: tableColumn, row: row)
        } else {
            return fileCellView(for: tableColumn, row: row)
        }
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView == commitTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else { return }
        loadCommitDetails(hash: filteredEntries[row].hash)
    }
    
    private func commitCellView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filteredEntries[row]
        
        switch tableColumn?.identifier.rawValue {
        case "graph":
            let cellView = GitGraphCellView(frame: NSRect(x: 0, y: 0, width: graphColumn.width, height: 20))
            if row < graphData.count {
                cellView.graphRow = graphData[row]
            }
            return cellView
            
        case "subject":
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            
            if entry.refs.isEmpty {
                label.stringValue = entry.subject
            } else {
                let attr = NSMutableAttributedString()
                let refAttr: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.systemOrange,
                    .font: NSFont.boldSystemFont(ofSize: 11)
                ]
                attr.append(NSAttributedString(string: "(\(entry.refs)) ", attributes: refAttr))
                let msgAttr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12)
                ]
                attr.append(NSAttributedString(string: entry.subject, attributes: msgAttr))
                label.attributedStringValue = attr
            }
            return label
            
        case "author":
            let label = NSTextField(labelWithString: entry.author)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            return label
            
        case "date":
            let label = NSTextField(labelWithString: entry.date)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            return label
            
        case "hash":
            let label = NSTextField(labelWithString: entry.shortHash)
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .tertiaryLabelColor
            return label
            
        default:
            return nil
        }
    }
    
    private func fileCellView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < changedFiles.count else { return nil }
        let fileEntry = changedFiles[row]
        let parts = fileEntry.split(separator: "\t", maxSplits: 1)
        let status = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : fileEntry
        
        switch tableColumn?.identifier.rawValue {
        case "fileStatus":
            let label = NSTextField(labelWithString: status)
            label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            label.alignment = .center
            switch status {
            case "M": label.textColor = .systemOrange
            case "A": label.textColor = .systemGreen
            case "D": label.textColor = .systemRed
            case "R": label.textColor = .systemPurple
            default:  label.textColor = .labelColor
            }
            return label
            
        case "filePath":
            let label = NSTextField(labelWithString: path)
            label.font = NSFont.systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingMiddle
            return label
            
        default:
            return nil
        }
    }
}

// MARK: - Split View Delegate

extension LogWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == self.splitView {
            return 100  // minimum top pane height
        }
        return 100
    }
    
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == self.splitView {
            return splitView.bounds.height - 100  // minimum bottom pane height
        }
        return splitView.bounds.width - 100
    }
}

// MARK: - File Log Window (per-file history)

class FileLogWindowController: NSWindowController {
    
    private let repositoryPath: String
    private let filePath: String
    private var logEntries: [LogEntry] = []
    private var filteredEntries: [LogEntry] = []
    private var commitTableView: NSTableView!
    private var messageTextView: NSTextView!
    private var fileTableView: NSTableView!
    private var changedFiles: [String] = []
    private var selectedCommitHash: String?
    private var splitView: NSSplitView!
    private var maxCount = 100
    private var searchField: NSSearchField!
    private var searchText: String = ""
    
    init(repositoryPath: String, filePath: String) {
        self.repositoryPath = repositoryPath
        self.filePath = filePath
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Log: \(filePath)"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        
        super.init(window: window)
        setupUI()
        loadFileLog()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Toolbar
        let toolbarHeight: CGFloat = 35
        let toolbarY = contentView.bounds.height - toolbarHeight
        
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        refreshButton.frame = NSRect(x: 10, y: toolbarY + 4, width: 80, height: 28)
        refreshButton.autoresizingMask = [.maxXMargin, .minYMargin]
        refreshButton.bezelStyle = .rounded
        contentView.addSubview(refreshButton)
        
        let countLabel = NSTextField(labelWithString: "Entries:")
        countLabel.frame = NSRect(x: 100, y: toolbarY + 7, width: 50, height: 20)
        countLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(countLabel)
        
        let countField = NSPopUpButton(frame: NSRect(x: 155, y: toolbarY + 4, width: 80, height: 28))
        countField.addItems(withTitles: ["25", "50", "100", "200", "500"])
        countField.selectItem(withTitle: "100")
        countField.target = self
        countField.action = #selector(countChanged(_:))
        countField.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(countField)
        
        searchField = NSSearchField(frame: NSRect(x: contentView.bounds.width - 220, y: toolbarY + 4, width: 210, height: 28))
        searchField.placeholderString = "Search message, author, hash..."
        searchField.autoresizingMask = [.minXMargin, .minYMargin]
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        contentView.addSubview(searchField)
        
        // Main split view (top=commits, bottom=details)
        splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: contentView.bounds.height - toolbarHeight))
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.delegate = self
        
        // --- Top pane: Commit list ---
        let commitScrollView = NSScrollView()
        commitScrollView.hasVerticalScroller = true
        commitScrollView.borderType = .noBorder
        commitScrollView.autoresizingMask = [.width, .height]
        
        commitTableView = NSTableView()
        commitTableView.delegate = self
        commitTableView.dataSource = self
        commitTableView.allowsMultipleSelection = false
        commitTableView.rowHeight = 20
        commitTableView.usesAlternatingRowBackgroundColors = true
        
        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "Message"
        subjectCol.width = 400
        subjectCol.minWidth = 150
        commitTableView.addTableColumn(subjectCol)
        
        let authorCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("author"))
        authorCol.title = "Author"
        authorCol.width = 160
        authorCol.minWidth = 80
        commitTableView.addTableColumn(authorCol)
        
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Date"
        dateCol.width = 100
        dateCol.minWidth = 80
        commitTableView.addTableColumn(dateCol)
        
        let hashCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hash"))
        hashCol.title = "Hash"
        hashCol.width = 80
        hashCol.minWidth = 60
        commitTableView.addTableColumn(hashCol)
        
        commitTableView.headerView = NSTableHeaderView()
        commitTableView.doubleAction = #selector(commitDoubleClicked(_:))
        commitTableView.target = self
        commitScrollView.documentView = commitTableView
        
        // --- Bottom pane: Details (message + files side by side) ---
        let bottomPane = NSView()
        bottomPane.autoresizingMask = [.width, .height]
        
        let detailSplit = NSSplitView()
        detailSplit.isVertical = true
        detailSplit.dividerStyle = .thin
        detailSplit.autoresizingMask = [.width, .height]
        
        // Message scroll view
        let msgScrollView = NSScrollView()
        msgScrollView.hasVerticalScroller = true
        msgScrollView.borderType = .bezelBorder
        msgScrollView.autoresizingMask = [.width, .height]
        
        messageTextView = NSTextView()
        messageTextView.isEditable = false
        messageTextView.isRichText = false
        messageTextView.font = NSFont.systemFont(ofSize: 12)
        messageTextView.isVerticallyResizable = true
        messageTextView.isHorizontallyResizable = false
        messageTextView.autoresizingMask = [.width]
        messageTextView.textContainer?.widthTracksTextView = true
        messageTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        msgScrollView.documentView = messageTextView
        
        // Files scroll view
        let filesScrollView = NSScrollView()
        filesScrollView.hasVerticalScroller = true
        filesScrollView.borderType = .bezelBorder
        filesScrollView.autoresizingMask = [.width, .height]
        
        fileTableView = NSTableView()
        fileTableView.delegate = self
        fileTableView.dataSource = self
        fileTableView.rowHeight = 18
        fileTableView.doubleAction = #selector(fileDoubleClicked(_:))
        fileTableView.target = self
        
        // Context menu for file table
        let fileMenu = NSMenu()
        fileMenu.addItem(NSMenuItem(title: "Show Diff", action: #selector(showFileDiff(_:)), keyEquivalent: ""))
        fileTableView.menu = fileMenu
        
        let fileStatusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileStatus"))
        fileStatusCol.title = "S"
        fileStatusCol.width = 25
        fileStatusCol.minWidth = 25
        fileStatusCol.maxWidth = 25
        fileTableView.addTableColumn(fileStatusCol)
        
        let filePathCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filePath"))
        filePathCol.title = "File"
        filePathCol.width = 350
        filePathCol.minWidth = 100
        fileTableView.addTableColumn(filePathCol)
        
        fileTableView.headerView = NSTableHeaderView()
        filesScrollView.documentView = fileTableView
        
        detailSplit.addSubview(msgScrollView)
        detailSplit.addSubview(filesScrollView)
        
        bottomPane.addSubview(detailSplit)
        detailSplit.frame = bottomPane.bounds
        
        // Add to main split
        splitView.addSubview(commitScrollView)
        splitView.addSubview(bottomPane)
        
        contentView.addSubview(splitView)
        window.contentView = contentView
        
        DispatchQueue.main.async {
            self.splitView.setPosition(self.splitView.bounds.height * 0.55, ofDividerAt: 0)
            detailSplit.setPosition(detailSplit.bounds.width * 0.45, ofDividerAt: 0)
        }
    }
    
    @objc private func refresh(_ sender: Any?) {
        loadFileLog()
    }
    
    @objc private func countChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let count = Int(title) {
            maxCount = count
            loadFileLog()
        }
    }
    
    @objc private func searchChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        applyFilter()
    }
    
    private func applyFilter() {
        if searchText.isEmpty {
            filteredEntries = logEntries
        } else {
            let query = searchText.lowercased()
            filteredEntries = logEntries.filter {
                $0.subject.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                $0.hash.lowercased().contains(query) ||
                $0.shortHash.lowercased().contains(query)
            }
        }
        commitTableView.reloadData()
        if !filteredEntries.isEmpty {
            commitTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadCommitDetails(hash: filteredEntries[0].hash)
        } else {
            messageTextView.string = ""
            changedFiles = []
            fileTableView.reloadData()
        }
    }
    
    private func loadFileLog() {
        Task {
            do {
                let entries = try await GitCommandRunner.shared.fileLogEntries(at: repositoryPath, file: filePath, maxCount: maxCount)
                await MainActor.run {
                    self.logEntries = entries
                    self.applyFilter()
                }
            } catch {
                await MainActor.run {
                    self.messageTextView.string = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func loadCommitDetails(hash: String) {
        selectedCommitHash = hash
        Task {
            do {
                let message = try await GitCommandRunner.shared.commitMessage(at: repositoryPath, hash: hash)
                let files = try await GitCommandRunner.shared.commitFiles(at: repositoryPath, hash: hash)
                
                await MainActor.run {
                    self.messageTextView.string = message
                    self.changedFiles = files
                    self.fileTableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self.messageTextView.string = "Error: \(error.localizedDescription)"
                    self.changedFiles = []
                    self.fileTableView.reloadData()
                }
            }
        }
    }
    
    @objc private func fileDoubleClicked(_ sender: Any?) {
        showDiffForSelectedFile()
    }
    
    @objc private func showFileDiff(_ sender: Any?) {
        showDiffForSelectedFile()
    }
    
    private func showDiffForSelectedFile() {
        let row = fileTableView.clickedRow >= 0 ? fileTableView.clickedRow : fileTableView.selectedRow
        guard row >= 0, row < changedFiles.count,
              let hash = selectedCommitHash else { return }
        let parts = changedFiles[row].split(separator: "\t", maxSplits: 1)
        let file = parts.count > 1 ? String(parts[1]) : changedFiles[row]
        
        let externalTool = RepositoryPreferences.shared.externalDiffTool
        if !externalTool.isEmpty {
            Task {
                do {
                    let oldFile = try await GitCommandRunner.shared.exportFileAtParentRevision(
                        at: repositoryPath, hash: hash, file: file
                    )
                    let newFile = try await GitCommandRunner.shared.exportFileAtRevision(
                        at: repositoryPath, hash: hash, file: file
                    )
                    await MainActor.run {
                        ExternalDiffLauncher.launch(tool: externalTool, oldFile: oldFile, newFile: newFile)
                    }
                } catch {
                    // Submodule entries cannot be exported as regular files for external diffs.
                    // Fall back to built-in textual diff representation.
                    do {
                        let diff = try await GitCommandRunner.shared.commitFileDiff(
                            at: repositoryPath, hash: hash, file: file
                        )
                        await MainActor.run {
                            let diffWindow = DiffWindowController(
                                repositoryPath: self.repositoryPath,
                                diffContent: diff,
                                title: "\(file) @ \(String(hash.prefix(7)))"
                            )
                            diffWindow.showWindow(nil)
                            diffWindow.window?.makeKeyAndOrderFront(nil)
                        }
                    } catch {
                        await MainActor.run {
                            GitErrorAlert.present(error, title: "Diff failed", window: self.window)
                        }
                    }
                }
            }
        } else {
            Task {
                do {
                    let diff = try await GitCommandRunner.shared.commitFileDiff(
                        at: repositoryPath, hash: hash, file: file
                    )
                    await MainActor.run {
                        let diffWindow = DiffWindowController(
                            repositoryPath: self.repositoryPath,
                            diffContent: diff,
                            title: "\(file) @ \(String(hash.prefix(7)))"
                        )
                        diffWindow.showWindow(nil)
                        diffWindow.window?.makeKeyAndOrderFront(nil)
                    }
                } catch {
                    await MainActor.run {
                        GitErrorAlert.present(error, title: "Diff failed", window: self.window)
                    }
                }
            }
        }
    }
    
    @objc private func commitDoubleClicked(_ sender: Any?) {
        let row = commitTableView.clickedRow
        guard row >= 0, row < filteredEntries.count else { return }
        let entry = filteredEntries[row]
        
        Task {
            do {
                let diff = try await GitCommandRunner.shared.commitDiff(
                    at: repositoryPath, hash: entry.hash
                )
                await MainActor.run {
                    let diffWindow = DiffWindowController(
                        repositoryPath: self.repositoryPath,
                        diffContent: diff,
                        title: "\(entry.subject) (\(entry.shortHash))"
                    )
                    diffWindow.showWindow(nil)
                    diffWindow.window?.makeKeyAndOrderFront(nil)
                }
            } catch {
                await MainActor.run {
                    GitErrorAlert.present(error, title: "Diff failed", window: self.window)
                }
            }
        }
    }
}

extension FileLogWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == commitTableView {
            return filteredEntries.count
        } else {
            return changedFiles.count
        }
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == commitTableView {
            guard row < filteredEntries.count else { return nil }
            let entry = filteredEntries[row]
            switch tableColumn?.identifier.rawValue {
            case "subject":
                let label = NSTextField(labelWithString: "")
                label.font = NSFont.systemFont(ofSize: 12)
                label.lineBreakMode = .byTruncatingTail
                if entry.refs.isEmpty {
                    label.stringValue = entry.subject
                } else {
                    let attr = NSMutableAttributedString()
                    let refAttr: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.systemOrange,
                        .font: NSFont.boldSystemFont(ofSize: 11)
                    ]
                    attr.append(NSAttributedString(string: "(\(entry.refs)) ", attributes: refAttr))
                    attr.append(NSAttributedString(string: entry.subject, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
                    label.attributedStringValue = attr
                }
                return label
            case "author":
                let label = NSTextField(labelWithString: entry.author)
                label.font = NSFont.systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                label.lineBreakMode = .byTruncatingTail
                return label
            case "date":
                let label = NSTextField(labelWithString: entry.date)
                label.font = NSFont.systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                return label
            case "hash":
                let label = NSTextField(labelWithString: entry.shortHash)
                label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                label.textColor = .tertiaryLabelColor
                return label
            default:
                return nil
            }
        } else {
            guard row < changedFiles.count else { return nil }
            let fileEntry = changedFiles[row]
            let parts = fileEntry.split(separator: "\t", maxSplits: 1)
            let status = parts.count > 0 ? String(parts[0]) : ""
            let path = parts.count > 1 ? String(parts[1]) : fileEntry
            
            switch tableColumn?.identifier.rawValue {
            case "fileStatus":
                let label = NSTextField(labelWithString: status)
                label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
                label.alignment = .center
                switch status {
                case "M": label.textColor = .systemOrange
                case "A": label.textColor = .systemGreen
                case "D": label.textColor = .systemRed
                case "R": label.textColor = .systemPurple
                default:  label.textColor = .labelColor
                }
                return label
            case "filePath":
                let label = NSTextField(labelWithString: path)
                label.font = NSFont.systemFont(ofSize: 11)
                label.lineBreakMode = .byTruncatingMiddle
                return label
            default:
                return nil
            }
        }
    }
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView == commitTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < filteredEntries.count else { return }
        loadCommitDetails(hash: filteredEntries[row].hash)
    }
}

extension FileLogWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 100
    }
    
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == self.splitView {
            return splitView.bounds.height - 100
        }
        return splitView.bounds.width - 100
    }
}
