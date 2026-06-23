import XCTest

/// Tests for submodule display behavior
final class GitSubmoduleTests: XCTestCase {

    var mainRepo: TestGitRepository!
    var subRepo: TestGitRepository!

    override func setUp() async throws {
        let repos = try TestGitRepository.createWithSubmodule()
        mainRepo = repos.main
        subRepo = repos.sub
    }

    override func tearDown() {
        mainRepo?.cleanup()
        subRepo?.cleanup()
        mainRepo = nil
        subRepo = nil
    }

    // MARK: - Submodule detection

    func testSubmoduleDetectedInTreeEntry() async throws {
        let entry = try await GitCommandRunner.shared.treeEntry(at: mainRepo.path, revision: "HEAD", file: "libs/mylib")
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.isSubmodule, "libs/mylib should be detected as a submodule")
        XCTAssertEqual(entry!.mode, "160000")
    }

    // MARK: - Submodule SHA diff (2-pane: SHA difference)

    func testSubmoduleSHADiffAfterUpdate() async throws {
        // Advance the submodule
        try subRepo.writeFile("lib.txt", content: "updated library\n")
        try subRepo.git("add", ".")
        try subRepo.git("commit", "-m", "Update lib")
        let newSHA = try subRepo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        // Get the branch name of the sub repo
        let branch = try subRepo.git("rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

        // Update the submodule reference in main repo by pulling in the submodule dir
        let subPath = mainRepo.rootURL.appendingPathComponent("libs/mylib").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", subPath, "-c", "protocol.file.allow=always", "pull", "origin", branch]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        try mainRepo.git("add", "libs/mylib")
        try mainRepo.git("commit", "-m", "Bump submodule")

        // Verify the commit diff shows submodule SHA change
        let entries = try await GitCommandRunner.shared.logEntries(at: mainRepo.path)
        let latestHash = entries[0].hash
        let diff = try await GitCommandRunner.shared.commitFileDiff(at: mainRepo.path, hash: latestHash, file: "libs/mylib")
        // diff --submodule=log shows "Submodule libs/mylib SHA1..SHA2"
        XCTAssertTrue(diff.contains("Submodule") || diff.contains("160000") || diff.contains(String(newSHA.prefix(7))),
                      "Diff should show submodule SHA change. Got: \(diff)")
    }

    // MARK: - Submodule export for external diff (2-pane)

    func testExportSubmoduleAtRevisionProducesSummaryFile() async throws {
        let entries = try await GitCommandRunner.shared.logEntries(at: mainRepo.path)
        let hash = entries[0].hash // "Add submodule" commit

        let tempPath = try await GitCommandRunner.shared.exportFileAtRevision(at: mainRepo.path, hash: hash, file: "libs/mylib")
        let content = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertTrue(content.contains("Submodule: libs/mylib"))
        XCTAssertTrue(content.contains("Commit:"))
    }

    // MARK: - Submodule status in working tree

    func testSubmoduleStatus() async throws {
        let status = try await GitCommandRunner.shared.status(at: mainRepo.path)
        // After adding submodule and committing, status should be clean
        let subEntries = status.filter { $0.filePath.contains("libs/mylib") }
        XCTAssertTrue(subEntries.isEmpty, "Submodule should not appear as dirty when clean")
    }

    // MARK: - submodule update --init

    func testSubmoduleUpdate() async throws {
        // De-init the submodule manually
        let subPath = mainRepo.rootURL.appendingPathComponent("libs/mylib").path
        try? FileManager.default.removeItem(atPath: subPath)
        try FileManager.default.createDirectory(atPath: subPath, withIntermediateDirectories: true)

        // Use git directly with protocol config since GitCommandRunner doesn't pass it
        try mainRepo.git("-c", "protocol.file.allow=always", "submodule", "update", "--init")

        // After update --init, the submodule should have content
        let libFile = mainRepo.rootURL.appendingPathComponent("libs/mylib/lib.txt").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: libFile),
                      "Submodule content should be restored after update --init")
    }
}
