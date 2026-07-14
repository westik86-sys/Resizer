import XCTest

final class ResizerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInitialScreenOffersSessionQueueAndMultiFileImport() throws {
        let app = launchFreshApp()
        defer { app.terminate() }

        XCTAssertTrue(
            app.buttons["choose-video"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["choose-video-toolbar"].exists)
        XCTAssertTrue(
            app.otherElements["empty-queue"].exists
                || app.groups["empty-queue"].exists
                || app.staticTexts["No videos"].exists
        )
        XCTAssertFalse(app.buttons["start-compression"].exists)
        XCTAssertFalse(app.buttons["start-queue-toolbar"].exists)
    }

    @MainActor
    func testSettingsExposeSafeNamingAndFFmpegLicense() throws {
        let app = launchFreshApp()
        defer { app.terminate() }

        app.menuBars.menuBarItems["Resizer"].click()
        app.menuItems["Settings…"].click()

        XCTAssertTrue(
            app.textFields["settings-output-filename-suffix"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["settings-ffmpeg-license-disclosure"].exists
        )
        XCTAssertTrue(
            app.radioGroups["settings-output-conflict-policy"].exists
                || app.groups["settings-output-conflict-policy"].exists
                || app.otherElements["settings-output-conflict-policy"].exists
        )
    }

    @MainActor
    private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }
}
