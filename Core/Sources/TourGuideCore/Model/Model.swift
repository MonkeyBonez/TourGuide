import Foundation

/// A named point: the walk's start or end.
public struct Place: Codable, Sendable, Equatable {
    public var name: String
    public var lat: Double
    public var lon: Double
    public init(name: String, lat: Double, lon: Double) { self.name = name; self.lat = lat; self.lon = lon }
}

/// One OSM sight candidate (PRD §4.4). JSON keys match the prototype's files so the measured
/// fixtures decode unchanged.
public struct POI: Codable, Sendable, Identifiable, Equatable {
    public var id: String                 // "node/123", "way/…", "relation/…"
    public var lat: Double
    public var lon: Double
    public var name: String?              // name:en, else name
    public var nameLocal: String?         // name (the local-language name)
    public var wikidata: String?
    public var wikipedia: String?
    public var heritage: String?
    /// The classifying keys: historic, tourism, amenity, building, religion, leisure.
    public var tags: [String: String]
    /// Every OSM tag (nil in the 6 Oct fixture, which kept only `tags`).
    public var allTags: [String: String]?
    /// Outer rings, each [[lat, lon], …].
    public var rings: [[[Double]]]
    public var wdLabel: String?
    public var wdDescription: String?
    public var sitelinks: Int?
    /// How the Wikidata item was found: tag, box, title-ja, …-via-child.
    public var match: String?
    public var parent: String?
    public var dupOf: String?

    enum CodingKeys: String, CodingKey {
        case id, lat, lon, name, wikidata, wikipedia, heritage, tags, rings, sitelinks, match, parent
        case nameLocal = "name_ja", allTags = "all_tags", wdLabel = "wd_label", wdDescription = "wd_description"
        case dupOf = "dup_of"
    }

    public init(id: String, lat: Double, lon: Double, name: String?, nameLocal: String?, tags: [String: String],
                allTags: [String: String]? = nil, rings: [[[Double]]] = [], wikidata: String? = nil) {
        self.id = id; self.lat = lat; self.lon = lon; self.name = name; self.nameLocal = nameLocal
        self.tags = tags; self.allTags = allTags; self.rings = rings; self.wikidata = wikidata
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lat = try c.decode(Double.self, forKey: .lat); lon = try c.decode(Double.self, forKey: .lon)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        nameLocal = try c.decodeIfPresent(String.self, forKey: .nameLocal)
        wikidata = try c.decodeIfPresent(String.self, forKey: .wikidata)
        wikipedia = try c.decodeIfPresent(String.self, forKey: .wikipedia)
        heritage = try c.decodeIfPresent(String.self, forKey: .heritage)
        tags = try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        allTags = try c.decodeIfPresent([String: String].self, forKey: .allTags)
        rings = try c.decodeIfPresent([[[Double]]].self, forKey: .rings) ?? []
        wdLabel = try c.decodeIfPresent(String.self, forKey: .wdLabel)
        wdDescription = try c.decodeIfPresent(String.self, forKey: .wdDescription)
        sitelinks = try c.decodeIfPresent(Int.self, forKey: .sitelinks)
        match = try c.decodeIfPresent(String.self, forKey: .match)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        dupOf = try c.decodeIfPresent(String.self, forKey: .dupOf)
    }

    /// A child inside an area, or a same-name duplicate: it scores through its parent (§4.3).
    public var isFolded: Bool { parent != nil || dupOf != nil }
    /// Only unambiguous OSM indoor tags change street relevance. Missing or conflicting tags stay unknown.
    public var isExplicitlyIndoor: Bool {
        let indoor = allTags?["indoor"] ?? tags["indoor"]
        let location = allTags?["location"] ?? tags["location"]
        let outdoor = allTags?["outdoor"] ?? tags["outdoor"]
        return (indoor == "yes" || location == "indoor") && indoor != "no" && location != "outdoor" && outdoor != "yes"
    }
    /// 1 = has a Wikidata item, 2 = named only, 0 = unnamed or folded.
    public var tier: Int { isFolded ? 0 : (wikidata != nil ? 1 : (name != nil ? 2 : 0)) }
    /// What a card calls it.
    public var displayName: String { name ?? wdLabel ?? nameLocal ?? id }
}

public struct Way: Codable, Sendable, Equatable {
    public var id: Int64
    public var tags: [String: String]
    public var nodes: [Int64]
    public init(id: Int64, tags: [String: String], nodes: [Int64]) { self.id = id; self.tags = tags; self.nodes = nodes }
}

/// Everything one Overpass query returns for a walk, after tiering: the unit that is cached.
public struct FetchBox: Codable, Sendable {
    public var start: Place
    public var end: Place
    /// [south, west, north, east]
    public var bbox: [Double]
    public var straightM: Double
    public var slack: Double
    public var routeFactor: Double
    public var pois: [POI]
    public var ways: [Way]
    /// [[osm id, lat, lon], …]
    public var nodes: [[Double]]

    enum CodingKeys: String, CodingKey {
        case start, end, bbox, pois, ways, nodes, slack
        case straightM = "straight_m", routeFactor = "route_factor"
    }

    public init(start: Place, end: Place, bbox: [Double], straightM: Double, slack: Double, routeFactor: Double,
                pois: [POI], ways: [Way], nodes: [[Double]]) {
        self.start = start; self.end = end; self.bbox = bbox; self.straightM = straightM; self.slack = slack
        self.routeFactor = routeFactor; self.pois = pois; self.ways = ways; self.nodes = nodes
    }

    /// The walk network inside `bbox`, no sights: ways with at least one node inside, and every
    /// node those ways use. What the fastest-path query returns, cut from a full box (tests,
    /// `tgtool route --narrow`, the bundled demo).
    public func cropped(to bbox: [Double]) -> FetchBox {
        var coord: [Int64: [Double]] = [:]
        for n in nodes { coord[Int64(n[0])] = n }
        func inside(_ n: [Double]) -> Bool { n[1] >= bbox[0] && n[1] <= bbox[2] && n[2] >= bbox[1] && n[2] <= bbox[3] }
        let kept = ways.filter { w in w.nodes.contains { coord[$0].map(inside) ?? false } }
        var used = Set<Int64>(); for w in kept { used.formUnion(w.nodes) }
        return FetchBox(start: start, end: end, bbox: bbox, straightM: straightM, slack: 0, routeFactor: routeFactor,
                        pois: [], ways: kept, nodes: nodes.filter { used.contains(Int64($0[0])) })
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        start = try c.decode(Place.self, forKey: .start); end = try c.decode(Place.self, forKey: .end)
        bbox = try c.decode([Double].self, forKey: .bbox)
        straightM = try c.decode(Double.self, forKey: .straightM)
        slack = try c.decodeIfPresent(Double.self, forKey: .slack) ?? 0.5
        routeFactor = try c.decodeIfPresent(Double.self, forKey: .routeFactor) ?? 1.25
        pois = try c.decode([POI].self, forKey: .pois)
        ways = try c.decodeIfPresent([Way].self, forKey: .ways) ?? []
        nodes = try c.decodeIfPresent([[Double]].self, forKey: .nodes) ?? []
    }
}
