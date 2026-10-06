#!/usr/bin/env python3
"""Card content for the POIs the routes pass, from the free sources:
  Wikidata   sitelink titles, P18 image, P571 inception
  Wikipedia  REST summary (extract + thumbnail), English first, Japanese fallback
  Commons    thumbnail bytes, embedded as data: URIs (the artifact cannot load external images)
  OSM        full tags (opening_hours, website, inscription, description, start_date, wikipedia, image)

Usage: python3 enrich.py cards.json [poi_tags.json] -> cards_enriched.json   (net calls cached)
"""
import base64, json, re, sys, time, urllib.parse, urllib.request

UA = "poi-corridor-test/0.2 (tour-guide prototype)"
CACHE_PATH = "enrich_cache.json"
try: cache = json.load(open(CACHE_PATH))
except Exception: cache = {}

def get(url, binary=False):
    if url in cache: return base64.b64decode(cache[url]) if binary else cache[url]
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    for i in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            cache[url] = base64.b64encode(data).decode() if binary else data.decode()
            json.dump(cache, open(CACHE_PATH, "w"))
            time.sleep(0.4)
            return data if binary else cache[url]
        except urllib.error.HTTPError as e:
            if e.code == 404: cache[url] = ""; json.dump(cache, open(CACHE_PATH, "w")); return b"" if binary else ""
            wait = int(e.headers.get("Retry-After", "30")) if e.code == 429 else 5 * (i + 1)
            print(f"  HTTP {e.code} {url[:80]} — waiting {wait}s", file=sys.stderr); time.sleep(wait)
        except Exception as e:
            print(f"  {e} {url[:80]}", file=sys.stderr); time.sleep(5)
    return b"" if binary else ""

def wikidata(qids):
    out = {}
    for i in range(0, len(qids), 50):
        chunk = qids[i:i + 50]
        res = get("https://www.wikidata.org/w/api.php?" + urllib.parse.urlencode({
            "action": "wbgetentities", "ids": "|".join(chunk), "props": "sitelinks|claims|descriptions|labels",
            "languages": "en|ja", "format": "json"}))
        if not res: continue
        for qid, ent in json.loads(res).get("entities", {}).items():
            sl = ent.get("sitelinks", {}); cl = ent.get("claims", {})
            def claim(p):
                for c in cl.get(p, []):
                    v = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                    if v: return v
            inception = claim("P571")
            out[qid] = {"enwiki": sl.get("enwiki", {}).get("title"), "jawiki": sl.get("jawiki", {}).get("title"),
                        "image": claim("P18"), "inception": inception and inception.get("time", "")[1:5],
                        "description_en": ent.get("descriptions", {}).get("en", {}).get("value"),
                        "description_ja": ent.get("descriptions", {}).get("ja", {}).get("value"),
                        "label_en": ent.get("labels", {}).get("en", {}).get("value")}
    return out

def summary(lang, title):
    res = get(f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{urllib.parse.quote(title.replace(' ', '_'))}")
    if not res: return None
    j = json.loads(res)
    if j.get("type") == "disambiguation": return None
    return {"extract": j.get("extract", ""), "thumb": (j.get("thumbnail") or {}).get("source"),
            "url": (j.get("content_urls") or {}).get("desktop", {}).get("page"), "lang": lang, "description": j.get("description")}

def data_uri(url):
    if not url: return None
    b = get(url, binary=True)
    if not b or len(b) > 200_000: return None
    mime = "image/png" if b[:4] == b"\x89PNG" else "image/jpeg"
    return f"data:{mime};base64," + base64.b64encode(b).decode()

def commons_thumb(filename, width=480):
    return f"https://commons.wikimedia.org/wiki/Special:FilePath/{urllib.parse.quote(filename.replace(' ', '_'))}?width={width}"

def main():
    cards = json.load(open(sys.argv[1]))
    tags = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
    ids = sorted({s["id"] for r in cards["routes"] for s in r["sights"]})
    pois = cards["pois"]
    qids = sorted({pois[i]["wikidata"] for i in ids if pois[i]["wikidata"]})
    print(f"{len(ids)} POIs on the routes, {len(qids)} Wikidata items", file=sys.stderr)
    wd = wikidata(qids)
    stats = {"extract_en": 0, "extract_ja": 0, "image": 0, "osm_tags": 0}
    for i in ids:
        p = pois[i]; t = tags.get(i, {})
        p["osm"] = {k: t[k] for k in ("opening_hours", "website", "inscription", "description", "description:en", "start_date",
                                      "denomination", "fee", "wikipedia", "image", "wikimedia_commons", "heritage", "phone") if k in t}
        if p["osm"]: stats["osm_tags"] += 1
        w = wd.get(p["wikidata"], {}) if p["wikidata"] else {}
        p["inception"] = w.get("inception"); p["enwiki"] = w.get("enwiki"); p["jawiki"] = w.get("jawiki")
        if w.get("description_en") and not p.get("wd_description"): p["wd_description"] = w["description_en"]
        # OSM wikipedia=ja:Title works as a title too.
        wp = t.get("wikipedia", "")
        m = re.match(r"^(\w+):(.+)$", wp)
        if m and not w.get(m[1] + "wiki"): w[m[1] + "wiki"] = m[2]
        summ = None
        for lang in ("en", "ja"):
            if w.get(lang + "wiki"):
                summ = summary(lang, w[lang + "wiki"])
                if summ and summ["extract"]: break
        if summ:
            p["extract"] = summ["extract"]; p["extract_lang"] = summ["lang"]; p["wp_url"] = summ["url"]
            stats["extract_" + summ["lang"]] += 1
        thumb = (summ or {}).get("thumb")
        if not thumb and w.get("image"): thumb = commons_thumb(w["image"])
        if not thumb and t.get("wikimedia_commons", "").startswith("File:"): thumb = commons_thumb(t["wikimedia_commons"][5:])
        if thumb:
            p["image"] = data_uri(thumb)
            if p["image"]: stats["image"] += 1; p["image_src"] = thumb
    json.dump(cards, open("cards_enriched.json", "w"), ensure_ascii=False)
    print("wrote cards_enriched.json", stats)
    for i in ids:
        p = pois[i]
        print(f"  T{p['tier']} {str(p['name'] or p['name_ja']):40.40} img={'y' if p.get('image') else '-'} "
              f"extract={p.get('extract_lang','-')} {len(p.get('extract',''))}ch osm={list(p['osm'].keys())}")

if __name__ == "__main__":
    main()
