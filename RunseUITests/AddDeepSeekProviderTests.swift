import XCTest

/// End-to-end smoke test for adding a DeepSeek provider through the UI.
///
/// The provider editor's "Save" action calls `ProviderAPITester.test`, which
/// performs a real round-trip against the configured base URL. This test
/// therefore doubles as a live integration check that the fix for the
/// "provider returned an empty result" bug holds against `api.deepseek.com`:
/// if the response parser does its job, the editor sheet dismisses on
/// success; otherwise the test will time out
/// waiting for the Providers list to reappear and surface the API-test
/// failure message captured from the UI.
///
/// Run with:
///   DEEPSEEK_API_KEY=sk-... xcodebuild test \
///     -scheme Zhiyin \
///     -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:RunseUITests/AddDeepSeekProviderTests
final class AddDeepSeekProviderTests: XCTestCase {
    @MainActor
    func testAddDeepSeekProviderPassesAPITest() throws {
        // xcodebuild forwards env vars prefixed with `TEST_RUNNER_` into the
        // test runner; for UI tests on some Xcode versions the prefix is
        // preserved, on others it's stripped. As a third fallback, read the
        // key from `/tmp/zhiyin-deepseek.key` so the value can stay out of git
        // and out of the shell history.
        let env = ProcessInfo.processInfo.environment
        var apiKey = env["DEEPSEEK_API_KEY"]
            ?? env["TEST_RUNNER_DEEPSEEK_API_KEY"]
            ?? ""
        if apiKey.isEmpty,
           let onDisk = try? String(contentsOfFile: "/tmp/zhiyin-deepseek.key", encoding: .utf8) {
            apiKey = onDisk.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try XCTSkipIf(apiKey.isEmpty, "Provide DEEPSEEK_API_KEY (or /tmp/zhiyin-deepseek.key) to run this live integration test.")

        let app = XCUIApplication()
        app.launchArguments = ["ZHIYIN_SKIP_GUIDE"]
        app.launch()

        // Providers tab → + → editor sheet.
        let providersTab = app.tabBars.buttons["Providers"]
        XCTAssertTrue(providersTab.waitForExistence(timeout: 5))
        providersTab.tap()

        let addButton = app.navigationBars["Providers"].buttons["plus"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        // SwiftUI's default `Picker` inside a Form renders as a Cell whose
        // accessibility label is "Provider, <current selection>". Match the
        // cell by static-text identifier so we don't have to know the exact
        // current selection (it could be "Custom" first time, or a preset
        // name if we re-run without erasing the simulator).
        let providerRow = app.cells.containing(.staticText, identifier: "Provider").firstMatch
        if !providerRow.waitForExistence(timeout: 5) {
            print("--- Accessibility hierarchy when Provider picker not found ---")
            print(app.debugDescription)
            XCTFail("Provider picker row not found.")
            return
        }
        providerRow.tap()

        let deepSeekOption = app.buttons["DeepSeek China"]
        if !deepSeekOption.waitForExistence(timeout: 5) {
            print("--- Hierarchy when DeepSeek option missing ---")
            print(app.debugDescription)
            XCTFail("DeepSeek China preset not in picker.")
            return
        }
        deepSeekOption.tap()

        // The picker pop dismisses back to the editor. Fill in the API key.
        let apiKeyField = app.secureTextFields["API key"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 5), "API key SecureField not found.")
        apiKeyField.tap()
        apiKeyField.typeText(apiKey)

        // Save → triggers ProviderAPITester.test (real network call). On
        // success the sheet dismisses and we land back on the Providers list
        // with a DeepSeek row. On failure the sheet stays and shows a
        // localized "API test failed: …" message.
        app.navigationBars["New Provider"].buttons["Save"].tap()

        let deepSeekRow = app.staticTexts["DeepSeek China"]
        let providersTitle = app.navigationBars["Providers"]

        let success = deepSeekRow.waitForExistence(timeout: 60)
            && providersTitle.exists

        if !success {
            let failureMessage = app.staticTexts
                .allElementsBoundByIndex
                .first(where: { $0.label.contains("API test failed") || $0.label.contains("empty result") })?
                .label ?? "(no failure message surfaced)"
            XCTFail("DeepSeek provider save did not complete successfully. UI reported: \(failureMessage)")
        }
    }
}
