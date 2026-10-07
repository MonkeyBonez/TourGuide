# Backlog

Deferred work, with enough context to pick up cold. Done items move to LEARNINGS.md.

- **Hard waypoints** (PRD §8.8). The router's no-U-turn rule means a sight up a dead-end path is
  never passed (Kanazawa: 全性寺, Ishikawa Prefectural Museum of Art touch no street within 30 m).
  Trigger: a user taps such a pin. Effort: route A→sight→B as two corridor searches, M.
- **Live re-route per GPS fix.** V0 fixes A when the route is planned. LikeWater's
  `CorridorService` (labels cover rule, hysteresis via `RouteEngine.evaluate/shouldKeep`) is the
  pattern. Effort: M.
- **log(sitelinks) fame** (§8.12) instead of linear with cap 20. Measure with `tgtool route`.
- **Viewing distance by size** (§8.9): a castle is seen from further than a wayside shrine.
- **Free-roam audio callouts**, **sub-stops inside a complex**, **Apple Intelligence filter for
  modern shrines/memorials** (PRD §2 Out).
- **Sign in with ChatGPT** (M6), gated on OpenAI granting a client_id; the documented callback
  is loopback (desktop).
- **Scoring grid.** Scoring is a brute-force sight × edge loop (fine on Kanazawa). Add an edge
  grid if a phone takes > 2 s.
- **Walk titles on a real eligible iPhone.** The model ran only on the Mac (`tgtool describe`);
  the iOS 26 simulator reports `.available` then fails every call (ModelManagerError 1026, no
  model assets) and the owner's 14 Pro isn't eligible. Trigger: an iPhone 15 Pro or later. Check
  titles match the Mac's (greedy), latency per walk, and the gate's drop rate. Effort: S.
- **Walk titles: a second city.** The variant was chosen on Kanazawa's four walks only. Rerun
  `tgtool describe <box> --matrix --variants U,V` on another corridor before trusting 100 %.
- **Speak the chosen walk's title** (`TTSService` exists in Photo/). Effort: S.
- **Near-duplicate Tier-1 names** ("Nagamachi Samurais District" / "…Samurai District", Nomura ×3)
  are collapsed only for the prompt (`WalkFacts.dedupe`); fold them in `WikidataMatcher.dedupe`
  so cards and counts agree. Effort: S.
- **Wikidata labels that name a different thing.** The box bridge gave 広坂緑地 the label
  "Shiinoki Cultural Complex" and Chuo Park "Ishikawa Modern Literature Museum"; prompt names
  prefer OSM `name`, but the bridge's name match is loose for small parks. Effort: S.
- **Snap A and B by cost, not by distance.** Kanazawa Station snaps to the nearest graph node
  (27 m north), and the direct route from there loops west round the station: 2,941 m / 35.6
  min. From a node 46 m east it is 2,387 m / 28.8 min (`tgtool fast kanazawa --buffer 150`
  found it by accident; LEARNINGS §7). Fix: try the k nearest connected nodes (or the nearest
  edge's two ends) and keep the one with the least snap + route. It moves every golden number
  (`expected_table.txt`, the UI test readouts), so it is its own change with a re-measure.
  Trigger: now — it is a 7-minute error on the demo walk. Effort: S–M.
- **Fast path for diagonal walks.** The fastest-path box is axis-aligned; a diagonal A→B gets a
  box near the full ellipse's size. Use an oriented corridor (Overpass `poly:`) if a diagonal
  walk's fast fetch is slow. Effort: S.
