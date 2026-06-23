import XCTest

/// Tests for context-switch git operations:
/// reset --hard, clean -xdf, stash, submodule update
final class GitContextSwitchTests: XCTestCase {

    var repo: TestGitRepository!

    override func setUp() async throws {
        repo = try TestGitRepository.create()
    }

    override func tearDown() {
        repo?.cleanup()
        repo = nil
    }

    // MARK: - git reset --hard HEAD

    func testResetHardDiscardsModifications() async throws {
        try repo.writeFile("README.md", content: "dirty change\n")
        let statusBefore = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertFalse(statusBefore.isEmpty, "Should have modified file")

        try await GitCommandRunner.shared.resetHard(at: repo.path)

        let statusAfter = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertTrue(statusAfter.isEmpty, "Working tree should be clean after reset --hard")
    }

    func testResetHardDiscardsStagedChanges() async throws {
        try repo.writeFile("staged.txt", content: "staged\n")
        try repo.git("add", "staged.txt")

        try await GitCommandRunner.shared.resetHard(at: repo.path)

        let status = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertTrue(status.isEmpty, "Staged files should be discarded after reset --hard")
    }

    // MARK: - git clean -xdf

    func testCleanRemovesUntrackedFiles() async throws {
        try repo.writeFile("untracked.txt", content: "junk\n")
        try repo.writeFile("build/output.o", content: "binary\n")

        try await GitCommandRunner.shared.cleanAll(at: repo.path)

        XCTAssertFalse(repo.fileExists("untracked.txt"), "Untracked file should be removed")
        XCTAssertFalse(repo.fileExists("build/output.o"), "Untracked dir should be removed")
    }

    func testCleanDoesNotRemoveTrackedFiles() async throws {
        try repo.writeFile("untracked.txt", content: "remove me\n")

        try await GitCommandRunner.shared.cleanAll(at: repo.path)

        XCTAssertTrue(repo.fileExists("README.md"), "Tracked file should remain")
        XCTAssertFalse(repo.fileExists("untracked.txt"), "Untracked file should be removed")
    }

    // MARK: - git stash save --include-untracked

    func testStashSaveAndPop() async throws {
        try repo.writeFile("README.md", content: "stashed change\n")
        try repo.writeFile("new_file.txt", content: "untracked stashed\n")

        try await GitCommandRunner.shared.stashSave(at: repo.path, message: "test stash", includeUntracked: true)

        // Working tree should be clean after stash
        let statusAfterSave = try await GitCommandRunner.shared.status(at: repo.path)
        XCTAssertTrue(statusAfterSave.isEmpty, "Working tree should be clean after stash save")
        XCTAssertFalse(repo.fileExists("new_file.txt"), "Untracked file should be stashed")

        // Pop the stash
        try await GitCommandRunner.shared.stashPop(at: repo.path)

        // Changes should be restored
        let content = try repo.readFile("README.md")
        XCTAssertEqual(content, "stashed change\n")
        XCTAssertTrue(repo.fileExists("new_file.txt"), "Untracked file should be restored")
    }

    func testStashSaveWithMessage() async throws {
        try repo.writeFile("README.md", content: "change\n")

        try await GitCommandRunner.shared.stashSave(at: repo.path, message: "my custom message", includeUntracked: true)

        let list = try await GitCommandRunner.shared.stashList(at: repo.path)
        XCTAssertTrue(list.contains("my custom message"), "Stash list should contain the message")
    }

    func testStashList() async throws {
        // Create two stashes
        try repo.writeFile("README.md", content: "first\n")
        try await GitCommandRunner.shared.stashSave(at: repo.path, message: "first stash", includeUntracked: false)

        try repo.writeFile("README.md", content: "second\n")
        try await GitCommandRunner.shared.stashSave(at: repo.path, message: "second stash", includeUntracked: false)

        let list = try await GitCommandRunner.shared.stashList(at: repo.path)
        XCTAssertTrue(list.contains("first stash"))
        XCTAssertTrue(list.contains("second stash"))
    }

    // MARK: - Revert (checkout HEAD --)

    func testRevertFile() async throws {
        try repo.writeFile("README.md", content: "dirty\n")

        try await GitCommandRunner.shared.revert(at: repo.path, files: ["README.md"])

        let content = try repo.readFile("README.md")
        XCTAssertEqual(content, "# Test Repo\n", "File should be reverted to HEAD")
    }

    func testRevertMultipleFiles() async throws {
        try repo.writeFile("a.txt", content: "a\n")
        try repo.writeFile("b.txt", content: "b\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Add a and b")

        try repo.writeFile("a.txt", content: "modified a\n")
        try repo.writeFile("b.txt", content: "modified b\n")

        try await GitCommandRunner.shared.revert(at: repo.path, files: ["a.txt", "b.txt"])

        XCTAssertEqual(try repo.readFile("a.txt"), "a\n")
        XCTAssertEqual(try repo.readFile("b.txt"), "b\n")
    }
}
