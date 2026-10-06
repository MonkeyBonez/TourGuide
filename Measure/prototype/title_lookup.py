#!/usr/bin/env python3
"""Fourth bridge, cheap: look the OSM name up as a Japanese / English Wikipedia title
(wbgetentities sites=jawiki|enwiki, 50 titles a call — no search API, no 429s).
Accept when the item's P625 is within 400 m, or it has no P625 but P131 = Kanazawa.

Usage: python3 title_lookup.py matched_in.json matched_out.json
"""
import json, math, sys, time, urllib.parse, urllib.request

WIKIDATA = "https://www.wikidata.org/w/api.php"
UA = "poi-corridor-test/0.2 (tour-guide prototype)"
KANAZAWA = "Q191130"

def http(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for i in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r: return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            wait = int(e.headers.get("Retry-After", "30")) if e.code == 429 else 5
            print(f"  HTTP {e.code}, waiting {wait}s", file=sys.stderr); time.sleep(wait)
    raise RuntimeError("gave up")

def metres(lat1, lon1, lat2, lon2):
    return math.hypot((lat2 - lat1) * 111_320, (lon2 - lon1) * 111_320 * math.cos(math.radians(lat1)))

def lookup(site, titles):
    out = {}
    titles = [t for t in dict.fromkeys(titles) if t]
    for i in range(0, len(titles), 50):
        chunk = titles[i:i + 50]
        res = http(WIKIDATA + "?" + urllib.parse.urlencode({"action": "wbgetentities", "sites": site, "titles": "|".join(chunk),
                   "props": "labels|descriptions|sitelinks|claims", "languages": "en|ja", "format": "json"}))
        for qid, ent in res.get("entities", {}).items():
            if "missing" in ent: continue
            sl = ent.get("sitelinks", {}); cl = ent.get("claims", {})
            title = sl.get(site, {}).get("title")
            coord = None
            for c in cl.get("P625", []):
                v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if v: coord = (v["latitude"], v["longitude"]); break
            p131 = [c.get("mainsnak", {}).get("datavalue", {}).get("value", {}).get("id") for c in cl.get("P131", [])]
            out[title] = {"qid": qid, "label": ent.get("labels", {}).get("en", {}).get("value") or ent.get("labels", {}).get("ja", {}).get("value"),
                          "description": ent.get("descriptions", {}).get("en", {}).get("value"),
                          "sitelinks": len([k for k in sl if k.endswith("wiki") and k != "commonswiki"]), "coord": coord, "p131": p131}
        time.sleep(1)
    return out

def main():
    d = json.load(open(sys.argv[1]))
    pois = d["pois"]
    todo = [p for p in pois if not p["wikidata"] and p["name"] and not p["parent"] and not p["dup_of"]]
    print(f"{len(todo)} named POIs without Wikidata; jawiki lookup on name_ja, enwiki on name:en", file=sys.stderr)
    ja = lookup("jawiki", [p["name_ja"] for p in todo])
    en = lookup("enwiki", [p["name"] for p in todo if p["name"] != p["name_ja"]])
    hits = {"ja": 0, "en": 0, "rejected": []}
    for p in todo:
        for site, table, key in (("ja", ja, p["name_ja"]), ("en", en, p["name"])):
            f = table.get(key)
            if not f or f["sitelinks"] < 1: continue
            ok = (f["coord"] and metres(p["lat"], p["lon"], *f["coord"]) <= 400) or (not f["coord"] and KANAZAWA in f["p131"])
            if not ok: hits["rejected"].append((key, f["qid"], f["sitelinks"], f["coord"] and round(metres(p["lat"], p["lon"], *f["coord"])))); continue
            p.update(wikidata=f["qid"], sitelinks=f["sitelinks"], wd_label=f["label"], wd_description=f["description"], match="title-" + site)
            hits[site] += 1; break
    json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False)
    print(f"title lookup: ja {hits['ja']}, en {hits['en']}; rejected (wrong place) {len(hits['rejected'])}: {hits['rejected'][:8]}")
    for p in sorted([p for p in todo if p["wikidata"]], key=lambda p: -p["sitelinks"])[:20]:
        print(f"  {p['sitelinks']:3d} {str(p['name']):42.42} {p['id']:18} {p['match']:9} {p['tags']}")

if __name__ == "__main__":
    main()
