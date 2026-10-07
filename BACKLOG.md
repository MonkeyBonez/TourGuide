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
- **V1: OpenAI describes the walks** (PRD §8.13, owner's call 6 Oct 2026). Why: the slider is
  abstract; the user is choosing between a few different walks. What: after the full load, sweep
  the slider (0.05 steps through `SliderLaw`), dedupe walks by their Tier-1 id set (Kanazawa → 4),
  one Chat Completions `json_object` call through `OpenAIClient` with each walk's minutes, extra
  minutes, km and sights in order → `[{slack, title, text}]`; "Compare walks" sheet beside the
  readout, tap a row → `setSlack`. Disk cache keyed by `TourPipeline.cacheKey(bbox)` + maxSlack +
  pace. Needs a saved key; no key or failure → button hidden. Tests offline: dedupe and prompt
  shape on the fixture, scripted reply parsing. Effort: M.
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
