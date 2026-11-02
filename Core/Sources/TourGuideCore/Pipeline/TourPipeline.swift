import Foundation

/// A → B to a tiered, matched `FetchBox`: the slack-ellipse box, one Overpass query, the
/// three Wikidata bridges, §4.3 dedupe. Cached on disk by box, so a corridor is fetched once.
public actor TourPipeline {
    public enum Stage: Sendable, Equatable {
        case cacheHit
        case overpass(OverpassClient.Progress)
        case parsing(bytes: Int)
        case wikidata(String)
        case degraded(String)
        case done(pois: Int, tier1: Int, ways: Int)
    }

    let overpass: OverpassClient
    /// The fastest-path fetch: short timeouts, hedged across mirrors (`fetchHedged`) — it is a
    /// head start, not the route, so it gives up quickly and silently.
    let fastOverpass: OverpassClient
    let fastStagger: TimeInterval
    let wikidata: WikidataClient
    let cache: DiskCache?
    public static let routeFactor = 1.25
    private static let matchingVersion = "visibility-v1"

    public init(transport: HTTPTransport = URLSessionTransport(requestTimeout: 90, resourceTimeout: 150),
                wikidataTransport: HTTPTransport? = nil,
                cache: DiskCache? = DiskCache.named("boxes", ttl: 30 * 86_400), overpassPause: TimeInterval = 10,
                fastTransport: HTTPTransport? = nil, fastStagger: TimeInterval = 3) {
        self.fastStagger = fastStagger
        overpass = OverpassClient(transport: transport, pause: overpassPause)
        fastOverpass = OverpassClient(transport: fastTransport ?? URLSessionTransport(requestTimeout: 20, resourceTimeout: 30),
                                      rounds: 1, pause: 0)
        wikidata = WikidataClient(transport: wikidataTransport ?? URLSessionTransport(requestTimeout: 20, resourceTimeout: 40))
        self.cache = cache
    }

    public static func cacheKey(bbox: [Double]) -> String {
        "box:\(OverpassQuery.version):\(matchingVersion):" + bbox.map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    private static func legacyCacheKey(bbox: [Double]) -> String {
        "box:\(OverpassQuery.version):" + bbox.map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    private func cachedBox(bbox: [Double]) -> FetchBox? {
        let key = Self.cacheKey(bbox: bbox)
        if let hit = cache?.load(FetchBox.self, key: key) { return hit }
        guard let hit = cache?.load(FetchBox.self, key: Self.legacyCacheKey(bbox: bbox)),
              Self.legacyMatchingIsCompatible(hit) else { return nil }
        return hit
    }

    private static func legacyMatchingIsCompatible(_ box: FetchBox) -> Bool {
        guard box.pois.contains(where: \.isExplicitlyIndoor) else { return true }
        let byID = Dictionary(box.pois.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return box.pois.allSatisfy { poi in
            guard let foldedInto = poi.parent ?? poi.dupOf else { return true }
            guard let parent = byID[foldedInto] else { return false }
            return poi.isExplicitlyIndoor == parent.isExplicitlyIndoor
        }
    }

    public static func walkCacheKey(bbox: [Double]) -> String {
        "walk:\(OverpassQuery.walkVersion):" + bbox.map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    /// The full box from the disk cache, if this corridor was fetched before (then the app
    /// skips the fastest-path step).
    public func cachedBox(from a: Place, to b: Place, maxSlack: Double = 0.5) -> FetchBox? {
        let (bbox, _) = SlackEllipse.bbox(a: a, b: b, slack: maxSlack, routeFactor: Self.routeFactor)
        guard var hit = cachedBox(bbox: bbox) else { return nil }
        hit.start = a; hit.end = b
        return hit
    }

    /// The walk network in a narrow box around A→B, no sights (PRD §5 step 8): enough to
    /// route the fastest path while the full corridor loads.
    public func fetchWalkNetwork(from a: Place, to b: Place, bufferM: Double = LineBuffer.defaultBufferM,
                                 useCache: Bool = true,
                                 progress: @escaping @Sendable (OverpassClient.Progress) -> Void = { _ in }) async throws -> FetchBox {
        let bbox = LineBuffer.bbox(a: a, b: b, bufferM: bufferM)
        let key = Self.walkCacheKey(bbox: bbox)
        if useCache, var hit = cache?.load(FetchBox.self, key: key) {
            hit.start = a; hit.end = b
            return hit
        }
        let straight = Polygon.metres(a.lat, a.lon, b.lat, b.lon)
        let data = try await fastOverpass.fetchHedged(query: OverpassQuery.walkOnlyText(bbox: bbox), stagger: fastStagger,
                                                      progress: progress)
        let box = try OverpassParser.parse(data, start: a, end: b, bbox: bbox, straightM: straight, slack: 0,
                                           routeFactor: Self.routeFactor)
        cache?.store(box, key: key)
        return box
    }

    /// Throws only when Overpass can't be reached or parsed: no streets, no route. A Wikidata
    /// failure is a `.degraded` stage and a box where every named sight is Tier 2.
    public func fetchBox(from a: Place, to b: Place, maxSlack: Double = 0.5, useCache: Bool = true,
                         progress: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> FetchBox {
        let (bbox, straight) = SlackEllipse.bbox(a: a, b: b, slack: maxSlack, routeFactor: Self.routeFactor)
        let key = Self.cacheKey(bbox: bbox)
        if useCache, var hit = cachedBox(bbox: bbox) {
            hit.start = a; hit.end = b
            progress(.cacheHit)
            return hit
        }
        let data = try await overpass.fetch(query: OverpassQuery.text(bbox: bbox)) { progress(.overpass($0)) }
        progress(.parsing(bytes: data.count))
        var box = try OverpassParser.parse(data, start: a, end: b, bbox: bbox, straightM: straight, slack: maxSlack,
                                           routeFactor: Self.routeFactor)
        var degraded: String?
        do {
            try await match(&box.pois, bbox: bbox, progress: progress)
        } catch {
            degraded = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            for i in box.pois.indices where box.pois[i].match == nil { box.pois[i].wikidata = nil }
            if !box.pois.contains(where: { $0.isFolded }) { WikidataMatcher.dedupe(&box.pois) }
            progress(.degraded("Wikidata unreachable (\(degraded!)); every sight is ranked by name only"))
        }
        if degraded == nil { cache?.store(box, key: key) }
        progress(.done(pois: box.pois.count, tier1: box.pois.filter { $0.tier == 1 }.count, ways: box.ways.count))
        return box
    }

    /// Tag bridge → box bridge → dedupe → title bridge (PRD §4.1, §4.3).
    public func match(_ pois: inout [POI], bbox: [Double], progress: @Sendable (Stage) -> Void = { _ in }) async throws {
        let tagged = pois.compactMap(\.wikidata)
        progress(.wikidata("fame for \(Set(tagged).count) tagged sights"))
        let tagEntities = try await wikidata.entities(ids: tagged)
        WikidataMatcher.applyTagBridge(&pois, entities: tagEntities)
        progress(.wikidata("Wikidata items in the box"))
        let items = try await wikidata.itemsWithCoordinates(in: bbox)
        WikidataMatcher.applyBoxBridge(&pois, items: items)
        WikidataMatcher.dedupe(&pois)
        let (ja, en) = WikidataMatcher.titleCandidates(pois)
        progress(.wikidata("Wikipedia titles for \(ja.count + en.count) names"))
        let jaHits = try await wikidata.entities(site: "jawiki", titles: ja)
        let enHits = try await wikidata.entities(site: "enwiki", titles: en)
        let localAdmin = Set(tagEntities.values.flatMap(\.p131))
        WikidataMatcher.applyTitleBridge(&pois, ja: jaHits, en: enHits, localAdmin: localAdmin)
    }
}
