# Tour Guide — V0 PRD

Status: draft, Oct 2026. Builds on the Sun Map iOS repo.
Revised 6 Oct 2026: the route is a scored walk, not a chain of stops (§1, §3, §5).
Measured 6 Oct 2026 on the Kanazawa corridor (`TOUR_GUIDE_MEASUREMENT_2026-10-06.md`): the §4 and §5
defaults below are the ones that produced the owner's own February 2025 walk at slack 0.1.
Read `poi_corridor.py` and its `results/` output before building; the test run decides the tier thresholds below.

## 1. Job to be done

Keep the tourist in the moment. Two things a tourist wants when walking from A to B in a new city:

1. Get there the most interesting way, not the fastest way (temples in Japan, statues in Italy), when they are willing to spend the time.
   This is less about stops than about things to almost look at while walking. The route itself changes with the slider — which streets you walk — rather than just which stops are strung along a fixed route.
2. Understand what they are looking at, by pointing the camera at it, without breaking stride to type or search.

## 2. V0 scope

In:

- Interest-scored route from A to B, with a time-vs-interest slider that changes which streets the route takes.
- Photo Q&A: photo is the core input; voice question is optional, mic only, no typing.
- Inference through the user's own ChatGPT plan via Sign in with ChatGPT; API-key fallback.
- Live data from Overpass (POIs and the walk network for the corridor) and Wikidata on every route. No server, no proxy key, no backend.
- Routing is ours: the Engine's corridor and router with interest in place of sun (§5). No Apple or Google routing; neither can score streets, only return a shortest path between points.
- Client is open source (required for ChatGPT plan usage, see §6).

Out (V1 or later, do not build):

- Free-roam mode with proactive audio callouts while walking ("look to your right…"), AirPods-based.
- Apple Intelligence on-device pass to judge whether a POI is worth stopping for (e.g. filtering modern wayside shrines and memorials).
- Sub-stops inside a complex (individual halls, pagodas). V0 treats a complex as one stop.
- Indoor/museum mode; phone-streams-video-to-model (hacky V2).
- Google Places as a source.
- Precomputed or cached city data.
- POI weighting beyond the two tiers.
- Hard waypoints. Tapping a pin to force the route through a sight the scoring cannot reach (§5 step 7) is a follow-up, not V0.

## 3. Relationship to Sun Map

Same engine, same routing layer. Sun Map scores street segments by sun and the router trades time for sun inside the corridor. Tour Guide is the same mechanism with interest in place of sun: each edge gets an interest score from the POIs within viewing distance of it, and the router trades time for interest. The Engine already carries `edgeInterest` per edge and a corridor-bounded slider router (`RouteEngine`, cost = seconds × (1 − w × score)); Tour Guide substitutes the score source. Nothing in Sun Map's scoring changes.

## 4. POI data

### 4.1 Sources

**Overpass API** (OSM, free, no key). One query over the corridor bounding box, `out tags center geom`, matching any of:

```
historic=*
tourism=attraction|artwork|viewpoint|museum|gallery
amenity=place_of_worship   (keep religion=*)
building=temple|shrine|church|pagoda
```

Why `building=*` as well as `amenity`: mappers often tag the roof but not the function, and large temple complexes are mapped as grounds (`amenity=place_of_worship` area) containing halls (`building=temple|pagoda`). Querying both catches sloppily tagged temples and the halls inside a complex.

**Wikidata** (free, no key). Three bridges from an OSM element to its Wikidata item, tried in order; the OSM `wikidata` tag alone is not enough (Kanazawa: 47 of 519 POIs carry one, and Nomura house, Omicho and the station gate do not):

1. the element's `wikidata=*` tag;
2. one SPARQL query for every item with coordinates (P625) inside the fetch box (240 items, 0.8 s in Kanazawa), matched to an OSM element within 250 m or inside its polygon whose `name`/`name:en` equals the item's ja/en label (containment only when the shorter is ≥ 60 % of the longer: "Kanazawa" must not match "Kanazawa Catholic Church");
3. `wbgetentities sites=jawiki|enwiki` on the OSM name as a Wikipedia title, 50 a call, accepted only if the item's coordinate is within 400 m or it has no coordinate but is located in (P131) the city. Not the free-text search API: it rate-limits after a handful of calls.

Then `wbgetentities` with `props=labels|descriptions|sitelinks|claims` (P18 image, P571 inception), languages `en|ja`. Wikidata rather than English Wikipedia so places with only a Japanese or Italian article still count. A sight with no Wikidata item anywhere (the Tsuzumi Gate) stays Tier 2.

**Wikipedia REST summary** (free, no key) on the en, else ja, sitelink: the lead paragraph and a thumbnail for the card. **Wikimedia Commons** for the P18 photo when there is no article thumbnail.

**Apple Place Card, in-app only** (free, no key). `MKMapItem` plus `MKMapItemDetailViewController` (iOS 18) shows Apple's own hours, phone, website, photos and reviews for a tapped sight. This is the V0 answer for Tier-2 detail — a neighbourhood temple has no article anywhere, and OSM gives it a name and a denomination at best. It cannot be called from a script, so it is untested until the app exists (§8.10). Google Places was evaluated and is out for V0: Pro/Enterprise field tiers at $17–25 per 1k details plus $7 per 1k photos, a billing key that would ship inside an open-source client, and terms that bar showing Places content on a non-Google map.

Keep: `heritage=*`, `name`, `name:en`, `wikipedia`, `opening_hours`, `fee`, `website`, `phone`, `denomination`, `inscription`, `start_date`.

### 4.2 Tiers

| Tier | Rule | Role |
|---|---|---|
| 1 | has a Wikidata item (any of the three bridges in §4.1) | Must-see. Highest edge weight: the route bends toward streets these are visible from. Wikidata sitelink count (number of language editions) is the fame score that scales the weight: weight = 3 + sitelinks. |
| 2 | has `name`, no Wikidata item | Worth a glance. Weight 1: tips the balance between otherwise equal streets, never pulls the route on its own. Shown as pins when near the route, and on the cards — these are what the walker actually stops at (the Nagamachi temples, Feb 2025). |
| dropped | no `name` | Not shown. |

Rationale: Wikipedia/Wikidata is high precision, low recall (Japan has ~80k shrines; a few thousand have articles). Tier 2 recovers the named neighbourhood shrine without letting generic businesses in. An unnamed `historic=wayside_shrine` is a roadside marker.

### 4.3 Dedupe

If a node, or a smaller area (a hall, a gate, the castle building), sits inside a `place_of_worship`, `historic`, `park` or `garden` area (point-in-polygon on the way geometry; relation outer rings), attach it to that parent. The parent is the sight that scores edges and gets the card; the child is kept as data only (V1 sub-stops). **The parent takes the fame of the most famous thing inside it**: Kanazawa Castle (20 languages) sits inside Kanazawa Castle Park, whose own item has 1; without the hand-up the park scored 4 and the route never went there. Same-name duplicates within 60 m collapse to one (the Nomura house is mapped three times). Kanazawa: 97 children folded, 54 Tier-1 sights left.

Overpass note: `out tags center geom` returns `geometry`/`bounds` and no `center` for ways and relations. Take the bounds midpoint when `center` is absent, or every area POI — the castle, Kenrokuen, Oyama's grounds — is silently dropped (the bug in the first `poi_corridor.py` run).

### 4.4 POI record

```
id            osm type/id
name          name:en, else name
name_local    name
lat, lon      node coords or way/relation center
kind          subset of tags: historic, tourism, amenity, building, religion
wikidata      Q-id or null
wd_label, wd_description, wd_sitelinks, wd_enwiki_title
heritage
tier          1 | 2
weight        tier × fame; what the POI adds to each edge within viewing distance
parent        id of enclosing area, or null
dist_m        perpendicular distance to the A→B line
along         0–1 fraction along the A→B line
side          W | E of the line
```

## 5. Routing

1. User picks A and B (reuse Sun Map's A/B input).
2. Fetch box = the bounding box of the slack ellipse: foci A and B, sum of straight-line distances ≤ L × (1 + max slack) × 1.25 (1.25 is the walking/straight-line allowance; Kanazawa measured 1.40). Fixed for the session; the slider does not refetch. A 400 m buffer around the line was wrong: it held 11 of 54 Tier-1 sights and missed the castle park (681 m off the line) and Kenrokuen (856 m), both inside the +50 % bound. Kanazawa: 3.4 × 3.9 km, 18,681 elements, 19 s when a mirror answered. The routing corridor is the Engine's: every street reachable within direct × (1 + slack).
3. Fetch and tier POIs (§4). The same Overpass query also returns the walk network (highway ways) for the box.
4. Build the graph and score it. Walk ways → the Engine's in-memory `PedestrianGraph` using the pipeline's walkability rule, no sidewalk synthesis (Kanazawa: 13,567 nodes, 16,289 edges). Each POI adds its weight to every edge within viewing distance, **measured to the polygon edge for an area**, not its centroid: by centroid the castle park touched 0 streets and Kenrokuen 11, and the slider was flat from 0.1 to 0.5; by polygon edge 713 and 985. 30 m is right once polygons are used; 60 m mostly adds Tier-2 noise. Edge score = min(1, interest / 20). The cap matters: at 5 or 10 every scored edge saturates, a 24-language garden equals a 2-language museum, and the route stops changing after slack 0.3.
5. Slider, time vs interest = the corridor slack.
   - Left end: slack 0, the direct route.
   - Right end: a fixed maximum extra walking time; one constant, start at +50%.
   - In between: the router finds the walk with the most interest-seconds that still arrives within the budget.
   Crossings are never discounted for interest (Like Water LEARNINGS §11: discounting them made the route cross the street fifteen times to chase the score).
6. Route with the existing router, interest in place of sun. Recompute live on every slider move; it is milliseconds on a corridor, so nothing is precomputed.
7. Sights off the street. The router has a no-U-turn rule, so a sight up a dead-end path (a shrine 60 m off the street) is never "passed" and never bends the route. In V0 those stay as pins. Follow-up (§8.8): tapping a pin makes it a hard waypoint; that is the only case that needs waypoint machinery.

8. Fastest path first. The full fetch (the slack ellipse, every sight, Wikidata) takes 20 s to a few minutes on public Overpass. While it loads, show the fastest walk so the user has something to follow at once; the slider and cards appear only when the full corridor is ready. The fastest path is still ours: a first, small Overpass query for the walk network in a narrow box around the A→B line (the direct route needs no sights and a fraction of the data), routed at slack 0. When the full corridor arrives, the route is recomputed at the user's slider position and the slider is shown. If the full fetch fails, the fastest path stays on screen with the banner (§8.2).

### 5.1 Screen

One screen: a map with the route from A to B, the time-vs-interest slider, and a row of POI cards for the sights the current route passes. While the corridor loads, the screen shows only the fastest path and its time, with the loading banner; no slider and no cards until the full fetch is in (§5 step 8). Moving the slider changes the route — which streets — and the cards change with it: fewer sights toward the time end, more toward the interest end.

- One card per Tier-1 POI within viewing distance of the route, in walking order. Tier-2 POIs within viewing distance appear as secondary pins on the map, not as cards. POIs in the box but not within viewing distance of the route are pins too, so the user can see what the slider is not reaching.
- Card contents are TBD. The data available per sight is the POI record in §4.4 (name, kind, Wikidata label and description, language count, heritage status). Start with name, kind, and the Wikidata description; leave the layout simple so the fields can change after the test run.
- Tapping a card centers the map on that sight.

## 6. Photo Q&A

Reuse the camera+explain prototype already on GitHub; do not rebuild it.

- User takes a photo. Optionally holds the mic to ask a question. No text input anywhere.
- Request to the model: photo, lat/lon, and traveler context (current A/B, the nearest Tier-1/2 POI names, the voice transcript if any).
- With a question: answer that question ("why is this red?", "what is this fish?"). Without one: say what the thing is and why it matters, briefly.
- Model access: **Sign in with ChatGPT** (OAuth with PKCE, Responses API scopes). Eligible Plus/Pro users spend their own plan allowance; no client secret, no app-side API key. As of Oct 2026, plan usage is open to open-source partners and selected private clients, so the client ships open source. Fallback: user pastes an OpenAI API key in settings.
- Verify before building: Sign in with ChatGPT "Preview limitations" page, specifically whether image inputs are covered. If not, the fallback path is the V0 path.

## 7. Test corridor and acceptance

Kanazawa Station → Murataya Ryokan, 1-5-2 Katamachi, Kanazawa.
Approx. 36.5781, 136.6480 → 36.5597, 136.6534. About a 30-minute walk. The direct route follows the main bus avenue; the interesting route bends west through Nagamachi.

Ground truth: the owner walked this in February 2025 and took the route west through Nagamachi because it looked more interesting than the avenue, stopping at the Buddhist temples on the west side and the Nomura samurai house. Measured on 6 Oct 2026 that walk is the slack-0.1 route: +77 m and +0.2 min on the direct 2941 m / 35.6 min. Slack 0.2 bends east instead (Oyama Shrine, the castle park, +6.1 min); 0.5 reaches Kenrokuen and the 21st Century Museum (+11.6 min, 3917 m of the 4410 m bound).

Expected Tier 1, with what the data says:

- Tsuzumi Gate (station) — no Wikidata item or Wikipedia article in any language; Tier 2 by every rule, and at the start anyway.
- Omicho Market — Tier 1 through the ja title lookup, 1 language, 518 m off the line; never pulls the route.
- Oyama Shrine — 10 languages; passed at slack ≥ 0.2.
- Kanazawa Castle Park — 20 (via the castle inside it); passed at slack ≥ 0.2.
- Nagamachi samurai district / Nomura residence — 2–3 languages; passed at slack 0.1, outscored at ≥ 0.2.
- Kenrokuen — 24; passed at slack 0.5.

Acceptance for V0:

- The slack-0.1 route is the February 2025 walk: west through Nagamachi, past the Nomura house, with one card per Tier-1 sight in walking order and the temples as pins or cards.
- With the slider at the left end, the route equals the direct route; the only cards are whatever the direct route happens to pass.
- Moving right, the route reaches the castle park and Oyama, then Kenrokuen, each within the bound; any Tier-1 it does not pass is explained (dead-end path, §5 step 7 — 全性寺 and the Prefectural Museum of Art touch no street within 30 m; or outscored by fame).
- Measured, not eyeballed: a compare tool prints, for the direct route and a few slider positions, metres, minutes, sights passed and crossings, the way `lwtool route --compare` does for sun. The Nagamachi bend has to emerge from the scoring, not be placed by hand. (It did.)
- A photo of the Tsuzumi Gate with no question returns an explanation of what it is; the same photo with "why is it shaped like that?" answers that question.

## 8. Open questions (deferred, do not block V0)

1. Slider range: the maximum extra walking time at the right end, and whether the slider is linear in time. The measurement says the walk this app exists for sits at slack 0.1 (+0.2 min) and the big loops at 0.2–0.5 (+6 to +12 min), so the low end needs the resolution.
2. Live vs precomputed data. Measured 6 Oct 2026: overpass-api.de 504 then 406, two other mirrors silent for 60–90 s, only maps.mail.ru answered; the real query 504'd twice before succeeding (2 min 27 s wall). Wikidata SPARQL and `wbgetentities` fine; the search API 429s. Release needs mirror rotation and a cache. The walk network rides on the same fetch, so a failed fetch means no route at all; that is a banner, not a fallback route.
3. One stop per complex vs sub-stops for halls and pagodas.
4. Weighting POIs beyond two tiers; whether Apple Intelligence can filter modern shrines/memorials on device.
5. How Tier 2 is presented in V1 free-roam (audio callouts).
6. Whether Sign in with ChatGPT plan usage covers image inputs in preview.
7. What goes on a POI card beyond name, kind, and description (photo? distance? a one-line "why stop here"?).
8. Follow-up: hard waypoints for sights the scoring cannot reach. The router's no-U-turn rule means a sight up a dead-end path is never passed. Tapping its pin should make it a hard waypoint the route must visit; this is the only case that needs waypoint machinery, and it is not in V0.
9. Viewing distance: 30 m to the polygon edge (§5 step 4). Still open whether it should vary by POI size (a castle is seen from further than a wayside shrine).
10. To do, in-app: Apple's Place Card (`MKMapItemDetailViewController`) on a tapped Tier-2 sight — does Apple have hours and photos for a Nagamachi temple that has no article anywhere? Cannot be tested outside the app (§4.1).
11. Japanese text on the cards: use Apple's on-device Translation framework, flagged as machine-translated, with OSM `name:en` winning whenever it exists. Measured 6 Oct 2026 on the 46 Japanese strings of the Kanazawa cards (8 article leads, 38 names): 1.7 s for all of them after a one-time 4.5-minute language download. Article leads read well (Ozaki Shrine's is near-perfect; the one systematic slip is 社 as "company"). Names are useful for the kind words — shrine, temple, mausoleum, park — but readings of place names are unreliable (白髯 → "Shiraku", 長町 → "Nagashi-cho") and 用水 / 緑地 are left as "water" / "Ryokuchi"; a reading dictionary (pykakasi) or a kind suffix from the OSM tag would do better for names. The framework only hands out a session through SwiftUI and the download prompt needs a window, so this is in-app, not a script; `LanguageAvailability.status` must be awaited on a live main run loop.
12. Whether fame should be log(sitelinks) rather than linear with a cap of 20 (§5 step 4).
