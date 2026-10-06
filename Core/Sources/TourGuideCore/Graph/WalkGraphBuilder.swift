import Foundation
import LikeWaterEngine

/// Walk ways → the Engine's in-memory `PedestrianGraph`, one edge per OSM node pair, flagged by
/// the pipeline's rule (`Pipeline/sidewalks.py`), no sidewalk synthesis (PRD §5 step 4).
public enum WalkGraphBuilder {
    static let streetClasses: Set<String> = ["residential", "tertiary", "secondary", "primary", "unclassified",
                                             "living_street", "service", "tertiary_link", "secondary_link", "primary_link"]

    public static func flags(for t: [String: String]) -> UInt8 {
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

    public static func build(_ box: FetchBox) -> (graph: PedestrianGraph, edgeWay: [Int64]) {
        var coord: [Int64: (lat: Double, lon: Double)] = [:]
        coord.reserveCapacity(box.nodes.count)
        for n in box.nodes { coord[Int64(n[0])] = (n[1], n[2]) }
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
            guard w.nodes.count > 1 else { continue }
            for k in 1..<w.nodes.count {
                guard let a = node(w.nodes[k - 1]), let b = node(w.nodes[k]), a != b else { continue }
                let lo = min(a, b), hi = max(a, b)
                guard seenPair.insert(Int64(lo) << 32 | Int64(hi)).inserted else { continue }
                let len = haversineMeters(nodeLat[Int(a)], nodeLon[Int(a)], nodeLat[Int(b)], nodeLon[Int(b)])
                guard len > 0 else { continue }
                eA.append(lo); eB.append(hi); eLen.append(len); eFlags.append(f); eWay.append(w.id)
            }
        }
        let bbox = BBox(minLat: box.bbox[0], minLon: box.bbox[1], maxLat: box.bbox[2], maxLon: box.bbox[3])
        let graph = PedestrianGraph(nodeLat: nodeLat, nodeLon: nodeLon, edgeA: eA, edgeB: eB, edgeLen: eLen,
                                    edgeFlags: eFlags, edgeInterest: nil, bbox: bbox)
        return (graph, eWay)
    }
}
