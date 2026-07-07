import XCTest

/// Tests for files/paths that start with a dot (hidden files and dot-directories).
/// Reproduces reported issues where diffs are not shown correctly for such paths.
final class GitDotPathTests: XCTestCase {

    var repo: TestGitRepository!

    override func setUp() async throws {
        repo = try TestGitRepository.create()
    }

    override func tearDown() {
        repo?.cleanup()
        repo = nil
    }

    // MARK: - Status

    func testStatusDotFile() async throws {
        try repo.writeFile(".gitignore", content: "*.log\n")

        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, ".gitignore")
        XCTAssertEqual(entries[0].workTreeStatus, .untracked)
    }

    func testStatusFileInsideDotFolder() async throws {
        try repo.writeFile(".github/workflows/ci.yml", content: "name: CI\n")

        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, ".github/workflows/ci.yml")
    }

    // MARK: - Working tree diff

    func testDiffDotFile() async throws {
        try repo.writeFile(".gitignore", content: "*.log\n")
        try repo.git("add", ".gitignore")
        try repo.git("commit", "-m", "Add gitignore")

        try repo.writeFile(".gitignore", content: "*.log\n*.tmp\n")

        let diff = try await GitCommandRunner.shared.diff(at: repo.path, file: ".gitignore")
        XCTAssertFalse(diff.isEmpty, "Diff for a dot-file should not be empty")
        XCTAssertTrue(diff.contains(".gitignore"), "Diff should reference the file path")
        XCTAssertTrue(diff.contains("*.tmp"), "Diff should contain the added line")
    }

    func testDiffFileInsideDotFolder() async throws {
        try repo.writeFile(".github/workflows/ci.yml", content: "name: CI\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Add workflow")

        try repo.writeFile(".github/workflows/ci.yml", content: "name: CI\non: push\n")

        let diff = try await GitCommandRunner.shared.diff(at: repo.path, file: ".github/workflows/ci.yml")
        XCTAssertFalse(diff.isEmpty, "Diff for a file inside a dot-folder should not be empty")
        XCTAssertTrue(diff.contains("on: push"), "Diff should contain the added line")
    }

    // MARK: - Commit diff

    func testCommitFileDiffDotFile() async throws {
        try repo.writeFile(".gitignore", content: "*.log\n")
        try repo.git("add", ".gitignore")
        try repo.git("commit", "-m", "Add gitignore")

        try repo.writeFile(".gitignore", content: "*.log\n*.tmp\n")
        try repo.git("add", ".gitignore")
        try repo.git("commit", "-m", "Update gitignore")

        let entries = try await GitCommandRunner.shared.logEntries(at: repo.path)
        let latestHash = entries[0].hash

        let diff = try await GitCommandRunner.shared.commitFileDiff(at: repo.path, hash: latestHash, file: ".gitignore")
        XCTAssertFalse(diff.isEmpty, "Commit diff for a dot-file should not be empty")
        XCTAssertTrue(diff.contains("*.tmp"))
    }

    func testCommitFilesListingDotPaths() async throws {
        try repo.writeFile(".env", content: "A=1\n")
        try repo.writeFile(".github/workflows/ci.yml", content: "name: CI\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Add dot paths")

        let entries = try await GitCommandRunner.shared.logEntries(at: repo.path)
        let latestHash = entries[0].hash

        let files = try await GitCommandRunner.shared.commitFiles(at: repo.path, hash: latestHash)
        let joined = files.joined(separator: "\n")
        XCTAssertTrue(joined.contains(".env"), "commitFiles should list .env, got: \(joined)")
        XCTAssertTrue(joined.contains(".github/workflows/ci.yml"), "commitFiles should list dot-folder path, got: \(joined)")
    }

    // MARK: - Export for external diff

    func testExportDotFileAtRevision() async throws {
        try repo.writeFile(".gitignore", content: "*.log\n")
        try repo.git("add", ".gitignore")
        try repo.git("commit", "-m", "Add gitignore")

        let entries = try await GitCommandRunner.shared.logEntries(at: repo.path)
        let latestHash = entries[0].hash

        let tempPath = try await GitCommandRunner.shared.exportFileAtRevision(at: repo.path, hash: latestHash, file: ".gitignore")
        let content = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertTrue(content.contains("*.log"), "Exported dot-file content should match, got temp path: \(tempPath)")
    }

    func testExportFileInsideDotFolderAtRevision() async throws {
        try repo.writeFile(".github/workflows/ci.yml", content: "name: CI\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Add workflow")

        let entries = try await GitCommandRunner.shared.logEntries(at: repo.path)
        let latestHash = entries[0].hash

        let tempPath = try await GitCommandRunner.shared.exportFileAtRevision(at: repo.path, hash: latestHash, file: ".github/workflows/ci.yml")
        let content = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertTrue(content.contains("name: CI"), "Exported dot-folder file content should match, got temp path: \(tempPath)")
    }

    func testExportWorkingTreeDotFile() async throws {
        try repo.writeFile(".gitignore", content: "*.log\n")
        try repo.git("add", ".gitignore")
        try repo.git("commit", "-m", "Add gitignore")
        try repo.writeFile(".gitignore", content: "*.log\n*.tmp\n")

        let tempPath = try await GitCommandRunner.shared.exportWorkingTreeItemForDiff(at: repo.path, file: ".gitignore")
        let content = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertTrue(content.contains("*.tmp"), "Working tree dot-file export should contain latest content, got: \(tempPath)")
    }

    // MARK: - Temp file naming (external diff)

    /// Demonstrates how temp file names are generated for dot-files.
    /// For a dot-file like `.gitignore`, the current logic keeps the leading dot in the
    /// base name and appends a `.txt` extension, producing a *hidden* temp file such as
    /// `/tmp/.gitignore_HEAD.txt`. This is the most likely source of "diff not shown
    /// correctly" for dot-files when using an external diff tool.
    func testTempFileNamingForDotFile() async throws {
        let emptyTemp = try GitCommandRunner.shared.createEmptyTempFile(for: ".gitignore", suffix: "_HEAD")
        let name = (emptyTemp as NSString).lastPathComponent
        print("DOTFILE-TEMP: \(emptyTemp)")

        // The generated temp file should NOT be a hidden file, and should keep a
        // recognizable name for the dot-file.
        XCTAssertFalse(name.hasPrefix("."), "Temp file for a dot-file should not itself be hidden, got: \(name)")
        XCTAssertTrue(name.contains("gitignore"), "Temp file should reference the original name, got: \(name)")
    }

    func testTempFileNamingForFileInsideDotFolder() async throws {
        let emptyTemp = try GitCommandRunner.shared.createEmptyTempFile(for: ".github/workflows/ci.yml", suffix: "_HEAD")
        let name = (emptyTemp as NSString).lastPathComponent
        print("DOTFOLDER-TEMP: \(emptyTemp)")

        XCTAssertFalse(name.hasPrefix("."), "Temp file should not be hidden, got: \(name)")
        XCTAssertEqual((name as NSString).pathExtension, "yml", "Extension should be preserved for dot-folder file, got: \(name)")
    }
}
