import XCTest

/// Runs against the app launched with UITEST_FAKE_CAMERA=1. Written on Windows; verified on macOS CI.
/// Expected strings mirror NurseCopy (the test bundle does not link the core package).
final class CaptureFlowUITests: XCTestCase {
    let banner = "Research Use Only — not for diagnosis or treatment decisions. Continue standard care and blood tests."

    func launch(_ extra: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_FAKE_CAMERA"] = "1"
        extra.forEach { app.launchEnvironment[$0.key] = $0.value }
        app.launch()
        return app
    }

    func lookUp(_ app: XCUIApplication) {
        let f = app.textFields["study-id-field"]
        XCTAssertTrue(f.waitForExistence(timeout: 5))
        f.tap(); f.typeText("DS-417")
        app.buttons["lookup-button"].tap()
    }

    func reachCapture(_ app: XCUIApplication) {
        lookUp(app)
        app.buttons["assent-agree-button"].tap()
        for id in ["resting", "glasses", "light", "holder", "colourCard"] {
            app.switches["check-\(id)"].tap()
        }
        app.buttons["checklist-continue"].tap()
        let hr = app.textFields["vitals-hr"]
        hr.tap(); hr.typeText("88")
        app.buttons["vitals-continue"].tap()
    }

    func testHappyPathReachesRecordingSaved() {
        let app = launch()
        reachCapture(app)
        for _ in 0..<2 {
            app.buttons["start-button"].tap()
        }
        app.buttons["quality-continue"].tap()
        XCTAssertTrue(app.staticTexts["Recording saved for research"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["monitor-hr"].exists)
    }

    func testInvalidConsentShowsConsentBlockedAndNoCaptureButton() {
        let app = launch(["UITEST_CONSENT": "blocked"])
        lookUp(app)
        XCTAssertTrue(app.staticTexts["No valid study consent on record. Do not record. Contact the study coordinator."]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["start-button"].exists)
        XCTAssertFalse(app.buttons["assent-agree-button"].exists)
    }

    func testBannerExistsOnEveryScreenInFlow() {
        let app = launch()
        func assertBanner() { XCTAssertTrue(app.staticTexts[banner].waitForExistence(timeout: 5)) }
        assertBanner()
        lookUp(app); assertBanner()
        app.buttons["assent-agree-button"].tap(); assertBanner()
        for id in ["resting", "glasses", "light", "holder", "colourCard"] { app.switches["check-\(id)"].tap() }
        app.buttons["checklist-continue"].tap(); assertBanner()
        let hr = app.textFields["vitals-hr"]; hr.tap(); hr.typeText("88")
        app.buttons["vitals-continue"].tap(); assertBanner()
        app.buttons["start-button"].tap(); assertBanner()
        app.buttons["start-button"].tap(); assertBanner()
        app.buttons["quality-continue"].tap(); assertBanner()
    }

    func testExperimentalSectionAbsentWhenDisabled() {
        let app = launch()
        reachCapture(app)
        app.buttons["start-button"].tap()
        app.buttons["start-button"].tap()
        app.buttons["quality-continue"].tap()
        XCTAssertTrue(app.staticTexts["monitor-hr"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["experimental-section"].exists)
        XCTAssertFalse(app.staticTexts["EXPERIMENTAL"].exists)
    }

    func testOfflineWithRosterConsentSnapshotOlderThan24hBlocksCapture() {
        let app = launch(["UITEST_CONSENT": "stale"])
        lookUp(app)
        XCTAssertTrue(app.staticTexts["No valid study consent on record. Do not record. Contact the study coordinator."]
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["start-button"].exists)
    }

    func testThermalSeriousDuringRecordingInterruptsAndShowsPhoneWarm() {
        let app = launch(["UITEST_THERMAL_SERIOUS": "1"])
        reachCapture(app)
        XCTAssertTrue(app.staticTexts["Phone is warm — wait a minute"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["start-button"].isEnabled)
    }
}