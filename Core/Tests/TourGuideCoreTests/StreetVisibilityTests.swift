import Foundation
import XCTest
import LikeWaterEngine
@testable import TourGuideCore

final class StreetVisibilityTests: XCTestCase {
    func testExplicitIndoorTagsDoNotScoreOrBecomePassedSights() throws {
        // The same invented metre-scale graph at Japanese and European latitudes, not real streets.
        for (lat, lon) in [(35.0, 139.0), (41.9, 12.5)] {
            let session = try TourSession(box: relocatedFixture(lat: lat, lon: lon))
            let direct = try session.route(slack: 0)
            let wider = try session.route(slack: 0.5)
            XCTAssertEqual(direct.passed.map(\.sight.poi.displayName), ["Fixture: Museum Exterior"])
            XCTAssertEqual(wider.passed.map(\.sight.poi.displayName),
                           ["Fixture: Temple Gate", "Fixture: Plaza Sculpture", "Fixture: Museum Exterior"])
            XCTAssertNotEqual(direct.route.edges, wider.route.edges, "the slider changes streets")
            for name in ["Fixture: Indoor Collection", "Fixture: Indoor Exhibition"] {
                let indoor = try XCTUnwrap(session.scored.sights.first { $0.poi.displayName == name })
                XCTAssertEqual(indoor.weight, 0)
                XCTAssertTrue(indoor.edges.isEmpty)
                XCTAssertEqual(session.explain(indoor, route: wider), .explicitlyIndoor)
            }
        }
    }

    func testMissingAndContradictoryTagsRemainEligible() {
        func poi(_ tags: [String: String], allTags: [String: String]? = nil) -> POI {
            POI(id: "node/1", lat: 0, lon: 0, name: "Example", nameLocal: nil, tags: tags, allTags: allTags)
        }
        XCTAssertTrue(poi(["indoor": "yes"]).isExplicitlyIndoor, "legacy partial tags")
        XCTAssertTrue(poi([:], allTags: ["location": "indoor"]).isExplicitlyIndoor)
        XCTAssertFalse(poi(["tourism": "museum"]).isExplicitlyIndoor, "missing tags are unknown")
        XCTAssertFalse(poi([:], allTags: ["indoor": "yes", "location": "outdoor"]).isExplicitlyIndoor)
        XCTAssertFalse(poi([:], allTags: ["location": "indoor", "indoor": "no"]).isExplicitlyIndoor)
        XCTAssertFalse(poi([:], allTags: ["indoor": "yes", "outdoor": "yes"]).isExplicitlyIndoor)
        XCTAssertFalse(poi([:], allTags: ["level": "0", "covered": "yes"]).isExplicitlyIndoor)

        // The real OSM building's category is not a reason to suppress its exterior.
        let sfmoma = POI(id: "way/41692824", lat: 37.785915, lon: -122.4007359,
                         name: "San Francisco Museum of Modern Art", nameLocal: nil,
                         tags: ["tourism": "museum", "building": "yes"],
                         allTags: ["tourism": "museum", "building": "yes"])
        XCTAssertFalse(sfmoma.isExplicitlyIndoor)
    }

    private func relocatedFixture(lat: Double, lon: Double) throws -> FetchBox {
        var box = try BundledFixtures.visibility()
        let oldLat = box.start.lat, oldLon = box.start.lon
        let lonScale = cos(oldLat * .pi / 180) / cos(lat * .pi / 180)
        func latitude(_ value: Double) -> Double { lat + value - oldLat }
        func longitude(_ value: Double) -> Double { lon + (value - oldLon) * lonScale }
        box.nodes = box.nodes.map { [$0[0], latitude($0[1]), longitude($0[2])] }
        for i in box.pois.indices {
            box.pois[i].lat = latitude(box.pois[i].lat)
            box.pois[i].lon = longitude(box.pois[i].lon)
        }
        box.end.lat = latitude(box.end.lat); box.end.lon = longitude(box.end.lon)
        box.start.lat = lat; box.start.lon = lon
        box.bbox = [latitude(box.bbox[0]), longitude(box.bbox[1]), latitude(box.bbox[2]), longitude(box.bbox[3])]
        return box
    }
}
