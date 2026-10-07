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

    /// The slider's left end is the most-sights walk (PRD §5 step 5, flipped 6 Oct 2026).
    func testLeftEndReachesKenrokuenAfterOyama() {
        let app = launch(slack: 0.5)
        XCTAssertEqual(readout(app), "47 min · 3.9 km · 8 sights · +12 min")
        let names = (0..<8).map { app.descendants(matching: .any)["card-\($0)"].label }
        let oyama = names.firstIndex(of: "Oyama-jinja Shrine"), kenroku = names.firstIndex(of: "Kenroku-en Park")
        XCTAssertNotNil(oyama); XCTAssertNotNil(kenroku)
        XCTAssertLessThan(oyama!, kenroku!)
        shoot(app, "slack-0.5")
    }

    /// Moving the slider changes the route (which streets), not just the cards. Direct is the
    /// right end; dragging left buys sights.
    func testSliderChangesTheRoute() {
        let app = launch(slack: 0)
        XCTAssertTrue(readout(app).contains("direct"))
        let slider = app.sliders["slackSlider"]
        XCTAssertGreaterThan(slider.normalizedSliderPosition, 0.95, "slack 0 sits at the right end")
        slider.adjust(toNormalizedSliderPosition: 0.0)
        let r = app.staticTexts["routeReadout"]
        let moved = NSPredicate(format: "label CONTAINS '+12 min'")
        expectation(for: moved, evaluatedWith: r); waitForExpectations(timeout: 10)
        shoot(app, "slider-left")
    }

    func testSliderRightEndIsDirect() {
        let app = launch(slack: 0.5)
        XCTAssertTrue(readout(app).contains("+12 min"))
        let slider = app.sliders["slackSlider"]
        XCTAssertLessThan(slider.normalizedSliderPosition, 0.05, "the widest walk sits at the left end")
        slider.adjust(toNormalizedSliderPosition: 1.0)
        let direct = NSPredicate(format: "label ENDSWITH 'direct'")
        expectation(for: direct, evaluatedWith: app.staticTexts["routeReadout"]); waitForExpectations(timeout: 10)
        shoot(app, "slider-right")
    }

    /// Square law: the owner's walk (slack 0.1) sits mid-slider, not crammed at the direct end.
    func testNagamachiWalkSitsMidSlider() {
        let app = launch(slack: 0.1)
        _ = readout(app)
        XCTAssertEqual(app.sliders["slackSlider"].normalizedSliderPosition, 0.553, accuracy: 0.03)
    }

    /// Card tap outlines the sight's grounds and zooms; the route doesn't change.
    func testCardTapOutlinesTheSight() {
        let app = launch(slack: 0.5)
        let before = readout(app)
        let kenroku = (0..<8).map { app.descendants(matching: .any)["card-\($0)"] }.first { $0.label == "Kenroku-en Park" }
        XCTAssertNotNil(kenroku)
        kenroku!.tap()
        sleep(2)
        XCTAssertEqual(app.staticTexts["routeReadout"].label, before)
        shoot(app, "card-tap-kenrokuen")
        let pin = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Kenroku-en Park,' AND value == 'selected'")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "the sight's pin is selected on the map")
        let map = app.otherElements["map"].frame
        XCTAssertTrue(map.contains(CGPoint(x: pin.frame.midX, y: pin.frame.midY)), "zoomed so the pin is on screen")
        XCTAssertLessThan(pin.frame.midY, map.height - 400, "above the bottom panel")
        // A point sight gets the halo path; tapping it doesn't crash or reroute either.
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'card-' AND label == 'Oyama-jinja Shrine'")).firstMatch.tap()
        sleep(1)
        XCTAssertEqual(app.staticTexts["routeReadout"].label, before)
        let oyama = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Oyama-jinja Shrine,' AND value == 'selected'")).firstMatch
        XCTAssertTrue(oyama.waitForExistence(timeout: 5), "selection moves to the new sight")
        shoot(app, "card-tap-oyama")
    }

    /// PRD §5 step 8: the fastest path while the full corridor loads; no slider, no cards.
    func testFastestPathShowsWhileSightsLoad() {
        let app = launch(slack: 0.1, extra: ["-uiTestSlowLoad", "6"])
        let fast = app.staticTexts["fastReadout"]
        XCTAssertTrue(fast.waitForExistence(timeout: 5), "fastest path first")
        XCTAssertTrue(fast.label.hasPrefix("Fastest 36 min · 2.9 km"), fast.label)
        XCTAssertFalse(app.sliders["slackSlider"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["card-0"].exists)
        shoot(app, "fastest-while-loading")
        XCTAssertTrue(readout(app).hasPrefix("36 min · 3.0 km · 6 sights"))
        XCTAssertFalse(fast.exists)
        XCTAssertTrue(app.sliders["slackSlider"].exists)
    }

    func testFullLoadFailureKeepsTheFastestPath() {
        let app = launch(slack: 0.1, extra: ["-uiTestFullLoadFails", "1"])
        let banner = app.descendants(matching: .any)["bannerFailed"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        let fast = app.staticTexts["fastReadout"]
        XCTAssertTrue(fast.waitForExistence(timeout: 5))
        XCTAssertEqual(fast.label, "Fastest 36 min · 2.9 km")
        XCTAssertTrue(banner.label.contains("Showing the fastest walk"), banner.label)
        XCTAssertTrue(app.buttons["retryButton"].exists)
        XCTAssertFalse(app.sliders["slackSlider"].exists)
        shoot(app, "fastest-kept-after-failure")
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
