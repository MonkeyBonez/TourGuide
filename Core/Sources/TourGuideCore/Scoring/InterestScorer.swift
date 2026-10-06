import Foundation
import LikeWaterEngine

/// The measured constants (6 Oct 2026, Kanazawa): 30 m to the polygon edge, cap 20,
/// Tier-1 weight 3 + sitelinks, Tier-2 weight 1.
public struct ScoringParams: Sendable, Equatable {
    public var viewingMetres = 30.0
    public var cap = 20.0
    public var tier1Base = 3.0
    public var tier2Weight = 1.0
    /// Measure to the polygon edge for areas (false = centroid only, the setting that left the slider flat).
    public var usePolygons = true
    public init() {}
}

/// A tiered POI and the street edges it can be seen from.
public struct Sight: Sendable {
    public let poi: POI
    public let tier: Int
    public let weight: Double
    public let edges: Set<Int32>
    /// Perpendicular metres to the straight A→B line, and fraction along it.
    public let distToLine: Double
    public let along: Double
}

public struct Scored: Sendable {
    public let sights: [Sight]
    /// Per graph edge: the summed weight of the sights within viewing distance.
    public let interest: [Double]
    public let folded: Int
    public let params: ScoringParams
    public func score(edge: Int32) -> Float { Float(min(1, interest[Int(edge)] / params.cap)) }
}

public enum InterestScorer {
    public static func score(graph: PedestrianGraph, box: FetchBox, plane: LocalPlane, params: ScoringParams = .init()) -> Scored {
        let viewing = params.viewingMetres
        let (bx, by) = plane.project(lat: box.end.lat, lon: box.end.lon)
        func lineDistance(_ x: Double, _ y: Double) -> (Double, Double) {
            let dx = bx, dy = by
            let l2 = dx * dx + dy * dy
            let t = l2 > 0 ? max(0, min(1, (x * dx + y * dy) / l2)) : 0
            return (hypot(x - t * dx, y - t * dy), t)
        }
        let n = graph.edgeCount
        var ex = [Double](repeating: 0, count: n), ey = ex, fx = ex, fy = ex
        for e in 0..<n {
            let a = Int(graph.edgeA[e]), b = Int(graph.edgeB[e])
            (ex[e], ey[e]) = plane.project(lat: graph.nodeLat[a], lon: graph.nodeLon[a])
            (fx[e], fy[e]) = plane.project(lat: graph.nodeLat[b], lon: graph.nodeLon[b])
        }
        var sights: [Sight] = []
        var interest = [Double](repeating: 0, count: n)
        var folded = 0
        for p in box.pois {
            if p.isFolded { folded += 1; continue }
            let tier = p.tier
            guard tier > 0 else { continue }
            let (px, py) = plane.project(lat: p.lat, lon: p.lon)
            let (dl, along) = lineDistance(px, py)
            let weight = tier == 1 ? params.tier1Base + Double(p.sitelinks ?? 0) : params.tier2Weight
            let rings: [[(Double, Double)]] = params.usePolygons
                ? p.rings.map { $0.map { let q = plane.project(lat: $0[0], lon: $0[1]); return (q.x, q.y) } } : []
            var minX = px, maxX = px, minY = py, maxY = py
            for r in rings { for (x, y) in r { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
            var near = Set<Int32>()
            for e in 0..<n {
                let x1 = ex[e], y1 = ey[e], x2 = fx[e], y2 = fy[e]
                if max(x1, x2) < minX - viewing || min(x1, x2) > maxX + viewing ||
                   max(y1, y2) < minY - viewing || min(y1, y2) > maxY + viewing { continue }
                var d = Polygon.segDist(px, py, x1, y1, x2, y2)
                if d > viewing, !rings.isEmpty {
                    for r in rings {
                        if Polygon.pointInRing(x1, y1, r) || Polygon.pointInRing(x2, y2, r) { d = 0; break }
                        for i in 1..<r.count {
                            d = min(d, Polygon.segSegDist((x1, y1), (x2, y2), r[i - 1], r[i]))
                            if d <= viewing { break }
                        }
                        if d <= viewing { break }
                    }
                }
                if d <= viewing { near.insert(Int32(e)) }
            }
            for e in near { interest[Int(e)] += weight }
            sights.append(Sight(poi: p, tier: tier, weight: weight, edges: near, distToLine: dl, along: along))
        }
        return Scored(sights: sights, interest: interest, folded: folded, params: params)
    }
}
