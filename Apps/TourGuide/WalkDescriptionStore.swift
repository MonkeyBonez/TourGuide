import Foundation
import TourGuideCore

/// "Compare walks" (PRD §8.13): the distinct walks along the slider, and a title for each written
/// on this iPhone by Apple Intelligence. The walks, their numbers and sights are ours and always
/// shown; the title is added when the phone has Apple Intelligence (iPhone 15 Pro and later). Cached per corridor; one walk at
/// a time, published as each lands. Never blocks the route; every failure is silent.
@MainActor
final class WalkDescriptionStore: ObservableObject {
    enum Mode { case live, canned, unavailable }
    /// `failed`: the model said it was available but no call succeeded (7 Oct 2026, the iOS 26
    /// simulator: `.available`, then ModelManagerError 1026 "no underlying assets" on every call).
    enum Status: Equatable { case idle, describing(Int, Int), done, failed, unavailable(WalkDescriberAvailability), off }

    @Published var walks: [WalkOption] = []
    @Published var blurbs: [String: WalkBlurbText] = [:]
    @Published var status: Status = .idle
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "walkBlurbs")
            if enabled, let context, let key { load(walks: walks, context: context, cacheKey: key) }
            else if !enabled { task?.cancel(); status = .off }
        }
    }

    let mode: Mode
    private var task: Task<Void, Never>?
    private var context: WalkFacts.Context?
    private var key: String?
    private let cache = DiskCache.named("walkblurbs", ttl: 30 * 86_400)
    struct Saved: Codable { var variant: String; var blurbs: [String: WalkBlurbText] }

    /// -uiTestWalkBlurbs canned|none|live; fixture runs default to unavailable so UI tests never touch the model.
    init() {
        let d = UserDefaults.standard
        switch d.string(forKey: "uiTestWalkBlurbs") {
        case "canned": mode = .canned
        case "none": mode = .unavailable
        case "live": mode = .live          // the real model, on the fixture (opt-in UI test)
        default: mode = d.string(forKey: "uiTestFixture") != nil ? .unavailable : .live
        }
        enabled = d.object(forKey: "walkBlurbs") as? Bool ?? true
    }

    static func cacheKey(bbox: [Double], maxSlack: Double, pace: Double) -> String {
        "walkblurbs:v\(WalkFacts.promptVersion):\(TourPipeline.cacheKey(bbox: bbox))|\(maxSlack)|\(pace)"
    }

    static var availability: WalkDescriberAvailability {
        #if canImport(FoundationModels)
        return OnDeviceWalkDescriber.availability
        #else
        return .noFramework
        #endif
    }

    func reset() {
        task?.cancel(); task = nil
        walks = []; blurbs = [:]; status = .idle; context = nil; key = nil
    }

    func load(walks: [WalkOption], context: WalkFacts.Context, cacheKey: String) {
        task?.cancel()
        self.walks = walks; self.context = context; self.key = cacheKey
        switch mode {
        case .canned:
            let titles = ["Direct Route", "Samurai Heritage Trail", "Kanazawa Castle Park and Shrine", "Kenroku-en and Museum Walk"]
            blurbs = Dictionary(uniqueKeysWithValues: walks.enumerated().map {
                ($0.element.id, WalkBlurbText(title: titles[min($0.offset, titles.count - 1)], text: ""))
            })
            status = .done
            return
        case .unavailable:
            status = .unavailable(.deviceNotEligible)
            return
        case .live: break
        }
        guard enabled else { status = .off; return }
        let availability = Self.availability
        guard availability == .available else { status = .unavailable(availability); return }
        if let saved = cache.load(Saved.self, key: cacheKey) { blurbs = saved.blurbs.filter { id, _ in walks.contains { $0.id == id } } }
        let missing = walks.filter { blurbs[$0.id] == nil }
        guard !missing.isEmpty else { status = .done; return }
        #if canImport(FoundationModels)
        let (variant, sampling) = WalkFacts.chosen
        task = Task { [weak self] in
            let describer = OnDeviceWalkDescriber(variant: variant, sampling: sampling)
            describer.prewarm()
            var errors = 0, written = 0
            for (i, w) in missing.enumerated() {
                guard let self, !Task.isCancelled else { return }
                self.status = .describing(i, missing.count)
                // The gate (LEARNINGS §8): a title that fails the scorer's checks is retried once
                // with sampling, then dropped — never shown.
                var shown: WalkBlurbText?
                for attempt in [sampling, WalkSampling.default] {
                    let d = attempt == sampling ? describer : OnDeviceWalkDescriber(variant: variant, sampling: attempt)
                    do {
                        let b = try await d.describe(w, context: context)
                        let ok = WalkBlurbScore.titleIsShowable(b, option: w, allSightNames: context.allSightNames)
                        Self.log("walk \(i + 1) [\(attempt)]: \"\(b.title)\" \(ok ? "shown" : "gated")")
                        if ok { shown = b; break }
                    } catch {
                        errors += 1
                        Self.log("walk \(i + 1) [\(attempt)]: \(error)")
                    }
                }
                guard !Task.isCancelled else { return }
                if let shown {
                    written += 1
                    self.blurbs[w.id] = shown
                    self.cache.store(Saved(variant: variant.rawValue, blurbs: self.blurbs), key: cacheKey)
                }
            }
            // Every attempt threw: say so, rather than "written by Apple Intelligence" over bare rows.
            self?.status = written == 0 && errors == 2 * missing.count ? .failed : .done
        }
        #endif
    }

    /// Apple Intelligence's title, or none (owner's ruling: no title without it).
    func title(_ w: WalkOption) -> String? { blurbs[w.id]?.title }

    static func log(_ s: String) {
        #if DEBUG
        print("[walks] " + s)
        #endif
    }

    var footer: String {
        switch status {
        case .unavailable(.deviceNotEligible), .unavailable(.noFramework):
            return "This iPhone can't name walks: Apple Intelligence needs an iPhone 15 Pro or newer."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to get walk titles."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model; titles will appear on a later walk."
        case .unavailable(.available): return ""
        case .describing(let i, let n): return "Naming walk \(i + 1) of \(n) on this iPhone…"
        case .done: return "Titles are written on this iPhone by Apple Intelligence."
        case .failed: return "Apple Intelligence couldn't name these walks on this iPhone right now."
        case .off: return "Walk titles are off (Settings)."
        case .idle: return ""
        }
    }
}
