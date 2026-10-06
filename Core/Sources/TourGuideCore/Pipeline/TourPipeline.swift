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
    let wikidata: WikidataClient
    let cache: DiskCache?
    public static let routeFactor = 1.25

    public init(transport: HTTPTransport = URLSessionTransport(requestTimeout: 180, resourceTimeout: 240),
                wikidataTransport: HTTPTransport? = nil,
                cache: DiskCache? = DiskCache.named("boxes", ttl: 30 * 86_400), overpassPause: TimeInterval = 10) {
        overpass = OverpassClient(transport: transport, pause: overpassPause)
        wikidata = WikidataClient(transport: wikidataTransport ?? URLSessionTransport(requestTimeout: 20, resourceTimeout: 40))
        self.cache = cache
    }

    public static func cacheKey(bbox: [Double]) -> String {
        "box:\(OverpassQuery.version):" + bbox.map { String(format: "%.5f", $0) }.joined(separator: ",")
    }

    /// Throws only when Overpass can't be reached or parsed: no streets, no route. A Wikidata
    /// failure is a `.degraded` stage and a box where every named sight is Tier 2.
    public func fetchBox(from a: Place, to b: Place, maxSlack: Double = 0.5, useCache: Bool = true,
                         progress: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> FetchBox {
        let (bbox, straight) = SlackEllipse.bbox(a: a, b: b, slack: maxSlack, routeFactor: Self.routeFactor)
        let key = Self.cacheKey(bbox: bbox)
        if useCache, var hit = cache?.load(FetchBox.self, key: key) {
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
