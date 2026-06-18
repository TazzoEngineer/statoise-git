import Cocoa

class LogWindowController: NSWindowController {
    
    private let repositoryPath: String
    private var logTextView: NSTextView!
    
    init(repositoryPath: String) {
        self.repositoryPath = repositoryPath
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Git Log - \(URL(fileURLWithPath: repositoryPath).lastPathComponent)"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        setupUI()
        loadLog()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Toolbar buttons
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        refreshButton.frame = NSRect(x: 10, y: 465, width: 80, height: 28)
        refreshButton.autoresizingMask = [.maxXMargin, .minYMargin]
        refreshButton.bezelStyle = .rounded
        contentView.addSubview(refreshButton)
        
        let countLabel = NSTextField(labelWithString: "Entries:")
        countLabel.frame = NSRect(x: 100, y: 468, width: 50, height: 20)
        countLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(countLabel)
        
        let countField = NSPopUpButton(frame: NSRect(x: 155, y: 465, width: 80, height: 28))
        countField.addItems(withTitles: ["25", "50", "100", "200", "500"])
        countField.selectItem(withTitle: "50")
        countField.tag = 50
        countField.target = self
        countField.action = #selector(countChanged(_:))
        countField.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(countField)
        
        // Log text view (monospaced, for git log --graph output)
        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 780, height: 450))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        
        logTextView = NSTextView(frame: scrollView.bounds)
        logTextView.isEditable = false
        logTextView.isRichText = false
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.autoresizingMask = [.width]
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = true
        logTextView.textContainer?.widthTracksTextView = false
        logTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = logTextView
        contentView.addSubview(scrollView)
        
        window.contentView = contentView
    }
    
    private var maxCount = 50
    
    private func loadLog() {
        Task {
            do {
                let output = try await GitCommandRunner.shared.log(at: repositoryPath, maxCount: maxCount)
                
                await MainActor.run {
                    self.logTextView.string = output
                    self.colorizeLog()
                }
            } catch {
                await MainActor.run {
                    self.logTextView.string = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func colorizeLog() {
        guard let textStorage = logTextView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string
        
        // Color branch/tag decorations
        let decoPattern = try? NSRegularExpression(pattern: "\\(([^)]+)\\)", options: [])
        decoPattern?.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            if let range = match?.range {
                textStorage.addAttribute(.foregroundColor, value: NSColor.systemYellow, range: range)
            }
        }
        
        // Color commit hashes (short, 7+ hex chars at line start after graph chars)
        let hashPattern = try? NSRegularExpression(pattern: "(?<=[ *|/\\\\])([0-9a-f]{7,})(?= )", options: [])
        hashPattern?.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            if let range = match?.range(at: 1) {
                textStorage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
            }
        }
    }
    
    @objc private func refresh(_ sender: Any?) {
        loadLog()
    }
    
    @objc private func countChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title, let count = Int(title) {
            maxCount = count
            loadLog()
        }
    }
}
