# Learnings

The running record of what building Tour Guide taught us: data-source verdicts, measured
effects, wrong assumptions. Prefer a measured number and name the tool that produced it.

## 1. The sun router as an interest router (Kanazawa, 6 Oct 2026)

Carried over from Like Water `LEARNINGS.md` §15 — measured with a scratch compare tool, now
`tgtool route`:

executable against `Engine/` (not added to the repo; the write-up sits beside the PRD):

- **The router needs no change to score something other than sun.** A one-slot
  `SunTimeline(constant:)` carrying an interest score per corridor edge, `sunWeight` 1, and the
  slider as corridor slack gives a time-vs-interest walk. Direct 2941 m / 35.6 min; slack 0.1
  bends west through Nagamachi for +0.2 min; 0.2 bends east past Oyama Shrine and the castle
  park for +6.1 min; 0.5 reaches Kenrokuen and the 21st Century Museum for +11.6 min. Corridor +
  route: 0.1 ms (130 edges) to 18.5 ms (9,440 edges). Crossings kept full cost, as in §11.
- **An in-memory `PedestrianGraph` from one Overpass query is enough for a corridor.** The
  walk-filter ways of a 3.4 × 3.9 km box (18,681 elements, 19 s) → 13,567 nodes / 16,289 edges
  through the convenience init, pipeline edge flags, no sidewalk synthesis. The walking/straight-
  line factor was 1.40, so a fetch box has to be the slack ellipse, not a fixed buffer: a 400 m
  buffer held 11 of 54 Tier-1 sights and missed the castle (681 m off the line) and Kenrokuen (856 m).
- **Interest from areas must be measured to the polygon edge, not the centroid.** Centroid
  scoring gave the castle park 0 edges and Kenrokuen 11, and the slider went flat (one route for
  slack 0.1–0.5); polygon-edge scoring gave 713 and 985 and the bends above. The pipeline's
  `interest_scores()` uses geometry already; anything that reimplements it per-point will miss this.
- **A score cap that saturates kills the slider.** `score = min(1, interest/cap)`: cap 5–10
  saturated every scored edge, the route stopped changing after slack 0.3 and Kenrokuen (24
  language editions) stayed "reachable but outscored"; cap 20 let fame differences through.
- **Public Overpass and Wikidata are not a runtime you can lean on.** overpass-api.de 504/406,
  two other mirrors silent for 60–90 s, only maps.mail.ru answered; the real query 504'd twice
  before succeeding (2 min 27 s). Wikidata SPARQL (240 items with coordinates in the box, 0.8 s)
  and `wbgetentities` were fine until `wbsearchentities` 429'd the IP. Our bundle rule stands for
  the apps here; the Tour Guide's live fetch needs mirror rotation and a cache.

- **Ground truth.** Slack 0.1 is the walk the owner took in February 2025 (west through
  Nagamachi, stopping at the temples and the Nomura house). The temples are Tier 2; the
  slider's useful range is concentrated at its low end.
- **Tiering.** The OSM `wikidata` tag alone is a weak Tier-1 bridge (47 of 519 POIs). A Wikidata
  coordinate-box SPARQL query matched by name, then a jawiki/enwiki title lookup, recovered the
  rest. The grounds take the fame of the most famous thing inside them (Kanazawa Castle, 20
  languages, inside a 1-language park item). `out tags center geom` returns no `center` for
  ways/relations — take the bounds midpoint or lose every area POI.
- **Translation.** Apple's on-device framework: 46 strings in 1.7 s after a 4.5-minute language
  download that needs a window. Leads read well; name readings slip (白髯 → "Shiraku").

## 2. Porting the prototype to Swift (6 Oct 2026)

- **The port reproduces the measurement exactly.** `tgtool route kanazawa` prints the
  prototype's table line for line (`scripts/measure.sh` diffs it, timings and tag order
  excluded): 2941 / 3012 / 3483 / 3483 / 3917 m, 1 / 6 / 6 / 6 / 8 Tier-1. The same walking-order
  card ids and positions as the prototype's `cards.json` (`TourRouterTests.testCardsMatchThePrototype`).
- **Package tools 5.9 cannot say `.iOS(.v18)`**; Core is tools 6.0 with `swiftLanguageModes: [.v5]`.
- **Swift dictionary order is per process.** The prototype printed `tags` in random order, so the
  golden comparison ignores the tags column; `tgtool` now sorts them.
- **Debug-build cost.** Building the Kanazawa session (graph + scoring 328 sights × 16,289 edges
  + labels) and five routes runs in ~1.9 s in a debug test build; slack 0.5 alone is 0.23 s debug,
  18.5 ms release.

## 3. The live pipeline in Swift (6 Oct 2026, `tgtool fetch`)

- **One live fetch, A → B to a tiered box, 21 s** on the first try (maps.mail.ru answered;
  Overpass 18.4 s for 2.5 MB, Wikidata tag + box + title bridges 2.5 s). Same result as the
  prototype: 519 POIs, 54 Tier 1, 4,595 walk ways, 13,567 nodes; `tgtool route` on the live box
  prints the golden table. The second fetch is a disk-cache hit in 0.04 s.
- **The Swift matcher equals the prototype on all 519 POIs** (`WikidataMatcherTests`): tag 46,
  box 14, tag-via-child 4, box-via-child 2, 97 parents, 2 duplicates, 53 Tier 1 before the title
  bridge (54 after, Omicho).
- **Box-bridge fame uses SPARQL `wikibase:sitelinks`**, tag-bridge fame uses `wbgetentities`
  sitelinks minus commons; the prototype mixed them and the golden numbers depend on it. Kept.
- **Title-bridge locality without a hard-coded city:** P131 values of the tag-bridged entities.
- **Cards from the free sources** (`tgtool cards kanazawa --slacks 0.1,0.5`): 40 distinct sights,
  12 article leads (5 en, 7 ja), 13 photos. 広坂緑地 shows the Shiinoki Cultural Complex lead —
  the park took its child's item; correct by the rule, odd on a card.
- **A 200 can carry an Overpass runtime error** (`"remark": "runtime error…"`); the client treats
  it as a failed mirror.

## 4. The app on the simulator (6 Oct 2026, iPhone 17 Pro, iOS 26.0)

- **Kanazawa end to end in the app.** Bundled fixture: session build (graph + interest +
  labels) 544–564 ms in a Debug build, route 67 ms (slack 0.1) to 245 ms (0.5) in Debug. Live
  (no fixture): the in-app fetch reached a route at slack 0.2 = 42 min · 3.5 km · +6 min, the
  golden numbers, in roughly a minute while maps.mail.ru was slow (18 s for a one-node probe).
- **Per-mirror timeout 180 s was too patient**: a hung mirror would hold the banner for 3 min
  before rotating. Now 90 s per request, 150 s per resource; the real query takes ~18 s.
- **`LazyHStack` hides off-screen cards from accessibility**, so UI tests could not see card 3+.
  The row is at most ~10 cards: plain `HStack`.
- **The fixture path must honour the requested ends.** The demo box carries Murataya as its
  end; a UI test sending the destination into the sea still routed to Murataya until the app
  overwrote the box's start/end — now it's the off-graph banner, as on a live fetch.
- **The direct route passes one Tier-1 sight** (平岡野神社, 0 languages, OSM-tagged), so the left
  end reads "1 sight · direct", not zero.
- **Dropped SwiftOpenAI** (≈20 transitive packages: NIO, async-http-client) for an 80-line
  Chat Completions client in Core on the shared `HTTPTransport`; request shape and error
  mapping are unit-tested offline. The key is only ever in the Authorization header.

## 5. Apple Maps knows most of the temples (PRD §8.10, 6 Oct 2026)

`MKLocalSearch` on the OSM name (local, then English) within 300 m, nearest item kept if
≤ 150 m — the Place Card sheet's lookup — for the 40 sights on the slack 0.1 and 0.5 walks:
**22 of 40 found.** The Tier-2 temples the owner stopped at are there with English names and
phones: 専光寺 → Senko-ji Temple (5 m), 福念寺 → Fukunen-ji Temple (3 m), 仁隋寺 → Ninzui Temple;
also Nomura-ke Samurai Residence, Ozaki, Ishiura, Oyama, Kenrokuen. Misses: 光善寺, 照教寺,
白髯神社, the castle park and the 21st Century Museum (name mismatch: Apple's items are named
differently), and street-name memorials. Some hits are wrong things (武蔵ヶ辻小緑地 → a bus stop,
広坂緑地 at 113 m): the 150 m guard is loose for small parks. Apple's English names are a better
source than the translator for Tier-2 names (Senko-ji vs the translator's "Gokatayama Senko-ji").
Hours and photos aren't exposed by `MKMapItem`; they show only inside `MKMapItemDetailViewController`.

Mechanics: a command-line MapKit (or Translation) call blocked on a semaphore deadlocks — the
callbacks need the main run loop; use `RunLoop.main.run()` and `exit` from the task.

## 6. Release and phone (6 Oct 2026)

- Release build carries all five usage strings (they're in `project.yml` base settings), the
  privacy manifest and the icon; a signed Release archive builds (team FMDJTXM4W7).
- `xcodebuild -destination id=` wants the hardware UDID, not the CoreDevice identifier that
  `devicectl` prints; `scripts/install_phone.sh` builds for `generic/platform=iOS` and installs
  with devicectl. Installed and launched on the owner's iPhone 14 Pro (iOS 27.0.1).

## 7. Finishing V0: slider flip, highlight, fastest path, Apple names (6 Oct 2026)

**Slider.** The owner flipped it: left = most sights, right = direct. The square law
(`SliderLaw`: slack = max × (1 − p)²) puts slack 0.1, the owner's walk, at p 0.553 instead of
0.8; the right half now spans slack 0–0.125 in ten 0.05 steps (a linear slider gave it 2.5).
`slack` stays the stored value; the slider binds to a derived position, so persistence, launch
arguments and `setMaxSlack` didn't change. Tests: `SliderLawTests`, `testSliderRightEndIsDirect`,
`testNagamachiWalkSitsMidSlider`.

**Highlight on card tap.** The OSM rings were already on every area POI (the parser keeps them for
the polygon viewing distance), so outlining the grounds needed no new data: Kenroku-en, the castle
park and Oyama outline; Nomura (a node) gets a 60 m halo. MapKit pitfalls:
- `render` removes every overlay on each slider move, so the highlight is re-added at its end.
- Removing annotations fires `didDeselect`; without a `rendering` guard each slider move cleared
  the selection. The deselect handler must check the guard synchronously (a `Task` hop runs
  after the guard is reset).
- `MKAnnotationView` selection isn't in the accessibility tree, so the selected pin carries
  `accessibilityValue = "selected"`; the UI test (and VoiceOver) read that.

**Fastest path while loading** (`tgtool fast`):

| box | area vs ellipse | nodes | direct route |
|---|---|---|---|
| 150 m buffer | 14 % | 20 % | **2,387 m** — wrong start snap (46 m vs 27 m) |
| 200 m | 16 % | 23 % | 2,941 m, same nodes |
| 300 m (used) | 22 % | 30 % | 2,941 m, same nodes |

Kanazawa's direct route strays at most 221 m from the A→B line. Live, from the Mac:

| fetch | time |
|---|---|
| fast query, mirrors in turn | 15.5 s (mail.ru) · 23 s (mail.ru timed out at 20 s, then overpass-api.de) |
| fast query, hedged 3 s apart | 5.0 · 6.6 · 12.6 · 14.1 s |
| full corridor | 51 s (mail.ru 504 after 44 s, then overpass-api.de) |

Hedging is cheap for a small query and turns one hung mirror into a 3 s cost. Cancelled losers
surface as `URLError.cancelled` (-999) and must not be reported as mirror failures. The map fit
had to learn the panel's height: with only the fastest-path readout, the 470 pt bottom inset
left the route tiny at the top.

**The 150 m box found a real snapping bug.** Kanazawa Station snaps to its nearest node, 27 m
north, from which the direct route loops west round the station: 2,941 m / 35.6 min. A node 46 m
east gives 2,387 m / 28.8 min (`tgtool route` on the fixture with the start moved there). Nearest-
node snapping can cost minutes at a station; the measured walk factor 1.40 is partly this.
Not fixed here: it moves every golden number. In BACKLOG ("snap by cost").

**Apple names** (`tgtool applenames kanazawa`, guard = `AppleNameGuard`). The loose rule (nearest
≤ 150 m) had 19 of 40; the guard accepts 16, and only Japanese-named sights use it: 10 of 22 get
an Apple name. Rejected correctly: 武蔵ヶ辻小緑地 → a bus stop (category), 長町 → a parking lot,
照教寺 → "Shoen-ji Temple" 398 m away (a different temple), a sundial 143 m off. Two fixes came
from the run: Apple calls 木倉町広場 "Kiguracho Hiroba" (a plaza) with category Park, so a park
also accepts Apple's park category; and **MapKit throttles** (`MKError.loadingThrottled`, code 3)
after ~80 back-to-back searches, and again after ~50 at 1.2 s spacing. The store spaces lookups
1.5 s, and a throttled search goes back on the queue after 30 s instead of being cached as "Apple
has nothing".
