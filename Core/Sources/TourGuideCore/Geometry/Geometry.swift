import Foundation
import LikeWaterEngine

/// The fetch box: bounding box of the ellipse with foci A and B whose sum of distances is
/// L × (1 + slack) × routeFactor (PRD §5 step 2). Same constants as the prototype so the bbox
/// and its cache key reproduce the fixture to the last digit.
public enum SlackEllipse {
    public static func bbox(a: Place, b: Place, slack: Double = 0.5, routeFactor: Double = 1.25) -> (bbox: [Double], straightM: Double) {
        let my = 111_320.0, mx = 111_320.0 * cos(a.lat * .pi / 180)
        let ax = a.lon * mx, ay = a.lat * my, bx = b.lon * mx, by = b.lat * my
        let l = hypot(bx - ax, by - ay)
        let s = l * (1 + slack) * routeFactor
        let semiMajor = s / 2, c = l / 2
        let semiMinor = (semiMajor * semiMajor - c * c).squareRoot()
        let cx = (ax + bx) / 2, cy = (ay + by) / 2
        let ux = l > 0 ? (bx - ax) / l : 1, uy = l > 0 ? (by - ay) / l : 0
        let hx = ((semiMajor * ux) * (semiMajor * ux) + (semiMinor * uy) * (semiMinor * uy)).squareRoot()
        let hy = ((semiMajor * uy) * (semiMajor * uy) + (semiMinor * ux) * (semiMinor * ux)).squareRoot()
        return ([(cy - hy) / my, (cx - hx) / mx, (cy + hy) / my, (cx + hx) / mx], l)
    }
}

/// Planar helpers in local metres (`LocalPlane`).
public enum Polygon {
    @inline(__always)
    public static func segDist(_ px: Double, _ py: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let dx = x2 - x1, dy = y2 - y1
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / l2)) : 0
        return hypot(px - (x1 + t * dx), py - (y1 + t * dy))
    }

    /// Segments that cross have distance 0; otherwise the minimum is at an endpoint.
    public static func segSegDist(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ d: (Double, Double)) -> Double {
        func cross(_ o: (Double, Double), _ p: (Double, Double), _ q: (Double, Double)) -> Double {
            (p.0 - o.0) * (q.1 - o.1) - (p.1 - o.1) * (q.0 - o.0)
        }
        let d1 = cross(c, d, a), d2 = cross(c, d, b), d3 = cross(a, b, c), d4 = cross(a, b, d)
        if ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0)) { return 0 }
        return min(segDist(a.0, a.1, c.0, c.1, d.0, d.1), segDist(b.0, b.1, c.0, c.1, d.0, d.1),
                   segDist(c.0, c.1, a.0, a.1, b.0, b.1), segDist(d.0, d.1, a.0, a.1, b.0, b.1))
    }

    public static func pointInRing(_ x: Double, _ y: Double, _ ring: [(Double, Double)]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let (xi, yi) = ring[i], (xj, yj) = ring[j]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Point-in-rings on [[lat, lon]] rings, the matcher's version (prototype `point_in_rings`).
    public static func pointInLatLonRings(lat: Double, lon: Double, _ rings: [[[Double]]]) -> Bool {
        for ring in rings {
            var inside = false
            let n = ring.count
            for i in 0..<n {
                let y1 = ring[i][0], x1 = ring[i][1], y2 = ring[(i + 1) % n][0], x2 = ring[(i + 1) % n][1]
                if (y1 > lat) != (y2 > lat), lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1) { inside.toggle() }
            }
            if inside { return true }
        }
        return false
    }

    /// Shoelace area in degree² — only ever compared with another ring's, so units don't matter.
    public static func ringAreaDeg(_ rings: [[[Double]]]) -> Double {
        rings.reduce(0) { total, r in
            var s = 0.0
            for i in 0..<r.count { let j = (i + 1) % r.count; s += r[i][0] * r[j][1] - r[j][0] * r[i][1] }
            return total + abs(s) / 2
        }
    }

    /// The prototype's flat-earth metres between two lat/lon points.
    public static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        hypot((lat2 - lat1) * 111_320, (lon2 - lon1) * 111_320 * cos(lat1 * .pi / 180))
    }
}
