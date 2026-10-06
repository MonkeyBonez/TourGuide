import XCTest
import LikeWaterEngine
@testable import TourGuideCore

final class SlackEllipseTests: XCTestCase {
    func testKanazawaBoxMatchesTheFetchedFixture() throws {
        let (bbox, straight) = SlackEllipse.bbox(a: BundledFixtures.kanazawaStart, b: BundledFixtures.kanazawaEnd)
        let expected = [36.55131054502503, 136.6318372899353, 36.586489454974966, 136.6695627100647]
        for (a, b) in zip(bbox, expected) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        XCTAssertEqual(straight, 2104, accuracy: 1)
        XCTAssertEqual(Kanazawa.box.bbox, bbox)
    }
}

final class WalkGraphTests: XCTestCase {
    func testGraphFromTheSnapshot() {
        let g = Kanazawa.session.graph
        XCTAssertEqual(g.nodeCount, 13_567)
        XCTAssertEqual(g.edgeCount, 16_289)
        XCTAssertEqual((0..<g.edgeCount).filter { g.isCrossing($0) }.count, 383)
        XCTAssertEqual(g.componentSizes.count, 28)
        XCTAssertEqual(g.componentSizes.max(), 13_406)
        XCTAssertEqual(Kanazawa.session.snapA, 27, accuracy: 1)
        XCTAssertEqual(Kanazawa.session.snapB, 21, accuracy: 1)
    }

    func testFlagsFollowThePipelineRule() {
        XCTAssertEqual(WalkGraphBuilder.flags(for: ["highway": "footway", "footway": "crossing"]) & EdgeFlag.crossing, EdgeFlag.crossing)
        XCTAssertEqual(WalkGraphBuilder.flags(for: ["highway": "steps"]) & EdgeFlag.steps, EdgeFlag.steps)
        XCTAssertEqual(WalkGraphBuilder.flags(for: ["highway": "residential", "sidewalk": "both"]),
                       EdgeFlag.streetSidewalkTag | EdgeFlag.street)
        XCTAssertEqual(WalkGraphBuilder.flags(for: ["highway": "footway", "footway": "sidewalk"]), EdgeFlag.sidewalk)
    }
}

final class InterestScorerTests: XCTestCase {
    func testScoringMatchesTheMeasurement() {
        let s = Kanazawa.session.scored
        XCTAssertEqual(s.sights.count, 328)
        XCTAssertEqual(s.sights.filter { $0.tier == 1 }.count, 54)
        XCTAssertEqual(s.folded, 99)
        XCTAssertEqual(s.interest.filter { $0 > 0 }.count, 5_045)
        XCTAssertEqual(s.interest.max(), 55)
        XCTAssertEqual(s.sights.filter { $0.edges.isEmpty }.count, 10)
        XCTAssertEqual(Kanazawa.sight("Kanazawa Castle Park").edges.count, 713)
        XCTAssertEqual(Kanazawa.sight("Kenroku-en Park").edges.count, 985)
        XCTAssertTrue(Kanazawa.sight("全性寺").edges.isEmpty)
    }

    /// The finding that changed the PRD: by centroid the castle park touches no street.
    func testCentroidsLoseTheAreas() {
        var p = ScoringParams(); p.usePolygons = false
        let g = Kanazawa.session.graph
        let s = InterestScorer.score(graph: g, box: Kanazawa.box, plane: Kanazawa.session.plane, params: p)
        XCTAssertEqual(s.sights.first { $0.poi.name == "Kanazawa Castle Park" }!.edges.count, 0)
    }
}

final class TourRouterTests: XCTestCase {
    func names(_ r: TourRoute, tier: Int = 1) -> [String] { r.passed.filter { $0.sight.tier == tier }.map { $0.sight.poi.displayName } }

    func testDirectRoute() {
        let r = Kanazawa.routes[0]!
        XCTAssertEqual(Kanazawa.session.directMetres, 2941, accuracy: 0.5)
        XCTAssertEqual(r.metres, 2941, accuracy: 0.5)
        XCTAssertEqual(r.seconds / 60, 35.6, accuracy: 0.05)
        XCTAssertEqual(r.corridorEdges, 130)
    }

    /// The owner's February 2025 walk: west through Nagamachi for +0.2 min.
    func testSlackPointOneIsTheNagamachiWalk() {
        let r = Kanazawa.routes[0.1]!
        XCTAssertEqual(r.metres, 3012, accuracy: 0.5)
        XCTAssertEqual((r.seconds - Kanazawa.routes[0]!.seconds) / 60, 0.2, accuracy: 0.05)
        XCTAssertEqual(names(r).count, 6)
        XCTAssertEqual(names(r, tier: 2).count, 14)
        XCTAssertTrue(names(r).contains("Nomura Samurai House"))
        XCTAssertEqual(r.corridorEdges, 3336)
        XCTAssertFalse(names(r).contains("Kanazawa Castle Park"))
    }

    func testSlackPointTwoBendsEast() {
        let r = Kanazawa.routes[0.2]!
        XCTAssertEqual(r.metres, 3483, accuracy: 0.5)
        XCTAssertEqual(r.seconds / 60, 41.7, accuracy: 0.05)
        XCTAssertTrue(names(r).contains("Kanazawa Castle Park"))
        XCTAssertTrue(names(r).contains("Oyama-jinja Shrine"))
        XCTAssertFalse(names(r).contains("Nomura Samurai House"))
        XCTAssertEqual(Kanazawa.routes[0.3]!.route.edges, r.route.edges)
    }

    func testRightEndReachesKenrokuen() {
        let r = Kanazawa.routes[0.5]!
        XCTAssertEqual(r.metres, 3917, accuracy: 0.5)
        XCTAssertEqual(r.seconds / 60, 47.2, accuracy: 0.05)
        XCTAssertEqual(names(r).count, 8)
        XCTAssertEqual(r.corridorEdges, 9440)
        let n = names(r)
        XCTAssertTrue(n.contains("Kenroku-en Park"))
        XCTAssertTrue(n.contains("21st Century Museum of Contemporary Art, Kanazawa"))
        XCTAssertLessThan(n.firstIndex(of: "Oyama-jinja Shrine")!, n.firstIndex(of: "Kenroku-en Park")!)
    }

    func testPassedSightsAreInWalkingOrder() {
        for r in Kanazawa.routes.values {
            let along = r.passed.map(\.alongMetres)
            XCTAssertEqual(along, along.sorted())
            XCTAssertLessThanOrEqual(along.last ?? 0, r.metres)
        }
    }

    func testMissesAreExplained() {
        let r = Kanazawa.routes[0.5]!
        XCTAssertEqual(Kanazawa.session.explain(Kanazawa.sight("全性寺"), route: r), .noEdge)
        guard case .outscored(let via) = Kanazawa.session.explain(Kanazawa.sight("Nomura Samurai House"), route: r) else {
            return XCTFail("Nomura should be reachable but outscored at 0.5")
        }
        XCTAssertEqual(via, 2989, accuracy: 1)
    }

    func testSliderIsMilliseconds() throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try Kanazawa.session.route(slack: 0.5)
        XCTAssertLessThan((CFAbsoluteTimeGetCurrent() - t0) * 1000, 2000)   // debug build; release is ~20 ms
    }

    /// Same sights, same order, same positions as the prototype's cards.json.
    func testCardsMatchThePrototype() throws {
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: Kanazawa.fixture("expected_cards.json"))) as! [String: Any]
        for gr in golden["routes"] as! [[String: Any]] {
            let slack = gr["slack"] as! Double
            let r = Kanazawa.routes[slack] ?? (try! Kanazawa.session.route(slack: slack))
            let gs = gr["sights"] as! [[String: Any]]
            XCTAssertEqual(r.passed.map { $0.sight.poi.id }, gs.map { $0["id"] as! String }, "slack \(slack)")
            for (p, g) in zip(r.passed, gs) { XCTAssertEqual(p.alongMetres, g["alongMetres"] as! Double, accuracy: 0.5) }
        }
    }
}
