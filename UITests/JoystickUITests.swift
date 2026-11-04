import XCTest

final class JoystickUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    private func launch(openMode: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-jellyfin.enabled", "NO", "-page", "0", "-demoInputLog", "YES", "-demoEyesFree", openMode ? "YES" : "NO"]
        app.launch()
        if openMode { XCTAssertTrue(app.buttons["remoteMode-eyesFree"].waitForExistence(timeout: 10)) }
    }

    private var log: XCUIElement { app.staticTexts["eyesFreeInputLog"] }
    private var stick: XCUIElement { app.descendants(matching: .any).matching(identifier: "eyesFreeStick").firstMatch }
    private var count: Int { Int(log.label.split(separator: ":").first ?? "-1") ?? -1 }

    func testSwitchPersistentModes() {
        launch(openMode: false)
        let entry = app.buttons["remoteMode-eyesFree"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["remoteMode-eyesFree"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Eyes-free mode on iPhone 18 Pro Max"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["remoteMode-standard"].tap()
        XCTAssertFalse(stick.exists)
        XCTAssertTrue(entry.exists)
    }

    func testTapBackAndHome() {
        launch()
        stick.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        XCTAssertEqual(log.label, "1:OK")
        app.buttons["eyesFreeBack"].tap()
        XCTAssertEqual(log.label, "2:Back")
        app.buttons["Home"].tap()
        XCTAssertEqual(log.label, "3:Home")
    }

    func testRestingThumbDoesNothing() {
        launch()
        stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.65)
        XCTAssertEqual(log.label, "0:None")
    }

    func testFloatingStickRepeatsAndStopsOnLift() {
        launch()
        let start = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
        let end = start.withOffset(CGVector(dx: 70, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.9)
        XCTAssertTrue(log.label.hasSuffix(":Right"))
        let afterLift = count
        XCTAssertGreaterThanOrEqual(afterLift, 2)
        let noMore = NSPredicate { [weak self] _, _ in self?.count != afterLift }
        let expectation = XCTNSPredicateExpectation(predicate: noMore, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 0.6), .timedOut)
        XCTAssertTrue(log.label.hasSuffix(":Right"))
    }

    func testDraggingDoesNotSelect() {
        launch()
        let start = stick.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.6))
        let end = start.withOffset(CGVector(dx: 0, dy: -65))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(log.label.hasSuffix(":Up"))
        XCTAssertGreaterThanOrEqual(count, 1)
    }
}
