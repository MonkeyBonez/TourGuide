import Foundation
import MapKit
import TourGuideCore

/// Apple Maps' English names for sights whose OSM name is Japanese (PRD §8.10): a name search
/// near the pin, kept only when `AppleNameGuard` agrees it is the same place. Hits and misses are
/// cached on disk, so a corridor is looked up once. Off in UI tests (no network there).
@MainActor
final class AppleNameStore: ObservableObject {
    /// POI id → Apple's name.
    @Published var names: [String: String] = [:]
    /// POI id → the map item, so the Place Card opens without searching again.
    var items: [String: MKMapItem] = [:]
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "appleNames"); if enabled { pump() } } }
    private var looked: [String: String] = [:]          // id → name, "" = Apple has nothing
    private var queue: [SightCard] = []
    private var running = false
    private let cache = DiskCache.named("applenames", ttl: 30 * 86_400)
    private static let cacheKey = "apple-names:v1"

    init(disabled: Bool = false) {
        enabled = disabled ? false : (UserDefaults.standard.object(forKey: "appleNames") as? Bool ?? true)
        if let saved = cache.load([String: String].self, key: Self.cacheKey) {
            looked = saved
            names = saved.filter { !$0.value.isEmpty }
        }
    }

    /// Queue sights; only those shown under a Japanese name and not yet looked up.
    func request(_ cards: [SightCard]) {
        let new = cards.filter { c in
            POI.isJapanese(c.poi.displayName) && looked[c.id] == nil && !queue.contains { $0.id == c.id }
        }
        guard !new.isEmpty else { return }
        queue += new
        pump()
    }

    private func pump() {
        guard enabled, !running, !queue.isEmpty else { return }
        running = true
        Task { [weak self] in
            while let self, self.enabled, !self.queue.isEmpty {
                let c = self.queue.removeFirst()
                switch await Self.lookup(c.poi) {
                case .hit(let name, let item):
                    self.names[c.id] = name; self.items[c.id] = item; self.looked[c.id] = name
                case .miss:
                    self.looked[c.id] = ""
                case .failed:
                    // Throttled or offline: not a miss. Try again later, after a pause.
                    self.queue.append(c)
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continue
                }
                self.cache.store(self.looked, key: Self.cacheKey)
                // MapKit throttles (MKError.loadingThrottled) after ~50 searches even at 1.2 s
                // spacing (measured 6 Oct 2026); a lookup is up to two searches.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self?.running = false
        }
    }

    enum Lookup { case hit(String, MKMapItem), miss, failed }

    /// Local name first, then the OSM English-ish name; nearest guarded result wins.
    static func lookup(_ poi: POI) async -> Lookup {
        let here = CLLocation(latitude: poi.lat, longitude: poi.lon)
        var queries: [String] = []
        for q in [poi.nameLocal, poi.name].compactMap({ $0 }) where !queries.contains(q) { queries.append(q) }
        for q in queries {
            switch await search(q, poi: poi, here: here) {
            case .hit(let n, let i): return .hit(n, i)
            case .failed: return .failed
            case .miss: continue
            }
        }
        return .miss
    }

    static func search(_ q: String, poi: POI, here: CLLocation) async -> Lookup {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = q
        r.resultTypes = .pointOfInterest
        r.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 300, longitudinalMeters: 300)
        let items: [MKMapItem]
        do { items = try await MKLocalSearch(request: r).start().mapItems }
        catch let e as MKError where e.code == .placemarkNotFound { return .miss }
        catch { return .failed }
        let ranked = items.map { ($0, $0.location.distance(from: here)) }.sorted { $0.1 < $1.1 }
        for (item, d) in ranked {
            guard let name = item.name, !POI.isJapanese(name) else { continue }
            if AppleNameGuard.accept(poi: poi, resultName: name, distance: d, categoryRaw: item.pointOfInterestCategory?.rawValue) {
                return .hit(name, item)
            }
        }
        return .miss
    }
}
