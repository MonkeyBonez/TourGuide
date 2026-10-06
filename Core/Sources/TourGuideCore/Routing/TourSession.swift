import Foundation
import LikeWaterEngine

public struct Coordinate: Codable, Sendable, Equatable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

/// A sight the route passes: where along the walk it first comes within viewing distance.
public struct PassedSight: Sendable {
    public let sight: Sight
    public let firstEdgeIndex: Int
    public let alongMetres: Double
    public let alongSeconds: Double
}

public struct TourRoute: Sendable {
    public let slack: Double
    public let route: Route
    public let coordinates: [Coordinate]
    public let crossings: Int
    public let corridorEdges: Int
    public let corridorMs: Double
    /// In walking order.
    public let passed: [PassedSight]
    public var metres: Double { route.metres }
    public var seconds: Double { route.seconds }
    /// Sidewalk seconds weighted by interest score (the router's objective, read back).
    public var interestSeconds: Double { route.sunSeconds }
    public var computeMs: Double { corridorMs + route.computeMs }
}

public enum SessionError: Error, LocalizedError, Equatable {
    case startOffGraph, destinationOffGraph, noRoute
    public var errorDescription: String? {
        switch self {
        case .startOffGraph: return "The start is not near a walkable street."
        case .destinationOffGraph: return "The destination is not near a walkable street."
        case .noRoute: return "No walking route between these two points."
        }
    }
}

/// Why a sight is or isn't on the route at a slider position.
public enum Reach: Sendable, Equatable {
    case passed
    case noEdge                          // nothing walkable within viewing distance (dead end, §5 step 7)
    case overBound(viaMetres: Double)    // the cheapest walk past it exceeds direct × (1 + slack)
    case outscored(viaMetres: Double)    // reachable, but other streets scored higher
}

/// One fetched corridor, built once: graph, interest, snapped ends, destination labels at the
/// slider's maximum. `route(slack:)` is the slider (milliseconds). Immutable after init; use it
/// from one actor at a time.
public final class TourSession: @unchecked Sendable {
    public let box: FetchBox
    public let graph: PedestrianGraph
    public let edgeWay: [Int64]
    public let plane: LocalPlane
    public let scored: Scored
    public let origin: Int32
    public let destination: Int32
    public let snapA: Double
    public let snapB: Double
    public let labels: DestinationLabels
    public let maxSlack: Double
    public let pace: PaceModel
    public let buildMs: Double
    private let scratch: CorridorScratch
    private lazy var fromOrigin: [Double] = {
        (try? CorridorEngine.labels(graph: graph, destination: origin, origin: destination, slack: 10).dTo)
            ?? [Double](repeating: .infinity, count: graph.nodeCount)
    }()

    /// Shortest walking distance A → B.
    public var directMetres: Double { labels.dTo[Int(origin)] }

    public init(box: FetchBox, pace: PaceModel = PaceModel(), params: ScoringParams = .init(), maxSlack: Double = 0.5) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        self.box = box; self.pace = pace; self.maxSlack = maxSlack
        (graph, edgeWay) = WalkGraphBuilder.build(box)
        plane = LocalPlane(originLat: box.start.lat, originLon: box.start.lon)
        scored = InterestScorer.score(graph: graph, box: box, plane: plane, params: params)
        guard let o = graph.nearestConnectedNode(lat: box.start.lat, lon: box.start.lon) else { throw SessionError.startOffGraph }
        guard let d = graph.nearestConnectedNode(lat: box.end.lat, lon: box.end.lon) else { throw SessionError.destinationOffGraph }
        origin = o; destination = d
        snapA = haversineMeters(box.start.lat, box.start.lon, graph.nodeLat[Int(o)], graph.nodeLon[Int(o)])
        snapB = haversineMeters(box.end.lat, box.end.lon, graph.nodeLat[Int(d)], graph.nodeLon[Int(d)])
        do { labels = try CorridorEngine.labels(graph: graph, destination: d, origin: o, slack: maxSlack) }
        catch { throw SessionError.noRoute }
        scratch = CorridorScratch(graph: graph)
        buildMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    /// The route at one slider position: corridor at `slack`, interest in place of sun, w = 1.
    public func route(slack: Double) throws -> TourRoute {
        let s = min(max(slack, 0), maxSlack)
        let corridor: Corridor
        do { corridor = try CorridorEngine.corridor(graph: graph, labels: labels, origin: origin, slack: s, scratch: scratch) }
        catch { throw SessionError.noRoute }
        let seconds = pace.edgeSeconds(graph: graph, edges: corridor.edges, terrain: nil)
        let score = corridor.edges.map { scored.score(edge: $0) }
        let timeline = SunTimeline(constant: score, departure: Date(timeIntervalSince1970: 0), slots: 1)
        let route: Route
        do {
            route = try RouteEngine.route(graph: graph, corridor: corridor, labels: labels, origin: origin,
                                          timeline: timeline, edgeSeconds: seconds, sunWeight: 1)
        } catch { throw SessionError.noRoute }
        var order: [Int32: Int] = [:]
        for (i, e) in route.edges.enumerated() where order[e] == nil { order[e] = i }
        let routeEdges = Set(route.edges)
        var cum = [Double](repeating: 0, count: route.edges.count + 1)
        for (i, e) in route.edges.enumerated() { cum[i + 1] = cum[i] + graph.edgeLen[Int(e)] }
        let passed = scored.sights.filter { !$0.edges.isDisjoint(with: routeEdges) }
            .map { s -> PassedSight in
                let i = s.edges.compactMap { order[$0] }.min() ?? 0
                return PassedSight(sight: s, firstEdgeIndex: i, alongMetres: cum[i], alongSeconds: route.arrivalSeconds[i])
            }
            .sorted { $0.firstEdgeIndex < $1.firstEdgeIndex }
        let xs = route.edges.filter { graph.isCrossing(Int($0)) }.count
        let coords = route.nodes.map { Coordinate(lat: graph.nodeLat[Int($0)], lon: graph.nodeLon[Int($0)]) }
        return TourRoute(slack: s, route: route, coordinates: coords, crossings: xs, corridorEdges: corridor.edges.count,
                         corridorMs: corridor.computeMs, passed: passed)
    }

    /// Why `sight` is or isn't on the route at `slack` (the compare tool's "misses explained").
    public func explain(_ sight: Sight, route: TourRoute) -> Reach {
        if route.passed.contains(where: { $0.sight.poi.id == sight.poi.id }) { return .passed }
        if sight.edges.isEmpty { return .noEdge }
        let dTo = labels.dTo, dFrom = fromOrigin
        let via = sight.edges.map { e -> Double in
            let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)]), len = graph.edgeLen[Int(e)]
            return min(dFrom[a] + len + dTo[b], dFrom[b] + len + dTo[a])
        }.min() ?? .infinity
        return via > directMetres * (1 + route.slack) ? .overBound(viaMetres: via) : .outscored(viaMetres: via)
    }
}
