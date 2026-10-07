import Foundation

// "Compare walks" (PRD §8.13): the distinct walks along the slider, the facts the on-device model
// is given about each, and the scorer the prompt experiment is judged by. Everything checkable is
// computed here; the model only writes a title and a sentence. Framework-free, so the app, the
// cache and the tests never touch FoundationModels types.

/// One sight as the model is told about it.
public struct SightFact: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var kind: String
    public var famous: Bool
    /// Wikipedia languages (sitelinks): orders what a walk adds, best known first.
    public var fame: Int = 0
}

/// One distinct walk: the cheapest slider position that passes this set of Tier-1 sights.
public struct WalkOption: Sendable, Identifiable, Equatable {
    /// The Tier-1 ids, sorted and joined: stable across sessions, so it keys the cache.
    public var id: String
    public var slack: Double
    public var position: Double
    public var seconds: Double
    public var metres: Double
    public var extraSeconds: Double
    public var isDirect: Bool
    /// Walking order.
    public var tier1: [SightFact]
    public var tier1Ids: Set<String>
    public var tier2Names: [String]
    public var tier2Kinds: [String: Int]
    /// Against the previous (shorter) walk, in walking order.
    public var adds: [String]
    public var drops: [String]
}

public struct WalkBlurbText: Codable, Sendable, Equatable {
    public var title: String
    public var text: String
    public init(title: String, text: String) { self.title = title; self.text = text }
}

public enum WalkDescriberAvailability: String, Sendable, Equatable {
    case available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, noFramework
}

public enum WalkSampling: Sendable, Equatable, CustomStringConvertible {
    case `default`, greedy, temperature(Double)
    public var description: String {
        switch self { case .default: return "default"; case .greedy: return "greedy"; case .temperature(let t): return "temp \(t)" }
    }
}

public enum WalkDescriberError: Error, Equatable {
    case unavailable, unsupportedGuide, refused(String), failed(String)
}

public enum WalkFacts {
    /// Bump when any prompt text changes: it is part of the blurb cache key.
    public static let promptVersion = 3
    /// The prompt shape and sampling the app ships, chosen by `tgtool describe --matrix` (LEARNINGS §8).
    /// Round 5 winner, 7 Oct 2026: a title only, from the walk's two best-known new sights, greedy
    /// — 100 % of titles pass every check, 0.36 s a walk on the Mac. Sentences never beat the facts.
    public static let chosen: (Variant, WalkSampling) = (.titleTop2, .greedy)

    public enum Variant: String, CaseIterable, Sendable {
        case facts = "A", contrast = "B", contrastT2 = "C", blurbOnly = "D", fewShot = "E", guarded = "F", addsOnly = "G"
        case leads = "H", titleOnly = "T", titleAnchored = "U", titleTop2 = "V"
        public var label: String {
            switch self {
            case .facts: return "A facts"; case .contrast: return "B contrast"; case .contrastT2: return "C contrast+T2"
            case .blurbOnly: return "D blurb only"; case .fewShot: return "E few-shot"; case .guarded: return "F guarded"
            case .addsOnly: return "G adds only"; case .leads: return "H leads"; case .titleOnly: return "T title only"
            case .titleAnchored: return "U title anchored"; case .titleTop2: return "V title top-2"
            }
        }
    }

    /// Names the model must not mention unless they are on the walk (the hallucination check).
    public struct Context: Sendable, Equatable {
        public var from: String
        public var to: String
        public var allSightNames: [String]
        /// POI id → the first sentence of its Wikipedia lead (English only), for variant H.
        public var leads: [String: String]
        public init(from: String, to: String, allSightNames: [String], leads: [String: String] = [:]) {
            self.from = from; self.to = to; self.allSightNames = allSightNames; self.leads = leads
        }
    }

    /// The first sentence of an article lead, without parentheticals (dates, readings), ≤ 200 chars.
    public static func firstSentence(_ extract: String) -> String {
        var s = extract.replacingOccurrences(of: #"\s*[（(][^)）]*[)）]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: #"(?<=.{40})\. "#, options: .regularExpression) { s = String(s[..<r.lowerBound]) + "." }
        return s.count > 200 ? String(s.prefix(199)) + "…" : s
    }

    // MARK: Distinct walks

    /// Sweep the slider (`steps` + 1 positions through `SliderLaw`, slack 0 → max), keep the first
    /// (cheapest) walk for each set of Tier-1 sights passed. Kanazawa: four walks, ~240 ms.
    public static func distinctWalks(session: TourSession, maxSlack: Double, steps: Int = 20) throws -> [WalkOption] {
        let direct = try session.route(slack: 0)
        var seen = Set<Set<String>>(), out: [WalkOption] = []
        for i in stride(from: steps, through: 0, by: -1) {
            let position = Double(i) / Double(steps)
            let r = try session.route(slack: SliderLaw.slack(position: position, maxSlack: maxSlack))
            let t1 = r.passed.filter { $0.sight.tier == 1 }
            let ids = Set(t1.map { $0.sight.poi.id })
            guard seen.insert(ids).inserted else { continue }
            let t2 = r.passed.filter { $0.sight.tier == 2 }
            var kinds: [String: Int] = [:]
            for p in t2 { kinds[p.sight.poi.kindLabel.lowercased(), default: 0] += 1 }
            out.append(WalkOption(
                id: ids.sorted().joined(separator: ","), slack: r.slack, position: position,
                seconds: r.seconds, metres: r.metres, extraSeconds: r.seconds - direct.seconds, isDirect: out.isEmpty,
                tier1: dedupe(t1.map { fact($0.sight.poi) }), tier1Ids: ids,
                tier2Names: t2.map { promptName($0.sight.poi) }, tier2Kinds: kinds, adds: [], drops: []))
        }
        for i in out.indices.dropFirst() {
            let prev = Set(out[i - 1].tier1.map(\.name)), now = Set(out[i].tier1.map(\.name))
            out[i].adds = out[i].tier1.map(\.name).filter { !prev.contains($0) }
            out[i].drops = out[i - 1].tier1.map(\.name).filter { !now.contains($0) }
        }
        return out
    }

    public static func context(session: TourSession) -> Context {
        Context(from: session.box.start.name, to: session.box.end.name,
                allSightNames: session.scored.sights.map { promptName($0.poi) })
    }

    /// An English name when one exists anywhere (OSM name, Wikidata label), else the local one.
    /// A ", Kanazawa" / ", Ishikawa Prefecture" suffix is dropped: in a comma list it reads as
    /// a second sight (measured: "…adds: Shiinoki Cultural Complex, Ishikawa Prefecture, Chuo Park").
    public static func promptName(_ poi: POI) -> String {
        for c in [poi.name, poi.wdLabel, poi.displayName].compactMap({ $0 })
        where !POI.isJapanese(c) && !c.hasPrefix("node/") && !c.hasPrefix("way/") && !c.hasPrefix("relation/") {
            return c.components(separatedBy: ", ").first ?? c
        }
        return poi.displayName
    }

    static func fact(_ poi: POI) -> SightFact {
        SightFact(id: poi.id, name: promptName(poi), kind: poi.kindLabel.lowercased(), famous: (poi.sitelinks ?? 0) >= 10,
                  fame: poi.sitelinks ?? 0)
    }

    /// "Nagamachi Samurais District" and "Nagamachi Samurai District" are one place to a reader.
    static func dedupe(_ facts: [SightFact]) -> [SightFact] {
        var keys = Set<String>()
        return facts.filter { keys.insert(looseKey($0.name)).inserted }
    }

    static func looseKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map { w -> String in
            var w = String(w); if w.count > 3, w.hasSuffix("s") { w.removeLast() }; return w
        }.joined(separator: " ")
    }

    // MARK: Prompts (no digits, no examples in guides — both measured to go wrong)

    /// Round 2 (7 Oct 2026): the direct walk gets no "shorter route" wording (round 1 made the
    /// model call the direct walk "less crowded than the shorter route"), and every variant is told
    /// to name sights and not to describe streets (round 1 invented "lined with shops").
    public static func instructions(_ v: Variant, direct: Bool = false) -> String {
        let base = "You help a tourist in Japan choose between walking routes that share the same start and destination. "
            + "Describe one route, using only the facts given. Name at least one of its sights."
        let contrast = direct ? "" : " Lead with what it adds over the shorter route."
        let rules = " Never mention minutes, kilometres or any number; the app shows those. Be concrete and brief."
            + " Do not describe the streets, crowds, food, atmosphere or history beyond the facts."
            + " Do not use filler words such as scenic, beautiful, enjoy, peaceful, vibrant, rich, serene or charming."
        switch v {
        case .facts: return base + rules
        case .leads:
            return base + rules + " Use the notes about its sights to say what makes this route worth taking,"
                + " in your own words. Do not just list the sights."
        case .titleOnly:
            return "You help a tourist in Japan choose between walking routes that share the same start and destination. "
                + "Write only a title of two to five words that captures what sets this route apart, using only the facts given."
                + " No numbers. Do not use filler words such as scenic, beautiful, rich, serene or charming."
        case .titleAnchored, .titleTop2:
            return "You help a tourist in Japan choose between walking routes that share the same start and destination. "
                + "Write only a title of two to five words. "
                + (direct ? "This is the most direct route: say so in the title."
                          : "Build the title around the most famous sight this route adds, by name.")
                + " No numbers. Do not use filler words such as scenic, beautiful, rich, serene, cultural or historical."
        case .contrast, .contrastT2, .guarded, .addsOnly: return base + contrast + rules
        case .blurbOnly: return base + contrast + " Write one or two sentences only." + rules
        case .fewShot:
            return base + contrast + rules + " Example, for a different city: the facts \"Sights passed in order: "
                + "Nishiki Market (market, famous); Nijo Castle (castle, famous). Compared with the shorter route it adds: "
                + "Nijo Castle.\" give the title \"Nijo Castle detour\" and the text \"Swings past the moats and gates of "
                + "Nijo Castle after the food stalls of Nishiki Market.\""
        }
    }

    /// Names the few-shot example uses, so the scorer can catch them being copied.
    public static let exampleNames = ["Nishiki Market", "Nijo Castle"]

    public static func prompt(for o: WalkOption, variant v: Variant, context c: Context) -> String {
        func described(_ f: SightFact) -> String { "\(f.name) (\(f.kind)\(f.famous ? ", famous" : ""))" }
        if v == .addsOnly {
            var s = "Route from \(c.from) to \(c.to)."
            if o.isDirect {
                s += " This is the most direct route. It passes: " + (o.tier1.isEmpty ? "no sights of note" : o.tier1.map(described).joined(separator: "; ")) + "."
            } else {
                let added = o.tier1.filter { o.adds.contains($0.name) }
                s += " Compared with the shorter route it adds: " + (added.isEmpty ? "nothing new" : added.map(described).joined(separator: "; ")) + "."
                if !o.drops.isEmpty { s += " It no longer passes: " + o.drops.joined(separator: "; ") + "." }
            }
            return s
        }
        let shown = o.tier1.prefix(12).map(described)
        var s = "Route from \(c.from) to \(c.to). Sights passed in order: "
            + (shown.isEmpty ? "none of note" : shown.joined(separator: "; ") + (o.tier1.count > 12 ? "; and others" : "")) + "."
        if v == .leads {
            let notes = o.tier1.compactMap { f in c.leads[f.id].map { "\(f.name): \($0)" } }
            if !notes.isEmpty { s += " Notes about its sights: " + notes.joined(separator: " ") }
            return s
        }
        guard v != .facts, v != .titleOnly else { return s }
        if v == .titleTop2 {
            // Round 5: only the two best-known additions — with all of them the model strung the
            // names into the title ("Kanazawa Castle Park + Oyama-jinja Shrine + Shiinoki + …").
            if o.isDirect { return "Route from \(c.from) to \(c.to). This is the most direct route." }
            let top = o.tier1.filter { o.adds.contains($0.name) }.sorted { $0.fame > $1.fame }.prefix(2).map(described)
            return "Route from \(c.from) to \(c.to). Compared with the shorter route, its best-known new sights are: "
                + (top.isEmpty ? "none" : top.joined(separator: "; ")) + "."
        }
        if v == .titleAnchored {
            if o.isDirect { return s + " This is the most direct route." }
            // Best known first: with no "famous" sight the model titles the walk after the first one
            // listed (round 4: "Kanazawa City Ashigaru Museum" for the Nagamachi samurai walk).
            let added = o.tier1.filter { o.adds.contains($0.name) }.sorted { $0.fame > $1.fame }.map(described)
            return s + " Compared with the shorter route it adds: " + (added.isEmpty ? "nothing new" : added.joined(separator: "; ")) + "."
        }
        if o.isDirect {
            s += " This is the most direct route."
        } else {
            s += " Compared with the shorter route it adds: " + (o.adds.isEmpty ? "nothing new" : o.adds.joined(separator: "; "))
            if !o.drops.isEmpty { s += ". It no longer passes: " + o.drops.joined(separator: "; ") }
            s += "."
        }
        if v == .contrastT2 {
            let parts = o.tier2Kinds.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { k, n in
                n == 1 ? "a \(k)" : (n == 2 ? "two \(plural(k))" : "several \(plural(k))")
            }
            if !parts.isEmpty { s += " Smaller places along it: " + parts.joined(separator: ", ") + "." }
        }
        return s
    }

    static func plural(_ k: String) -> String {
        k.hasSuffix("s") || k.hasSuffix("sh") || k.hasSuffix("ch") ? k + "es" : (k.hasSuffix("y") ? String(k.dropLast()) + "ies" : k + "s")
    }

    /// The title when the model writes none (variant D, or no Apple Intelligence).
    public static func codeTitle(_ o: WalkOption) -> String {
        if o.isDirect { return "Direct" }
        let a = o.adds.isEmpty ? o.tier1.map(\.name) : o.adds
        guard !a.isEmpty else { return "Different streets" }
        return "Adds " + a.prefix(3).joined(separator: ", ") + (a.count > 3 ? "…" : "")
    }

    /// Code-made titles for the `.anyOf` fallback when the regex guide is unsupported.
    public static func candidateTitles(_ o: WalkOption) -> [String] {
        if o.isDirect { return ["Direct", "The direct way", "Straight there"] }
        guard let first = o.adds.first ?? o.tier1.first?.name else { return ["Different streets"] }
        return ["Via \(first)", "\(first) detour", "Past \(first)", codeTitle(o)]
    }
}

// MARK: - Scorer

/// What a good blurb is, as checks a machine can run (the experiment's judge, LEARNINGS §8).
public enum WalkBlurbScore {
    public enum Check: String, CaseIterable, Sendable {
        case noNumbers, titleLength, namesOne, noForeignSight, noFiller, noFalseComparison, notAList, specific
    }

    /// Words that don't tell one walk from another (round 4: "Cultural and Historical Trail" passed
    /// every other check and named nothing).
    static let vague: Set<String> = ["park", "parks", "shrine", "shrines", "temple", "temples", "museum", "museums", "house",
                                     "district", "garden", "hall", "kanazawa", "city", "jinja", "cultural", "complex",
                                     "historic", "historical", "heritage", "trail", "walk", "route", "tour", "shinto",
                                     "japanese", "station", "ryokan", "murataya"]

    /// Round 2 added the filler round 1 produced: rich, serene, tranquil, iconic, unique, journey, spiritual, comprehensive.
    public static let filler: Set<String> = ["scenic", "beautiful", "enjoy", "experience", "peaceful", "bustling",
                                              "deeper", "escape", "vibrant", "charming", "stunning", "breathtaking",
                                              "rich", "serene", "tranquil", "iconic", "unique", "journey", "spiritual", "comprehensive"]

    public static func check(_ b: WalkBlurbText, option o: WalkOption, allSightNames: [String]) -> [Check: Bool] {
        let both = (b.title + " " + b.text)
        let lower = both.lowercased()
        let onWalk = o.tier1.map(\.name) + o.tier2Names
        var r: [Check: Bool] = [:]

        var stripped = both
        for n in onWalk.sorted(by: { $0.count > $1.count }) { stripped = stripped.replacingOccurrences(of: n, with: "") }
        r[.noNumbers] = !stripped.contains { $0.isNumber }

        // Round 2: "route"/"walk" in a title is allowed ("Shinto Shrine Trail" is a fine title), and a
        // code-written title (variant D, or no model) isn't the model's to fail.
        let words = b.title.split(whereSeparator: \.isWhitespace)
        r[.titleLength] = b.title == WalkFacts.codeTitle(o) || ((2...6).contains(words.count) && !b.title.hasSuffix("."))

        let named = o.isDirect ? ["direct"] + o.tier1.map(\.name) : (o.adds.isEmpty ? o.tier1.map(\.name) : o.adds)
        // A title alone (variant T) is judged on its own checks; it needn't name a sight.
        r[.namesOne] = b.text.isEmpty || named.contains { mentions(lower, $0) }

        // Round 4: the title must tell this walk from the others — a distinctive word of what it adds.
        let titleWords = Set(b.title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        if b.title == WalkFacts.codeTitle(o) {
            r[.specific] = true
        } else if o.isDirect {
            r[.specific] = titleWords.contains("direct") || titleWords.contains("straight") || titleWords.contains("fastest")
        } else {
            let source: [String] = o.adds.isEmpty ? o.tier1.map(\.name) : o.adds
            var distinctive = Set<String>()
            for name in source { for w in wordsOf(name) where w.count >= 4 && !vague.contains(w) { distinctive.insert(w) } }
            let tw = Set(titleWords.map(stem))
            r[.specific] = !tw.isDisjoint(with: distinctive)
        }

        // Round 3: a sentence that restates the sight list adds nothing — the sheet shows the list.
        let listed = o.tier1.filter { mentions(b.text.lowercased(), $0.name) }.count
        r[.notAList] = o.tier1.count < 3 || listed < max(3, Int((0.75 * Double(o.tier1.count)).rounded(.up)))

        // Saying what a walk no longer passes is fair; naming anything else off the walk is not.
        let allowed = onWalk + o.drops
        let onKeys = allowed.map { $0.lowercased() }
        let foreign = Set(allSightNames).subtracting(allowed).filter { f in
            let c = core(f).lowercased()
            let key = places.contains(c) ? f.lowercased() : c
            return key.count >= 5 && !onKeys.contains { $0.contains(key) }
        }
        r[.noForeignSight] = !foreign.contains { mentions(lower, $0) }

        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        r[.noFiller] = tokens.isDisjoint(with: filler)

        // Round 3: size and age comparisons are never in the facts ("larger than Chuo Park").
        let invented = !tokens.isDisjoint(with: ["larger", "bigger", "smaller", "older", "newer", "oldest", "largest", "biggest"])
        if invented {
            r[.noFalseComparison] = false
        } else if o.isDirect {
            r[.noFalseComparison] = !(tokens.contains("longer") || tokens.contains("adds") || tokens.contains("detour"))
        } else if o.extraSeconds > 30 {
            r[.noFalseComparison] = !(tokens.contains("shorter") || tokens.contains("quicker") || tokens.contains("faster"))
        } else {
            r[.noFalseComparison] = true
        }
        return r
    }

    static func stem(_ w: String) -> String { w.hasSuffix("s") && w.count > 4 ? String(w.dropLast()) : w }
    static func wordsOf(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map { stem(String($0)) }
    }

    public static func passes(_ r: [Check: Bool]) -> Bool { Check.allCases.allSatisfy { r[$0] ?? false } }

    /// The runtime gate (round 5): the checks the app can run on a model title before showing it.
    /// A title that fails is retried once with sampling, then dropped — never shown.
    public static func titleIsShowable(_ b: WalkBlurbText, option o: WalkOption, allSightNames: [String]) -> Bool {
        let r = check(WalkBlurbText(title: b.title, text: ""), option: o, allSightNames: allSightNames)
        return passes(r)
    }

    public static func distinctTitles(_ titles: [String]) -> Bool {
        Set(titles.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }).count == titles.count
    }

    /// A name counts as mentioned if its distinctive part is: "Kenroku-en" for "Kenroku-en Park".
    static func mentions(_ lowerText: String, _ name: String) -> Bool {
        let c = core(name).lowercased()
        if lowerText.contains(name.lowercased()) { return true }
        // A core that is just the city ("Kanazawa Castle Park" → "Kanazawa") is not this sight.
        return c.count >= 4 && !places.contains(c) && lowerText.contains(c)
    }

    static let places: Set<String> = ["kanazawa", "ishikawa", "japan", "kyoto", "tokyo"]

    static let generic: Set<String> = ["park", "shrine", "temple", "museum", "house", "district", "garden", "hall", "gate",
                                       "castle", "residence", "market", "of", "the", "kanazawa"]

    /// Drop trailing generic words and ", Kanazawa"-style suffixes.
    static func core(_ name: String) -> String {
        var n = name.split(separator: ",").first.map(String.init) ?? name
        var words = n.split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last, generic.contains(last.lowercased()) { words.removeLast() }
        n = words.joined(separator: " ")
        return n
    }
}
