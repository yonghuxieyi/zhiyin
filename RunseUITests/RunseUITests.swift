import XCTest

final class RunseUITests: XCTestCase {
    func testPrimaryTabsExist() {
        let app = XCUIApplication()
        app.launchArguments = ["ZHIYIN_SKIP_GUIDE"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["翻译"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["语音"].exists)
        XCTAssertTrue(app.tabBars.buttons["同传"].exists)
        XCTAssertTrue(app.tabBars.buttons["拍照"].exists)
        XCTAssertTrue(app.tabBars.buttons["设置"].exists)
        XCTAssertFalse(app.tabBars.buttons["Providers"].exists)
        XCTAssertFalse(app.tabBars.buttons["Prompts"].exists)
        XCTAssertFalse(app.tabBars.buttons["History"].exists)
        XCTAssertFalse(app.tabBars.buttons["Try"].exists)
    }
}
