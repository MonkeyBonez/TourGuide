import Foundation

public struct WikipediaSummary: Codable, Sendable, Equatable {
    public var extract: String
    public var lang: String
    public var url: String?
    public var thumbnail: String?
}

public actor WikipediaClient {
    let transport: HTTPTransport
    public init(transport: HTTPTransport) { self.transport = transport }

    /// The REST summary (lead paragraph + thumbnail). Nil for a missing page or a disambiguation.
    public func summary(lang: String, title: String) async throws -> WikipediaSummary? {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#")
        let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) ?? title
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return nil }
        let data: Data
        do { data = try await transport.fetch(URLRequest(url: url)) }
        catch let e as HTTPError where e.status == 404 { return nil }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], j["type"] as? String != "disambiguation",
              let extract = j["extract"] as? String, !extract.isEmpty else { return nil }
        return WikipediaSummary(extract: extract, lang: lang,
                                url: ((j["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String,
                                thumbnail: (j["thumbnail"] as? [String: Any])?["source"] as? String)
    }
}

/// What a card shows beyond name and kind.
public struct CardContent: Codable, Sendable, Equatable {
    public var extract: String?
    public var extractLang: String?
    public var wikipediaURL: String?
    public var wikipediaTitle: String?
    public var imageURL: String?
    /// The Commons page for the photo (author and licence).
    public var imageCreditURL: String?
    public var inception: String?
    public var description: String?
    /// OSM detail tags: opening_hours, fee, website, phone, denomination, inscription, start_date.
    public var osm: [String: String]
}

/// Card content from Wikidata (titles, P18 photo, P571 year), the Wikipedia summary (en, else
/// ja), and OSM detail tags. Never throws: a failed lookup is a plainer card.
public actor CardEnricher {
    static let osmKeys = ["opening_hours", "fee", "website", "phone", "denomination", "inscription",
                          "description", "description:en", "start_date"]
    let wikidata: WikidataClient
    let wikipedia: WikipediaClient
    let cache: DiskCache?
    var entities: [String: WikidataEntity] = [:]

    public init(transport: HTTPTransport, cache: DiskCache? = DiskCache.named("cards", ttl: 7 * 86_400)) {
        wikidata = WikidataClient(transport: transport); wikipedia = WikipediaClient(transport: transport); self.cache = cache
    }

    /// One bulk entity lookup for a set of cards (call before `content(for:)` to save requests).
    public func prefetch(_ pois: [POI]) async {
        let ids = Set(pois.compactMap(\.wikidata)).subtracting(entities.keys)
        guard !ids.isEmpty, let got = try? await wikidata.entities(ids: Array(ids)) else { return }
        entities.merge(got) { a, _ in a }
    }

    public func content(for poi: POI) async -> CardContent {
        let key = "card:v1:\(poi.id):\(poi.wikidata ?? "-")"
        if let hit = cache?.load(CardContent.self, key: key) { return hit }
        var c = CardContent(osm: (poi.allTags ?? [:]).filter { Self.osmKeys.contains($0.key) })
        c.description = poi.wdDescription
        if let q = poi.wikidata {
            if entities[q] == nil, let got = try? await wikidata.entities(ids: [q]) { entities.merge(got) { a, _ in a } }
            let e = entities[q]
            c.inception = e?.inception
            c.description = c.description ?? e?.descriptionEn
            var titles: [(String, String)] = []
            if let t = e?.enwiki { titles.append(("en", t)) }
            if let t = e?.jawiki { titles.append(("ja", t)) }
            if let wp = poi.wikipedia ?? poi.allTags?["wikipedia"], let colon = wp.firstIndex(of: ":") {
                let lang = String(wp[..<colon]), title = String(wp[wp.index(after: colon)...])
                if !titles.contains(where: { $0.0 == lang }) { titles.append((lang, title)) }
            }
            for (lang, title) in titles {
                if let s = try? await wikipedia.summary(lang: lang, title: title) {
                    c.extract = s.extract; c.extractLang = s.lang; c.wikipediaURL = s.url; c.wikipediaTitle = title
                    c.imageURL = s.thumbnail
                    break
                }
            }
            if let file = e?.image {
                let f = file.replacingOccurrences(of: " ", with: "_")
                let enc = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
                c.imageCreditURL = "https://commons.wikimedia.org/wiki/File:\(enc)"
                if c.imageURL == nil { c.imageURL = "https://commons.wikimedia.org/wiki/Special:FilePath/\(enc)?width=480" }
            }
        }
        cache?.store(c, key: key)
        return c
    }
}
