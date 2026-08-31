import XCTest

/// Basic functionality tests for GitCommandRunner
final class GitCommandRunnerBasicTests: XCTestCase {

    var repo: TestGitRepository!

    override func setUp() async throws {
        repo = try TestGitRepository.create()
    }

    override func tearDown() {
        repo?.cleanup()
        repo = nil
    }

    // MARK: - Repository detection

    func testIsGitRepository() async {
        let result = await GitCommandRunner.shared.isGitRepository(at: repo.path)
        XCTAssertTrue(result)
    }

    func testIsNotGitRepository() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("not_a_repo_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = await GitCommandRunner.shared.isGitRepository(at: tempDir.path)
        XCTAssertFalse(result)
    }

    // MARK: - Status

    func testStatusClean() async throws {
        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertTrue(entries.isEmpty)
    }

    func testStatusModifiedFile() async throws {
        try repo.writeFile("README.md", content: "# Modified\n")

        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "README.md")
        XCTAssertEqual(entries[0].workTreeStatus, .modified)
    }

    func testStatusUntrackedFile() async throws {
        try repo.writeFile("new_file.txt", content: "hello\n")

        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "new_file.txt")
        XCTAssertEqual(entries[0].workTreeStatus, .untracked)
    }

    func testStatusAddedFile() async throws {
        try repo.writeFile("staged.txt", content: "staged content\n")
        try repo.git("add", "staged.txt")

        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].filePath, "staged.txt")
        XCTAssertEqual(entries[0].indexStatus, .added)
    }

    // MARK: - Commit

    func testCommit() async throws {
        try repo.writeFile("file.txt", content: "content\n")
        try await GitCommandRunner.shared.add(at: repo.path, files: ["file.txt"])
        try await GitCommandRunner.shared.commit(at: repo.path, message: "Add file")

        let entries = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertTrue(entries.isEmpty, "Working tree should be clean after commit")
    }

    /// A failing commit must carry git's own explanation. `git commit` with an
    /// empty index reports "nothing to commit" on stdout, not stderr, so an
    /// error that only captured stderr would be blank in the dialog.
    func testFailedCommitCarriesGitOutput() async {
        do {
            try await GitCommandRunner.shared.commit(at: repo.path, message: "Nothing staged")
            XCTFail("Committing an empty index should fail")
        } catch let error as GitError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
            XCTAssertTrue(
                error.diagnosticDetails.contains("nothing to commit"),
                "Details should quote git verbatim, got: \(error.diagnosticDetails)"
            )
            XCTAssertTrue(error.diagnosticDetails.contains("git commit"))
        } catch {
            XCTFail("Expected GitError, got \(error)")
        }
    }

    /// Guards the concurrent pipe drain: a command whose output exceeds the
    /// 64KB pipe buffer used to deadlock when the pipes were read in sequence.
    func testLargeOutputDoesNotDeadlock() async throws {
        let bigContent = String(repeating: "line of text for the diff\n", count: 20_000)
        try repo.writeFile("README.md", content: bigContent)

        let diff = try await GitCommandRunner.shared.diff(at: repo.path)
        XCTAssertGreaterThan(diff.count, 65_536)
    }

    // MARK: - Diff

    func testDiff() async throws {
        try repo.writeFile("README.md", content: "# Changed Content\n")

        let diff = try await GitCommandRunner.shared.diff(at: repo.path)
        XCTAssertTrue(diff.contains("Changed Content"))
        XCTAssertTrue(diff.contains("README.md"))
    }

    func testDiffSpecificFile() async throws {
        try repo.writeFile("README.md", content: "# Changed\n")
        try repo.writeFile("other.txt", content: "other\n")

        let diff = try await GitCommandRunner.shared.diff(at: repo.path, file: "README.md")
        XCTAssertTrue(diff.contains("Changed"))
        XCTAssertFalse(diff.contains("other"))
    }

    // MARK: - Log

    func testLogEntries() async throws {
        // Make a second commit
        try repo.writeFile("second.txt", content: "second\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Second commit")

        let entries = try await GitCommandRunner.shared.logEntries(at: repo.path)
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        XCTAssertEqual(entries[0].subject, "Second commit")
        XCTAssertEqual(entries[1].subject, "Initial commit")
    }

    func testCommitFileDiff() async throws {
        try repo.writeFile("README.md", content: "# Updated\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Update readme")

        let entries = try await GitCommandRunner.shared.logEntries(at: repo.path)
        let latestHash = entries[0].hash

        let diff = try await GitCommandRunner.shared.commitFileDiff(at: repo.path, hash: latestHash, file: "README.md")
        XCTAssertTrue(diff.contains("Updated"))
    }

    // MARK: - File Log

    func testFileLogEntries() async throws {
        try repo.writeFile("tracked.txt", content: "v1\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Add tracked")

        try repo.writeFile("tracked.txt", content: "v2\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Update tracked")

        let entries = try await GitCommandRunner.shared.fileLogEntries(at: repo.path, file: "tracked.txt")
        XCTAssertGreaterThanOrEqual(entries.count, 2)
        XCTAssertEqual(entries[0].subject, "Update tracked")
        XCTAssertEqual(entries[1].subject, "Add tracked")
    }

    // MARK: - Branch

    func testCurrentBranch() async throws {
        let branch = try await GitCommandRunner.shared.currentBranch(at: repo.path)
        // Modern git may use "main" or "master" depending on config
        XCTAssertFalse(branch.isEmpty)
    }
}
