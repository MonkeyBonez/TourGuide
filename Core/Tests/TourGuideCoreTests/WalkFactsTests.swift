import XCTest
@testable import TourGuideCore

/// PRD §8.13: the distinct walks, their facts, and the scorer the prompt experiment is judged by.
final class WalkFactsTests: XCTestCase {
    static let walks = try! WalkFacts.distinctWalks(session: Kanazawa.session, maxSlack: 0.5)
    static let ctx = WalkFacts.context(session: Kanazawa.session)

    func testDistinctWalksOnTheFixture() {
        let w = Self.walks
        XCTAssertEqual(w.count, 4)
        for (got, want) in zip(w.map(\.slack), [0, 0.02, 0.18, 0.361]) { XCTAssertEqual(got, want, accuracy: 0.001) }
        XCTAssertEqual(w.map { $0.tier1Ids.count }, [1, 6, 6, 8])
        for (got, want) in zip(w.map(\.metres), [2941.0, 2997, 3464, 3917]) { XCTAssertEqual(got, want, accuracy: 0.5) }
        XCTAssertEqual(w.map(\.isDirect), [true, false, false, false])
        XCTAssertEqual(w[0].tier1.map(\.name), ["Hiraokano Shrine"], "the Wikidata label stands in for 平岡野神社")
        XCTAssertEqual(w[3].adds, ["Kenroku-en Park", "Ishiura Shrine", "21st Century Museum of Contemporary Art"])
        XCTAssertEqual(w[3].drops, ["Chuo Park"])
        XCTAssertTrue(w[1].adds.contains("Nomura Samurai House"))
        XCTAssertEqual(w[1].tier1.filter { $0.name.hasPrefix("Nagamachi Samurai") }.count, 1, "the two Nagamachi districts read as one")
        XCTAssertTrue(w[3].tier1.first { $0.name == "Kenroku-en Park" }!.famous)
        XCTAssertEqual(Set(w.map(\.id)).count, 4)
    }

    func testPromptsCarryNoNumbersOutsideNames() {
        for v in WalkFacts.Variant.allCases {
            XCTAssertFalse(WalkFacts.instructions(v).contains { $0.isNumber }, v.label)
            for w in Self.walks {
                var p = WalkFacts.prompt(for: w, variant: v, context: Self.ctx)
                for n in w.tier1.map(\.name) + w.drops { p = p.replacingOccurrences(of: n, with: "") }
                XCTAssertFalse(p.contains { $0.isNumber }, "\(v.label): \(p)")
            }
        }
    }

    func testContrastIsComputedNotAsked() {
        let p = WalkFacts.prompt(for: Self.walks[3], variant: .contrast, context: Self.ctx)
        XCTAssertTrue(p.contains("it adds: Kenroku-en Park; Ishiura Shrine; 21st Century Museum of Contemporary Art."), p)
        XCTAssertTrue(p.contains("It no longer passes: Chuo Park."), p)
        XCTAssertTrue(WalkFacts.prompt(for: Self.walks[0], variant: .contrast, context: Self.ctx).hasSuffix("This is the most direct route."))
        XCTAssertFalse(WalkFacts.prompt(for: Self.walks[3], variant: .facts, context: Self.ctx).contains("adds"))
        XCTAssertTrue(WalkFacts.prompt(for: Self.walks[1], variant: .contrastT2, context: Self.ctx).contains("Smaller places along it:"))
    }

    /// The shipped prompts, pinned: a wording change is a re-measure (`tgtool describe --matrix`),
    /// like `expected_table.txt`. Record with TG_RECORD_PROMPTS=1.
    func testShippedPromptGolden() throws {
        let v = WalkFacts.chosen.0
        var out = "variant \(v.rawValue) · sampling \(WalkFacts.chosen.1) · promptVersion \(WalkFacts.promptVersion)\n"
        out += "\n[instructions, direct]\n" + WalkFacts.instructions(v, direct: true)
        out += "\n\n[instructions]\n" + WalkFacts.instructions(v, direct: false)
        for (i, w) in Self.walks.enumerated() {
            out += "\n\n[walk \(i + 1)]\n" + WalkFacts.prompt(for: w, variant: v, context: Self.ctx)
        }
        out += "\n"
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/kanazawa/expected_prompts.txt")
        if ProcessInfo.processInfo.environment["TG_RECORD_PROMPTS"] == "1" { try out.write(to: src, atomically: true, encoding: .utf8) }
        XCTAssertEqual(out, try String(contentsOf: src, encoding: .utf8))
    }

    /// Round 5 winner's prompts carry two best-known additions, fame first.
    func testTop2PromptsNameTheBestKnown() {
        let p = WalkFacts.prompt(for: Self.walks[3], variant: .titleTop2, context: Self.ctx)
        XCTAssertTrue(p.contains("best-known new sights are: Kenroku-en Park (park, famous); 21st Century Museum of Contemporary Art (museum, famous)."), p)
        XCTAssertFalse(p.contains("Ishiura"))
        XCTAssertTrue(WalkFacts.prompt(for: Self.walks[1], variant: .titleTop2, context: Self.ctx).contains("Nomura Samurai House"))
    }

    /// The runtime gate keeps the titles the experiment rejected off the screen.
    func testGate() {
        func ok(_ t: String, _ i: Int) -> Bool {
            WalkBlurbScore.titleIsShowable(WalkBlurbText(title: t, text: ""), option: Self.walks[i], allSightNames: Self.ctx.allSightNames)
        }
        XCTAssertTrue(ok("Direct Route", 0))
        XCTAssertTrue(ok("Samurai Heritage Trail", 1))
        XCTAssertTrue(ok("Kenroku-en and Museum Walk", 3))
        XCTAssertFalse(ok("Nomura Samurai House and Nagamachi Samurais District", 1), "too long")
        XCTAssertFalse(ok("Cultural and Historical Trail", 3), "names nothing this walk adds")
        XCTAssertFalse(ok("Shinto Shrine Walk", 0), "the direct walk's title must say direct")
        XCTAssertFalse(ok("Spiritual Trail", 2), "filler")
    }

    func testCodeTitles() {
        XCTAssertEqual(WalkFacts.codeTitle(Self.walks[0]), "Direct")
        XCTAssertEqual(WalkFacts.codeTitle(Self.walks[3]), "Adds Kenroku-en Park, Ishiura Shrine, 21st Century Museum of Contemporary Art")
    }

    func fails(_ title: String, _ text: String, walk: Int) -> Set<WalkBlurbScore.Check> {
        let r = WalkBlurbScore.check(WalkBlurbText(title: title, text: text), option: Self.walks[walk], allSightNames: Self.ctx.allSightNames)
        return Set(r.filter { !$0.value }.map(\.key))
    }

    /// The bad outputs measured on 6 Oct 2026 each fail the check meant for them.
    func testScorerCatchesTheMeasuredFailures() {
        XCTAssertTrue(fails("Route 3 is longer and takes 6 minutes longer than Route 1.", "Route 3 is longer.", walk: 2)
            .isSuperset(of: [.noNumbers, .titleLength]))
        XCTAssertTrue(fails("Samurai heritage", "Pass Nomura Samurai House. Route 2 adds 36 minutes and 3.0 km.", walk: 1).contains(.noNumbers))
        XCTAssertTrue(fails("Kenroku-en Park and Museum", "Visits Kenroku-en Park. It is shorter than the previous route.", walk: 3)
            .contains(.noFalseComparison))
        XCTAssertTrue(fails("Castle park and shrines", "Past Oyama-jinja Shrine; it avoids the bustling city streets.", walk: 2).contains(.noFiller))
        XCTAssertTrue(fails("Samurai lanes and temple gates", "Short walk with samurai houses and temples.", walk: 0).contains(.namesOne),
                      "the copied guide example on the direct walk names nothing it passes")
        XCTAssertTrue(fails("Direct to the ryokan", "The direct way, past Kenroku-en Park.", walk: 0).contains(.noForeignSight))
        XCTAssertTrue(fails("A short walk to a shrine.", "The direct way past Hiraokano Shrine.", walk: 0).contains(.titleLength))
    }

    func testScorerPassesGoodBlurbs() {
        XCTAssertEqual(fails("The Kenroku-en loop", "Adds Kenroku-en Park, Ishiura Shrine and the 21st Century Museum of Contemporary Art, and skips Chuo Park.", walk: 3), [])
        XCTAssertEqual(fails("Straight down the avenue", "The direct way, past Hiraokano Shrine.", walk: 0), [])
        XCTAssertEqual(fails("Through the samurai quarter", "Turns west through the Nagamachi lanes, past the Nomura Samurai House.", walk: 1), [])
        XCTAssertTrue(WalkBlurbScore.distinctTitles(["Direct", "Samurai quarter", "Castle and Oyama"]))
        XCTAssertFalse(WalkBlurbScore.distinctTitles(["Castle walk", "castle walk "]))
    }
}
