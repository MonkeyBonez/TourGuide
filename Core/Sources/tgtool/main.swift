// tgtool — Tour Guide's measuring tool (the `lwtool route --compare` of interest).
//   tgtool route box.json [--slacks 0,0.1,0.2,0.3,0.5] [--view 30] [--cap 20] [--tier2 1] [--centroids]
//                [--cards out.json] [--geojson out.geojson]
//   tgtool fetch <lat,lon> <lat,lon> [--name-a X] [--name-b Y] [--slack 0.5] [--out box.json] [--record DIR] [--no-cache]
//   tgtool match box_pois.json wikidata_box.json [--out matched.json]
//   tgtool cards box.json [--slacks 0.1,0.5] [--out cards.json] [--record DIR]
import Foundation
import LikeWaterEngine
import TourGuideCore

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(2) }
func loadBox(_ path: String) throws -> FetchBox {
    path == "kanazawa" ? try BundledFixtures.kanazawa()
        : try JSONDecoder().decode(FetchBox.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}
func writeJSON(_ object: Any, _ path: String) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
}
func coordinate(_ s: String) -> (Double, Double) {
    let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard p.count == 2 else { fail("bad coordinate \(s), want lat,lon") }
    return (p[0], p[1])
}

guard !args.isEmpty else { fail("usage: tgtool route|fetch|match|cards …") }
let command = args.removeFirst()

switch command {
case "route": try routeCommand()
case "fetch": try await fetchCommand()
case "match": try matchCommand()
case "cards": try await cardsCommand()
default: fail("unknown command \(command)")
}

// MARK: - route

func routeCommand() throws {
    var params = ScoringParams()
    params.viewingMetres = Double(opt("--view") ?? "30")!
    params.cap = Double(opt("--cap") ?? "20")!
    params.tier2Weight = Double(opt("--tier2") ?? "1")!
    params.usePolygons = !flag("--centroids")
    let slacks = (opt("--slacks") ?? "0,0.1,0.2,0.3,0.5").split(separator: ",").map { Double($0)! }
    let cardsPath = opt("--cards"), geojsonPath = opt("--geojson")
    let bufferM = 400.0
    guard let path = args.first else { fail("usage: tgtool route box.json|kanazawa") }
    let box = try loadBox(path)
    let session = try TourSession(box: box, params: params, maxSlack: slacks.max()!)
    let graph = session.graph, scored = session.scored
    let crossings = (0..<graph.edgeCount).filter { graph.isCrossing($0) }.count
    print("graph: \(graph.nodeCount) nodes, \(graph.edgeCount) edges (\(crossings) crossings), " +
          "\(graph.componentSizes.count) components, largest \(graph.componentSizes.max() ?? 0)")
    print(String(format: "snap: A %.0f m, B %.0f m from the graph", session.snapA, session.snapB))
    let tier1 = scored.sights.filter { $0.tier == 1 }
    let inBuffer = scored.sights.filter { $0.distToLine <= bufferM }
    print("pois: \(box.pois.count) in box, \(scored.folded) folded into a parent or duplicate, \(scored.sights.count) tiered (\(tier1.count) tier 1, \(scored.sights.count - tier1.count) tier 2); " +
          "\(inBuffer.count) inside the \(Int(bufferM)) m buffer (\(inBuffer.filter { $0.tier == 1 }.count) tier 1)")
    print("interest: \(scored.interest.filter { $0 > 0 }.count) of \(graph.edgeCount) edges scored within \(Int(params.viewingMetres)) m" +
          (params.usePolygons ? " (polygon edges)" : " (centroids)") +
          String(format: "; max %.0f, cap %.0f → score = min(1, interest/cap)", scored.interest.max() ?? 0, params.cap))
    let unreachedT1 = tier1.filter { $0.edges.isEmpty }
    print("  \(scored.sights.filter { $0.edges.isEmpty }.count) sights touch no edge at this viewing distance" +
          (unreachedT1.isEmpty ? "" : ": tier 1 → " + unreachedT1.map { $0.poi.name ?? $0.poi.id }.joined(separator: ", ")))
    print(String(format: "direct: %.0f m walking (straight line %.0f m, factor %.2f); labels %.1f ms",
                 session.directMetres, box.straightM, session.directMetres / box.straightM, session.labels.computeMs))

    let routes = try slacks.map { try session.route(slack: $0) }
    print("\nslack   metres   min  +min  cross  interest-s  T1  T2  corridor  ms")
    for r in routes {
        print(String(format: "%5.2f  %7.0f  %4.1f  %4.1f  %5d  %9.0f  %3d %3d  %7d  %5.1f",
                     r.slack, r.metres, r.seconds / 60, (r.seconds - routes[0].seconds) / 60, r.crossings,
                     r.interestSeconds, r.passed.filter { $0.sight.tier == 1 }.count, r.passed.filter { $0.sight.tier == 2 }.count,
                     r.corridorEdges, r.computeMs))
    }
    for r in routes {
        print("\nslack \(r.slack): tier-1 sights passed, in walking order")
        for p in r.passed where p.sight.tier == 1 {
            let s = p.sight
            print("  - \(s.poi.name ?? s.poi.id)  [\(s.poi.sitelinks ?? 0) langs, w \(Int(s.weight)), \(s.poi.match ?? "-")\(s.poi.rings.isEmpty ? "" : ", area")]  " +
                  s.poi.tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        }
        let t2 = r.passed.filter { $0.sight.tier == 2 }.map { $0.sight.poi.name ?? $0.sight.poi.id }
        if !t2.isEmpty { print("  tier 2 (\(t2.count)): " + t2.prefix(12).joined(separator: ", ") + (t2.count > 12 ? ", …" : "")) }
    }

    // Expected sights (PRD §7) and why each is or isn't passed at the widest slider.
    let aliases: [String: String] = ["Tsuzumi": "鼓門", "Omicho": "近江町", "Oyama": "尾山神社", "Kanazawa Castle": "金沢城",
                                     "Kenroku": "兼六園", "Nomura": "野村家"]
    let widest = routes.last!
    print("\nexpected sights at slack \(widest.slack) (bound \(Int(session.directMetres * (1 + widest.slack))) m):")
    for e in ["Tsuzumi", "Omicho", "Oyama", "Kanazawa Castle", "Nagamachi", "Nomura", "Kenroku"] {
        let matches = scored.sights.filter { s in
            let names = [s.poi.name, s.poi.nameLocal, s.poi.wdLabel].compactMap { $0 }.joined(separator: " ").lowercased()
            return names.contains(e.lowercased()) || aliases[e].map { names.contains($0) } == true
        }
        if matches.isEmpty { print("  ✗ \(e): not in the fetched box at all"); continue }
        for s in matches {
            let reach = session.explain(s, route: widest)
            var why = ""
            switch reach {
            case .passed: break
            case .noEdge: why = "touches no edge within \(Int(params.viewingMetres)) m"
            case .overBound(let via): why = String(format: "needs %.0f m via it, over the bound", via)
            case .outscored(let via): why = String(format: "reachable (%.0f m via it) but outscored", via)
            }
            print("  \(reach == .passed ? "✓" : "✗") \(e): \(s.poi.name ?? s.poi.id) [tier \(s.tier), \(s.poi.sitelinks ?? 0) langs, \(Int(s.distToLine)) m off the line, \(s.edges.count) edges]" + (why.isEmpty ? "" : " — \(why)"))
        }
    }

    if let cardsPath {
        var pois: [String: Any] = [:]
        for s in scored.sights {
            let p = s.poi
            pois[p.id] = ["name": p.name ?? "", "name_ja": p.nameLocal ?? "", "lat": p.lat, "lon": p.lon, "tags": p.tags,
                          "wikidata": p.wikidata ?? "", "sitelinks": p.sitelinks ?? 0, "wd_label": p.wdLabel ?? "",
                          "wd_description": p.wdDescription ?? "", "match": p.match ?? "", "area": !p.rings.isEmpty,
                          "tier": s.tier, "weight": s.weight, "edges": s.edges.count] as [String: Any]
        }
        let rs: [[String: Any]] = routes.map { r in
            ["slack": r.slack, "metres": r.metres, "seconds": r.seconds, "crossings": r.crossings,
             "sights": r.passed.map { ["id": $0.sight.poi.id, "tier": $0.sight.tier, "weight": $0.sight.weight,
                                        "alongMetres": $0.alongMetres, "alongSeconds": $0.alongSeconds] as [String: Any] }]
        }
        try writeJSON(["routes": rs, "pois": pois, "viewing": params.viewingMetres, "cap": params.cap, "direct": session.directMetres], cardsPath)
        print("\nwrote \(cardsPath)")
    }
    if let geojsonPath {
        var features: [[String: Any]] = routes.map { r in
            ["type": "Feature", "properties": ["slack": r.slack, "metres": r.metres, "seconds": r.seconds],
             "geometry": ["type": "LineString", "coordinates": r.coordinates.map { [$0.lon, $0.lat] }]]
        }
        for s in scored.sights {
            features.append(["type": "Feature", "properties": ["name": s.poi.name ?? s.poi.id, "tier": s.tier, "weight": s.weight, "edges": s.edges.count],
                             "geometry": ["type": "Point", "coordinates": [s.poi.lon, s.poi.lat]]])
        }
        try writeJSON(["type": "FeatureCollection", "features": features], geojsonPath)
        print("\nwrote \(geojsonPath)")
    }
}

// MARK: - stubs filled in M1
func fetchCommand() async throws { fail("fetch: not built yet") }
func matchCommand() throws { fail("match: not built yet") }
func cardsCommand() async throws { fail("cards: not built yet") }
