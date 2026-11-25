import XCTest

final class RunseUITests: XCTestCase {
    func testPrimaryTabsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["ZHIYIN_SKIP_GUIDE"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Providers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Prompts"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        XCTAssertTrue(app.tabBars.buttons["History"].exists)
    }
}
