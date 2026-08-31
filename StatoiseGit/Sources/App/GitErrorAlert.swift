import Cocoa

/// Presents a git failure so the actual message from git is readable, selectable
/// and copyable. `NSAlert(error:)` crams everything into the bold title line and
/// truncates anything long, which is useless for diagnosing a failed commit.
enum GitErrorAlert {

    /// - Parameters:
    ///   - title: what the user was trying to do, e.g. "Commit failed".
    ///   - window: when given, the alert is shown as a sheet on that window.
    @MainActor
    static func present(_ error: Error, title: String, window: NSWindow? = nil) {
        let summary: String
        let details: String

        if let gitError = error as? GitError {
            summary = gitError.errorDescription ?? "\(error)"
            details = gitError.diagnosticDetails
        } else {
            summary = error.localizedDescription
            details = (error as NSError).description
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = summary
        alert.accessoryView = detailView(for: details)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Details")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("\(title)\n\(summary)\n\n\(details)", forType: .string)
        }

        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    @MainActor
    private static func detailView(for details: String) -> NSView {
        let width: CGFloat = 460
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        // Measure the text so short errors get a compact box instead of a
        // half-empty one, while long output stays scrollable.
        let measured = NSAttributedString(string: details, attributes: [.font: font])
            .boundingRect(
                with: NSSize(width: width - 12, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        let height = min(max(ceil(measured.height) + 12, 60), 260)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = font
        textView.string = details
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }
}
