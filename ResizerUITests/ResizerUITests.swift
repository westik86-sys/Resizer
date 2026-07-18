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
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings-automatically-reveal-completed-outputs"
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-third-party-notices"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings-gpl-2"].exists
        )
    }

    @MainActor
    func testRussianLaunchUsesLocalizedPrimaryContent() throws {
        let app = launchFreshApp(
            language: "ru",
            locale: "ru_RU"
        )
        defer { app.terminate() }

        XCTAssertTrue(
            app.buttons["choose-video"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Нет видео"].exists)
        XCTAssertTrue(app.buttons["Добавить видео…"].exists)
    }

    @MainActor
    func testRussianSettingsLocalizeFFmpegDisclosure() throws {
        let app = launchFreshApp(language: "ru", locale: "ru_RU")
        defer { app.terminate() }

        XCTAssertTrue(
            app.buttons["choose-video"].waitForExistence(timeout: 5)
        )
        app.menuBars.menuBarItems["Resizer"].click()
        app.menuItems["Настройки…"].click()

        XCTAssertTrue(
            app.staticTexts[
                "FFmpeg встроен в Resizer на условиях GPL 2.0 или более поздней версии и включает статически скомпонованный libx264. Компоненты nonfree и libx265 не включены."
            ].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testReadyVideoOffersQuickFlexibleAudioAndRemoval() throws {
        let app = launchFreshApp()
        defer { app.terminate() }

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "ResizerTests/Fixtures/Media/short-h264-aac.mp4"
            )

        let addButton = app.buttons["choose-video"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])

        let locationField = app.sheets.textFields.firstMatch
        XCTAssertTrue(locationField.waitForExistence(timeout: 5))
        locationField.typeText(fixtureURL.path)
        app.typeKey(.enter, modifierFlags: [])
        app.typeKey(.enter, modifierFlags: [])

        XCTAssertTrue(
            app.descendants(matching: .any)["compression-mode-selector"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(app.descendants(matching: .any)["keep-audio"].exists)

        let removeButton = app.buttons["remove-queue-job"]
        XCTAssertTrue(removeButton.isEnabled)

        let flexibleSegment = app.descendants(matching: .any)["Flexible"]
        XCTAssertTrue(flexibleSegment.exists)
        flexibleSegment.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["flexible-quality"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["flexible-resolution"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["flexible-frame-rate"].exists
        )

        removeButton.click()
        XCTAssertTrue(app.staticTexts["No videos"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchFreshApp(
        language: String = "en",
        locale: String = "en_US",
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        app.launchArguments += additionalArguments
        app.launch()
        return app
    }
}
