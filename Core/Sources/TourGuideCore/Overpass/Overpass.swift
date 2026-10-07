import Foundation

/// The one query (PRD §4.1, §5 step 3): sights and the walk network for the fetch box.
/// Text identical to the 6 Oct prototype so a fixture is reproducible.
public enum OverpassQuery {
    public static let version = "v1"

    public static func text(bbox: [Double], timeout: Int = 180) -> String {
        let bb = String(format: "%.5f,%.5f,%.5f,%.5f", bbox[0], bbox[1], bbox[2], bbox[3])
        return """
        [out:json][timeout:\(timeout)];
        (
          nwr["historic"](\(bb));
          nwr["tourism"~"^(attraction|artwork|viewpoint|museum|gallery)$"](\(bb));
          nwr["amenity"~"^(place_of_worship|marketplace)$"](\(bb));
          nwr["building"~"^(temple|shrine|church|pagoda|castle)$"](\(bb));
          nwr["leisure"~"^(park|garden)$"](\(bb));
        )->.poi;
        .poi out tags center geom;
        way["highway"]["area"!~"yes"]["access"!~"no"]["highway"!~"abandoned|bus_guideway|construction|cycleway|motor|no|planned|platform|proposed|raceway|razed|rest_area|services"]["foot"!~"no"]["service"!~"private"]["sidewalk"!~"separate"]["sidewalk:both"!~"separate"]["sidewalk:left"!~"separate"]["sidewalk:right"!~"separate"](\(bb))->.w;
        .w out body;
        node(w.w);
        out skel qt;
        """
    }

    /// The fastest-path query (PRD §5 step 8): only the walk network, no sights, for the narrow
    /// `LineBuffer` box. Same way filter as `text`, so the graph is built the same way.
    public static let walkVersion = "v1"
    public static func walkOnlyText(bbox: [Double], timeout: Int = 25) -> String {
        let bb = String(format: "%.5f,%.5f,%.5f,%.5f", bbox[0], bbox[1], bbox[2], bbox[3])
        return """
        [out:json][timeout:\(timeout)];
        way["highway"]["area"!~"yes"]["access"!~"no"]["highway"!~"abandoned|bus_guideway|construction|cycleway|motor|no|planned|platform|proposed|raceway|razed|rest_area|services"]["foot"!~"no"]["service"!~"private"]["sidewalk"!~"separate"]["sidewalk:both"!~"separate"]["sidewalk:left"!~"separate"]["sidewalk:right"!~"separate"](\(bb))->.w;
        .w out body;
        node(w.w);
        out skel qt;
        """
    }

    /// osmnx's "walk" filter (2.1.1) with the pipeline's default access: keep access=private,
    /// drop access=no. Applied again client-side so a POI way that is also a highway is sorted.
    public static func walkable(_ t: [String: String]) -> Bool {
        guard let hw = t["highway"], t["area"] != "yes", t["access"] != "no" else { return false }
        for bad in ["abandoned", "bus_guideway", "construction", "cycleway", "motor", "no", "planned", "platform",
                    "proposed", "raceway", "razed", "rest_area", "services"] where hw.contains(bad) { return false }
        if t["foot"] == "no" || t["service"] == "private" { return false }
        for k in ["sidewalk", "sidewalk:both", "sidewalk:left", "sidewalk:right"] where t[k] == "separate" { return false }
        return true
    }
}

public enum OverpassParser {
    public struct ParseError: Error, LocalizedError { public var errorDescription: String? { "Overpass returned something that isn't OSM JSON." } }
    static let classifying: Set<String> = ["historic", "tourism", "amenity", "building", "religion", "leisure"]

    public static func parse(_ data: Data, start: Place, end: Place, bbox: [Double], straightM: Double,
                             slack: Double, routeFactor: Double) throws -> FetchBox {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw ParseError() }
        var pois: [POI] = [], ways: [Way] = []
        var nodes: [Int64: (Double, Double)] = [:], nodeOrder: [Int64] = []
        var tagged: [Int64: (Double, Double)] = [:]
        for el in elements {
            guard let type = el["type"] as? String, let id = (el["id"] as? NSNumber)?.int64Value else { continue }
            let tags = el["tags"] as? [String: String] ?? [:]
            if type == "node", el["tags"] == nil, let lat = el["lat"] as? Double, let lon = el["lon"] as? Double {
                if nodes[id] == nil { nodeOrder.append(id) }
                nodes[id] = (lat, lon); continue
            }
            if type == "way", OverpassQuery.walkable(tags), let ns = el["nodes"] as? [NSNumber] {
                ways.append(Way(id: id, tags: tags, nodes: ns.map(\.int64Value))); continue
            }
            // `out tags center geom` gives geometry and bounds but no `center` for ways and
            // relations; the bounds midpoint stands in (the bug that dropped every area POI).
            var lat: Double, lon: Double
            if type == "node", let a = el["lat"] as? Double, let b = el["lon"] as? Double {
                lat = a; lon = b; tagged[id] = (a, b)
            } else if let c = el["center"] as? [String: Double], let a = c["lat"], let b = c["lon"] {
                lat = a; lon = b
            } else if let b = el["bounds"] as? [String: Double], let s = b["minlat"], let n = b["maxlat"], let w = b["minlon"], let e = b["maxlon"] {
                lat = (s + n) / 2; lon = (w + e) / 2
            } else { continue }
            var poi = POI(id: "\(type)/\(id)", lat: lat, lon: lon, name: tags["name:en"] ?? tags["name"], nameLocal: tags["name"],
                          tags: tags.filter { classifying.contains($0.key) }, allTags: tags, rings: rings(el), wikidata: tags["wikidata"])
            poi.wikipedia = tags["wikipedia"]; poi.heritage = tags["heritage"]
            pois.append(poi)
        }
        // A tagged node (a POI) can also be a way node; its coordinates came with the POI.
        for w in ways { for n in w.nodes where nodes[n] == nil { if let c = tagged[n] { nodes[n] = c; nodeOrder.append(n) } } }
        return FetchBox(start: start, end: end, bbox: bbox, straightM: straightM, slack: slack, routeFactor: routeFactor,
                        pois: pois, ways: ways, nodes: nodeOrder.map { [Double($0), nodes[$0]!.0, nodes[$0]!.1] })
    }

    /// Polygon rings for a closed way, or a relation's outer members, as [[lat, lon], …].
    static func rings(_ el: [String: Any]) -> [[[Double]]] {
        func pts(_ g: Any?) -> [[Double]]? {
            guard let g = g as? [[String: Any]], g.count > 3 else { return nil }
            return g.compactMap { p in (p["lat"] as? Double).flatMap { la in (p["lon"] as? Double).map { [la, $0] } } }
        }
        if el["type"] as? String == "way", let g = pts(el["geometry"]) {
            return g.first == g.last ? [g] : []
        }
        if el["type"] as? String == "relation", let members = el["members"] as? [[String: Any]] {
            return members.filter { $0["role"] as? String == "outer" }.compactMap { pts($0["geometry"]) }
        }
        return []
    }
}

/// Public Overpass instances hang and refuse unpredictably (6 Oct 2026: three of four failed;
/// the real query 504'd twice). Rotate through mirrors, two rounds, with a pause between rounds.
public actor OverpassClient {
    public static let mirrors = [
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    public enum Progress: Sendable, Equatable {
        case trying(mirror: String, attempt: Int, of: Int)
        case failed(mirror: String, reason: String)
    }
    public struct AllMirrorsFailed: Error, LocalizedError {
        public let reasons: [String]
        public init(reasons: [String]) { self.reasons = reasons }
        public var errorDescription: String? { "Couldn't reach any OpenStreetMap server (\(reasons.count) tries)." }
    }

    let transport: HTTPTransport
    let mirrors: [String]
    let rounds: Int
    let pause: TimeInterval

    public init(transport: HTTPTransport, mirrors: [String] = OverpassClient.mirrors, rounds: Int = 2, pause: TimeInterval = 10) {
        self.transport = transport; self.mirrors = mirrors; self.rounds = rounds; self.pause = pause
    }

    /// Hedged fetch for a small query: mirror i starts `stagger × i` seconds in unless an answer
    /// has come back; the first good answer wins and the rest are cancelled. One slow mirror then
    /// costs `stagger`, not its whole timeout.
    public func fetchHedged(query: String, stagger: TimeInterval = 3,
                            progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Data {
        let mirrors = self.mirrors, transport = self.transport
        let reasons = ReasonLog()
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            for (i, m) in mirrors.enumerated() {
                group.addTask {
                    if i > 0 { try await Task.sleep(nanoseconds: UInt64(stagger * Double(i) * 1e9)) }
                    let host = URL(string: m)?.host ?? m
                    progress(.trying(mirror: host, attempt: i + 1, of: mirrors.count))
                    do { return try await Self.attempt(m, query: query, transport: transport) }
                    catch is CancellationError { throw CancellationError() }
                    catch let e as URLError where e.code == .cancelled { throw CancellationError() }
                    catch {
                        let r = Self.reason(error)
                        reasons.add("\(host): \(r)"); progress(.failed(mirror: host, reason: r))
                        return nil
                    }
                }
            }
            for try await result in group {
                if let data = result { group.cancelAll(); return data }
            }
            throw AllMirrorsFailed(reasons: reasons.items)
        }
    }

    static func attempt(_ mirror: String, query: String, transport: HTTPTransport) async throws -> Data {
        var r = URLRequest(url: URL(string: mirror)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = formBody(["data": query])
        let data = try await transport.fetch(r)
        // A 200 with a runtime error (timeout, out of memory) has no usable elements.
        if let s = String(data: data.prefix(4096), encoding: .utf8), s.contains("\"remark\""), s.contains("runtime error") {
            throw URLError(.cannotParseResponse)
        }
        guard data.first == UInt8(ascii: "{") else { throw URLError(.cannotParseResponse) }
        return data
    }

    static func reason(_ error: Error) -> String {
        (error as? HTTPError).map { "HTTP \($0.status)" }
            ?? (error as? URLError).map { "\($0.code == .timedOut ? "timed out" : "error \($0.code.rawValue)")" } ?? "\(error)"
    }

    public func fetch(query: String, progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Data {
        var reasons: [String] = []
        let total = mirrors.count * rounds
        var attempt = 0
        for round in 0..<rounds {
            if round > 0 && pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * Double(round) * 1e9)) }
            for m in mirrors {
                try Task.checkCancellation()
                attempt += 1
                let host = URL(string: m)?.host ?? m
                progress(.trying(mirror: host, attempt: attempt, of: total))
                do {
                    return try await Self.attempt(m, query: query, transport: transport)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let reason = Self.reason(error)
                    reasons.append("\(host): \(reason)")
                    progress(.failed(mirror: host, reason: reason))
                }
            }
        }
        throw AllMirrorsFailed(reasons: reasons)
    }
}

final class ReasonLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    func add(_ s: String) { lock.withLock { _items.append(s) } }
    var items: [String] { lock.withLock { _items } }
}
