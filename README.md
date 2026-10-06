# Tour Guide

Walk from A to B the interesting way. A slider trades minutes for sights: at the left end you get
the direct route; move it right and the route itself changes — which streets you walk — to pass
the temples, gardens and old districts worth seeing. Cards show what the route passes, in walking
order. Point the camera at something to hear what it is.

Built on the [Like Water](https://github.com/MonkeyBonez/LikeWater) corridor router (`Engine/`,
a pinned copy of LikeWater @ `497e141`), with interest in place of sun. Streets and places come
live from OpenStreetMap (Overpass), fame from Wikidata, card text and photos from Wikipedia and
Wikimedia Commons. See `ATTRIBUTION.md`.

## The measurement it's built on

Kanazawa Station → Murataya Ryokan (`docs/TOUR_GUIDE_MEASUREMENT_2026-10-06.md`):

| slider (slack) | route | walk |
|---|---|---|
| 0.0 | the bus avenue | 2.9 km · 35.6 min |
| 0.1 | west through the Nagamachi samurai district | +0.2 min |
| 0.2 | east past Oyama Shrine and the castle park | +6.1 min |
| 0.5 | the loop through Kenrokuen | +11.6 min |

`scripts/measure.sh` reproduces that table from the bundled snapshot and diffs it against the
golden output.

## Run

```sh
cd Core && swift test                 # no network
scripts/measure.sh                    # the table above
swift run -c release --package-path Core tgtool fetch 36.5781,136.6480 36.5597,136.6534 --out /tmp/kz.json
swift run -c release --package-path Core tgtool route /tmp/kz.json
xcodegen generate && open TourGuide.xcodeproj
```

The photo mode uses your own OpenAI API key, stored in the iOS Keychain. The repository contains
no keys.

## Licence

MIT. Data licences in `ATTRIBUTION.md`.
