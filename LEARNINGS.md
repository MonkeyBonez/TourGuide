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
