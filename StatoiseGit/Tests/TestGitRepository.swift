import Foundation

/// Helper to create and manage temporary git repositories for testing
class TestGitRepository {
    let rootURL: URL
    var path: String { rootURL.path }

    private init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Create a new temporary git repository with an initial commit
    static func create() throws -> TestGitRepository {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatoiseGitTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let repo = TestGitRepository(rootURL: tempDir)
        try repo.git("init")
        try repo.git("config", "user.email", "test@example.com")
        try repo.git("config", "user.name", "Test User")

        // Initial commit
        try repo.writeFile("README.md", content: "# Test Repo\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "Initial commit")

        return repo
    }

    /// Create a repo with a submodule
    static func createWithSubmodule() throws -> (main: TestGitRepository, sub: TestGitRepository) {
        // Create the submodule repo first
        let subRepo = try create()
        try subRepo.writeFile("lib.txt", content: "library content\n")
        try subRepo.git("add", ".")
        try subRepo.git("commit", "-m", "Add lib")

        // Create main repo and add submodule using file:// protocol
        let mainRepo = try create()
        try mainRepo.git("-c", "protocol.file.allow=always", "submodule", "add", "file://\(subRepo.path)", "libs/mylib")
        try mainRepo.git("commit", "-m", "Add submodule")

        return (mainRepo, subRepo)
    }

    func writeFile(_ relativePath: String, content: String) throws {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func readFile(_ relativePath: String) throws -> String {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func deleteFile(_ relativePath: String) throws {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
    }

    func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(relativePath).path)
    }

    @discardableResult
    func git(_ args: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = rootURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw NSError(domain: "TestGit", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(output)"])
        }
        return output
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    deinit {
        cleanup()
    }
}
