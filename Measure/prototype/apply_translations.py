#!/usr/bin/env python3
"""Merge machine translations back into the card records.

Usage: python3 apply_translations.py cards_enriched.json translate/keys.json translate/out.json cards_translated.json [engine-label]
Adds per POI: name_mt (English for a Japanese-only name), extract_mt (English for a Japanese lead), mt_engine.
"""
import json, sys

cards = json.load(open(sys.argv[1])); keys = json.load(open(sys.argv[2])); out = json.load(open(sys.argv[3]))
engine = sys.argv[5] if len(sys.argv) > 5 else "Apple on-device"
n = {"name": 0, "extract": 0}
for (pid, field), text in zip(keys, out):
    p = cards["pois"].get(pid)
    if not p or not text: continue
    if field in ("name", "name_ja"): p["name_mt"] = text; n["name"] += 1
    elif field == "extract": p["extract_mt"] = text; n["extract"] += 1
    p["mt_engine"] = engine
json.dump(cards, open(sys.argv[4], "w"), ensure_ascii=False)
print(f"applied {n['name']} name and {n['extract']} extract translations ({engine})")
