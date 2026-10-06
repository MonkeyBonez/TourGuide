import Foundation
import CoreLocation
import LikeWaterEngine
import TourGuideCore

/// One sight as the screen sees it.
struct SightCard: Identifiable, Equatable {
    let poi: POI
    let tier: Int
    let weight: Double
    /// Metres and seconds into the walk where it first comes into view (passed sights only).
    var alongMetres: Double = 0
    var alongSeconds: Double = 0
    var passed = false
    var id: String { poi.id }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: poi.lat, longitude: poi.lon) }
}

struct RouteSnapshot: Equatable {
    var slack: Double
    var coordinates: [CLLocationCoordinate2D]
    var metres: Double
    var seconds: Double
    var crossings: Int
    /// Tier-1 sights the route passes, in walking order: the cards.
    var cards: [SightCard]
    /// Tier-2 sights the route passes, in walking order: secondary pins, and the "named places" row.
    var named: [SightCard]
    var computeMs: Double

    static func == (l: RouteSnapshot, r: RouteSnapshot) -> Bool {
        l.slack == r.slack && l.metres == r.metres && l.cards.map(\.id) == r.cards.map(\.id)
    }
}

struct SessionInfo: Equatable {
    var directMetres: Double
    var directSeconds: Double
    var maxSlackSeconds: Double
    var snapA: Double
    var snapB: Double
    var tier1: Int
    var tier2: Int
    var buildMs: Double
    /// Every tiered sight in the box (pins).
    var sights: [SightCard]
}

/// Owns the fetched corridor and the session built from it (LikeWater's CorridorService shape:
/// an actor, a generation counter so a stale load never overwrites a newer one).
actor TourService {
    private let pipeline = TourPipeline()
    private(set) var box: FetchBox?
    private var session: TourSession?
    private var generation = 0

    func fetch(from a: Place, to b: Place, maxSlack: Double,
               progress: @escaping @Sendable (TourPipeline.Stage) -> Void) async throws -> FetchBox {
        try await pipeline.fetchBox(from: a, to: b, maxSlack: maxSlack, progress: progress)
    }

    /// Build the session (graph, interest, labels) for a box. ~1 s on a phone for Kanazawa.
    func load(box: FetchBox, maxSlack: Double, pace: Double) throws -> SessionInfo {
        generation += 1
        let s = try TourSession(box: box, pace: PaceModel(pace: WalkingPace(metresPerSecond: pace)), maxSlack: maxSlack)
        let direct = try s.route(slack: 0), widest = try s.route(slack: maxSlack)
        self.box = box; session = s
        let sights = s.scored.sights.map { SightCard(poi: $0.poi, tier: $0.tier, weight: $0.weight) }
        return SessionInfo(directMetres: s.directMetres, directSeconds: direct.seconds, maxSlackSeconds: widest.seconds,
                           snapA: s.snapA, snapB: s.snapB, tier1: sights.filter { $0.tier == 1 }.count,
                           tier2: sights.filter { $0.tier == 2 }.count, buildMs: s.buildMs, sights: sights)
    }

    func route(slack: Double) throws -> RouteSnapshot {
        guard let s = session else { throw SessionError.noRoute }
        let r = try s.route(slack: slack)
        let passed = r.passed.map {
            SightCard(poi: $0.sight.poi, tier: $0.sight.tier, weight: $0.sight.weight,
                      alongMetres: $0.alongMetres, alongSeconds: $0.alongSeconds, passed: true)
        }
        return RouteSnapshot(slack: r.slack,
                             coordinates: r.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) },
                             metres: r.metres, seconds: r.seconds, crossings: r.crossings,
                             cards: passed.filter { $0.tier == 1 }, named: passed.filter { $0.tier == 2 },
                             computeMs: r.computeMs)
    }

    /// Sights near a point, nearest first (the photo's context).
    func sights(near c: CLLocationCoordinate2D, within metres: Double, limit: Int) -> [String] {
        guard let s = session else { return [] }
        return s.scored.sights
            .map { ($0, haversineMeters(c.latitude, c.longitude, $0.poi.lat, $0.poi.lon)) }
            .filter { $0.1 <= metres }
            .sorted { ($0.0.tier, $0.1) < ($1.0.tier, $1.1) }
            .prefix(limit)
            .map { "\($0.0.poi.displayName) (\($0.0.poi.kindLabel), \(Int($0.1)) m)" }
    }
}
