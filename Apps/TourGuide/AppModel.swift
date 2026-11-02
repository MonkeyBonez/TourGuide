import Foundation
import SwiftUI
import MapKit
import TourGuideCore

/// Screen state. LikeWater's AppModel shape: debounced recompute, version counters that tell
/// the map what to redraw, launch overrides for UI tests. The slider is corridor slack; the
/// score weight is pinned at 1 (PRD §5).
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, fetching(String), ready, waiting(String), fetchFailed(String), noRoute(String) }
    enum Banner: Equatable {
        case waitingForLocation
        case fetching(String)
        case fetchFailed(String, keepingFast: Bool)
        case degraded(String)
        case noRoute(String)
    }
    enum LongPressTarget: String, CaseIterable, Identifiable { case destination = "Destination", start = "Start"; var id: String { rawValue } }

    @Published var origin: Place?
    @Published var destination: Place?
    @Published var phase: Phase = .idle
    @Published var degraded: String?
    @Published var info: SessionInfo?
    @Published var snapshot: RouteSnapshot?
    /// The fastest path, shown while the full corridor loads (PRD §5 step 8); nil once it's in.
    @Published var fastSnapshot: RouteSnapshot?
    @Published var slack: Double
    @Published var maxSlack: Double
    @Published var pace: Double
    @Published var showTimings: Bool
    @Published var showNamed = false
    @Published var longPressTarget: LongPressTarget = .destination
    @Published var cardContent: [String: CardContent] = [:]
    @Published var selectedCard: String?
    @Published var placeCard: SightCard?
    @Published var showSettings = false
    @Published var showSearch = false
    @Published var searchingStart = false
    @Published var showPhoto = false
    @Published var showAttribution = false
    @Published var showCompare = false

    // Map redraw requests.
    @Published var routeVersion = 0
    @Published var pinsVersion = 0
    @Published var fitRequest = 0
    @Published var highlightVersion = 0

    let location = LocationService()
    let service = TourService()
    let translations = TranslationStore()
    let appleNames = AppleNameStore(disabled: UserDefaults.standard.string(forKey: "uiTestFixture") != nil)
    let walkBlurbs = WalkDescriptionStore()
    private let enricher = CardEnricher(transport: URLSessionTransport(requestTimeout: 20, resourceTimeout: 40))
    private let fixtureEnricher = CardEnricher(transport: FixtureTransport(
        directory: Bundle.main.bundleURL.appendingPathComponent("OfflineCardFixtures")), cache: nil)
    private var loadTask: Task<Void, Never>?
    private var fastTask: Task<Void, Never>?
    private var rerouteTask: Task<Void, Never>?
    private var fixture: String?
    var isFixture: Bool { fixture != nil }
    static let fallbackCenter = CLLocationCoordinate2D(latitude: BundledFixtures.kanazawaStart.lat, longitude: BundledFixtures.kanazawaStart.lon)

    init() {
        let d = UserDefaults.standard
        slack = d.object(forKey: "slack") as? Double ?? 0.10
        maxSlack = d.object(forKey: "maxSlack") as? Double ?? 0.5
        pace = d.object(forKey: "pace") as? Double ?? 1.4
        showTimings = d.bool(forKey: "showTimings")
        applyLaunchOverrides()
    }

    // MARK: Banners and readouts

    var banner: Banner? {
        switch phase {
        case .fetching(let s): return .fetching(s)
        case .waiting: return .waitingForLocation
        case .fetchFailed(let s): return .fetchFailed(s, keepingFast: fastSnapshot != nil)
        case .noRoute(let s): return .noRoute(s)
        case .idle, .ready: return degraded.map { .degraded($0) }
        }
    }

    var routeReadout: String {
        guard let r = snapshot, let info else { return "" }
        return Self.readout(seconds: r.seconds, metres: r.metres, sights: r.cards.count, slack: r.slack, directSeconds: info.directSeconds)
    }
    /// One format for the panel and the "Compare walks" rows, so they agree to the character.
    static func readout(seconds: Double, metres: Double, sights: Int, slack: Double, directSeconds: Double) -> String {
        let extra = seconds - directSeconds
        var parts = ["\(minutes(seconds)) min", String(format: "%.1f km", metres / 1000), "\(sights) sight\(sights == 1 ? "" : "s")"]
        parts.append(extra < 30 ? (slack < 0.005 ? "direct" : "no extra time") : "+\(minutes(extra)) min")
        return parts.joined(separator: " · ")
    }
    func readout(for w: WalkOption) -> String {
        Self.readout(seconds: w.seconds, metres: w.metres, sights: w.tier1Ids.count, slack: w.slack,
                     directSeconds: info?.directSeconds ?? w.seconds - w.extraSeconds)
    }
    var fastReadout: String {
        guard let f = fastSnapshot else { return "" }
        let base = "Fastest \(Self.minutes(f.seconds)) min · " + String(format: "%.1f km", f.metres / 1000)
        if case .fetching = phase { return base + " · loading sights…" }
        return base
    }
    var directCaption: String { info.map { "Direct \(Self.minutes($0.directSeconds)) min" } ?? "Direct" }
    var maxCaption: String { info.map { "+\(Self.minutes($0.maxSlackSeconds - $0.directSeconds)) min" } ?? "More sights" }
    var timingsText: String {
        guard let info, let r = snapshot else { return "" }
        return String(format: "session %.0f ms · route %.1f ms · snap A %.0f m, B %.0f m · %d / %d sights",
                      info.buildMs, r.computeMs, info.snapA, info.snapB, info.tier1, info.tier2)
    }
    static func minutes(_ s: Double) -> Int { Int((s / 60).rounded()) }

    // MARK: Planning

    var effectiveStart: CLLocationCoordinate2D? {
        origin.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? location.coordinate
    }

    func setDestination(_ p: Place) { destination = p; plan() }
    func setStart(_ p: Place?) { origin = p; if destination != nil { plan() } }

    func handleLongPress(at c: CLLocationCoordinate2D) {
        let p = Place(name: "Dropped pin", lat: c.latitude, lon: c.longitude)
        longPressTarget == .start ? setStart(p) : setDestination(p)
    }

    /// The bundled Kanazawa snapshot: Kanazawa Station → Murataya Ryokan, no network.
    func loadDemo() {
        fixture = "kanazawa"
        origin = BundledFixtures.kanazawaStart
        destination = BundledFixtures.kanazawaEnd
        plan()
    }

    func plan() {
        guard let destination else { return }
        guard let start = effectiveStart else {
            phase = .waiting("Waiting for your location — or long-press to set a start.")
            return
        }
        let a = origin ?? Place(name: "My location", lat: start.latitude, lon: start.longitude)
        let maxSlack = self.maxSlack, pace = self.pace, fixture = self.fixture
        let d = UserDefaults.standard
        let slowLoad = d.double(forKey: "uiTestSlowLoad"), fullFails = d.string(forKey: "uiTestFullLoadFails") == "1"
        loadTask?.cancel(); fastTask?.cancel()
        snapshot = nil; fastSnapshot = nil; info = nil; degraded = nil; cardContent = [:]
        clearSelection()
        walkBlurbs.reset()
        routeVersion += 1; pinsVersion += 1
        phase = .fetching("Fetching streets and sights…")
        fastTask = Task { [weak self] in await self?.loadFastest(from: a, to: destination, pace: pace, maxSlack: maxSlack, fixture: fixture) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if slowLoad > 0 { try await Task.sleep(nanoseconds: UInt64(slowLoad * 1e9)) }
                if fullFails { throw OverpassClient.AllMirrorsFailed(reasons: ["UI test"]) }
                let box: FetchBox
                if let fixture {
                    box = try self.fixtureBox(fixture, from: a, to: destination)
                } else {
                    box = try await self.service.fetch(from: a, to: destination, maxSlack: maxSlack) { stage in
                        Task { @MainActor [weak self] in self?.show(stage) }
                    }
                }
                try Task.checkCancellation()
                self.phase = .fetching("Scoring \(box.pois.count) places along \(box.ways.count) streets…")
                let info = try await self.service.load(box: box, maxSlack: maxSlack, pace: pace)
                try Task.checkCancellation()
                self.info = info
                self.fastTask?.cancel()
                self.pinsVersion += 1
                self.phase = .ready
                await self.reroute(fit: true)
                self.fastSnapshot = nil
                // Compare walks (PRD §8.13): facts now, Apple Intelligence's words as they land.
                if let o = try? await self.service.walkOptions(maxSlack: maxSlack), !Task.isCancelled {
                    self.walkBlurbs.load(walks: o.walks, context: o.context,
                                         cacheKey: WalkDescriptionStore.cacheKey(bbox: o.bbox, maxSlack: maxSlack, pace: pace))
                }
            } catch is CancellationError {
            } catch let e as SessionError {
                self.phase = .noRoute(e.errorDescription ?? "No route.")
            } catch {
                self.phase = .fetchFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// The head start: walk network only, in a narrow box around A→B, routed at slack 0. Skipped
    /// when the full corridor is cached; any failure is silent (the full load reports).
    private func loadFastest(from a: Place, to b: Place, pace: Double, maxSlack: Double, fixture: String?) async {
        do {
            let narrow: FetchBox
            if let fixture {
                let full = try fixtureBox(fixture, from: a, to: b)
                narrow = full.cropped(to: LineBuffer.bbox(a: a, b: b))
            } else {
                if await service.cachedBox(from: a, to: b, maxSlack: maxSlack) != nil { return }
                narrow = try await service.fetchWalkNetwork(from: a, to: b)
            }
            try Task.checkCancellation()
            let snap = try await service.loadFast(box: narrow, pace: pace)
            try Task.checkCancellation()
            guard info == nil else { return }
            fastSnapshot = snap
            routeVersion += 1; fitRequest += 1
        } catch {}
    }

    private func fixtureBox(_ name: String, from a: Place, to b: Place) throws -> FetchBox {
        var box: FetchBox
        switch name {
        case "kanazawa": box = try BundledFixtures.kanazawa()
        case "visibility": box = try BundledFixtures.visibility()
        default: throw CocoaError(.fileNoSuchFile)
        }
        box.start = a; box.end = b
        return box
    }

    private func show(_ stage: TourPipeline.Stage) {
        guard case .fetching = phase else { return }
        switch stage {
        case .cacheHit: phase = .fetching("Loading this walk from the cache…")
        case .overpass(.trying(let m, let a, let n)): phase = .fetching("Fetching streets and sights · \(m) (\(a)/\(n))…")
        case .overpass(.failed(let m, let r)): phase = .fetching("\(m) failed (\(r)) · trying the next server…")
        case .parsing(let b): phase = .fetching("Reading \(b / 1024) KB of map data…")
        case .wikidata(let s): phase = .fetching("Ranking sights · \(s)…")
        case .degraded(let s): degraded = s
        case .done: break
        }
    }

    // MARK: Slider

    /// Left (0) = most sights, right (1) = direct; square law (`SliderLaw`).
    var sliderPosition: Double { SliderLaw.position(slack: slack, maxSlack: maxSlack) }
    func setSliderPosition(_ p: Double) {
        let s = SliderLaw.slack(position: p, maxSlack: maxSlack)
        if s != slack { setSlack(s) }
    }

    func setSlack(_ value: Double) {
        slack = value
        UserDefaults.standard.set(value, forKey: "slack")
        rerouteTask?.cancel()
        rerouteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            await self?.reroute(fit: false)
        }
    }

    func reroute(fit: Bool) async {
        guard info != nil else { return }
        do {
            let r = try await service.route(slack: slack)
            snapshot = r
            routeVersion += 1
            if fit { fitRequest += 1 }
            enrich(r.cards + r.named)
            translations.request((r.cards + r.named).flatMap { [$0.poi.name, $0.poi.nameLocal] }.compactMap { $0 })
            appleNames.request(r.cards + r.named)
        } catch {
            phase = .noRoute((error as? LocalizedError)?.errorDescription ?? "No route.")
        }
    }

    private func enrich(_ cards: [SightCard]) {
        let todo = cards.filter { cardContent[$0.id] == nil }
        guard !todo.isEmpty else { return }
        let enricher = fixture == nil ? self.enricher : fixtureEnricher
        Task { [weak self] in
            guard let self else { return }
            await enricher.prefetch(todo.map(\.poi))
            for c in todo {
                let content = await enricher.content(for: c.poi)
                self.cardContent[c.id] = content
                if let ex = content.extract, content.extractLang != "en" { self.translations.request([ex]) }
            }
        }
    }

    // MARK: Compare walks

    /// The walk on screen: the one passing the same Tier-1 sights (the dedupe rule itself; the
    /// default slack 0.10 sits exactly between two walks, so distance can't decide).
    func isCurrent(_ w: WalkOption) -> Bool {
        if let r = snapshot { return Set(r.cards.map(\.id)) == w.tier1Ids }
        return false
    }

    /// Walk this one. A no-op on the current walk, so tapping it never changes streets.
    func choose(_ w: WalkOption) {
        guard !isCurrent(w) else { return }
        setSlack(w.slack)
    }

    // MARK: Settings

    func setMaxSlack(_ v: Double) {
        maxSlack = v; UserDefaults.standard.set(v, forKey: "maxSlack")
        slack = min(slack, v)
        if destination != nil { plan() }
    }
    func setPace(_ v: Double) {
        pace = v; UserDefaults.standard.set(v, forKey: "pace")
        if destination != nil { plan() }
    }
    func setShowTimings(_ v: Bool) { showTimings = v; UserDefaults.standard.set(v, forKey: "showTimings") }

    /// Card or pin tap: outline the sight's grounds (or a halo for a point), grow its pin, zoom
    /// to it (PRD §5.1). Tier 2 also opens Apple's Place Card.
    func select(_ card: SightCard) {
        selectedCard = card.id
        highlightVersion += 1
        if card.tier == 2 { placeCard = card }
    }
    func clearSelection() {
        guard selectedCard != nil else { return }
        selectedCard = nil
        highlightVersion += 1
    }

    // MARK: Photo context

    func photoContext(question: String?) async -> TravelerContext {
        let here = location.coordinate ?? effectiveStart
        let nearby = here != nil ? await service.sights(near: here!, within: 150, limit: 3) : []
        return TravelerContext(from: origin?.name ?? (location.coordinate != nil ? "my location" : nil), to: destination?.name,
                               nearbySights: nearby, question: question, lat: here?.latitude, lon: here?.longitude)
    }

    // MARK: UI tests

    /// -uiTestFixture kanazawa|visibility · -uiTestStart "lat,lon" · -uiTestDestination "lat,lon"
    /// -uiTestDestinationName · -uiTestSlack · -uiTestMaxSlack · -uiTestPace · -uiTestTimings 1
    private func applyLaunchOverrides() {
        let d = UserDefaults.standard
        func coord(_ k: String) -> CLLocationCoordinate2D? {
            let p = (d.string(forKey: k) ?? "").split(separator: ",").compactMap { Double($0) }
            return p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
        }
        if let s = d.string(forKey: "uiTestSlack").flatMap(Double.init) { slack = s }
        if let s = d.string(forKey: "uiTestMaxSlack").flatMap(Double.init) { maxSlack = s }
        if let p = d.string(forKey: "uiTestPace").flatMap(Double.init) { pace = p }
        if d.string(forKey: "uiTestTimings") == "1" { showTimings = true }
        fixture = d.string(forKey: "uiTestFixture")
        if let a = coord("uiTestStart") { origin = Place(name: "Start", lat: a.latitude, lon: a.longitude) }
        if let b = coord("uiTestDestination") {
            destination = Place(name: d.string(forKey: "uiTestDestinationName") ?? "Destination", lat: b.latitude, lon: b.longitude)
            if fixture == "kanazawa" {
                origin = origin.map { Place(name: BundledFixtures.kanazawaStart.name, lat: $0.lat, lon: $0.lon) }
                destination = destination.map { Place(name: BundledFixtures.kanazawaEnd.name, lat: $0.lat, lon: $0.lon) }
            }
            DispatchQueue.main.async { self.plan() }
        }
    }
}
