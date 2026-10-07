import XCTest
import LikeWaterEngine
@testable import TourGuideCore

/// PRD §5 step 5 / §8.1: left = most sights, right = direct, square law.
final class SliderLawTests: XCTestCase {
    func testEndsAreFlipped() {
        XCTAssertEqual(SliderLaw.slack(position: 0, maxSlack: 0.5), 0.5)
        XCTAssertEqual(SliderLaw.slack(position: 1, maxSlack: 0.5), 0)
        XCTAssertEqual(SliderLaw.position(slack: 0, maxSlack: 0.5), 1)
        XCTAssertEqual(SliderLaw.position(slack: 0.5, maxSlack: 0.5), 0)
    }

    func testSquareLawGivesTheLowEndTheTravel() {
        // The owner's Nagamachi walk (slack 0.1) sits at 0.55, not at 0.8 as a linear slider had it.
        XCTAssertEqual(SliderLaw.position(slack: 0.1, maxSlack: 0.5), 0.553, accuracy: 0.001)
        XCTAssertEqual(SliderLaw.position(slack: 0.2, maxSlack: 0.5), 0.368, accuracy: 0.001)
        XCTAssertEqual(SliderLaw.slack(position: 0.55, maxSlack: 0.5), 0.101)
        // Right half covers slack 0…0.125: ten of the twenty 0.05 steps.
        XCTAssertEqual(SliderLaw.slack(position: 0.5, maxSlack: 0.5), 0.125)
    }

    func testRoundTripAndMonotone() {
        var last = Double.infinity
        for i in 0...20 {
            let p = Double(i) / 20
            let s = SliderLaw.slack(position: p, maxSlack: 1.0)
            XCTAssertLessThanOrEqual(s, last); last = s
            XCTAssertEqual(SliderLaw.position(slack: s, maxSlack: 1.0), p, accuracy: 0.02)
        }
    }

    func testZeroMaxIsDirectWithoutNaN() {
        XCTAssertEqual(SliderLaw.position(slack: 0, maxSlack: 0), 1)
        XCTAssertEqual(SliderLaw.slack(position: 0.3, maxSlack: 0), 0)
        XCTAssertEqual(SliderLaw.position(slack: 0.7, maxSlack: 0.5), 0, "clamped")
    }
}

/// PRD §5 step 8: the fastest path from a narrow, sight-less box.
final class FastPathTests: XCTestCase {
    func testKanazawaNarrowBox() {
        let bb = LineBuffer.bbox(a: BundledFixtures.kanazawaStart, b: BundledFixtures.kanazawaEnd)
        for (a, b) in zip(bb, [36.55701, 136.64464, 36.58079, 136.65676]) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testNarrowBoxRoutesTheDirectWalk() throws {
        let narrow = Kanazawa.box.cropped(to: LineBuffer.bbox(a: Kanazawa.box.start, b: Kanazawa.box.end))
        XCTAssertTrue(narrow.pois.isEmpty)
        XCTAssertEqual(narrow.slack, 0)
        let s = try TourSession(box: narrow, maxSlack: 0)
        let r = try s.route(slack: 0)
        XCTAssertEqual(r.metres, 2941, accuracy: 0.5)
        let full = Kanazawa.routes[0]!
        XCTAssertEqual(r.coordinates.map { [$0.lat, $0.lon] }, full.coordinates.map { [$0.lat, $0.lon] })
    }

    func testCroppedBoxIsAFraction() {
        let narrow = Kanazawa.box.cropped(to: LineBuffer.bbox(a: Kanazawa.box.start, b: Kanazawa.box.end))
        XCTAssertEqual(narrow.ways.count, 1390)
        XCTAssertLessThan(Double(narrow.nodes.count), 0.35 * Double(Kanazawa.box.nodes.count))
        let ids = Set(narrow.nodes.map { Int64($0[0]) })
        XCTAssertTrue(narrow.ways.allSatisfy { $0.nodes.allSatisfy(ids.contains) }, "every way keeps all its nodes")
    }

    /// 150 m is too narrow: A's 27 m node drops out of the main component and the "fastest" path
    /// starts elsewhere. 300 m reproduces the full box's direct route exactly.
    func testTooNarrowABoxChangesTheStart() throws {
        let narrow = Kanazawa.box.cropped(to: LineBuffer.bbox(a: Kanazawa.box.start, b: Kanazawa.box.end, bufferM: 150))
        let s = try TourSession(box: narrow, maxSlack: 0)
        XCTAssertGreaterThan(s.snapA, 40)
    }

    func testWalkOnlyQueryText() {
        let q = OverpassQuery.walkOnlyText(bbox: [36.55701, 136.64464, 36.58079, 136.65676])
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:25];"))
        XCTAssertFalse(q.contains("nwr["), "no sights in the fast query")
        XCTAssertTrue(q.contains(#"way["highway"]["area"!~"yes"]"#))
        XCTAssertTrue(q.contains("(36.55701,136.64464,36.58079,136.65676)->.w;"))
        XCTAssertTrue(q.hasSuffix("node(w.w);\nout skel qt;"))
        // Same way filter as the full query, so the two graphs are built the same way.
        let full = OverpassQuery.text(bbox: [36.55701, 136.64464, 36.58079, 136.65676])
        let wayLine = q.split(separator: "\n").first { $0.hasPrefix("way[") }!
        XCTAssertTrue(full.contains(wayLine))
    }

    func tempCache() -> DiskCache {
        DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)"), ttl: 3600)
    }

    func testWalkNetworkParsesWithoutPOIsAndIsCached() async throws {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        let raw = #"{"elements":[{"type":"way","id":2,"nodes":[3,4],"tags":{"highway":"footway"}},{"type":"node","id":3,"lat":36.578,"lon":136.648},{"type":"node","id":4,"lat":36.56,"lon":136.653}]}"#
        t.script(host: "maps.mail.ru", [(200, Data(raw.utf8))])
        let cache = tempCache()
        let pipeline = TourPipeline(transport: t, wikidataTransport: t, cache: cache, overpassPause: 0, fastTransport: t, fastStagger: 5)
        let a = BundledFixtures.kanazawaStart, b = BundledFixtures.kanazawaEnd
        let box = try await pipeline.fetchWalkNetwork(from: a, to: b)
        XCTAssertTrue(box.pois.isEmpty)
        XCTAssertEqual(box.ways.count, 1)
        XCTAssertEqual(box.nodes.count, 2)
        XCTAssertEqual(t.requests.count, 1)
        let again = try await pipeline.fetchWalkNetwork(from: a, to: b)
        XCTAssertEqual(again.ways.count, 1)
        XCTAssertEqual(t.requests.count, 1, "second call is a cache hit")
        XCTAssertNotNil(cache.load(FetchBox.self, key: TourPipeline.walkCacheKey(bbox: LineBuffer.bbox(a: a, b: b))))
    }

    func testFastClientGivesUpAfterOneRound() async {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        let pipeline = TourPipeline(transport: t, wikidataTransport: t, cache: tempCache(), overpassPause: 0, fastTransport: t, fastStagger: 0)
        do {
            _ = try await pipeline.fetchWalkNetwork(from: BundledFixtures.kanazawaStart, to: BundledFixtures.kanazawaEnd)
            XCTFail("no mirror answers")
        } catch let e as OverpassClient.AllMirrorsFailed {
            XCTAssertEqual(e.reasons.count, OverpassClient.mirrors.count, "each mirror once, no second round")
        } catch { XCTFail("\(error)") }
    }

    /// A hung first mirror costs the stagger, not its timeout.
    func testHedgedFetchTakesTheFirstGoodAnswer() async throws {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        t.script(host: "a.test", [(504, Data())])
        t.script(host: "b.test", [(200, Data(#"{"elements":[2]}"#.utf8))])
        t.script(host: "c.test", [(200, Data(#"{"elements":[3]}"#.utf8))])
        let client = OverpassClient(transport: t, mirrors: ["https://a.test/i", "https://b.test/i", "https://c.test/i"], rounds: 1, pause: 0)
        let data = try await client.fetchHedged(query: "x", stagger: 0.2)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"elements":[2]}"#)
    }

    func testCachedBoxProbe() async {
        let cache = tempCache()
        let pipeline = TourPipeline(transport: FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent")), cache: cache)
        let a = BundledFixtures.kanazawaStart, b = BundledFixtures.kanazawaEnd
        let none = await pipeline.cachedBox(from: a, to: b)
        XCTAssertNil(none)
        cache.store(Kanazawa.box, key: TourPipeline.cacheKey(bbox: Kanazawa.box.bbox))
        let hit = await pipeline.cachedBox(from: a, to: b)
        XCTAssertEqual(hit?.pois.count, 519)
    }
}

/// Card tap draws the grounds for an area and a halo for a point (PRD §5.1).
final class HighlightDataTests: XCTestCase {
    func testKenrokuenHasRingsNomuraDoesNot() {
        XCTAssertFalse(Kanazawa.sight("Kenroku-en Park").poi.rings.isEmpty)
        XCTAssertFalse(Kanazawa.sight("Kanazawa Castle Park").poi.rings.isEmpty)
        XCTAssertTrue(Kanazawa.sight("Nomura Samurai House").poi.rings.isEmpty)
        XCTAssertTrue(Kanazawa.sight("Kenroku-en Park").poi.rings.allSatisfy { $0.count >= 4 && $0.first == $0.last })
    }
}

/// PRD §8.10: Apple's English name only when it is clearly the same place.
final class AppleNameGuardTests: XCTestCase {
    func poi(_ tags: [String: String], rings: [[[Double]]] = []) -> POI {
        POI(id: "x", lat: 36.57, lon: 136.65, name: "名前", nameLocal: "名前", tags: tags, rings: rings)
    }
    /// A ~40 × 40 m square: a small pocket park.
    let small: [[[Double]]] = [[[36.57, 136.65], [36.57, 136.6504], [36.5704, 136.6504], [36.5704, 136.65], [36.57, 136.65]]]
    /// ~450 × 450 m.
    let big: [[[Double]]] = [[[36.57, 136.65], [36.57, 136.655], [36.574, 136.655], [36.574, 136.65], [36.57, 136.65]]]

    func testBusStopIsNotAPocketPark() {
        let p = poi(["leisure": "park"], rings: small)
        XCTAssertLessThan(AppleNameGuard.areaM2(p), 5_000)
        XCTAssertFalse(AppleNameGuard.accept(poi: p, resultName: "Musashigatsuji", distance: 20, categoryRaw: "MKPOICategoryPublicTransport"))
        XCTAssertFalse(AppleNameGuard.accept(poi: p, resultName: "Musashi Bus Stop", distance: 20, categoryRaw: nil), "a park needs a park name")
        XCTAssertTrue(AppleNameGuard.accept(poi: p, resultName: "Musashi Pocket Park", distance: 20, categoryRaw: nil))
        XCTAssertTrue(AppleNameGuard.accept(poi: p, resultName: "Kiguracho Hiroba", distance: 4, categoryRaw: "MKPOICategoryPark"))
    }

    func testSmallParkMustBeClose() {
        let p = poi(["leisure": "park"], rings: small)
        XCTAssertFalse(AppleNameGuard.accept(poi: p, resultName: "Hirosaka Park", distance: 113, categoryRaw: "MKPOICategoryPark"))
        let g = poi(["leisure": "park"], rings: big)
        XCTAssertTrue(AppleNameGuard.accept(poi: g, resultName: "Kenrokuen Garden", distance: 140, categoryRaw: "MKPOICategoryPark"))
    }

    func testTemples() {
        let t = poi(["amenity": "place_of_worship", "religion": "buddhist"])
        XCTAssertTrue(AppleNameGuard.accept(poi: t, resultName: "Senko-ji Temple", distance: 5, categoryRaw: nil))
        XCTAssertTrue(AppleNameGuard.accept(poi: t, resultName: "Ninzui", distance: 25, categoryRaw: nil), "anything within 30 m")
        XCTAssertFalse(AppleNameGuard.accept(poi: t, resultName: "Lawson", distance: 40, categoryRaw: nil))
        XCTAssertFalse(AppleNameGuard.accept(poi: t, resultName: "Fukunen-ji Temple", distance: 80, categoryRaw: nil), "a point sight: 60 m")
        let area = poi(["amenity": "place_of_worship", "religion": "shinto"], rings: big)
        XCTAssertTrue(AppleNameGuard.accept(poi: area, resultName: "Oyama Shrine", distance: 150, categoryRaw: nil))
        XCTAssertFalse(AppleNameGuard.accept(poi: area, resultName: "Oyama Shrine", distance: 151, categoryRaw: nil))
    }
}
