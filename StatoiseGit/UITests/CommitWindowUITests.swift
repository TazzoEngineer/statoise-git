import XCTest

/// UI Tests for Statoise Git commit window context menu
final class CommitWindowUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Commit window context menu

    /// Verify right-clicking on a file item shows "Revert" option
    func testContextMenuShowsRevert() throws {
        // Open commit window via menu
        app.menuBars.menuBarItems["Action"].click()
        app.menuBars.menuBarItems["Action"].menuItems["Commit…"].click()

        let commitWindow = app.windows["Commit"]
        XCTAssertTrue(commitWindow.waitForExistence(timeout: 5), "Commit window should appear")

        // Wait for the file table to populate
        let table = commitWindow.tables.firstMatch
        guard table.waitForExistence(timeout: 5) else {
            XCTSkip("No files in commit window (clean working tree)")
            return
        }

        let firstRow = table.tableRows.firstMatch
        guard firstRow.waitForExistence(timeout: 3) else {
            XCTSkip("No file entries in table")
            return
        }

        // Right-click to show context menu
        firstRow.rightClick()

        let revertItem = app.menuItems["Revert"]
        XCTAssertTrue(revertItem.waitForExistence(timeout: 2), "Context menu should have 'Revert' option")
    }

    /// Verify right-clicking on a file item shows "Delete" option
    func testContextMenuShowsDelete() throws {
        app.menuBars.menuBarItems["Action"].click()
        app.menuBars.menuBarItems["Action"].menuItems["Commit…"].click()

        let commitWindow = app.windows["Commit"]
        XCTAssertTrue(commitWindow.waitForExistence(timeout: 5), "Commit window should appear")

        let table = commitWindow.tables.firstMatch
        guard table.waitForExistence(timeout: 5) else {
            XCTSkip("No files in commit window (clean working tree)")
            return
        }

        let firstRow = table.tableRows.firstMatch
        guard firstRow.waitForExistence(timeout: 3) else {
            XCTSkip("No file entries in table")
            return
        }

        firstRow.rightClick()

        let deleteItem = app.menuItems["Delete"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 2), "Context menu should have 'Delete' option")
    }
}
