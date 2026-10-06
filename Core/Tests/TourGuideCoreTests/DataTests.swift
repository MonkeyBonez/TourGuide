import XCTest
@testable import TourGuideCore

final class OverpassTests: XCTestCase {
    func testQueryTextIsTheMeasuredOne() {
        let q = OverpassQuery.text(bbox: Kanazawa.box.bbox)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:180];"))
        XCTAssertTrue(q.contains(#"nwr["historic"](36.55131,136.63184,36.58649,136.66956);"#))
        XCTAssertTrue(q.contains(#"nwr["leisure"~"^(park|garden)$"]"#))
        XCTAssertTrue(q.contains(".poi out tags center geom;"))
        XCTAssertTrue(q.hasSuffix("node(w.w);\nout skel qt;"))
    }

    func testWalkableFilter() {
        XCTAssertTrue(OverpassQuery.walkable(["highway": "residential"]))
        XCTAssertTrue(OverpassQuery.walkable(["highway": "service", "access": "private"]))
        XCTAssertFalse(OverpassQuery.walkable(["highway": "pedestrian", "area": "yes"]))
        XCTAssertFalse(OverpassQuery.walkable(["highway": "footway", "access": "no"]))
        XCTAssertFalse(OverpassQuery.walkable(["highway": "primary", "sidewalk": "separate"]))
        XCTAssertFalse(OverpassQuery.walkable(["highway": "motorway"]))
        XCTAssertFalse(OverpassQuery.walkable(["highway": "cycleway"]))
        XCTAssertFalse(OverpassQuery.walkable(["highway": "track", "foot": "no"]))
        XCTAssertFalse(OverpassQuery.walkable(["building": "yes"]))
    }

    /// The four shapes that matter, including the one that silently dropped every area POI.
    func testParserHandlesNodesAreasRelationsAndSharedNodes() throws {
        let raw = """
        {"elements":[
          {"type":"node","id":1,"lat":36.0,"lon":136.0,"tags":{"historic":"memorial","name":"Stone"}},
          {"type":"way","id":2,"bounds":{"minlat":36.0,"minlon":136.0,"maxlat":36.002,"maxlon":136.002},
           "geometry":[{"lat":36.0,"lon":136.0},{"lat":36.0,"lon":136.002},{"lat":36.002,"lon":136.002},{"lat":36.002,"lon":136.0},{"lat":36.0,"lon":136.0}],
           "tags":{"leisure":"park","name":"Big Park","wikidata":"Q1","opening_hours":"24/7"}},
          {"type":"relation","id":3,"bounds":{"minlat":36.0,"minlon":136.0,"maxlat":36.001,"maxlon":136.001},
           "members":[{"type":"way","ref":9,"role":"outer","geometry":[{"lat":36.0,"lon":136.0},{"lat":36.0,"lon":136.001},{"lat":36.001,"lon":136.001},{"lat":36.0,"lon":136.0}]}],
           "tags":{"amenity":"place_of_worship","religion":"buddhist","name":"寺","name:en":"Temple"}},
          {"type":"node","id":10,"lat":36.01,"lon":136.01,"tags":{"tourism":"artwork","name":"Gate"}},
          {"type":"way","id":20,"nodes":[11,10],"tags":{"highway":"footway"}},
          {"type":"node","id":11,"lat":36.011,"lon":136.011}
        ]}
        """
        let box = try OverpassParser.parse(Data(raw.utf8), start: Place(name: "A", lat: 36, lon: 136), end: Place(name: "B", lat: 36.01, lon: 136.01),
                                           bbox: [35.9, 135.9, 36.1, 136.1], straightM: 1, slack: 0.5, routeFactor: 1.25)
        XCTAssertEqual(box.pois.map(\.id), ["node/1", "way/2", "relation/3", "node/10"])
        let park = box.pois[1]
        XCTAssertEqual(park.lat, 36.001, accuracy: 1e-9)
        XCTAssertEqual(park.rings.count, 1)
        XCTAssertEqual(park.wikidata, "Q1")
        XCTAssertEqual(park.allTags?["opening_hours"], "24/7")
        XCTAssertEqual(park.tags, ["leisure": "park"])
        XCTAssertEqual(box.pois[2].name, "Temple"); XCTAssertEqual(box.pois[2].nameLocal, "寺")
        XCTAssertEqual(box.pois[2].rings.first?.count, 4)
        XCTAssertEqual(box.ways.map(\.id), [20])
        XCTAssertEqual(Set(box.nodes.map { Int($0[0]) }), [10, 11], "the gate node is also a way node")
    }
}

final class OverpassClientTests: XCTestCase {
    func testRotatesPastFailingMirrors() async throws {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        t.script(host: "a.test", [(504, Data("gateway".utf8))])
        t.script(host: "b.test", [(200, nil)])                       // timeout
        t.script(host: "c.test", [(200, Data(#"{"elements":[]}"#.utf8))])
        let client = OverpassClient(transport: t, mirrors: ["https://a.test/i", "https://b.test/i", "https://c.test/i"], pause: 0)
        let log = Log()
        let data = try await client.fetch(query: "x") { log.add($0) }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"elements":[]}"#)
        XCTAssertEqual(log.items, [.trying(mirror: "a.test", attempt: 1, of: 6), .failed(mirror: "a.test", reason: "HTTP 504"),
                                   .trying(mirror: "b.test", attempt: 2, of: 6), .failed(mirror: "b.test", reason: "timed out"),
                                   .trying(mirror: "c.test", attempt: 3, of: 6)])
    }

    func testAllMirrorsFailing() async {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        for h in ["a.test", "b.test"] { t.script(host: h, [(429, Data()), (502, Data())]) }
        let client = OverpassClient(transport: t, mirrors: ["https://a.test/i", "https://b.test/i"], pause: 0)
        do { _ = try await client.fetch(query: "x"); XCTFail("should throw") }
        catch let e as OverpassClient.AllMirrorsFailed { XCTAssertEqual(e.reasons.count, 4) }
        catch { XCTFail("\(error)") }
    }

    /// A 200 carrying an Overpass runtime error is a failure, not an empty city.
    func testRuntimeErrorRemarkIsAFailure() async throws {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        t.script(host: "a.test", [(200, Data(#"{"elements":[],"remark":"runtime error: Query timed out"}"#.utf8))])
        t.script(host: "b.test", [(200, Data(#"{"elements":[1]}"#.utf8))])
        let client = OverpassClient(transport: t, mirrors: ["https://a.test/i", "https://b.test/i"], pause: 0)
        let data = try await client.fetch(query: "x")
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"elements":[1]}"#)
    }
}

final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [OverpassClient.Progress] = []
    func add(_ p: OverpassClient.Progress) { lock.withLock { _items.append(p) } }
    var items: [OverpassClient.Progress] { lock.withLock { _items } }
}

final class WikidataMatcherTests: XCTestCase {
    func load<T: Decodable>(_ t: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: Kanazawa.fixture(name)))
    }

    /// The Swift port gives the prototype's result on all 519 POIs.
    func testMatcherReproducesThePrototype() throws {
        var box = try load(FetchBox.self, "box_pois.json")
        let items = try load([WikidataItem].self, "wikidata_box.json")
        let golden = try load(FetchBox.self, "matched_v2_pois.json")
        for i in box.pois.indices where box.pois[i].wikidata != nil { box.pois[i].match = "tag" }
        WikidataMatcher.applyBoxBridge(&box.pois, items: items)
        WikidataMatcher.dedupe(&box.pois)
        XCTAssertEqual(box.pois.count, 519)
        for (a, b) in zip(box.pois, golden.pois) {
            XCTAssertEqual(a.wikidata, b.wikidata, a.id); XCTAssertEqual(a.sitelinks ?? 0, b.sitelinks ?? 0, a.id)
            XCTAssertEqual(a.wdLabel, b.wdLabel, a.id); XCTAssertEqual(a.match, b.match, a.id)
            XCTAssertEqual(a.parent, b.parent, a.id); XCTAssertEqual(a.dupOf, b.dupOf, a.id)
        }
        let counts = Dictionary(grouping: box.pois.compactMap(\.match), by: { $0 }).mapValues(\.count)
        XCTAssertEqual(counts, ["tag": 46, "box": 14, "tag-via-child": 4, "box-via-child": 2])
        XCTAssertEqual(box.pois.filter { $0.parent != nil }.count, 97)
        XCTAssertEqual(box.pois.filter { $0.dupOf != nil }.count, 2)
        XCTAssertEqual(box.pois.filter { $0.tier == 1 }.count, 53)
        // The castle's 20 languages reach the park it stands in.
        let park = box.pois.first { $0.name == "Kanazawa Castle Park" }!
        XCTAssertEqual(park.sitelinks, 20); XCTAssertEqual(park.match, "tag-via-child")
    }

    func testNameRule() {
        let church = POI(id: "n/1", lat: 0, lon: 0, name: "Kanazawa Catholic Church", nameLocal: nil, tags: [:])
        XCTAssertFalse(WikidataMatcher.namesMatch(poi: church, labelEn: "Kanazawa", labelJa: "金沢市"))
        let oyama = POI(id: "n/2", lat: 0, lon: 0, name: "Oyama-jinja Shrine", nameLocal: "尾山神社", tags: [:])
        XCTAssertTrue(WikidataMatcher.namesMatch(poi: oyama, labelEn: "Oyama Shrine", labelJa: "尾山神社"))
        XCTAssertEqual(WikidataMatcher.normalize("Kenroku-en Garden"), "kenrokuen")
    }

    func testTitleBridgeGuards() {
        func omicho() -> [POI] { [POI(id: "node/1", lat: 36.5714, lon: 136.6562, name: "Omicho Market", nameLocal: "近江町市場", tags: ["amenity": "marketplace"])] }
        func entity(_ coord: [Double]?, p131: [String] = []) -> WikidataEntity {
            WikidataEntity(qid: "Q11638507", labelEn: "Ōmichō Market", labelJa: "近江町市場", descriptionEn: nil, descriptionJa: nil,
                           sitelinks: 1, coord: coord, p131: p131, enwiki: nil, jawiki: "近江町市場", image: nil, inception: nil)
        }
        var p = omicho()
        WikidataMatcher.applyTitleBridge(&p, ja: ["近江町市場": entity([36.5716, 136.6566])], en: [:], localAdmin: [])
        XCTAssertEqual(p[0].tier, 1); XCTAssertEqual(p[0].match, "title-ja")
        p = omicho()
        WikidataMatcher.applyTitleBridge(&p, ja: ["近江町市場": entity([36.59, 136.6566])], en: [:], localAdmin: [])
        XCTAssertEqual(p[0].tier, 2, "a same-name market 2 km away is someone else's")
        p = omicho()
        WikidataMatcher.applyTitleBridge(&p, ja: ["近江町市場": entity(nil, p131: ["Q191130"])], en: [:], localAdmin: ["Q191130"])
        XCTAssertEqual(p[0].tier, 1, "no coordinate but located in this city")
    }

    func testSitelinkRule() {
        XCTAssertEqual(WikidataClient.sitelinkCount(["enwiki", "jawiki", "commonswiki", "enwikivoyage", "frwiki"]), 3)
    }
}

final class CardEnricherTests: XCTestCase {
    var transport: FixtureTransport {
        FixtureTransport(directory: Bundle.module.url(forResource: "http", withExtension: nil, subdirectory: "Fixtures")!)
    }

    func testCardsFromRecordedResponses() async throws {
        let enricher = CardEnricher(transport: transport, cache: nil)
        let r = Kanazawa.routes[0.5]!
        await enricher.prefetch(r.passed.map(\.sight.poi))
        let kenroku = await enricher.content(for: Kanazawa.sight("Kenroku-en Park").poi)
        XCTAssertEqual(kenroku.extractLang, "en")
        XCTAssertTrue(kenroku.extract?.contains("strolling") == true || kenroku.extract?.contains("garden") == true)
        XCTAssertNotNil(kenroku.imageURL)
        XCTAssertEqual(kenroku.wikipediaTitle, "Kenroku-en")
        let ozaki = await enricher.content(for: Kanazawa.sight("Ozaki Shrine").poi)
        XCTAssertEqual(ozaki.extractLang, "ja")
        XCTAssertTrue(ozaki.extract?.contains("尾﨑神社") == true)
        let tier2 = await enricher.content(for: Kanazawa.sight("照教寺").poi)
        XCTAssertNil(tier2.extract, "no article anywhere: a plainer card, not an error")
    }

    func testMissingNetworkIsAPlainCard() async {
        let enricher = CardEnricher(transport: FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent")), cache: nil)
        let c = await enricher.content(for: Kanazawa.sight("Kenroku-en Park").poi)
        XCTAssertNil(c.extract); XCTAssertNil(c.imageURL)
    }
}

final class PipelineTests: XCTestCase {
    func tempCache() -> DiskCache {
        DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)"), ttl: 3600)
    }

    func testCacheHitSkipsTheNetwork() async throws {
        let cache = tempCache()
        let box = Kanazawa.box
        cache.store(box, key: TourPipeline.cacheKey(bbox: box.bbox))
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        let pipeline = TourPipeline(transport: t, wikidataTransport: t, cache: cache, overpassPause: 0)
        let got = try await pipeline.fetchBox(from: BundledFixtures.kanazawaStart, to: BundledFixtures.kanazawaEnd)
        XCTAssertEqual(got.pois.count, 519)
        XCTAssertTrue(t.requests.isEmpty)
    }

    /// Streets but no Wikidata: still a route, every named sight Tier 2, and nothing cached.
    func testWikidataDownDegradesInsteadOfFailing() async throws {
        let overpass = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        let raw = #"{"elements":[{"type":"node","id":1,"lat":36.57,"lon":136.65,"tags":{"historic":"memorial","name":"Stone","wikidata":"Q5"}},{"type":"way","id":2,"nodes":[3,4],"tags":{"highway":"footway"}},{"type":"node","id":3,"lat":36.578,"lon":136.648},{"type":"node","id":4,"lat":36.56,"lon":136.653}]}"#
        overpass.script(host: "maps.mail.ru", [(200, Data(raw.utf8))])
        let wikidataDown = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        for h in ["www.wikidata.org", "query.wikidata.org"] { wikidataDown.script(host: h, Array(repeating: (503, Data()), count: 9)) }
        let cache = tempCache()
        let pipeline = TourPipeline(transport: overpass, wikidataTransport: wikidataDown, cache: cache, overpassPause: 0)
        let stages = StageLog()
        let box = try await pipeline.fetchBox(from: BundledFixtures.kanazawaStart, to: BundledFixtures.kanazawaEnd) { stages.add($0) }
        XCTAssertEqual(box.pois.first?.tier, 2)
        XCTAssertTrue(stages.items.contains { if case .degraded = $0 { return true }; return false })
        XCTAssertNil(cache.load(FetchBox.self, key: TourPipeline.cacheKey(bbox: box.bbox)), "a degraded box is not cached")
    }

    func testDiskCacheExpires() {
        let c = DiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tg-\(UUID().uuidString)"), ttl: -1)
        c.store(["a": 1], key: "k")
        XCTAssertNil(c.load([String: Int].self, key: "k"))
    }
}

final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [TourPipeline.Stage] = []
    func add(_ s: TourPipeline.Stage) { lock.withLock { _items.append(s) } }
    var items: [TourPipeline.Stage] { lock.withLock { _items } }
}
