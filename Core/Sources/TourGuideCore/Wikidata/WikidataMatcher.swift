import Foundation

/// Tier-1 bridges and §4.3 dedupe, ported from the 6 Oct prototype (`match_wikidata.py`,
/// `title_lookup.py`). Pure functions on `[POI]`; order: tag → box → dedupe → title.
public enum WikidataMatcher {
    private struct DedupeKey: Hashable {
        let name: String
        let isIndoor: Bool
    }

    static let stripChars = try! NSRegularExpression(pattern: "[\\s\\-\u{2010}\u{30fb}()\u{ff08}\u{ff09}\u{300c}\u{300d}'\u{2019}]")
    static let kindSuffix = try! NSRegularExpression(pattern: "(temple|shrine|garden|park|museum|castle|gate|market)$")

    public static func normalize(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        var t = s.lowercased()
        t = stripChars.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        t = kindSuffix.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        return t
    }

    /// Equal after normalising, or one contains the other and is at least 60 % of it
    /// ("Kanazawa" must not match "Kanazawa Catholic Church").
    public static func namesMatch(poi: POI, labelEn: String?, labelJa: String?) -> Bool {
        let a = Set([normalize(poi.name), normalize(poi.nameLocal)]).subtracting([""])
        let b = Set([normalize(labelEn), normalize(labelJa)]).subtracting([""])
        for x in a {
            for y in b {
                let lx = x.unicodeScalars.count, ly = y.unicodeScalars.count
                if lx < 3 || ly < 3 { continue }
                if x == y { return true }
                let (lo, hi, nlo, nhi) = lx <= ly ? (x, y, lx, ly) : (y, x, ly, lx)
                if hi.contains(lo) && nlo >= 4 && Double(nlo) / Double(nhi) >= 0.6 { return true }
            }
        }
        return false
    }

    /// OSM `wikidata=*`: fill in label, description and fame from the entities.
    public static func applyTagBridge(_ pois: inout [POI], entities: [String: WikidataEntity]) {
        for i in pois.indices {
            guard let q = pois[i].wikidata else { pois[i].sitelinks = pois[i].sitelinks ?? 0; continue }
            pois[i].match = "tag"
            if let e = entities[q] {
                pois[i].wdLabel = e.label; pois[i].wdDescription = e.descriptionEn; pois[i].sitelinks = e.sitelinks
            } else { pois[i].sitelinks = pois[i].sitelinks ?? 0 }
        }
    }

    /// Items with coordinates in the box: within 250 m or inside the POI's polygon, names agree.
    public static func applyBoxBridge(_ pois: inout [POI], items: [WikidataItem]) {
        for i in pois.indices where pois[i].wikidata == nil && pois[i].name != nil {
            var best: (Double, WikidataItem)?
            for it in items where it.sitelinks >= 1 {
                let d = Polygon.metres(pois[i].lat, pois[i].lon, it.lat, it.lon)
                let inside = !pois[i].rings.isEmpty && Polygon.pointInLatLonRings(lat: it.lat, lon: it.lon, pois[i].rings)
                if (d <= 250 || inside) && namesMatch(poi: pois[i], labelEn: it.label, labelJa: it.labelJa) {
                    if best == nil || d < best!.0 { best = (d, it) }
                }
            }
            if let (_, it) = best {
                pois[i].wikidata = it.qid; pois[i].sitelinks = it.sitelinks; pois[i].wdLabel = it.label; pois[i].match = "box"
            }
        }
    }

    /// §4.3: a node, or a smaller area, inside a worship/historic/park/garden area joins it; the
    /// parent takes the fame of the most famous child. Same-name POIs within 60 m collapse.
    public static func dedupe(_ pois: inout [POI]) {
        let parentIdx = pois.indices.filter { i in
            let t = pois[i].tags
            return !pois[i].rings.isEmpty && (t["amenity"] == "place_of_worship" || t["historic"] != nil
                                             || t["leisure"] == "park" || t["leisure"] == "garden")
        }
        let area = pois.map { $0.rings.isEmpty ? 0 : Polygon.ringAreaDeg($0.rings) }
        for i in pois.indices {
            let own = area[i]
            for q in parentIdx where q != i && area[q] > own * 1.5
                && pois[i].isExplicitlyIndoor == pois[q].isExplicitlyIndoor
                && Polygon.pointInLatLonRings(lat: pois[i].lat, lon: pois[i].lon, pois[q].rings) {
                pois[i].parent = pois[q].id
                if pois[i].wikidata != nil && (pois[i].sitelinks ?? 0) > (pois[q].sitelinks ?? 0) {
                    pois[q].wikidata = pois[i].wikidata; pois[q].sitelinks = pois[i].sitelinks
                    pois[q].wdLabel = pois[i].wdLabel; pois[q].match = (pois[i].match ?? "") + "-via-child"
                }
                break
            }
        }
        var byName: [DedupeKey: [Int]] = [:]
        for i in pois.indices where pois[i].parent == nil && pois[i].name != nil {
            let n = normalize(pois[i].name)
            let key = DedupeKey(name: n.isEmpty ? normalize(pois[i].nameLocal) : n, isIndoor: pois[i].isExplicitlyIndoor)
            if let q = byName[key, default: []].first(where: { Polygon.metres(pois[i].lat, pois[i].lon, pois[$0].lat, pois[$0].lon) <= 60 }) {
                pois[i].dupOf = pois[q].id
                if pois[i].wikidata != nil && pois[q].wikidata == nil {
                    pois[q].wikidata = pois[i].wikidata; pois[q].sitelinks = pois[i].sitelinks
                    pois[q].wdLabel = pois[i].wdLabel; pois[q].match = pois[i].match
                }
            } else { byName[key, default: []].append(i) }
        }
    }

    /// The candidates for the title bridge: named, unmatched, unfolded.
    public static func titleCandidates(_ pois: [POI]) -> (ja: [String], en: [String]) {
        let todo = pois.filter { $0.wikidata == nil && $0.name != nil && !$0.isFolded }
        return (todo.compactMap(\.nameLocal), todo.filter { $0.name != $0.nameLocal }.compactMap(\.name))
    }

    /// The OSM name as a Wikipedia title; accepted only where it is this place: P625 within
    /// 400 m, or no P625 and located in (P131) one of `localAdmin`.
    public static func applyTitleBridge(_ pois: inout [POI], ja: [String: WikidataEntity], en: [String: WikidataEntity],
                                        localAdmin: Set<String>) {
        for i in pois.indices where pois[i].wikidata == nil && pois[i].name != nil && !pois[i].isFolded {
            for (site, table, key) in [("ja", ja, pois[i].nameLocal), ("en", en, pois[i].name)] {
                guard let key, let f = table[key], f.sitelinks >= 1 else { continue }
                let ok: Bool
                if let c = f.coord { ok = Polygon.metres(pois[i].lat, pois[i].lon, c[0], c[1]) <= 400 }
                else { ok = !localAdmin.isDisjoint(with: f.p131) }
                guard ok else { continue }
                pois[i].wikidata = f.qid; pois[i].sitelinks = f.sitelinks; pois[i].wdLabel = f.label
                pois[i].wdDescription = f.descriptionEn; pois[i].match = "title-" + site
                break
            }
        }
    }
}
