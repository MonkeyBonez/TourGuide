import XCTest

/// Driven by the bundled Kanazawa snapshot (-uiTestFixture kanazawa): no network, same numbers
/// as `scripts/measure.sh`.
final class TourGuideUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(slack: Double, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture", "kanazawa", "-uiTestStart", "36.5781,136.6480",
                               "-uiTestDestination", "36.5597,136.6534", "-uiTestSlack", "\(slack)", "-uiTestTimings", "1"] + extra
        app.launch()
        return app
    }

    func readout(_ app: XCUIApplication) -> String {
        let r = app.staticTexts["routeReadout"]
        XCTAssertTrue(r.waitForExistence(timeout: 30), "no route")
        return r.label
    }

    func shoot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testDirectRoute() {
        let app = launch(slack: 0)
        XCTAssertEqual(readout(app), "36 min · 2.9 km · 1 sight · direct")
        shoot(app, "slack-0")
    }

    /// The owner's February 2025 walk: west through Nagamachi, Nomura house on the cards.
    func testSlackPointOneIsTheNagamachiWalk() {
        let app = launch(slack: 0.1)
        XCTAssertTrue(readout(app).hasPrefix("36 min · 3.0 km · 6 sights"))
        let names = (0..<6).map { app.descendants(matching: .any)["card-\($0)"].label }
        XCTAssertEqual(names.first, "平岡野神社")
        XCTAssertTrue(names.contains("Nomura Samurai House"), "\(names)")
        XCTAssertEqual(names.last, "Maeda Tosanokami-ke Shiryokan")
        shoot(app, "slack-0.1")
    }

    func testRightEndReachesKenrokuenAfterOyama() {
        let app = launch(slack: 0.5)
        XCTAssertEqual(readout(app), "47 min · 3.9 km · 8 sights · +12 min")
        let names = (0..<8).map { app.descendants(matching: .any)["card-\($0)"].label }
        let oyama = names.firstIndex(of: "Oyama-jinja Shrine"), kenroku = names.firstIndex(of: "Kenroku-en Park")
        XCTAssertNotNil(oyama); XCTAssertNotNil(kenroku)
        XCTAssertLessThan(oyama!, kenroku!)
        shoot(app, "slack-0.5")
    }

    /// Moving the slider changes the route (which streets), not just the cards.
    func testSliderChangesTheRoute() {
        let app = launch(slack: 0)
        XCTAssertTrue(readout(app).contains("direct"))
        app.sliders["slackSlider"].adjust(toNormalizedSliderPosition: 1.0)
        let r = app.staticTexts["routeReadout"]
        let moved = NSPredicate(format: "label CONTAINS '+12 min'")
        expectation(for: moved, evaluatedWith: r); waitForExpectations(timeout: 10)
        shoot(app, "slider-right")
    }

    func testNamedPlacesAndPlaceCard() {
        let app = launch(slack: 0.1)
        _ = readout(app)
        let toggle = app.buttons["namedToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.label.contains("14 named places"), toggle.label)
        toggle.tap()
        let temple = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '光善寺'")).firstMatch
        XCTAssertTrue(temple.waitForExistence(timeout: 5))
        shoot(app, "named-places")
    }

    func testPhotoModeWithoutAKeyAsksForOne() {
        let app = launch(slack: 0.1)
        _ = readout(app)
        app.buttons["cameraButton"].tap()
        XCTAssertTrue(app.buttons["closePhoto"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["micButton"].exists)
        shoot(app, "photo-mode")
        app.buttons["closePhoto"].tap()
        XCTAssertTrue(app.staticTexts["routeReadout"].waitForExistence(timeout: 5))
    }

    func testDestinationOffTheMapIsABannerNotARoute() {
        let app = XCUIApplication()
        // Start in Kanazawa, destination in the Sea of Japan: the fixture's graph can't reach it.
        app.launchArguments = ["-uiTestFixture", "kanazawa", "-uiTestStart", "36.5781,136.6480", "-uiTestDestination", "36.70,136.40"]
        app.launch()
        let banner = app.descendants(matching: .any)["bannerNoRoute"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["routeReadout"].exists)
        shoot(app, "no-route")
    }
}
