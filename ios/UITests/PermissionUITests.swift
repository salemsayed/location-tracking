import XCTest

final class PermissionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = ["--ios-permission-smoke"]
        app.launch()
        XCTAssertTrue(app.buttons["Request Location"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Location permission: prompt"].exists)
        return app
    }
    func testLocationPromptDenial() {
        let app = launch()
        app.buttons["Request Location"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        let deny = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'allow' AND label CONTAINS[c] 't '")).firstMatch
        XCTAssertTrue(deny.exists)
        deny.tap()
        XCTAssertTrue(app.staticTexts["Location permission: denied"].waitForExistence(timeout: 15))
        app.buttons["Request Position"].tap()
        XCTAssertTrue(app.staticTexts["Position error: PERMISSION_DENIED"].waitForExistence(timeout: 15))
    }
    func testApproximatePermissionAndTemporaryPrecision() throws {
        let app = launch()
        app.buttons["Request Location"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        let precise = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'precise'")).firstMatch
        guard precise.exists else { throw XCTSkip("This simulator does not expose the precision toggle") }
        if !precise.label.lowercased().contains("off") { precise.tap() }
        let allow = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'while using'")).firstMatch
        XCTAssertTrue(allow.exists)
        allow.tap()
        XCTAssertTrue(app.staticTexts["Provider accuracy: approximate"].waitForExistence(timeout: 15))
        app.buttons["Request Precision"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        let upgrade = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'precise' AND NOT label CONTAINS[c] 'keep'")).firstMatch
        XCTAssertTrue(upgrade.exists)
        upgrade.tap()
        XCTAssertTrue(app.staticTexts["Provider accuracy: precise"].waitForExistence(timeout: 15))
    }
}
