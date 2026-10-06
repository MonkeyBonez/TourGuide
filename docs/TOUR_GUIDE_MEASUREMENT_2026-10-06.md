# Tour Guide — Kanazawa corridor measurement, 6 Oct 2026

The PRD §7 acceptance run: the Like Water Engine routing the test corridor with interest in
place of sun, measured the way `lwtool route --compare` measures sun. Numbers, then what they
change in the PRD.

## Setup

- Engine unchanged: `CorridorEngine.labels/corridor` + `RouteEngine.route`, with a one-slot
  constant `SunTimeline` carrying the interest score per corridor edge (`sunWeight` 1, so the
  effective weight is the router's 0.9 cap). Crossings keep full cost, as for sun.
- Graph: one Overpass query returns POIs and the walk network (`highway` ways with the osmnx
  walk filter the pipeline uses) → in-memory `PedestrianGraph` via the convenience init, pipeline
  edge flags, no sidewalk synthesis. 13,567 nodes, 16,289 edges, 383 crossings, largest
  component 13,406. A and B snap 27 m / 21 m.
- Pace: `PaceModel()` defaults (1.4 m/s, 12 s per crossing, no terrain).
- Scoring: each POI adds `weight` to every edge within viewing distance; `score = min(1,
  interest / cap)`. Tier 1 weight = 3 + Wikidata sitelinks; Tier 2 weight = 1.
- Tool: `tgmeasure` (a scratch SwiftPM executable depending on `Engine/`), plus three stdlib
  Python scripts: `fetch_box.py` (Overpass), `match_wikidata.py` (fame), `title_lookup.py`.
  Scratch copies live in this session's scratchpad; nothing was added to the repo.

## Result (polygon viewing distance 30 m, cap 20)

| slack | metres | min | +min | crossings | interest-s | T1 passed | T2 passed | corridor edges | ms |
|---|---|---|---|---|---|---|---|---|---|
| 0.0 | 2941 | 35.6 | 0.0 | 3 | 47 | 1 | 6 | 130 | 0.1 |
| 0.1 | 3012 | 35.9 | +0.2 | 0 | 184 | 6 | 14 | 3336 | 5.4 |
| 0.2 | 3483 | 41.7 | +6.1 | 1 | 693 | 6 | 15 | 4938 | 7.4 |
| 0.3 | 3483 | 41.7 | +6.1 | 1 | 693 | 6 | 15 | 6381 | 11.2 |
| 0.5 | 3917 | 47.2 | +11.6 | 3 | 1070 | 8 | 16 | 9440 | 18.5 |

Which streets, by slider position:

- 0.0: the direct route down the bus avenue. Passes one Tier-1 (平岡野神社, 0 langs) and six Tier-2.
- 0.1: bends **west through Nagamachi** for +77 m / +0.2 min: Nomura Samurai House, the
  Nagamachi district nodes, Maeda Tosanokami-ke Shiryokan. The bend emerged from the scoring.
- 0.2–0.3: bends **east** instead: Ozaki Shrine, Kanazawa Castle Park (20 langs), Oyama Shrine
  (10), 広坂緑地, Chuo Park. +6.1 min. Nagamachi is dropped; the router cannot afford both sides.
- 0.5: the full loop: Castle Park, Oyama, **Kenrokuen (24 langs)**, Ishiura Shrine, the 21st
  Century Museum (16). +11.6 min, 3917 m of a 4410 m bound.

Viewing distance 60 m (same cap): same shape, +1 to +3 Tier-1 per row, Tier-2 counts up 50 %
(9 / 21 / 22 / 22 / 25), 0.5 → 3893 m, 11 Tier-1. Only one sight touches no street at 60 m.

**Ground truth: the slack-0.1 route is the walk the owner took in February 2025**, chosen on
the day because it looked more interesting than the avenue. The stops that made it were the
Buddhist temples on the west side (専光寺, 光善寺, 福念寺 — all Tier 2 here, weight 1) and the
Nomura samurai house (Tier 1, 3 langs). Two things follow: the walk the product exists for costs
almost nothing in time on this corridor (+77 m, +0.2 min by the pace model), so the slider's
value is concentrated at its low end (§8.1); and Tier 2 is what the walker actually stopped for,
so it must be on the cards or pins even though it should not pull the route.

Expected list (PRD §7) at slack 0.5: ✓ Oyama, ✓ Kanazawa Castle, ✓ Kenrokuen. ✗ Nagamachi and
Nomura: passed at slack 0.1, outscored at 0.5 (their fame is 2–3 langs). ✗ Omicho Market: Tier 1
with 1 lang after the title lookup, 518 m off the line, outscored. ✗ Tsuzumi Gate: no Wikidata
item and no Wikipedia article in any language, so Tier 2 by every rule; it is at the start anyway.

## What the numbers change

1. **Fetch box = the slack ellipse, not 400 m.** Only 11 of 54 Tier-1 sights fall inside a 400 m
   buffer. Castle Park is 681 m off the straight line, Kenrokuen 856 m, both well inside the +50 %
   bound. Used: bbox of the ellipse with foci A and B and sum of distances ≤ L × (1 + slack) × 1.25
   (the 1.25 is the walking/straight-line factor; measured 1.40 here). 3.4 × 3.9 km, 18,681
   elements, 19 s when the mirror answered.
2. **The OSM `wikidata` tag is not enough as the Tier-1 bridge.** 47 of 519 POIs carry one, and
   the famous ones carry it on their *area* (Kenrokuen, the castle, Oyama's grounds), which
   `poi_corridor.py` dropped (bug, below). The station-front nodes (Tsuzumi, Nomura, Omicho) have
   none. Measured bridges: tag 47 → Wikidata coordinate-box query (SPARQL, 240 items with
   coordinates, 0.8 s) matched by name within 250 m or inside the polygon +15 → Japanese/English
   Wikipedia title lookup (`wbgetentities sites=jawiki`, 50 titles a call) +1 (Omicho), 42
   same-name items elsewhere correctly rejected by a 400 m / located-in-Kanazawa guard. The
   free-text search API (`wbsearchentities`) returns 429 after a handful of calls; abandoned.
3. **Viewing distance must be measured to the polygon edge for areas.** With centroids the Castle
   Park touches 0 edges and Kenrokuen 11; with polygon edges 713 and 985. With centroids the
   slider is flat: slack 0.1 to 0.5 all give the same 3010 m route. 30 m is fine once polygons
   are used; 60 m mostly adds Tier-2 noise.
4. **The grounds take the fame of the most famous thing inside them.** Kanazawa Castle (20 langs)
   sits inside Kanazawa Castle Park, which has its own 1-lang item; without the hand-up the park
   scored 4 and the route never went there. Buildings inside grounds fold like nodes (97 children
   folded; Oyama's gate and main hall into the shrine). Same-name duplicates within 60 m collapse
   (Nomura ×3).
5. **Cap ≈ 20, so fame differences survive.** Cap 5 or 10 saturates every scored edge, the slider
   goes flat after 0.3 and Kenrokuen is "reachable (3833 m via it) but outscored". Cap 20 is what
   produced the table above. Whether the score should be log(sitelinks) instead is open.
6. **Live Overpass is fragile.** overpass-api.de: 504 then 406; private.coffee and kumi: no answer
   in 60–90 s; only maps.mail.ru answered (14 s for a one-node probe). The real query 504'd twice
   and succeeded on the third try, 2 min 27 s wall. Wikidata SPARQL and `wbgetentities` were fine
   until the search API got the IP throttled. A release build needs mirror rotation and a cache;
   §8.2 stands: a failed fetch is a banner.
7. **Compute is not a concern.** Labels 0.9 ms; corridor + route 0.1 ms (slack 0) to 18.5 ms
   (slack 0.5, 9,440 corridor edges). Scoring 328 sights against 16k edges with polygons is under a
   second in release. Live recompute on every slider move is fine.
8. **Dead-end sights (§5 step 7, §8.8) are real here:** 全性寺 and the Ishikawa Prefectural Museum
   of Art touch no street within 30 m.

## Bugs in `poi_corridor.py`

- `out tags center geom` returns `geometry`/`bounds` but no `center` for ways and relations, so the
  `elif "center" in el` branch skips every area POI. That is why the first run found 1 Tier-1 in 63.
  Use the bounds midpoint (or compute the centroid) when `center` is absent.
- The W/E side label is inverted for a southbound corridor (the cross product's sign is "left of
  travel", which is east when walking south).

## Cards: what the free sources give (45 POIs on the four walks)

Wikipedia lead paragraph: 13 (5 English, 8 Japanese only). Photo (article thumbnail or Wikidata P18, embedded): 14.
Founding year (P571): 6. OSM detail tags on 19: `opening_hours` 7, `denomination` 5, `phone` 4,
`website` 3, `fee` 2. The 31 Tier-2 places have a name, a kind and at best a denomination. Apple's
Place Card (in-app only) is the untested candidate for the rest (PRD §8.10).

## Translation: Apple's on-device framework (6 Oct 2026)

46 Japanese strings (8 article leads, 38 names) through `TranslationSession` on this Mac: **1.7 s for
all 46** after a one-time 4.5-minute Japanese language download. Leads read well — Ozaki Shrine's
("enshrines Amaterasu Ōmikami, Tōshō Daigongen and the third lord of the Kaga Domain…") is
near-perfect; Ishiura's turns 旧社格は県社 into "the former company is a prefectural company".
Names: the kind words come through (Hiraokano Shrine, Fukunenji Temple, Ōtani Mausoleum, Old
Tamaru Town) but readings slip (白髯 → "Shiraku", 長町 → "Nagashi-cho", 仁隋寺 → "Rensui") and
用水 / 緑地 stay "water" / "Ryokuchi". Verdict: use it for leads and descriptions, flagged; for
names prefer OSM `name:en`, then a reading dictionary plus the kind from the tag.

Mechanics worth knowing: the framework hands out a session only through SwiftUI's
`.translationTask`; the download prompt is a sheet on that window, so there is no headless path
(a bare command-line `LanguageAvailability.status` call also deadlocks unless awaited on a running
main run loop). In the app this is free; for a script it means an AppKit shell with one window.

## To do

- In-app: Apple Place Card (`MKMapItemDetailViewController`) on a Tier-2 temple — hours, photos?
  Cannot be tested outside the app.
- In-app: wire the Translation framework to the cards as above; OSM `name:en` wins.
- Slider linearity / the right-end budget (§8.1): the table has the data for 0 / 0.1 / 0.2 / 0.5.
- Whether a Nagamachi-plus-castle route exists within +50 % if Nagamachi's fame is weighted up.
- The photo Q&A half of the PRD.
