import XCTest

/// Tests for the repository lookup the Finder extension runs on every drawn item
final class RepositoryLocatorTests: XCTestCase {

    var repo: TestGitRepository!

    override func setUp() async throws {
        repo = try TestGitRepository.create()
    }

    override func tearDown() {
        repo?.cleanup()
        repo = nil
    }

    // MARK: - Repository root

    func testRepositoryRootForRootItself() {
        XCTAssertEqual(RepositoryLocator.repositoryRoot(containing: repo.path), repo.path)
    }

    func testRepositoryRootForFileInRepository() {
        let file = (repo.path as NSString).appendingPathComponent("README.md")
        XCTAssertEqual(RepositoryLocator.repositoryRoot(containing: file), repo.path)
    }

    func testRepositoryRootForNestedDirectory() throws {
        try repo.writeFile("a/b/c/deep.txt", content: "deep\n")
        let nested = (repo.path as NSString).appendingPathComponent("a/b/c")
        XCTAssertEqual(RepositoryLocator.repositoryRoot(containing: nested), repo.path)
    }

    func testRepositoryRootIsNilOutsideAnyRepository() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatoiseGitTests_plain_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertNil(RepositoryLocator.repositoryRoot(containing: outside.path))
    }

    func testRepositoryRootForNonExistentPathWalksUp() {
        let missing = (repo.path as NSString).appendingPathComponent("does/not/exist.txt")
        XCTAssertEqual(RepositoryLocator.repositoryRoot(containing: missing), repo.path)
    }

    // MARK: - Submodules

    func testSubmoduleResolvesToItselfNotTheSuperproject() throws {
        let repos = try TestGitRepository.createWithSubmodule()
        defer {
            repos.main.cleanup()
            repos.sub.cleanup()
        }

        let submodule = (repos.main.path as NSString).appendingPathComponent("libs/mylib")
        let fileInSubmodule = (submodule as NSString).appendingPathComponent("lib.txt")

        // A submodule's .git is a file, and git reports status against the submodule.
        XCTAssertTrue(RepositoryLocator.isRepositoryRoot(submodule))
        XCTAssertEqual(RepositoryLocator.repositoryRoot(containing: fileInSubmodule), submodule)
    }

    // MARK: - Repository root detection

    func testIsRepositoryRoot() {
        XCTAssertTrue(RepositoryLocator.isRepositoryRoot(repo.path))
        XCTAssertFalse(RepositoryLocator.isRepositoryRoot((repo.path as NSString).deletingLastPathComponent))
    }

    // MARK: - Exclusions

    func testExcludesGitInternalsAndNoisyDirectories() {
        XCTAssertTrue(RepositoryLocator.isExcluded("/Users/someone/proj/.git/config"))
        XCTAssertTrue(RepositoryLocator.isExcluded("/Users/someone/proj/node_modules/left-pad/index.js"))
        XCTAssertTrue(RepositoryLocator.isExcluded("/Users/someone/proj/DerivedData/Build"))
        XCTAssertTrue(RepositoryLocator.isExcluded(RepositoryLocator.homeDirectory + "/Library/Caches/x"))
    }

    func testDoesNotExcludeOrdinaryPaths() {
        XCTAssertFalse(RepositoryLocator.isExcluded("/Users/someone/proj/Sources/App/main.swift"))
        XCTAssertFalse(RepositoryLocator.isExcluded(repo.path))
    }

    func testHomeDirectoryIsOutsideAnySandboxContainer() {
        XCTAssertFalse(RepositoryLocator.homeDirectory.contains("/Library/Containers/"))
    }
}
