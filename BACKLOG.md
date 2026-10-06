# Backlog

Deferred work, with enough context to pick up cold. Done items move to LEARNINGS.md.

- **Hard waypoints** (PRD §8.8). The router's no-U-turn rule means a sight up a dead-end path is
  never passed (Kanazawa: 全性寺, Ishikawa Prefectural Museum of Art touch no street within 30 m).
  Trigger: a user taps such a pin. Effort: route A→sight→B as two corridor searches, M.
- **Square-law slider** (§8.1). The owner's own walk is slack 0.1 (+0.2 min); the big loops are
  0.2–0.5. The low end needs the travel. Trigger: first on-device use. Effort: S.
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
- **Apple names for Tier-2 sights.** Apple Maps had 22 of 40 route sights with English names
  (LEARNINGS §5); use its name when found instead of translating. Tighten the 150 m guard for
  small parks. Effort: S.
