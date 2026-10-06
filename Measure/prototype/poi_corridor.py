#!/usr/bin/env python3
"""
POI corridor test: can OSM + Wikidata produce a good list of points of
interest along a walking corridor?  Standalone; stdlib only.

Usage:  python3 poi_corridor.py
Output: results/kanazawa_corridor.md, results/kanazawa_corridor_raw.json
"""
import json, math, os, sys, time, urllib.parse, urllib.request

# --- Corridor -----------------------------------------------------------------
START = ("Kanazawa Station", 36.5781, 136.6480)
END   = ("Murataya Ryokan",  36.5597, 136.6534)
BUFFER_M = 400

OVERPASS = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"
WIKIDATA = "https://www.wikidata.org/w/api.php"
UA = "poi-corridor-test/0.1 (tour-guide prototype)"

# --- Geometry -----------------------------------------------------------------
def m_per_deg(lat):
    return 111_320.0, 111_320.0 * math.cos(math.radians(lat))

def to_xy(lat, lon):
    my, mx = m_per_deg(START[1])
    return (lon - START[2]) * mx, (lat - START[1]) * my

def dist_to_segment(lat, lon):
    """Perpendicular distance (m) to corridor and fraction along it (0-1)."""
    px, py = to_xy(lat, lon)
    ax, ay = to_xy(START[1], START[2]); bx, by = to_xy(END[1], END[2])
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    cx, cy = ax + t * dx, ay + t * dy
    side = (dx * (py - ay) - dy * (px - ax))  # sign = left/right of line
    return math.hypot(px - cx, py - cy), t, ("W" if side > 0 else "E")

def point_in_poly(lat, lon, poly):
    inside = False
    n = len(poly)
    for i in range(n):
        (y1, x1), (y2, x2) = poly[i], poly[(i + 1) % n]
        if (y1 > lat) != (y2 > lat):
            xint = x1 + (lat - y1) * (x2 - x1) / (y2 - y1)
            if lon < xint:
                inside = not inside
    return inside

# --- Fetch --------------------------------------------------------------------
def http(url, data=None, retries=3):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA})
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read().decode())
        except Exception as e:
            if i == retries - 1: raise
            print(f"  retry {i+1}: {e}", file=sys.stderr); time.sleep(5 * (i + 1))

def fetch_overpass():
    pad = BUFFER_M / 111_320.0 * 1.3
    s, n = min(START[1], END[1]) - pad, max(START[1], END[1]) + pad
    w, e = min(START[2], END[2]) - pad, max(START[2], END[2]) + pad
    bbox = f"{s},{w},{n},{e}"
    q = f"""[out:json][timeout:90];
(
  nwr["historic"]({bbox});
  nwr["tourism"~"^(attraction|artwork|viewpoint|museum|gallery)$"]({bbox});
  nwr["amenity"="place_of_worship"]({bbox});
  nwr["building"~"^(temple|shrine|church|pagoda)$"]({bbox});
);
out tags center geom;"""
    print("Querying Overpass…", file=sys.stderr)
    return http(OVERPASS, data=urllib.parse.urlencode({"data": q}).encode())["elements"]

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

# --- Main ---------------------------------------------------------------------
def main():
    elements = fetch_overpass()
    items = []
    for el in elements:
        tags = el.get("tags", {})
        if el["type"] == "node": lat, lon = el["lat"], el["lon"]
        elif "center" in el:      lat, lon = el["center"]["lat"], el["center"]["lon"]
        else: continue
        d, t, side = dist_to_segment(lat, lon)
        if d > BUFFER_M: continue
        poly = None
        if el["type"] == "way" and el.get("geometry") and len(el["geometry"]) > 3:
            poly = [(g["lat"], g["lon"]) for g in el["geometry"]]
        elif el["type"] == "relation" and "bounds" in el:
            b = el["bounds"]
            poly = [(b["minlat"], b["minlon"]), (b["minlat"], b["maxlon"]),
                    (b["maxlat"], b["maxlon"]), (b["maxlat"], b["minlon"])]
        items.append({
            "id": f'{el["type"]}/{el["id"]}', "lat": lat, "lon": lon,
            "name": tags.get("name:en") or tags.get("name"), "name_ja": tags.get("name"),
            "wikidata": tags.get("wikidata"), "wikipedia": tags.get("wikipedia"),
            "heritage": tags.get("heritage"),
            "kind": {k: v for k, v in tags.items()
                     if k in ("historic", "tourism", "amenity", "building", "religion")},
            "dist_m": round(d), "along": round(t, 3), "side": side, "poly": poly,
            "parent": None, "tags": tags,
        })

    # Dedupe: attach small features sitting inside a place_of_worship/historic area
    parents = [i for i in items if i["poly"] and
               (i["tags"].get("amenity") == "place_of_worship" or "historic" in i["tags"])]
    for it in items:
        if it["poly"]: continue
        for p in parents:
            if p is not it and point_in_poly(it["lat"], it["lon"], p["poly"]):
                it["parent"] = p["name"] or p["id"]; break

    wd = fetch_wikidata([i["wikidata"] for i in items if i["wikidata"]])
    for it in items:
        it["wd"] = wd.get(it["wikidata"]) if it["wikidata"] else None

    tier1 = sorted([i for i in items if i["wikidata"]], key=lambda i: -(i["wd"] or {}).get("sitelinks", 0))
    tier2 = sorted([i for i in items if not i["wikidata"] and i["name"]], key=lambda i: i["dist_m"])
    dropped = [i for i in items if not i["wikidata"] and not i["name"]]

    # Sanity check
    expected = ["Tsuzumi", "Omicho", "Oyama", "Kanazawa Castle", "Nagamachi", "Nomura", "Kenroku"]
    found = {e: [i["name"] for i in tier1 if i["name"] and e.lower() in (i["name"] + " " + (i["wd"] or {}).get("label", "")).lower()] for e in expected}

    os.makedirs("results", exist_ok=True)
    def kind(i): return ", ".join(f"{k}={v}" for k, v in i["kind"].items())
    def row(i):
        w = i["wd"] or {}
        par = f" (inside: {i['parent']})" if i["parent"] else ""
        desc = f" — {w.get('description')}" if w.get("description") else ""
        return (f"- **{i['name'] or w.get('label') or i['id']}**{par} · {kind(i)} · "
                f"{i['dist_m']}m {i['side']} · {int(i['along']*100)}% along"
                f"{' · ' + str(w.get('sitelinks')) + ' langs' if w else ''}{desc}")

    lines = [f"# POI corridor: {START[0]} → {END[0]}", "",
             f"Buffer {BUFFER_M}m · {len(elements)} raw OSM elements in bbox · "
             f"{len(items)} within corridor · Tier 1: {len(tier1)} · Tier 2: {len(tier2)} · dropped: {len(dropped)}", "",
             "## Sanity check"]
    for e, hits in found.items():
        lines.append(f"- {'✅' if hits else '❌'} {e}: {', '.join(hits) if hits else 'MISSING'}")
    lines += ["", "## Tier 1 (has wikidata), by language count"] + [row(i) for i in tier1]
    lines += ["", "## Tier 2 (named, no wikidata), by distance"] + [row(i) for i in tier2]
    lines += ["", f"## Dropped (unnamed): {len(dropped)} — sample"] + \
             [f"- {i['id']} · {kind(i)} · {i['dist_m']}m" for i in dropped[:10]]
    # Text map: 20 buckets along corridor, W | E
    lines += ["", "## Tier 1 along the corridor (W side | E side)", "```"]
    for b in range(20):
        lo, hi = b / 20, (b + 1) / 20
        w = [i["name"] or i["id"] for i in tier1 if lo <= i["along"] < hi and i["side"] == "W"]
        e = [i["name"] or i["id"] for i in tier1 if lo <= i["along"] < hi and i["side"] == "E"]
        lines.append(f"{int(lo*100):3d}% {', '.join(w)[:40]:>40} | {', '.join(e)[:40]}")
    lines += ["```"]

    with open("results/kanazawa_corridor.md", "w", encoding="utf-8") as f: f.write("\n".join(lines))
    for i in items: i.pop("poly", None)
    with open("results/kanazawa_corridor_raw.json", "w", encoding="utf-8") as f:
        json.dump(items, f, ensure_ascii=False, indent=1)
    print("\n".join(lines[:4 + len(expected) + 1]))
    print("\nWrote results/kanazawa_corridor.md and results/kanazawa_corridor_raw.json")

if __name__ == "__main__":
    main()
