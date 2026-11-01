import XCTest
import CoreLocation

final class CheckInUITests: XCTestCase {
    override func tearDown() {
        let app = XCUIApplication()
        app.launchArguments = ["--ios-stage2-scenario"]
        app.launch()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if alert.exists { alert.buttons.firstMatch.tap() }
        if app.buttons["Stop tracking"].waitForExistence(timeout: 15) {
            app.buttons["Stop tracking"].tap()
            _ = app.staticTexts["Harness cleared"].waitForExistence(timeout: 15)
        }
        app.terminate()
        if #available(iOS 16.4, *) { XCUIDevice.shared.location = nil }
        super.tearDown()
    }
    func testNotificationFiresAfterKillAndTapRestoresOriginalSessionDeadline() {
        continueAfterFailure = false
        if #available(iOS 16.4, *) { XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 24.7136, longitude: 46.6753)) }
        let app = XCUIApplication()
        app.launchArguments = ["--ios-stage2-scenario"]
        app.launch(); app.terminate(); app.resetAuthorizationStatus(for: .location); app.launch()
        XCTAssertTrue(app.buttons["Start check-in"].waitForExistence(timeout: 30))
        app.buttons["Start check-in"].tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(40)
        while !app.staticTexts["State: enabled"].exists && Date() < deadline {
            let alert = system.alerts.firstMatch
            if alert.waitForExistence(timeout: 1) {
                let whileUsing = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'while using'")).firstMatch
                let allow = alert.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == 'OK'")).firstMatch
                if whileUsing.exists { whileUsing.tap() }
                else if allow.exists { allow.tap() }
                else { XCTFail(alert.debugDescription); return }
            }
        }
        XCTAssertTrue(app.staticTexts["State: enabled"].exists)
        XCTAssertTrue(app.staticTexts["Check-in pending: true"].waitForExistence(timeout: 15))
        let start = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Session start:'")).firstMatch.label
        XCTAssertFalse(start.hasSuffix(": 0"))
        app.terminate(); XCUIDevice.shared.press(.home)
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).press(forDuration: 0.1, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        func notification() -> XCUIElement { system.staticTexts.matching(NSPredicate(format: "label == %@", "Location tracking test check-in")).firstMatch }
        XCTAssertTrue(notification().waitForExistence(timeout: 160), system.debugDescription)
        let fired = XCTAttachment(screenshot: system.screenshot()); fired.name = "check-in-after-kill"; fired.lifetime = .keepAlways; add(fired)
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)).press(forDuration: 0.1, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        XCUIDevice.shared.press(.home)
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01)).press(forDuration: 0.1, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        XCTAssertTrue(notification().waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .notRunning)
        for _ in 0..<3 {
            guard app.state != .runningForeground, notification().exists else { break }
            let frame = notification().frame
            system.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            if app.wait(for: .runningForeground, timeout: 3) { break }
        }
        let opened = app.wait(for: .runningForeground, timeout: 30)
        if !opened {
            let screen = XCTAttachment(screenshot: system.screenshot()); screen.name = "check-in-tap-state"; screen.lifetime = .keepAlways; add(screen)
        }
        XCTAssertTrue(opened)
        XCTAssertTrue(app.staticTexts["Last start reason: restore"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts[start].exists)
        XCTAssertTrue(app.staticTexts["Delivered: 0"].waitForExistence(timeout: 10))
        let restored = XCTAttachment(screenshot: app.screenshot()); restored.name = "restored-original-deadline"; restored.lifetime = .keepAlways; add(restored)
        app.buttons["Stop tracking"].tap()
        XCTAssertTrue(app.staticTexts["State: disabled"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Check-in pending: false"].waitForExistence(timeout: 10))
    }
}
