import Cocoa

class DiffWindowController: NSWindowController {
    
    private let repositoryPath: String
    private let file: String?
    private var diffTextView: NSTextView!
    private var preloadedDiff: String?
    
    init(repositoryPath: String, file: String?) {
        self.repositoryPath = repositoryPath
        self.file = file
        self.preloadedDiff = nil
        
        let fileName = file ?? URL(fileURLWithPath: repositoryPath).lastPathComponent
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Diff - \(fileName)"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        setupUI()
        loadDiff()
    }
    
    /// Initialize with pre-loaded diff content
    init(repositoryPath: String, diffContent: String, title: String) {
        self.repositoryPath = repositoryPath
        self.file = nil
        self.preloadedDiff = diffContent
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Diff - \(title)"
        window.center()
        window.isReleasedWhenClosed = false
        
        super.init(window: window)
        setupUI()
        
        // Display pre-loaded diff
        diffTextView.string = diffContent
        colorizeDiff(diffContent)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        guard let window = window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        
        // Refresh button
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        refreshButton.frame = NSRect(x: 10, y: 565, width: 80, height: 28)
        refreshButton.autoresizingMask = [.maxXMargin, .minYMargin]
        refreshButton.bezelStyle = .rounded
        contentView.addSubview(refreshButton)
        
        // Diff text view
        let scrollView = NSScrollView(frame: NSRect(x: 10, y: 10, width: 780, height: 550))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        
        diffTextView = NSTextView(frame: scrollView.bounds)
        diffTextView.isEditable = false
        diffTextView.isRichText = true
        diffTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        diffTextView.autoresizingMask = [.width]
        diffTextView.isVerticallyResizable = true
        diffTextView.isHorizontallyResizable = true
        diffTextView.textContainer?.widthTracksTextView = false
        diffTextView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = diffTextView
        contentView.addSubview(scrollView)
        
        window.contentView = contentView
    }
    
    private func loadDiff() {
        Task {
            do {
                let output: String
                if let file = file, !file.isEmpty {
                    output = try await GitCommandRunner.shared.diff(at: repositoryPath, file: file)
                } else {
                    output = try await GitCommandRunner.shared.diff(at: repositoryPath)
                }
                
                let displayText = output.isEmpty ? "(No changes)" : output
                
                await MainActor.run {
                    self.colorizeDiff(displayText)
                }
            } catch {
                await MainActor.run {
                    self.diffTextView.string = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func colorizeDiff(_ text: String) {
        guard let textStorage = diffTextView.textStorage else { return }
        
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: monoFont,
            .foregroundColor: NSColor.labelColor
        ]
        
        let attributed = NSMutableAttributedString(string: text, attributes: defaultAttrs)
        
        let lines = text.components(separatedBy: "\n")
        var location = 0
        
        for line in lines {
            let lineRange = NSRange(location: location, length: line.count)
            
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemBrown, range: lineRange)
                attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: lineRange)
            } else if line.hasPrefix("+") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: lineRange)
                attributed.addAttribute(.backgroundColor, value: NSColor.systemGreen.withAlphaComponent(0.1), range: lineRange)
            } else if line.hasPrefix("-") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: lineRange)
                attributed.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.1), range: lineRange)
            } else if line.hasPrefix("@@") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemCyan, range: lineRange)
            } else if line.hasPrefix("diff ") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemYellow, range: lineRange)
                attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: lineRange)
            }
            
            location += line.count + 1 // +1 for newline
        }
        
        textStorage.setAttributedString(attributed)
    }
    
    @objc private func refresh(_ sender: Any?) {
        loadDiff()
    }
}
