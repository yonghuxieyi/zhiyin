import XCTest

/// Smoke test for picking the DeepSeek model through the model picker.
///
/// The old version of this test walked the Providers tab's editor sheet,
/// which was removed in the list 1–14 UI cleanup (清单 1): providers are
/// now seeded, and the model picker is the only place to switch models.
/// The live API round-trip this test used to exercise is covered by the
/// DeepSeek connector verification instead (custom.deepseek), not by UI.
///
/// The entry point moved again in UI redesign item 5: the bottom tab bar
/// is gone (pill nav: 翻译 / 相机 / 对话), and Settings is reached from
/// the top-right "..." card on the translate page.
///
/// Run with:
///   xcodebuild test \
///     -scheme Zhiyin \
///     -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:RunseUITests/AddDeepSeekProviderTests
final class AddDeepSeekProviderTests: XCTestCase {
    @MainActor
    func testSelectDeepSeekDailyInModelPicker() throws {
        let app = XCUIApplication()
        app.launchArguments = ["ZHIYIN_SKIP_GUIDE"]
        app.launch()

        // "..." card → 设置.
        let moreButton = app.buttons["更多选项"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()

        let settingsRow = app.buttons["设置"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.tap()

        let pickerButton = app.buttons["选择模型"]
        XCTAssertTrue(pickerButton.waitForExistence(timeout: 5))
        pickerButton.tap()

        // DeepSeek 日常 must be listed and selectable.
        let deepSeekRow = app.staticTexts["DeepSeek 日常"]
        XCTAssertTrue(deepSeekRow.waitForExistence(timeout: 5))
        deepSeekRow.tap()

        // Done → Settings shows DeepSeek 日常 as the current model.
        app.navigationBars["选择模型"].buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["DeepSeek 日常"].waitForExistence(timeout: 5))
    }
}
