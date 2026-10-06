#!/usr/bin/env python3
"""Attach Wikidata fame to OSM POIs three ways, and measure how much each finds.

  tag     the OSM element carries wikidata=*                 (the PRD's only bridge)
  box     a Wikidata item with coordinates (P625) in the fetch box sits within 250 m, or
          inside the POI's polygon, and its ja/en label matches the OSM name
  search  wbsearchentities on the OSM name (ja then en); accepted only if the item's P625
          is within 400 m, or it has no P625 but P131 (located in) = Kanazawa

Also does the PRD §4.3 dedupe: a node inside a historic / place_of_worship / leisure area
is attached to that parent; same-name POIs within 60 m collapse to one.

Usage: python3 match_wikidata.py kanazawa_box.json wikidata_box.json out.json [--search]
"""
import json, math, re, sys, time, urllib.parse, urllib.request

WIKIDATA = "https://www.wikidata.org/w/api.php"
UA = "poi-corridor-test/0.2 (tour-guide prototype)"
KANAZAWA = "Q191130"
CACHE = "wd_search_cache.json"

def http(url, retries=6):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r: return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if i == retries - 1: raise
            # Wikidata rate-limits the search API hard; honour Retry-After, default a minute.
            wait = int(e.headers.get("Retry-After", "60")) if e.code == 429 else 5 * (i + 1)
            print(f"  HTTP {e.code}, waiting {wait}s", file=sys.stderr); time.sleep(wait)
        except Exception as e:
            if i == retries - 1: raise
            time.sleep(5 * (i + 1))

def norm(s):
    if not s: return ""
    s = s.lower()
    s = re.sub(r"[\s\-‐・・()（）「」'’]", "", s)
    s = re.sub(r"(temple|shrine|garden|park|museum|castle|gate|market)$", "", s)
    return s

def names_match(poi, label_en, label_ja):
    a = {norm(poi.get("name")), norm(poi.get("name_ja"))} - {""}
    b = {norm(label_en), norm(label_ja)} - {""}
    for x in a:
        for y in b:
            if len(x) < 3 or len(y) < 3: continue
            if x == y: return True
            # Containment only when the shorter name is most of the longer one: "Kanazawa"
            # must not match "Kanazawa Catholic Church" (that gave the church the city's 90 langs).
            lo, hi = sorted((x, y), key=len)
            if lo in hi and len(lo) >= 4 and len(lo) / len(hi) >= 0.6: return True
    return False

def metres(lat1, lon1, lat2, lon2):
    return math.hypot((lat2 - lat1) * 111_320, (lon2 - lon1) * 111_320 * math.cos(math.radians(lat1)))

def point_in_rings(lat, lon, rings):
    for ring in rings:
        inside = False; n = len(ring)
        for i in range(n):
            (y1, x1), (y2, x2) = ring[i], ring[(i + 1) % n]
            if (y1 > lat) != (y2 > lat) and lon < x1 + (lat - y1) * (x2 - x1) / (y2 - y1): inside = not inside
        if inside: return True
    return False

def entity_facts(qids):
    """sitelinks, P625 coordinate, P131 for each qid (one call per 50)."""
    out = {}
    for i in range(0, len(qids), 50):
        chunk = qids[i:i + 50]
        res = http(WIKIDATA + "?" + urllib.parse.urlencode({
            "action": "wbgetentities", "ids": "|".join(chunk), "format": "json",
            "props": "labels|descriptions|sitelinks|claims", "languages": "en|ja"}))
        for qid, ent in res.get("entities", {}).items():
            sl = ent.get("sitelinks", {}); cl = ent.get("claims", {})
            coord = None
            for c in cl.get("P625", []):
                v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if v: coord = (v["latitude"], v["longitude"]); break
            p131 = [c.get("mainsnak", {}).get("datavalue", {}).get("value", {}).get("id") for c in cl.get("P131", [])]
            out[qid] = {"label": ent.get("labels", {}).get("en", {}).get("value") or ent.get("labels", {}).get("ja", {}).get("value"),
                        "label_ja": ent.get("labels", {}).get("ja", {}).get("value"),
                        "description": ent.get("descriptions", {}).get("en", {}).get("value"),
                        "sitelinks": len([k for k in sl if k.endswith("wiki") and k != "commonswiki"]),
                        "coord": coord, "p131": p131}
        time.sleep(0.3)
    return out

def main():
    box_path, wd_path, out_path = sys.argv[1:4]
    do_search = "--search" in sys.argv
    d = json.load(open(box_path)); W = json.load(open(wd_path))
    pois = d["pois"]
    try: cache = json.load(open(CACHE))
    except Exception: cache = {}

    stats = {"tag": 0, "box": 0, "search": 0, "none": 0}
    for p in pois:
        p["match"] = None; p["parent"] = None; p["dup_of"] = None
        if p["wikidata"]:
            p["match"] = "tag"; stats["tag"] += 1; continue
        if not p["name"]: continue
        best = None
        for it in W:
            if it["sitelinks"] < 1: continue
            dist = metres(p["lat"], p["lon"], it["lat"], it["lon"])
            inside = p["rings"] and point_in_rings(it["lat"], it["lon"], p["rings"])
            if (dist <= 250 or inside) and names_match(p, it["label"], it["label_ja"]):
                if best is None or dist < best[0]: best = (dist, it)
        if best:
            it = best[1]
            p.update(wikidata=it["qid"], sitelinks=it["sitelinks"], wd_label=it["label"], match="box"); stats["box"] += 1

    if do_search:
        todo = [p for p in pois if not p["wikidata"] and p["name"] and
                (p["tags"].get("tourism") in ("attraction", "museum", "gallery", "viewpoint") or
                 p["tags"].get("amenity") in ("marketplace", "place_of_worship") or "historic" in p["tags"] or
                 p["tags"].get("leisure") in ("park", "garden"))]
        print(f"name search for {len(todo)} sight-like named POIs…", file=sys.stderr)
        for k, p in enumerate(todo):
            cands = []
            # Japanese name first; the English one only when that finds nothing (halves the calls).
            for lang, name in (("ja", p["name_ja"]), ("en", p["name"])):
                if not name or (lang == "en" and cands): continue
                key = f"{lang}:{name}"
                if key not in cache:
                    res = http(WIKIDATA + "?" + urllib.parse.urlencode({"action": "wbsearchentities", "search": name,
                               "language": lang, "uselang": lang, "format": "json", "limit": 5}))
                    cache[key] = [s["id"] for s in res.get("search", [])]
                    time.sleep(1.0)
                cands += cache[key]
            cands = list(dict.fromkeys(cands))
            if not cands: continue
            facts_key = "facts:" + ",".join(cands)
            if facts_key not in cache: cache[facts_key] = entity_facts(cands)
            facts = cache[facts_key]
            accepted = None
            for qid in cands:
                f = facts.get(qid)
                if not f or f["sitelinks"] < 1 or not names_match(p, f["label"], f["label_ja"]): continue
                if f["coord"]:
                    if metres(p["lat"], p["lon"], *f["coord"]) <= 400: accepted = (qid, f); break
                elif KANAZAWA in f["p131"]: accepted = (qid, f); break
            if accepted:
                qid, f = accepted
                p.update(wikidata=qid, sitelinks=f["sitelinks"], wd_label=f["label"], wd_description=f["description"], match="search")
                stats["search"] += 1
            if (k + 1) % 20 == 0: json.dump(cache, open(CACHE, "w"), ensure_ascii=False)
        json.dump(cache, open(CACHE, "w"), ensure_ascii=False)
    stats["none"] = sum(1 for p in pois if not p["wikidata"] and p["name"])

    # §4.3 dedupe: node inside an area parent; same name within 60 m.
    parents = [p for p in pois if p["rings"] and (p["tags"].get("amenity") == "place_of_worship" or "historic" in p["tags"]
                                                  or p["tags"].get("leisure") in ("park", "garden"))]
    def ring_area(rings):
        return sum(abs(sum(r[i][0] * r[(i + 1) % len(r)][1] - r[(i + 1) % len(r)][0] * r[i][1] for i in range(len(r)))) / 2 for r in rings)
    for p in pois:
        own = ring_area(p["rings"]) if p["rings"] else 0
        for q in parents:
            # A node, or a smaller area (a hall inside the grounds), inside a parent area.
            if q is not p and ring_area(q["rings"]) > own * 1.5 and point_in_rings(p["lat"], p["lon"], q["rings"]):
                p["parent"] = q["id"]
                # The grounds take the fame of the most famous thing inside them: Kanazawa
                # Castle (20 langs) sits inside Kanazawa Castle Park (its own item, 1 lang).
                if p["wikidata"] and (p.get("sitelinks") or 0) > (q.get("sitelinks") or 0):
                    q.update(wikidata=p["wikidata"], sitelinks=p["sitelinks"], wd_label=p["wd_label"], match=p["match"] + "-via-child")
                break
    by_name = {}
    for p in pois:
        if p["parent"] or not p["name"]: continue
        key = norm(p["name"]) or norm(p["name_ja"])
        for q in by_name.get(key, []):
            if metres(p["lat"], p["lon"], q["lat"], q["lon"]) <= 60:
                p["dup_of"] = q["id"]
                if p["wikidata"] and not q["wikidata"]:
                    q.update(wikidata=p["wikidata"], sitelinks=p["sitelinks"], wd_label=p["wd_label"], match=p["match"])
                break
        else:
            by_name.setdefault(key, []).append(p)

    json.dump(d, open(out_path, "w"), ensure_ascii=False)
    tier1 = [p for p in pois if p["wikidata"] and not p["parent"] and not p["dup_of"]]
    print(f"matched: tag {stats['tag']}, box {stats['box']}, search {stats['search']}; named without Wikidata {stats['none']}; "
          f"parents attached {sum(1 for p in pois if p['parent'])}, duplicates {sum(1 for p in pois if p['dup_of'])}")
    print(f"tier 1 after dedupe: {len(tier1)}")
    for p in sorted(tier1, key=lambda p: -p["sitelinks"])[:25]:
        print(f"  {p['sitelinks']:3d} {str(p['name']):42.42} {p['id']:18} {p['match']:12} {p['tags']}" + (" area" if p["rings"] else ""))

if __name__ == "__main__":
    main()
