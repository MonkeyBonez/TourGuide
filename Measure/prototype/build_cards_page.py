#!/usr/bin/env python3
"""The Kanazawa page, second version: pick a walk, see the cards for what it passes.

Usage: python3 build_cards_page.py kanazawa_box.json routes_final_view30.geojson cards_enriched.json final_view30.txt leaflet.css out.html
"""
import json, re, sys

box_path, gj_path, cards_path, txt_path, css_path, out_path = sys.argv[1:7]
box = json.load(open(box_path)); gj = json.load(open(gj_path)); cards = json.load(open(cards_path))
txt = open(txt_path, encoding="utf-8").read()
css = re.sub(r"url\([^)]*\)", "none", open(css_path, encoding="utf-8").read())

coord = {int(n[0]): (round(n[1], 5), round(n[2], 5)) for n in box["nodes"]}
streets = [s for s in ([coord[n] for n in w["nodes"] if n in coord] for w in box["ways"]) if len(s) > 1]

# Routes: name each walk by what it does; slack 0.2 and 0.3 are the same walk.
lines = {f["properties"]["slack"]: f for f in gj["features"] if f["geometry"]["type"] == "LineString"}
NAMES = {0.0: ("Direct", "the bus avenue"), 0.1: ("Nagamachi", "west through the samurai district"),
         0.2: ("Castle & Oyama", "east past the shrine and the castle park"), 0.5: ("Kenrokuen loop", "round the castle, the garden and the museum")}
palette = {0.0: "#5b6472", 0.1: "#1f6f8b", 0.2: "#c98a1a", 0.5: "#b8402a"}
routes = []
for r in cards["routes"]:
    s = r["slack"]
    if s not in NAMES: continue
    f = lines[s]
    routes.append({"slack": s, "name": NAMES[s][0], "how": NAMES[s][1], "color": palette[s],
                   "metres": round(r["metres"]), "minutes": round(r["seconds"] / 60, 1), "crossings": r["crossings"],
                   "coords": [[round(c[1], 5), round(c[0], 5)] for c in f["geometry"]["coordinates"]],
                   "sights": r["sights"]})
base = routes[0]["minutes"]
for r in routes: r["plus"] = round(r["minutes"] - base, 1)

# POI records trimmed to what the cards show; same-name duplicates on one walk collapse.
def kind(p):
    t = p["tags"]; rel = t.get("religion"); den = p.get("osm", {}).get("denomination")
    if t.get("amenity") == "place_of_worship":
        base = {"shinto": "Shinto shrine", "buddhist": "Buddhist temple", "christian": "Church"}.get(rel, "Place of worship")
        return base + (f" · {den.replace('_', ' ')}" if den else "")
    if t.get("historic") == "castle": return "Castle"
    if t.get("historic"): return t["historic"].replace("_", " ").capitalize()
    if t.get("tourism") == "museum": return "Museum"
    if t.get("tourism") == "gallery": return "Gallery"
    if t.get("tourism") == "artwork": return "Artwork"
    if t.get("tourism") == "viewpoint": return "Viewpoint"
    if t.get("tourism") == "attraction": return "Attraction"
    if t.get("leisure") == "garden": return "Garden"
    if t.get("leisure") == "park": return "Park"
    if t.get("amenity") == "marketplace": return "Market"
    if t.get("building"): return t["building"].capitalize()
    return "Place"

pois = {}
for pid, p in cards["pois"].items():
    name = p["name"] or p["wd_label"] or p["name_ja"] or pid
    o = p.get("osm", {})
    pois[pid] = {"id": pid, "name": name, "name_ja": p["name_ja"] if p["name_ja"] and p["name_ja"] != name else "",
                 "lat": round(p["lat"], 5), "lon": round(p["lon"], 5), "tier": p["tier"], "weight": p["weight"],
                 "kind": kind(p), "sitelinks": p["sitelinks"], "wikidata": p["wikidata"], "inception": p.get("inception"),
                 "description": p.get("wd_description") or "", "extract": p.get("extract") or "", "extract_lang": p.get("extract_lang") or "",
                 "wp_url": p.get("wp_url") or "", "wp_title": p.get("enwiki") or p.get("jawiki") or "", "image": p.get("image") or "",
                 "hours": o.get("opening_hours", ""), "fee": o.get("fee", ""), "website": o.get("website", ""), "phone": o.get("phone", ""),
                 "inscription": o.get("inscription") or o.get("description:en") or o.get("description") or "",
                 "start_date": o.get("start_date", ""), "area": p["area"],
                 "name_mt": p.get("name_mt", ""), "extract_mt": p.get("extract_mt", ""), "mt_engine": p.get("mt_engine", "")}
for r in routes:
    seen, kept = set(), []
    for s in r["sights"]:
        key = re.sub(r"[^a-z0-9぀-鿿]", "", pois[s["id"]]["name"].lower().replace("samurais", "samurai"))
        if key in seen: continue
        seen.add(key); kept.append({"id": s["id"], "km": round(s["alongMetres"] / 1000, 1), "min": round(s["alongSeconds"] / 60)})
    r["sights"] = kept
used = {s["id"] for r in routes for s in r["sights"]}
pois = {k: v for k, v in pois.items() if k in used}
others = [[round(f["geometry"]["coordinates"][1], 5), round(f["geometry"]["coordinates"][0], 5), f["properties"]["tier"]]
          for f in gj["features"] if f["geometry"]["type"] == "Point"]

rows = re.findall(r"^\s*(\d\.\d\d)\s+(\d+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)$", txt, re.M)
table = "".join(f"<tr><td>{float(a):.1f}</td><td>{int(b):,}</td><td>{c}</td><td>{'+' if float(d) else ''}{d}</td><td>{e}</td><td>{g}</td><td>{h}</td><td>{float(j):.0f}</td></tr>"
                for a, b, c, d, e, f_, g, h, i, j in rows)

html = f"""<title>Kanazawa Slider Routes</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&family=Noto+Sans+JP:wght@400;500&display=swap">
<style>
{css}
/* Layout: map and a card column side by side; on a phone the map sits above and the cards scroll below. */
:root {{
  --bg: #f3f1ec; --fg: #1d1b17; --muted: #6b665c; --panel: #fbfaf7; --card: #ffffff; --rule: #ddd8cc;
  --street: #cbc5b8; --t1: #b8402a; --t2: #8a857a; --focus: #1f6f8b; --chip: #ece8df;
  --sans: "IBM Plex Sans", "Noto Sans JP", -apple-system, "Segoe UI", sans-serif; --mono: "IBM Plex Mono", ui-monospace, Menlo, monospace;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg: #171a1e; --fg: #ebe8e1; --muted: #a39e93; --panel: #1d2026; --card: #23272e; --rule: #373c45;
  --street: #3a404a; --t1: #e0634a; --t2: #8f9aa6; --focus: #6fb6d2; --chip: #2d323b; color-scheme: dark; }} }}
:root[data-theme="dark"] {{
  --bg: #171a1e; --fg: #ebe8e1; --muted: #a39e93; --panel: #1d2026; --card: #23272e; --rule: #373c45;
  --street: #3a404a; --t1: #e0634a; --t2: #8f9aa6; --focus: #6fb6d2; --chip: #2d323b; color-scheme: dark; }}
html, body {{ height: 100%; }}
body {{ margin: 0; background: var(--bg); color: var(--fg); font: 14px/1.45 var(--sans); }}
.app {{ display: grid; grid-template-columns: minmax(0, 1fr) 440px; height: 100%; }}
#map {{ min-height: 0; background: var(--bg); }}
.leaflet-container {{ background: var(--bg); font-family: var(--sans); }}
.leaflet-tooltip {{ background: var(--panel); color: var(--fg); border-color: var(--rule); font: 12px/1.3 var(--sans); }}
.leaflet-tooltip-top:before {{ border-top-color: var(--rule); }}
.leaflet-bar a {{ background: var(--panel); color: var(--fg); border-bottom-color: var(--rule); }}
#panel {{ min-width: 0; overflow: auto; background: var(--panel); border-left: 1px solid var(--rule); padding: 14px 16px 24px; }}
h1 {{ font-size: 17px; font-weight: 600; margin: 0; text-wrap: balance; }}
.sub {{ color: var(--muted); margin: 2px 0 12px; }}
.walks {{ display: grid; grid-template-columns: 1fr 1fr; gap: 6px; margin-bottom: 14px; }}
.walk {{ text-align: left; font: inherit; color: var(--fg); background: var(--card); border: 1px solid var(--rule); border-left: 5px solid var(--c); border-radius: 8px; padding: 8px 10px; cursor: pointer; }}
.walk b {{ display: block; font-weight: 600; }}
.walk span {{ font-family: var(--mono); font-size: 12px; color: var(--muted); }}
.walk[aria-pressed="true"] {{ background: color-mix(in srgb, var(--c) 14%, var(--card)); border-color: var(--c); }}
.walk:focus-visible {{ outline: 2px solid var(--focus); outline-offset: 2px; }}
.how {{ color: var(--muted); margin: 0 0 12px; }}
.cards {{ display: grid; gap: 10px; }}
.card {{ background: var(--card); border: 1px solid var(--rule); border-radius: 10px; overflow: hidden; scroll-margin: 12px; cursor: pointer; }}
.card.on {{ border-color: var(--focus); box-shadow: 0 0 0 2px color-mix(in srgb, var(--focus) 40%, transparent); }}
.card img {{ display: block; width: 100%; max-width: 100%; aspect-ratio: 16 / 9; object-fit: cover; }}
.card .body {{ padding: 10px 12px 12px; display: grid; gap: 6px; }}
.card h2 {{ font-size: 15px; font-weight: 600; margin: 0; line-height: 1.3; }}
.card h2 small {{ font-weight: 400; color: var(--muted); font-size: 13px; margin-left: 6px; }}
.meta {{ display: flex; flex-wrap: wrap; gap: 4px 8px; font-size: 12px; color: var(--muted); }}
.meta .at {{ font-family: var(--mono); }}
.chip {{ background: var(--chip); border-radius: 999px; padding: 1px 8px; }}
.chip.t1 {{ color: var(--t1); }}
.card p {{ margin: 0; font-size: 13px; }}
.card p.ja {{ font-family: "Noto Sans JP", var(--sans); }}
.card p.orig {{ color: var(--muted); font-size: 12px; }}
.mt {{ text-decoration: underline dotted color-mix(in srgb, var(--fg) 35%, transparent); text-underline-offset: 3px; }}
.facts {{ display: grid; grid-template-columns: max-content 1fr; gap: 2px 10px; font-size: 12px; }}
.facts dt {{ color: var(--muted); }} .facts dd {{ margin: 0; min-width: 0; overflow-wrap: anywhere; }}
.links {{ font-size: 12px; display: flex; gap: 12px; flex-wrap: wrap; }}
a {{ color: var(--focus); }}
.card.t2 .body {{ padding: 8px 12px 10px; }}
.card.t2 h2 {{ font-size: 14px; }}
details {{ margin-top: 16px; color: var(--muted); font-size: 12px; }}
summary {{ cursor: pointer; }}
table {{ border-collapse: collapse; width: 100%; margin-top: 6px; font-variant-numeric: tabular-nums; }}
th {{ font-size: 11px; font-weight: 500; letter-spacing: .04em; text-transform: uppercase; text-align: right; padding: 3px 6px 3px 0; border-bottom: 1px solid var(--rule); }}
td {{ font-family: var(--mono); font-size: 12px; text-align: right; padding: 3px 6px 3px 0; border-top: 1px solid var(--rule); }}
th:first-child, td:first-child {{ text-align: left; padding-left: 0; }}
.nomatch {{ color: var(--muted); font-size: 12px; }}
@media (max-width: 760px) {{
  .app {{ grid-template-columns: minmax(0, 1fr); grid-template-rows: 42% minmax(0, 1fr); }}
  #panel {{ border-left: 0; border-top: 1px solid var(--rule); padding: 12px 16px 24px; }}
}}
@media (prefers-reduced-motion: no-preference) {{ .leaflet-interactive {{ transition: opacity .2s; }} }}
</style>
<div class="app">
<div id="map" role="img" aria-label="Walk network of central Kanazawa with the four measured routes"></div>
<section id="panel" aria-label="Walks and sights">
<h1>Kanazawa Station → Murataya Ryokan</h1>
<p class="sub">Four slider positions, routed by the engine on interest-scored streets. Pick a walk; the cards are what it passes, in walking order.</p>
<div class="walks" role="group" aria-label="Walk">{''.join(f'<button class="walk" style="--c:{r["color"]}" data-i="{i}" aria-pressed="false"><b>{r["name"]}</b><span>{r["minutes"]:.1f} min · {"+" if r["plus"] else ""}{r["plus"]:.1f} · {r["metres"]:,} m</span></button>' for i, r in enumerate(routes))}</div>
<p class="how" id="how"></p>
<div class="cards" id="cards"></div>
<details><summary>Measured (polygon viewing 30 m, cap 20)</summary>
<table><thead><tr><th>slack</th><th>m</th><th>min</th><th>+min</th><th>cross</th><th>T1</th><th>T2</th><th>ms</th></tr></thead><tbody>{table}</tbody></table>
<p>Sources: OpenStreetMap (names, kinds, hours, fees), Wikidata (fame = language editions, dates), Wikipedia summaries and Wikimedia Commons photos. Tier 2 is named on OSM but has no article anywhere. Dotted-underlined text is machine-translated from Japanese on this Mac by Apple's Translation framework; the original follows in grey.</p>
</details>
</section>
</div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.js"></script>
<script>
const STREETS = {json.dumps(streets, separators=(",", ":"))};
const ROUTES = {json.dumps(routes, ensure_ascii=False, separators=(",", ":"))};
const POIS = {json.dumps(pois, ensure_ascii=False, separators=(",", ":"))};
const OTHERS = {json.dumps(others, separators=(",", ":"))};
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const esc = s => String(s).replace(/[&<>"]/g, c => ({{'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}}[c]));
const map = L.map('map', {{attributionControl: false, zoomSnap: 0.25}});
const canvas = L.canvas({{padding: 0.5}});
L.polyline(STREETS, {{renderer: canvas, color: css('--street'), weight: 1, interactive: false}}).addTo(map);
OTHERS.forEach(([lat, lon, tier]) => L.circleMarker([lat, lon], {{renderer: canvas, radius: tier === 1 ? 3 : 2, color: css('--t2'), weight: 1, fillColor: css('--t2'), fillOpacity: .35, interactive: false}}).addTo(map));
const lines = ROUTES.map(r => L.polyline(r.coords, {{color: r.color, weight: 5, opacity: .9, lineCap: 'round', lineJoin: 'round'}}).addTo(map)
  .bindTooltip(`${{r.name}} · ${{r.metres}} m · ${{r.minutes.toFixed(1)}} min`, {{sticky: true}}));
map.fitBounds(L.featureGroup(lines).getBounds().pad(0.08));
const sightLayer = L.layerGroup().addTo(map);
let active = 1, markers = {{}};

function card(s) {{
  const p = POIS[s.id], t1 = p.tier === 1;
  const meta = [`<span class="chip ${{t1 ? 't1' : ''}}">${{esc(p.kind)}}</span>`,
    p.inception ? `<span>est. ${{esc(p.inception)}}</span>` : (p.start_date ? `<span>${{esc(p.start_date)}}</span>` : ''),
    t1 ? `<span>${{p.sitelinks}} language${{p.sitelinks === 1 ? '' : 's'}} on Wikipedia</span>` : '<span>named on OSM only</span>',
    `<span class="at">${{s.km}} km · ${{s.min}} min in</span>`].filter(Boolean).join('');
  const text = p.extract ? `<p class="${{p.extract_lang}}">${{esc(p.extract)}}</p>` : (p.description ? `<p>${{esc(p.description)}}</p>` : (p.inscription ? `<p>${{esc(p.inscription)}}</p>` : ''));
  const facts = [p.hours && ['Hours', esc(p.hours)], p.fee && ['Fee', esc(p.fee)], p.phone && ['Phone', esc(p.phone)],
    p.website && ['Web', `<a href="${{esc(p.website)}}" target="_blank" rel="noopener">${{esc(p.website.replace(/^https?:\\/\\//, '').replace(/\\/$/, ''))}}</a>`]].filter(Boolean);
  const links = [p.wp_url && `<a href="${{esc(p.wp_url)}}" target="_blank" rel="noopener">Wikipedia${{p.wp_title && p.wp_title !== p.name ? ': ' + esc(p.wp_title) : ''}}</a>`,
    `<a href="https://www.openstreetmap.org/${{p.id}}" target="_blank" rel="noopener">OSM</a>`,
    p.wikidata && `<a href="https://www.wikidata.org/wiki/${{p.wikidata}}" target="_blank" rel="noopener">${{p.wikidata}}</a>`].filter(Boolean).join('');
  const title = p.name_mt ? `<span class="mt" title="machine-translated, ${{esc(p.mt_engine)}}">${{esc(p.name_mt)}}</span><small>${{esc(p.name)}}</small>`
                          : `${{esc(p.name)}}${{p.name_ja ? `<small>${{esc(p.name_ja)}}</small>` : ''}}`;
  const body = p.extract_mt ? `<p><span class="mt" title="machine-translated, ${{esc(p.mt_engine)}}">${{esc(p.extract_mt)}}</span></p><p class="ja orig">${{esc(p.extract)}}</p>` : text;
  return `<article class="card ${{t1 ? 't1' : 't2'}}" data-id="${{p.id}}" tabindex="0">
    ${{p.image ? `<img src="${{p.image}}" alt="">` : ''}}
    <div class="body"><h2>${{title}}</h2>
    <div class="meta">${{meta}}</div>${{body}}
    ${{facts.length ? `<dl class="facts">${{facts.map(([k, v]) => `<dt>${{k}}</dt><dd>${{v}}</dd>`).join('')}}</dl>` : ''}}
    <div class="links">${{links}}</div></div></article>`;
}}
function show(i) {{
  active = i;
  const r = ROUTES[i];
  document.querySelectorAll('.walk').forEach(b => b.setAttribute('aria-pressed', String(+b.dataset.i === i)));
  lines.forEach((l, j) => {{ l.setStyle({{opacity: j === i ? .95 : .18, weight: j === i ? 6 : 4}}); if (j === i) l.bringToFront(); }});
  document.getElementById('how').textContent = `${{r.how}} · ${{r.sights.filter(s => POIS[s.id].tier === 1).length}} sights with an article, ${{r.sights.filter(s => POIS[s.id].tier === 2).length}} named places · ${{r.crossings}} crossing${{r.crossings === 1 ? '' : 's'}}`;
  document.getElementById('cards').innerHTML = r.sights.map(card).join('');
  sightLayer.clearLayers(); markers = {{}};
  r.sights.forEach(s => {{
    const p = POIS[s.id], t1 = p.tier === 1;
    const m = L.circleMarker([p.lat, p.lon], {{radius: t1 ? Math.min(13, 4 + Math.sqrt(p.weight) * 1.5) : 4, color: t1 ? css('--t1') : css('--t2'),
      weight: 1.5, fillColor: t1 ? css('--t1') : css('--t2'), fillOpacity: .8}}).addTo(sightLayer).bindTooltip(p.name);
    m.on('click', () => focus(s.id, true)); markers[s.id] = m;
  }});
  document.querySelectorAll('.card').forEach(c => {{
    c.addEventListener('click', () => focus(c.dataset.id, false));
    c.addEventListener('keydown', e => {{ if (e.key === 'Enter') focus(c.dataset.id, false); }});
  }});
}}
function focus(id, fromMap) {{
  document.querySelectorAll('.card').forEach(c => c.classList.toggle('on', c.dataset.id === id));
  Object.entries(markers).forEach(([k, m]) => m.setStyle({{weight: k === id ? 3.5 : 1.5}}));
  const p = POIS[id];
  if (fromMap) document.querySelector(`.card[data-id="${{id}}"]`)?.scrollIntoView({{behavior: 'smooth', block: 'nearest'}});
  else map.flyTo([p.lat, p.lon], Math.max(map.getZoom(), 16.5), {{duration: .6}});
}}
document.querySelectorAll('.walk').forEach(b => b.addEventListener('click', () => show(+b.dataset.i)));
show(1);
new ResizeObserver(() => map.invalidateSize()).observe(document.getElementById('map'));
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => location.reload());
</script>
"""
open(out_path, "w", encoding="utf-8").write(html)
print(f"wrote {out_path}: {len(html)/1024:.0f} KB; {len(pois)} POIs on cards; " + "; ".join(f"{r['name']} {len(r['sights'])}" for r in routes))
