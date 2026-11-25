import XCTest

final class RunseScreenshotUITests: XCTestCase {
    private var screenshotDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let path = ProcessInfo.processInfo.environment["ZHIYIN_SCREENSHOT_DIR"] ?? NSTemporaryDirectory()
        screenshotDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
    }

    func testCaptureAppStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["ZHIYIN_SCREENSHOTS"]
        app.launch()

        XCTAssertTrue(app.buttons["guide.next"].waitForExistence(timeout: 8))
        capture(app, name: "01-get-started-select-text")

        tap(app.buttons["guide.next"])
        capture(app, name: "02-open-action-menu")

        tap(app.buttons["guide.next"])
        capture(app, name: "03-pin-runse")

        tap(app.buttons["guide.next"])
        capture(app, name: "04-choose-runse")

        tap(app.buttons["guide.next"])
        capture(app, name: "05-refine-or-translate")

        tap(app.buttons["guide.next"])
        capture(app, name: "06-settings-guide")

        tap(app.buttons["guide.next"])
        XCTAssertTrue(waitForAny(app, labels: ["翻译"], timeout: 5))
        capture(app, name: "07-translate")

        tap(firstExisting(app, labels: ["设置"]))
        capture(app, name: "08-settings")
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
    }

    private func firstExisting(_ query: XCUIElementQuery, labels: [String]) -> XCUIElement {
        for label in labels {
            let element = query[label]
            if element.exists {
                return element.firstMatch
            }
        }
        return query[labels[0]].firstMatch
    }

    private func firstExisting(_ app: XCUIApplication, labels: [String]) -> XCUIElement {
        let queries = [app.tabBars.buttons, app.buttons, app.staticTexts]
        for query in queries {
            for label in labels {
                let element = query[label]
                if element.exists {
                    return element.firstMatch
                }
            }
        }
        return app.tabBars.buttons[labels[0]].firstMatch
    }

    private func waitForAny(_ app: XCUIApplication, labels: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let queries = [app.staticTexts, app.buttons, app.tabBars.buttons]
            for query in queries {
                for label in labels where query[label].exists {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let data = app.screenshot().pngRepresentation
        let url = screenshotDirectory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url, options: .atomic)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Failed to write screenshot \(url.path): \(error)")
        }
    }
}
