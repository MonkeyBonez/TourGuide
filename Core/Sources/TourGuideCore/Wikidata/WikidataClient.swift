import Foundation

/// An item with a coordinate inside the fetch box (the SPARQL box query).
public struct WikidataItem: Codable, Sendable, Equatable {
    public var qid: String
    public var label: String?        // en, else ja, else the Q-id (the label service's fallback)
    public var labelJa: String?
    public var lat: Double
    public var lon: Double
    public var sitelinks: Int        // wikibase:sitelinks, as the 6 Oct box bridge used
    enum CodingKeys: String, CodingKey { case qid, label, lat, lon, sitelinks; case labelJa = "label_ja" }
}

/// What `wbgetentities` tells us about one item.
public struct WikidataEntity: Codable, Sendable, Equatable {
    public var qid: String
    public var labelEn: String?
    public var labelJa: String?
    public var descriptionEn: String?
    public var descriptionJa: String?
    /// Language editions: sitelink keys ending in "wiki", minus commonswiki (the fame score).
    public var sitelinks: Int
    public var coord: [Double]?      // [lat, lon] from P625
    public var p131: [String]
    public var enwiki: String?
    public var jawiki: String?
    public var image: String?        // P18, a Commons file name
    public var inception: String?    // P571, year
    public var label: String? { labelEn ?? labelJa }
}

/// Wikidata over its public APIs. Only bulk endpoints: the free-text search API
/// (`wbsearchentities`) rate-limited us after a handful of calls on 6 Oct, so it is never used.
public actor WikidataClient {
    static let api = URL(string: "https://www.wikidata.org/w/api.php")!
    static let sparql = URL(string: "https://query.wikidata.org/sparql")!
    let transport: HTTPTransport

    public init(transport: HTTPTransport) { self.transport = transport }

    /// Every item with a coordinate (P625) inside the box.
    public func itemsWithCoordinates(in bbox: [Double]) async throws -> [WikidataItem] {
        let q = """
        SELECT ?item ?itemLabel ?itemLabelJa ?coord ?sitelinks WHERE {
          SERVICE wikibase:box { ?item wdt:P625 ?coord . bd:serviceParam wikibase:cornerSouthWest "Point(\(bbox[1]) \(bbox[0]))"^^geo:wktLiteral . bd:serviceParam wikibase:cornerNorthEast "Point(\(bbox[3]) \(bbox[2]))"^^geo:wktLiteral . }
          ?item wikibase:sitelinks ?sitelinks .
          OPTIONAL { ?item rdfs:label ?itemLabelJa FILTER(LANG(?itemLabelJa)="ja") }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en,ja". }
        }
        """
        var c = URLComponents(url: Self.sparql, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "query", value: q), URLQueryItem(name: "format", value: "json")]
        var r = URLRequest(url: c.url!)
        r.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        let request = r
        let data = try await retrying { try await self.transport.fetch(request) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (root["results"] as? [String: Any])?["bindings"] as? [[String: Any]] else { return [] }
        var out: [String: WikidataItem] = [:], order: [String] = []
        for row in rows {
            func v(_ k: String) -> String? { (row[k] as? [String: Any])?["value"] as? String }
            guard let item = v("item"), let coord = v("coord"), let qid = item.split(separator: "/").last.map(String.init),
                  out[qid] == nil else { continue }
            let parts = coord.dropFirst(6).dropLast().split(separator: " ").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            out[qid] = WikidataItem(qid: qid, label: v("itemLabel"), labelJa: v("itemLabelJa"), lat: parts[1], lon: parts[0],
                                    sitelinks: Int(v("sitelinks") ?? "0") ?? 0)
            order.append(qid)
        }
        return order.map { out[$0]! }.sorted { $0.sitelinks > $1.sitelinks }
    }

    /// `wbgetentities` by id, 50 a call.
    public func entities(ids: [String]) async throws -> [String: WikidataEntity] {
        var out: [String: WikidataEntity] = [:]
        let unique = Array(Set(ids)).sorted()
        for start in stride(from: 0, to: unique.count, by: 50) {
            let chunk = unique[start..<min(start + 50, unique.count)]
            for e in try await get(["ids": chunk.joined(separator: "|")]) { out[e.qid] = e }
        }
        return out
    }

    /// `wbgetentities` by Wikipedia title on `site` (jawiki, enwiki), keyed by that title.
    public func entities(site: String, titles: [String]) async throws -> [String: WikidataEntity] {
        var out: [String: WikidataEntity] = [:]
        var seen = Set<String>()
        let unique = titles.filter { !$0.isEmpty && seen.insert($0).inserted }
        for start in stride(from: 0, to: unique.count, by: 50) {
            let chunk = unique[start..<min(start + 50, unique.count)]
            for e in try await get(["sites": site, "titles": chunk.joined(separator: "|")]) {
                if let t = site == "jawiki" ? e.jawiki : e.enwiki { out[t] = e }
            }
        }
        return out
    }

    func get(_ params: [String: String]) async throws -> [WikidataEntity] {
        var c = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
        c.queryItems = (params.merging(["action": "wbgetentities", "format": "json",
                                         "props": "labels|descriptions|sitelinks|claims", "languages": "en|ja"]) { a, _ in a })
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let request = URLRequest(url: c.url!)
        let data = try await retrying { try await self.transport.fetch(request) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: [String: Any]] else { return [] }
        return entities.compactMap { qid, ent in ent["missing"] != nil ? nil : Self.entity(qid: qid, ent) }
    }

    static func entity(qid: String, _ ent: [String: Any]) -> WikidataEntity {
        let sl = ent["sitelinks"] as? [String: [String: Any]] ?? [:]
        let claims = ent["claims"] as? [String: [[String: Any]]] ?? [:]
        func text(_ k: String, _ lang: String) -> String? { ((ent[k] as? [String: Any])?[lang] as? [String: Any])?["value"] as? String }
        func values(_ p: String) -> [Any] {
            (claims[p] ?? []).compactMap { (($0["mainsnak"] as? [String: Any])?["datavalue"] as? [String: Any])?["value"] }
        }
        let coord = values("P625").first.flatMap { v -> [Double]? in
            guard let d = v as? [String: Any], let la = d["latitude"] as? Double, let lo = d["longitude"] as? Double else { return nil }
            return [la, lo]
        }
        let inception = (values("P571").first as? [String: Any])?["time"] as? String
        return WikidataEntity(qid: qid, labelEn: text("labels", "en"), labelJa: text("labels", "ja"),
                              descriptionEn: text("descriptions", "en"), descriptionJa: text("descriptions", "ja"),
                              sitelinks: sitelinkCount(Array(sl.keys)), coord: coord,
                              p131: values("P131").compactMap { ($0 as? [String: Any])?["id"] as? String },
                              enwiki: sl["enwiki"]?["title"] as? String, jawiki: sl["jawiki"]?["title"] as? String,
                              image: values("P18").first as? String,
                              inception: inception.map { String($0.dropFirst().prefix(4)) })
    }

    public static func sitelinkCount(_ keys: [String]) -> Int { keys.filter { $0.hasSuffix("wiki") && $0 != "commonswiki" }.count }

    /// Honour Retry-After on 429; retry a 5xx once.
    func retrying(_ body: @Sendable () async throws -> Data) async throws -> Data {
        for attempt in 0..<3 {
            do { return try await body() }
            catch let e as HTTPError where (e.status == 429 || e.status >= 500) && attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(min(e.retryAfter ?? 1, 30) * 1e9))
            }
        }
        return try await body()
    }
}
