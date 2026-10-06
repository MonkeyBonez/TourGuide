// Tour Guide measurement: build an in-memory PedestrianGraph from an Overpass walk
// network, score edges by POIs within viewing distance, route with the Like Water
// router (interest in place of sun) at several slider positions, and print what each
// route does — metres, minutes, crossings, sights passed — the way `lwtool route
// --compare` does for sun.
//
// usage: tgmeasure kanazawa_box.json [--view 30] [--cap 10] [--slacks 0,0.1,0.2,0.3,0.5]
//                  [--buffer 400] [--poly] [--geojson out.geojson]
import Foundation
import LikeWaterEngine

// MARK: - Input

struct Place: Decodable { var name: String; var lat: Double; var lon: Double }
struct POI: Decodable {
    var id: String; var lat: Double; var lon: Double
    var name: String?; var name_ja: String?
    var wikidata: String?; var wikipedia: String?; var heritage: String?
    var tags: [String: String]; var prd_query: Bool
    var rings: [[[Double]]]
    var wd_label: String?; var wd_description: String?; var sitelinks: Int?
    var match: String?; var parent: String?; var dup_of: String?
}
struct Way: Decodable { var id: Int64; var tags: [String: String]; var nodes: [Int64] }
struct Box: Decodable {
    var start: Place; var end: Place; var bbox: [Double]; var straight_m: Double
    var pois: [POI]; var ways: [Way]; var nodes: [[Double]]
}

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}
let viewing = Double(opt("--view") ?? "30")!
let cap = Double(opt("--cap") ?? "10")!
let slacks = (opt("--slacks") ?? "0,0.1,0.2,0.3,0.5").split(separator: ",").map { Double($0)! }
let bufferM = Double(opt("--buffer") ?? "400")!
let usePolygons = flag("--poly")
let geojsonPath = opt("--geojson")
let cardsPath = opt("--cards")
let tier2Weight = Double(opt("--tier2") ?? "1")!
guard let path = args.first else { print("usage: tgmeasure box.json [--view m] [--cap n] [--slacks a,b] [--poly]"); exit(2) }
let box = try JSONDecoder().decode(Box.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

// MARK: - Graph (the pipeline's walkability rule; no sidewalk synthesis)

let plane = LocalPlane(originLat: box.start.lat, originLon: box.start.lon)
var coord: [Int64: (lat: Double, lon: Double)] = [:]
for n in box.nodes { coord[Int64(n[0])] = (n[1], n[2]) }

let streetClasses: Set<String> = ["residential", "tertiary", "secondary", "primary", "unclassified",
                                  "living_street", "service", "tertiary_link", "secondary_link", "primary_link"]
func flags(for t: [String: String]) -> UInt8 {
    var f: UInt8 = 0
    let fw = t["footway"] ?? "", hw = t["highway"] ?? ""
    if fw.contains("crossing") || hw == "crossing" { f |= EdgeFlag.crossing }
    if fw.contains("sidewalk") { f |= EdgeFlag.sidewalk }
    else if let s = t["sidewalk"], !["", "no", "none", "separate"].contains(s) { f |= EdgeFlag.streetSidewalkTag }
    if hw == "steps" { f |= EdgeFlag.steps }
    if streetClasses.contains(hw) && !fw.contains("sidewalk") { f |= EdgeFlag.street }
    if t["access"] == "private" { f |= EdgeFlag.privateAccess }
    return f
}

var nodeIndex: [Int64: Int32] = [:]
var nodeLat: [Double] = [], nodeLon: [Double] = []
func node(_ id: Int64) -> Int32? {
    if let i = nodeIndex[id] { return i }
    guard let c = coord[id] else { return nil }
    let i = Int32(nodeLat.count); nodeIndex[id] = i; nodeLat.append(c.lat); nodeLon.append(c.lon); return i
}
var eA: [Int32] = [], eB: [Int32] = [], eLen: [Double] = [], eFlags: [UInt8] = [], eWay: [Int64] = []
var seenPair = Set<Int64>()
for w in box.ways {
    let f = flags(for: w.tags)
    for k in 1..<w.nodes.count {
        guard let a = node(w.nodes[k - 1]), let b = node(w.nodes[k]), a != b else { continue }
        let lo = min(a, b), hi = max(a, b)
        guard seenPair.insert(Int64(lo) << 32 | Int64(hi)).inserted else { continue }
        let len = haversineMeters(nodeLat[Int(a)], nodeLon[Int(a)], nodeLat[Int(b)], nodeLon[Int(b)])
        guard len > 0 else { continue }
        eA.append(lo); eB.append(hi); eLen.append(len); eFlags.append(f); eWay.append(w.id)
    }
}
let gbox = BBox(minLat: box.bbox[0], minLon: box.bbox[1], maxLat: box.bbox[2], maxLon: box.bbox[3])
let graph = PedestrianGraph(nodeLat: nodeLat, nodeLon: nodeLon, edgeA: eA, edgeB: eB, edgeLen: eLen,
                            edgeFlags: eFlags, edgeInterest: nil, bbox: gbox)
let crossings = (0..<graph.edgeCount).filter { graph.isCrossing($0) }.count
print("graph: \(graph.nodeCount) nodes, \(graph.edgeCount) edges (\(crossings) crossings), " +
      "\(graph.componentSizes.count) components, largest \(graph.componentSizes.max() ?? 0)")

guard let origin = graph.nearestConnectedNode(lat: box.start.lat, lon: box.start.lon),
      let dest = graph.nearestConnectedNode(lat: box.end.lat, lon: box.end.lon) else { print("snap failed"); exit(1) }
let snapA = haversineMeters(box.start.lat, box.start.lon, graph.nodeLat[Int(origin)], graph.nodeLon[Int(origin)])
let snapB = haversineMeters(box.end.lat, box.end.lon, graph.nodeLat[Int(dest)], graph.nodeLon[Int(dest)])
print(String(format: "snap: A %.0f m, B %.0f m from the graph", snapA, snapB))

// MARK: - POIs → edge interest

struct Sight { var poi: POI; var tier: Int; var weight: Double; var edges: Set<Int32>; var distToLine: Double; var along: Double }
let ax = 0.0, ay = 0.0
let (bx, by) = plane.project(lat: box.end.lat, lon: box.end.lon)
func lineDistance(_ x: Double, _ y: Double) -> (Double, Double) {
    let dx = bx - ax, dy = by - ay
    let t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)))
    return (hypot(x - (ax + t * dx), y - (ay + t * dy)), t)
}
func segDist(_ px: Double, _ py: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    let dx = x2 - x1, dy = y2 - y1
    let l2 = dx * dx + dy * dy
    let t = l2 > 0 ? max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / l2)) : 0
    return hypot(px - (x1 + t * dx), py - (y1 + t * dy))
}
func segSegDist(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Double {
    // Segments that cross have distance 0; otherwise the minimum is at an endpoint.
    func cross(_ o: (Double, Double), _ p: (Double, Double), _ q: (Double, Double)) -> Double {
        (p.0 - o.0) * (q.1 - o.1) - (p.1 - o.1) * (q.0 - o.0)
    }
    let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
    if ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0)) { return 0 }
    return min(segDist(a.0, a.1, c.0, c.1, d.0, d.1), segDist(b.0, b.1, c.0, c.1, d.0, d.1),
               segDist(c.0, c.1, a.0, a.1, b.0, b.1), segDist(d.0, d.1, a.0, a.1, b.0, b.1))
}
func pointInRing(_ x: Double, _ y: Double, _ ring: [(Double, Double)]) -> Bool {
    var inside = false
    var j = ring.count - 1
    for i in 0..<ring.count {
        let (xi, yi) = ring[i], (xj, yj) = ring[j]
        if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
        j = i
    }
    return inside
}

let ex = (0..<graph.edgeCount).map { plane.project(lat: graph.nodeLat[Int(graph.edgeA[$0])], lon: graph.nodeLon[Int(graph.edgeA[$0])]) }
let ey = (0..<graph.edgeCount).map { plane.project(lat: graph.nodeLat[Int(graph.edgeB[$0])], lon: graph.nodeLon[Int(graph.edgeB[$0])]) }

var sights: [Sight] = []
var interest = [Double](repeating: 0, count: graph.edgeCount)
var inBuffer = 0, inBufferTier1 = 0
var folded = 0
for p in box.pois {
    // §4.3: a child inside an area, or a same-name duplicate, scores through its parent.
    if p.parent != nil || p.dup_of != nil { folded += 1; continue }
    let tier = p.wikidata != nil ? 1 : (p.name != nil ? 2 : 0)
    guard tier > 0 else { continue }
    let (px, py) = plane.project(lat: p.lat, lon: p.lon)
    let (dl, along) = lineDistance(px, py)
    if dl <= bufferM { inBuffer += 1; if tier == 1 { inBufferTier1 += 1 } }
    let weight = tier == 1 ? 3 + Double(p.sitelinks ?? 0) : tier2Weight
    let rings = usePolygons ? p.rings.map { $0.map { plane.project(lat: $0[0], lon: $0[1]) } }.map { $0.map { ($0.x, $0.y) } } : []
    var near = Set<Int32>()
    // Prefilter by bounding box so the polygon case stays cheap.
    var minX = px, maxX = px, minY = py, maxY = py
    for r in rings { for (x, y) in r { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    for e in 0..<graph.edgeCount {
        let (x1, y1) = (ex[e].x, ex[e].y), (x2, y2) = (ey[e].x, ey[e].y)
        if max(x1, x2) < minX - viewing || min(x1, x2) > maxX + viewing ||
           max(y1, y2) < minY - viewing || min(y1, y2) > maxY + viewing { continue }
        var d = segDist(px, py, x1, y1, x2, y2)
        if d > viewing, !rings.isEmpty {
            for r in rings {
                if pointInRing(x1, y1, r) || pointInRing(x2, y2, r) { d = 0; break }
                for i in 1..<r.count { d = min(d, segSegDist((x1, y1), (x2, y2), r[i - 1], r[i])); if d <= viewing { break } }
                if d <= viewing { break }
            }
        }
        if d <= viewing { near.insert(Int32(e)) }
    }
    for e in near { interest[Int(e)] += weight }
    sights.append(Sight(poi: p, tier: tier, weight: weight, edges: near, distToLine: dl, along: along))
}
let tier1 = sights.filter { $0.tier == 1 }
let scored = interest.filter { $0 > 0 }.count
print("pois: \(box.pois.count) in box, \(folded) folded into a parent or duplicate, \(sights.count) tiered (\(tier1.count) tier 1, \(sights.count - tier1.count) tier 2); " +
      "\(inBuffer) inside the \(Int(bufferM)) m buffer (\(inBufferTier1) tier 1)")
print("interest: \(scored) of \(graph.edgeCount) edges scored within \(Int(viewing)) m" + (usePolygons ? " (polygon edges)" : " (centroids)") +
      String(format: "; max %.0f, cap %.0f → score = min(1, interest/cap)", interest.max() ?? 0, cap))
let unreached = sights.filter { $0.edges.isEmpty }
print("  \(unreached.count) sights touch no edge at this viewing distance" +
      (tier1.filter { $0.edges.isEmpty }.isEmpty ? "" : ": tier 1 → " + tier1.filter { $0.edges.isEmpty }.map { $0.poi.name ?? $0.poi.id }.joined(separator: ", ")))

// MARK: - Route at each slider position

let maxSlack = slacks.max()!
let labels = try CorridorEngine.labels(graph: graph, destination: dest, origin: origin, slack: maxSlack)
let direct = labels.dTo[Int(origin)]
print(String(format: "direct: %.0f m walking (straight line %.0f m, factor %.2f); labels %.1f ms",
             direct, box.straight_m, direct / box.straight_m, labels.computeMs))
let pace = PaceModel()

var cardRoutes: [[String: Any]] = []
struct Row { var slack: Double; var route: Route; var passed: [Sight]; var crossings: Int; var corridorEdges: Int; var corridorMs: Double }
var rows: [Row] = []
var features: [[String: Any]] = []
for slack in slacks {
    let corridor = try CorridorEngine.corridor(graph: graph, labels: labels, origin: origin, slack: slack)
    let seconds = pace.edgeSeconds(graph: graph, edges: corridor.edges, terrain: nil)
    let score = corridor.edges.map { Float(min(1, interest[Int($0)] / cap)) }
    let timeline = SunTimeline(constant: score, departure: Date(), slots: 1)
    let route = try RouteEngine.route(graph: graph, corridor: corridor, labels: labels, origin: origin,
                                      timeline: timeline, edgeSeconds: seconds, sunWeight: 1)
    let routeEdges = Set(route.edges)
    // Sights passed, in walking order of the first route edge within viewing distance.
    var order: [Int32: Int] = [:]
    for (i, e) in route.edges.enumerated() where order[e] == nil { order[e] = i }
    let passed = sights.filter { !$0.edges.isDisjoint(with: routeEdges) }
        .sorted { ($0.edges.compactMap { order[$0] }.min() ?? 0) < ($1.edges.compactMap { order[$0] }.min() ?? 0) }
    let xs = route.edges.filter { graph.isCrossing(Int($0)) }.count
    rows.append(Row(slack: slack, route: route, passed: passed, crossings: xs, corridorEdges: corridor.edges.count, corridorMs: corridor.computeMs))
    // Cards: where along the walk each sight is first within viewing distance.
    var cum = [Double](repeating: 0, count: route.edges.count + 1)
    for (i, e) in route.edges.enumerated() { cum[i + 1] = cum[i] + graph.edgeLen[Int(e)] }
    cardRoutes.append(["slack": slack, "metres": route.metres, "seconds": route.seconds, "crossings": xs,
                       "sights": passed.map { s -> [String: Any] in
                           let i = s.edges.compactMap { order[$0] }.min() ?? 0
                           return ["id": s.poi.id, "tier": s.tier, "weight": s.weight, "alongMetres": cum[i],
                                   "alongSeconds": route.arrivalSeconds[i]] }])
    let coords = route.nodes.map { [graph.nodeLon[Int($0)], graph.nodeLat[Int($0)]] }
    features.append(["type": "Feature", "properties": ["slack": slack, "metres": route.metres, "seconds": route.seconds],
                     "geometry": ["type": "LineString", "coordinates": coords]])
}

print("\nslack   metres   min  +min  cross  interest-s  T1  T2  corridor  ms")
for r in rows {
    let base = rows[0].route
    print(String(format: "%5.2f  %7.0f  %4.1f  %4.1f  %5d  %9.0f  %3d %3d  %7d  %5.1f",
                 r.slack, r.route.metres, r.route.seconds / 60, (r.route.seconds - base.seconds) / 60, r.crossings,
                 r.route.sunSeconds, r.passed.filter { $0.tier == 1 }.count, r.passed.filter { $0.tier == 2 }.count,
                 r.corridorEdges, r.corridorMs + r.route.computeMs))
}
for r in rows {
    print("\nslack \(r.slack): tier-1 sights passed, in walking order")
    for s in r.passed where s.tier == 1 {
        print("  - \(s.poi.name ?? s.poi.id)  [\(s.poi.sitelinks ?? 0) langs, w \(Int(s.weight)), \(s.poi.match ?? "-")\(s.poi.rings.isEmpty ? "" : ", area")]  \(s.poi.tags.map { "\($0)=\($1)" }.joined(separator: " "))")
    }
    let t2 = r.passed.filter { $0.tier == 2 }.map { $0.poi.name ?? $0.poi.id }
    if !t2.isEmpty { print("  tier 2 (\(t2.count)): " + t2.prefix(12).joined(separator: ", ") + (t2.count > 12 ? ", …" : "")) }
}

// Expected sights (PRD §7) and why each is or isn't passed at the widest slider.
let expected = ["Tsuzumi", "Omicho", "Oyama", "Kanazawa Castle", "Nagamachi", "Nomura", "Kenroku"]
let widest = rows.last!
let bound = direct * (1 + widest.slack)
print("\nexpected sights at slack \(widest.slack) (bound \(Int(bound)) m):")
for e in expected {
    let matches = sights.filter { s in
        let names = [s.poi.name, s.poi.name_ja, s.poi.wd_label].compactMap { $0 }.joined(separator: " ").lowercased()
        return names.contains(e.lowercased()) || (e == "Tsuzumi" && names.contains("鼓門")) || (e == "Omicho" && names.contains("近江町"))
            || (e == "Oyama" && names.contains("尾山神社")) || (e == "Kanazawa Castle" && names.contains("金沢城"))
            || (e == "Kenroku" && names.contains("兼六園")) || (e == "Nomura" && names.contains("野村家"))
    }
    if matches.isEmpty { print("  ✗ \(e): not in the fetched box at all"); continue }
    for s in matches {
        let passed = widest.passed.contains { $0.poi.id == s.poi.id }
        var why = ""
        if !passed {
            if s.edges.isEmpty { why = "touches no edge within \(Int(viewing)) m" }
            else {
                // Cheapest detour through any of its edges: dFrom[a] + dTo[b] style using labels from both ends.
                let dFrom = try CorridorEngine.labels(graph: graph, destination: origin, origin: dest, slack: 10).dTo
                let via = s.edges.map { e -> Double in
                    let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
                    return min(dFrom[a] + graph.edgeLen[Int(e)] + labels.dTo[b], dFrom[b] + graph.edgeLen[Int(e)] + labels.dTo[a])
                }.min() ?? .infinity
                why = via > bound ? String(format: "needs %.0f m via it, over the bound", via) : String(format: "reachable (%.0f m via it) but outscored", via)
            }
        }
        print("  \(passed ? "✓" : "✗") \(e): \(s.poi.name ?? s.poi.id) [tier \(s.tier), \(s.poi.sitelinks ?? 0) langs, \(Int(s.distToLine)) m off the line, \(s.edges.count) edges]" + (why.isEmpty ? "" : " — \(why)"))
    }
}

if let cardsPath {
    var poiDict: [String: Any] = [:]
    for s in sights {
        let p = s.poi
        var d: [String: Any] = [:]
        d["name"] = p.name ?? ""; d["name_ja"] = p.name_ja ?? ""; d["lat"] = p.lat; d["lon"] = p.lon; d["tags"] = p.tags
        d["wikidata"] = p.wikidata ?? ""; d["sitelinks"] = p.sitelinks ?? 0; d["wd_label"] = p.wd_label ?? ""
        d["wd_description"] = p.wd_description ?? ""; d["match"] = p.match ?? ""; d["area"] = !p.rings.isEmpty
        d["tier"] = s.tier; d["weight"] = s.weight; d["edges"] = s.edges.count
        let ring: [[Double]] = p.rings.first ?? []
        d["ring"] = ring
        poiDict[p.id] = d
    }
    let cards: [String: Any] = ["routes": cardRoutes, "pois": poiDict, "viewing": viewing, "cap": cap, "direct": direct]
    try JSONSerialization.data(withJSONObject: cards).write(to: URL(fileURLWithPath: cardsPath))
    print("wrote \(cardsPath)")
}
if let geojsonPath {
    for s in sights {
        features.append(["type": "Feature", "properties": ["name": s.poi.name ?? s.poi.id, "tier": s.tier, "weight": s.weight, "edges": s.edges.count],
                         "geometry": ["type": "Point", "coordinates": [s.poi.lon, s.poi.lat]]])
    }
    let fc: [String: Any] = ["type": "FeatureCollection", "features": features]
    try JSONSerialization.data(withJSONObject: fc).write(to: URL(fileURLWithPath: geojsonPath))
    print("\nwrote \(geojsonPath)")
}
