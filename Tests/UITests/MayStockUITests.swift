import XCTest

final class MayStockUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testAppLaunchesAsAccessory() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    func testMenuBarItemExists() throws {
        let statusItems = app.statusItems
        XCTAssertTrue(statusItems.count > 0, "Should have at least one status item")
    }

    func testRightClickOpensSettings() throws {
        let statusItem = app.statusItems.firstMatch
        statusItem.rightClick()
        let settingsMenuItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 2))
    }
}
