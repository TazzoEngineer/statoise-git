import Cocoa

class CommitWindowController: NSWindowController {
    
    private let repositoryPath: String
    private var statusEntries: [GitStatusEntry] = []
    private var fileTableView: NSTableView!
    private var messageTextView: NSTextView!
    private var selectAllCheckbox: NSButton!
    private var selectedFiles: Set<String> = []
    private var branchLabel: NSTextField!
    
    init(repositoryPath: String) {
        self.repositoryPath = repositoryPath
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 550),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Commit - \(URL(fileURLWithPath: repositoryPath).lastPathComponent)"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        setupUI()
        loadStatus()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Branch label
        branchLabel = NSTextField(labelWithString: "Branch: ...")
        branchLabel.frame = NSRect(x: 10, y: 520, width: 680, height: 20)
        branchLabel.autoresizingMask = [.width, .minYMargin]
        branchLabel.font = NSFont.boldSystemFont(ofSize: 13)
        contentView.addSubview(branchLabel)
        
        // "Message:" label
        let msgLabel = NSTextField(labelWithString: "Commit Message:")
        msgLabel.frame = NSRect(x: 10, y: 490, width: 200, height: 20)
        msgLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(msgLabel)
        
        // Message text view
        let scrollViewMsg = NSScrollView(frame: NSRect(x: 10, y: 390, width: 680, height: 95))
        scrollViewMsg.autoresizingMask = [.width, .minYMargin]
        scrollViewMsg.hasVerticalScroller = true
        scrollViewMsg.borderType = .bezelBorder
        
        messageTextView = NSTextView(frame: scrollViewMsg.bounds)
        messageTextView.isEditable = true
        messageTextView.isRichText = false
        messageTextView.font = NSFont.systemFont(ofSize: 13)
        messageTextView.autoresizingMask = [.width, .height]
        messageTextView.isVerticallyResizable = true
        messageTextView.textContainer?.widthTracksTextView = true
        scrollViewMsg.documentView = messageTextView
        contentView.addSubview(scrollViewMsg)
        
        // "Changes:" label
        let changesLabel = NSTextField(labelWithString: "Changes:")
        changesLabel.frame = NSRect(x: 10, y: 362, width: 200, height: 20)
        changesLabel.autoresizingMask = [.minYMargin]
        contentView.addSubview(changesLabel)
        
        // Select All checkbox
        selectAllCheckbox = NSButton(checkboxWithTitle: "Select All", target: self, action: #selector(toggleSelectAll(_:)))
        selectAllCheckbox.frame = NSRect(x: 580, y: 362, width: 110, height: 20)
        selectAllCheckbox.autoresizingMask = [.minXMargin, .minYMargin]
        selectAllCheckbox.state = .on
        contentView.addSubview(selectAllCheckbox)
        
        // File list table
        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 50, width: 680, height: 310))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        fileTableView = NSTableView()
        fileTableView.delegate = self
        fileTableView.dataSource = self
        fileTableView.allowsMultipleSelection = true
        
        let checkColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check"))
        checkColumn.title = ""
        checkColumn.width = 30
        checkColumn.minWidth = 30
        checkColumn.maxWidth = 30
        fileTableView.addTableColumn(checkColumn)
        
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = "Status"
        statusColumn.width = 70
        statusColumn.minWidth = 50
        fileTableView.addTableColumn(statusColumn)
        
        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileColumn.title = "File"
        fileColumn.width = 560
        fileColumn.minWidth = 200
        fileTableView.addTableColumn(fileColumn)
        
        fileTableView.headerView = NSTableHeaderView()
        scrollView.documentView = fileTableView
        contentView.addSubview(scrollView)
        
        // Buttons
        let commitButton = NSButton(title: "Commit", target: self, action: #selector(doCommit(_:)))
        commitButton.frame = NSRect(x: 600, y: 10, width: 90, height: 32)
        commitButton.autoresizingMask = [.minXMargin, .maxYMargin]
        commitButton.bezelStyle = .rounded
        commitButton.keyEquivalent = "\r"
        contentView.addSubview(commitButton)
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(doCancel(_:)))
        cancelButton.frame = NSRect(x: 505, y: 10, width: 90, height: 32)
        cancelButton.autoresizingMask = [.minXMargin, .maxYMargin]
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)
        
        window.contentView = contentView
    }
    
    private func loadStatus() {
        Task {
            do {
                let branch = try await GitCommandRunner.shared.currentBranch(at: repositoryPath)
                let entries = try await GitCommandRunner.shared.status(at: repositoryPath)
                
                await MainActor.run {
                    self.branchLabel.stringValue = "Branch: \(branch)"
                    self.statusEntries = entries
                    self.selectedFiles = Set(entries.map(\.filePath))
                    self.fileTableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
    
    // MARK: - Actions
    
    @objc private func toggleSelectAll(_ sender: NSButton) {
        if sender.state == .on {
            selectedFiles = Set(statusEntries.map(\.filePath))
        } else {
            selectedFiles.removeAll()
        }
        fileTableView.reloadData()
    }
    
    @objc private func fileCheckboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < statusEntries.count else { return }
        let filePath = statusEntries[row].filePath
        
        if sender.state == .on {
            selectedFiles.insert(filePath)
        } else {
            selectedFiles.remove(filePath)
        }
        
        // Update select all state
        if selectedFiles.count == statusEntries.count {
            selectAllCheckbox.state = .on
        } else if selectedFiles.isEmpty {
            selectAllCheckbox.state = .off
        } else {
            selectAllCheckbox.state = .mixed
        }
    }
    
    @objc private func doCommit(_ sender: Any?) {
        let message = messageTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Empty commit message"
            alert.informativeText = "Please enter a commit message."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        
        guard !selectedFiles.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No files selected"
            alert.informativeText = "Please select at least one file to commit."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        
        Task {
            do {
                try await GitCommandRunner.shared.add(at: repositoryPath, files: Array(selectedFiles))
                try await GitCommandRunner.shared.commit(at: repositoryPath, message: message)
                
                await MainActor.run {
                    self.window?.close()
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            }
        }
    }
    
    @objc private func doCancel(_ sender: Any?) {
        window?.close()
    }
}

// MARK: - Table View

extension CommitWindowController: NSTableViewDataSource, NSTableViewDelegate {
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return statusEntries.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = statusEntries[row]
        
        switch tableColumn?.identifier.rawValue {
        case "check":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(fileCheckboxToggled(_:)))
            checkbox.tag = row
            checkbox.state = selectedFiles.contains(entry.filePath) ? .on : .off
            return checkbox
            
        case "status":
            let label = NSTextField(labelWithString: statusText(for: entry.displayStatus))
            label.textColor = statusColor(for: entry.displayStatus)
            label.font = NSFont.systemFont(ofSize: 12)
            return label
            
        case "file":
            let label = NSTextField(labelWithString: entry.filePath)
            label.font = NSFont.systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            return label
            
        default:
            return nil
        }
    }
    
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 22
    }
    
    private func statusText(for status: GitFileStatus) -> String {
        switch status {
        case .modified:   return "Modified"
        case .added:      return "Added"
        case .deleted:    return "Deleted"
        case .renamed:    return "Renamed"
        case .copied:     return "Copied"
        case .untracked:  return "Untracked"
        case .conflicted: return "Conflict"
        case .ignored:    return "Ignored"
        default:          return "Normal"
        }
    }
    
    private func statusColor(for status: GitFileStatus) -> NSColor {
        switch status {
        case .modified:   return .systemOrange
        case .added:      return .systemGreen
        case .deleted:    return .systemRed
        case .untracked:  return .systemBlue
        case .conflicted: return .systemYellow
        default:          return .labelColor
        }
    }
}
