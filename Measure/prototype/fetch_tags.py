#!/usr/bin/env python3
"""Full OSM tags for the POIs (the box fetch kept only the classifying keys).
Same bbox and POI query as fetch_box.py, `out tags center` only. Writes poi_tags.json {id: tags}.
"""
import json, sys, time, urllib.parse, urllib.request

OVERPASS = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
UA = "poi-corridor-test/0.2 (tour-guide prototype)"
box = json.load(open(sys.argv[1]))
s, w, n, e = box["bbox"]
bb = f"{s:.5f},{w:.5f},{n:.5f},{e:.5f}"
q = f"""[out:json][timeout:120];
(
  nwr["historic"]({bb});
  nwr["tourism"~"^(attraction|artwork|viewpoint|museum|gallery)$"]({bb});
  nwr["amenity"~"^(place_of_worship|marketplace)$"]({bb});
  nwr["building"~"^(temple|shrine|church|pagoda|castle)$"]({bb});
  nwr["leisure"~"^(park|garden)$"]({bb});
);
out tags center;"""
req = urllib.request.Request(OVERPASS, data=urllib.parse.urlencode({"data": q}).encode(), headers={"User-Agent": UA})
for i in range(4):
    try:
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=240) as r: els = json.loads(r.read().decode())["elements"]
        print(f"{len(els)} elements in {time.time()-t0:.0f}s", file=sys.stderr); break
    except Exception as exc:
        print(f"  retry {i+1}: {exc}", file=sys.stderr); time.sleep(20 * (i + 1))
else:
    sys.exit("gave up")
tags = {f'{el["type"]}/{el["id"]}': el.get("tags", {}) for el in els}
json.dump(tags, open(sys.argv[2], "w"), ensure_ascii=False)
keys = {}
for t in tags.values():
    for k in t: keys[k] = keys.get(k, 0) + 1
print("wrote", sys.argv[2], len(tags), "elements; useful keys:",
      {k: v for k, v in sorted(keys.items(), key=lambda kv: -kv[1]) if k in ("opening_hours", "website", "description", "inscription", "start_date", "denomination", "fee", "phone", "wikipedia", "image", "description:en", "name:en", "heritage", "ele")})
