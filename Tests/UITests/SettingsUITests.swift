import XCTest

final class SettingsUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testSettingsTabsExist() throws {
        let statusItem = app.statusItems.firstMatch
        statusItem.rightClick()
        app.menuItems["Settings…"].click()

        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(settingsWindow.buttons["General"].exists)
        XCTAssertTrue(settingsWindow.buttons["Monitors"].exists)
        XCTAssertTrue(settingsWindow.buttons["Appearance"].exists)
    }
}
