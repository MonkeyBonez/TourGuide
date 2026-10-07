# Tour Guide

iOS walking app for tourists: a time-vs-interest slider changes **which streets** the route
from A to B takes, cards show the sights it passes in walking order, and a photo mode explains
what you are looking at. PRD: `docs/TOUR_GUIDE_V0_PRD.md`. The measurement it rests on:
`docs/TOUR_GUIDE_MEASUREMENT_2026-10-06.md`.

Layout: `Engine/` (pinned copy of the Like Water engine, LikeWater @ 497e141 — corridor + router),
`Core/` (TourGuideCore: Overpass/Wikidata/Wikipedia clients, tiering, graph, interest, the
`TourSession` slider; `tgtool`), `Apps/TourGuide/` (the app), `UITests/`, `Measure/prototype/`
(the Python scripts the port was measured against).

## Rules

- **No keys in the repo, ever.** The repo is public. The only secret is the user's OpenAI key,
  in Keychain, typed into Settings. Nothing in source, plists, `project.yml`, fixtures, launch
  arguments, screenshots or docs. `git config core.hooksPath .githooks` runs a secret scan on
  every commit; don't bypass it.
- **Runtime fetch is allowed; every fetch degrades to a banner.** Overpass failing means no route
  (a banner, never a fallback route from someone else). Wikidata/Wikipedia failing means a
  flatter route (everything named is Tier 2) and a "degraded" banner.
- **Ours-only routing.** The Engine's corridor + router with interest in place of sun. Never
  Apple or Google routing: they can't score streets.
- **Measure, don't eyeball.** `scripts/measure.sh` must keep reproducing
  `Core/Tests/TourGuideCoreTests/Fixtures/kanazawa/expected_table.txt`. A change to scoring or
  tiering that moves those numbers updates the golden, with the number and the why in LEARNINGS.
- **Tests never hit the network.** Clients take an `HTTPTransport`; tests use `FixtureTransport`.
- **Keep `LEARNINGS.md` current in the same turn**; deferred work goes to `BACKLOG.md`.
- **Engine is a pinned copy.** Don't edit it here; a fix goes to LikeWater first, then re-copy.
- Attribution (OSM, Wikipedia, Wikimedia) stays visible in the app and in `ATTRIBUTION.md`.
- Publishing (GitHub push, TestFlight) is the owner's step. Agents commit locally.

## Run

- Core: `cd Core && swift test`; `scripts/measure.sh`.
- Live: `swift run -c release --package-path Core tgtool fetch 36.5781,136.6480 36.5597,136.6534 --out /tmp/kz.json`
  then `tgtool route /tmp/kz.json`.
- Fastest path (PRD §5 step 8): `tgtool fast kanazawa` (cut from the fixture; must say "same
  nodes: yes") or `tgtool fast <A> <B> --no-cache` (live, hedged mirrors).
- Apple names (PRD §8.10): `tgtool applenames kanazawa` — MapKit on the Mac; throttles after
  ~50 searches, wait a minute between runs.
- App: `xcodegen generate`, open `TourGuide.xcodeproj`, or `scripts/install_phone.sh`.
- UI tests: `xcodebuild -project TourGuide.xcodeproj -scheme TourGuide -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.
