#!/usr/bin/env python3
"""Fetch POIs + walk network for the Kanazawa test corridor in one Overpass query.

The box is the bounding box of the slack ellipse (straight-line A-B foci, sum of
distances <= L * (1 + slack) * routeFactor), not the PRD's fixed 400 m buffer, so we can
measure what a 400 m buffer would have cut off.  Stdlib only.

Usage: python3 fetch_box.py [slack] [routeFactor]  ->  kanazawa_box.json
"""
import json, math, re, sys, time, urllib.parse, urllib.request

START = ("Kanazawa Station", 36.5781, 136.6480)
END   = ("Murataya Ryokan",  36.5597, 136.6534)
SLACK = float(sys.argv[1]) if len(sys.argv) > 1 else 0.5
ROUTE_FACTOR = float(sys.argv[2]) if len(sys.argv) > 2 else 1.25

OVERPASS = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
WIKIDATA = "https://www.wikidata.org/w/api.php"
UA = "poi-corridor-test/0.2 (tour-guide prototype)"

MY = 111_320.0
MX = 111_320.0 * math.cos(math.radians(START[1]))

def http(url, data=None, retries=3, timeout=240):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode())
        except Exception as e:
            if i == retries - 1: raise
            print(f"  retry {i+1}: {e}", file=sys.stderr); time.sleep(10 * (i + 1))

def ellipse_bbox():
    ax, ay = START[2] * MX, START[1] * MY
    bx, by = END[2] * MX, END[1] * MY
    L = math.hypot(bx - ax, by - ay)
    s = L * (1 + SLACK) * ROUTE_FACTOR          # sum of distances to the foci
    a = s / 2; c = L / 2; b = math.sqrt(a * a - c * c)
    cx, cy = (ax + bx) / 2, (ay + by) / 2
    ux, uy = (bx - ax) / L, (by - ay) / L       # major axis
    # bbox of a rotated ellipse: half-extents sqrt((a ux)^2 + (b uy)^2), sqrt((a uy)^2 + (b ux)^2)
    hx = math.sqrt((a * ux) ** 2 + (b * uy) ** 2)
    hy = math.sqrt((a * uy) ** 2 + (b * ux) ** 2)
    print(f"straight line {L:.0f} m; ellipse sum {s:.0f} m, half-axes {a:.0f} x {b:.0f} m; "
          f"bbox {2*hx:.0f} x {2*hy:.0f} m", file=sys.stderr)
    return ((cy - hy) / MY, (cx - hx) / MX, (cy + hy) / MY, (cx + hx) / MX), L

# osmnx "walk" filter (2.1.1) with the pipeline's default_access (keep access=private, drop access=no)
WALK_BAD_HIGHWAY = re.compile(r"abandoned|bus_guideway|construction|cycleway|motor|no|planned|platform|proposed|raceway|razed|rest_area|services")
def walkable(t):
    hw = t.get("highway")
    if not hw or t.get("area") == "yes" or t.get("access") == "no": return False
    if WALK_BAD_HIGHWAY.search(hw): return False
    if t.get("foot") == "no" or t.get("service") == "private": return False
    for k in ("sidewalk", "sidewalk:both", "sidewalk:left", "sidewalk:right"):
        if t.get(k) == "separate": return False
    return True

def query(bbox):
    s, w, n, e = bbox
    bb = f"{s:.5f},{w:.5f},{n:.5f},{e:.5f}"
    return f"""[out:json][timeout:180];
(
  nwr["historic"]({bb});
  nwr["tourism"~"^(attraction|artwork|viewpoint|museum|gallery)$"]({bb});
  nwr["amenity"~"^(place_of_worship|marketplace)$"]({bb});
  nwr["building"~"^(temple|shrine|church|pagoda|castle)$"]({bb});
  nwr["leisure"~"^(park|garden)$"]({bb});
)->.poi;
.poi out tags center geom;
way["highway"]["area"!~"yes"]["access"!~"no"]["highway"!~"abandoned|bus_guideway|construction|cycleway|motor|no|planned|platform|proposed|raceway|razed|rest_area|services"]["foot"!~"no"]["service"!~"private"]["sidewalk"!~"separate"]["sidewalk:both"!~"separate"]["sidewalk:left"!~"separate"]["sidewalk:right"!~"separate"]({bb})->.w;
.w out body;
node(w.w);
out skel qt;"""

PRD_TOURISM = {"attraction", "artwork", "viewpoint", "museum", "gallery"}
PRD_BUILDING = {"temple", "shrine", "church", "pagoda"}
def prd_query(t):
    return ("historic" in t or t.get("tourism") in PRD_TOURISM
            or t.get("amenity") == "place_of_worship" or t.get("building") in PRD_BUILDING)

def outer_rings(el):
    """Polygon rings for a way (closed) or a relation (outer members), as [[lat,lon],...]."""
    if el["type"] == "way" and el.get("geometry") and len(el["geometry"]) > 3:
        g = el["geometry"]
        if g[0]["lat"] == g[-1]["lat"] and g[0]["lon"] == g[-1]["lon"]:
            return [[[p["lat"], p["lon"]] for p in g]]
        return []
    if el["type"] == "relation":
        rings = []
        for m in el.get("members", []):
            if m.get("role") == "outer" and m.get("geometry") and len(m["geometry"]) > 3:
                rings.append([[p["lat"], p["lon"]] for p in m["geometry"]])
        return rings
    return []

def fetch_wikidata(qids):
    out = {}
    qids = sorted(set(qids))
    for i in range(0, len(qids), 50):
        chunk = qids[i:i + 50]
        print(f"Wikidata {i+1}-{i+len(chunk)} of {len(qids)}…", file=sys.stderr)
        params = {"action": "wbgetentities", "ids": "|".join(chunk), "format": "json",
                  "props": "labels|descriptions|sitelinks", "languages": "en|ja"}
        res = http(WIKIDATA + "?" + urllib.parse.urlencode(params))
        for qid, ent in res.get("entities", {}).items():
            sl = ent.get("sitelinks", {})
            out[qid] = {
                "label": ent.get("labels", {}).get("en", {}).get("value")
                         or ent.get("labels", {}).get("ja", {}).get("value"),
                "description": ent.get("descriptions", {}).get("en", {}).get("value"),
                "sitelinks": len([k for k in sl if k.endswith("wiki") and k != "commonswiki"]),
                "enwiki": sl.get("enwiki", {}).get("title"),
            }
        time.sleep(0.5)
    return out

def main():
    bbox, L = ellipse_bbox()
    print("Querying Overpass (POIs + walk network)…", file=sys.stderr)
    t0 = time.time()
    els = http(OVERPASS, data=urllib.parse.urlencode({"data": query(bbox)}).encode())["elements"]
    print(f"  {len(els)} elements in {time.time()-t0:.0f}s", file=sys.stderr)

    pois, ways, nodes = [], [], {}
    for el in els:
        t = el.get("tags", {})
        if el["type"] == "node" and "tags" not in el:
            nodes[el["id"]] = [el["lat"], el["lon"]]; continue
        if el["type"] == "way" and walkable(t) and "nodes" in el:
            ways.append({"id": el["id"], "tags": t, "nodes": el["nodes"]})
            continue
        # `out tags center geom` returns geometry + bounds but no `center` for ways and
        # relations (poi_corridor.py skipped every area POI because of this).
        if el["type"] == "node": lat, lon = el["lat"], el["lon"]
        elif "center" in el: lat, lon = el["center"]["lat"], el["center"]["lon"]
        elif "bounds" in el:
            b = el["bounds"]; lat, lon = (b["minlat"] + b["maxlat"]) / 2, (b["minlon"] + b["maxlon"]) / 2
        else: continue
        pois.append({
            "id": f'{el["type"]}/{el["id"]}', "lat": lat, "lon": lon,
            "name": t.get("name:en") or t.get("name"), "name_ja": t.get("name"),
            "wikidata": t.get("wikidata"), "wikipedia": t.get("wikipedia"), "heritage": t.get("heritage"),
            "tags": {k: v for k, v in t.items() if k in ("historic", "tourism", "amenity", "building", "religion", "leisure")},
            "prd_query": prd_query(t), "rings": outer_rings(el),
        })
    # nodes with tags that walk ways reference (e.g. crossing nodes) came back in .w out body? No:
    # `out body` on ways lists node ids only; node(w.w) + out skel gives every referenced node.
    missing = {n for w in ways for n in w["nodes"] if n not in nodes}
    # tagged nodes (POI nodes that are also way nodes) were emitted with tags by .poi; fill them in
    for el in els:
        if el["type"] == "node" and el["id"] in missing: nodes[el["id"]] = [el["lat"], el["lon"]]
    missing = {n for w in ways for n in w["nodes"] if n not in nodes}
    if missing: print(f"  WARNING {len(missing)} way nodes without coords", file=sys.stderr)

    wd = fetch_wikidata([p["wikidata"] for p in pois if p["wikidata"]])
    for p in pois:
        w = wd.get(p["wikidata"]) if p["wikidata"] else None
        p["wd_label"] = w and w["label"]; p["wd_description"] = w and w["description"]
        p["sitelinks"] = (w or {}).get("sitelinks", 0); p["wd_enwiki"] = w and w["enwiki"]

    out = {"start": {"name": START[0], "lat": START[1], "lon": START[2]},
           "end": {"name": END[0], "lat": END[1], "lon": END[2]},
           "bbox": bbox, "straight_m": L, "slack": SLACK, "route_factor": ROUTE_FACTOR,
           "pois": pois, "ways": ways, "nodes": [[k, v[0], v[1]] for k, v in nodes.items()]}
    with open("kanazawa_box.json", "w", encoding="utf-8") as f: json.dump(out, f, ensure_ascii=False)
    t1 = sum(1 for p in pois if p["wikidata"]); named = sum(1 for p in pois if p["name"] and not p["wikidata"])
    print(f"wrote kanazawa_box.json: {len(pois)} POIs ({t1} with wikidata, {named} named only, "
          f"{sum(1 for p in pois if p['prd_query'])} matching the PRD query), {len(ways)} walk ways, {len(nodes)} nodes")

if __name__ == "__main__":
    main()
