#!/usr/bin/env python3
"""Builds the two bundled map resources from public datasets. Run by hand when the data should change; the output is committed.

    python3 -I scripts/make-world-data.py --natural-earth ne_110m_admin_0_countries.geojson \
        --cities cities5000.zip --admin1 admin1CodesASCII.txt --out Scroblytics/Resources/Origin \
        --drop-matching Config/forbidden-terms.local

Inputs (download them yourself into a folder outside the repository):
  Natural Earth, 1:110m Admin 0 Countries, GeoJSON   public domain         https://www.naturalearthdata.com
    (the Natural Earth project's own GitHub copy: nvkelso/natural-earth-vector, geojson/ne_110m_admin_0_countries.geojson)
  GeoNames cities5000.zip and admin1CodesASCII.txt     CC BY 4.0, credit GeoNames  https://download.geonames.org/export/dump/

Optional: --drop-matching Config/forbidden-terms.local leaves out any city or country whose line matches the project's local list of
words that must never ship (the first non-comment line, a case-insensitive extended regular expression, as scripts/release.sh reads it).
A place name that happens to contain one of them would otherwise fail the release's repository search.

Outputs:
  world-110m.json   {"countries": [{"iso": "US", "name": "United States of America", "rings": [[lon, lat, lon, lat, ...], ...]}]}
                    Only each polygon's outer ring, to two decimals; Antarctica is left out.
  cities5000.tsv    name <TAB> ascii name (empty when the same) <TAB> country code <TAB> region name <TAB> latitude <TAB> longitude <TAB> population
                    One line per place, grouped by country, largest first.
"""
import argparse
import io
import json
import os
import re
import sys
import zipfile


def ring_points(ring):
    out = []
    for lon, lat, *_ in ring:
        out.append(round(lon, 2))
        out.append(round(lat, 2))
    return out


def load_forbidden(path):
    if not path:
        return None
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.strip() and not line.lstrip().startswith("#"):
                return re.compile(line.strip(), re.IGNORECASE)
    return None


def countries(path, forbidden=None):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    result = []
    for feature in data["features"]:
        props = feature["properties"]
        iso = props.get("ISO_A2_EH") or props.get("ISO_A2")
        name = props.get("NAME") or props.get("ADMIN")
        if iso in (None, "-99", "-1"):
            # A handful of places have no code in the data; the ones people can be from are given theirs by name.
            iso = {"Kosovo": "XK", "N. Cyprus": None, "Somaliland": None}.get(name)
        if not iso or iso == "AQ" or (forbidden and forbidden.search(f"{name} {iso}")):
            continue
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        rings = [ring_points(polygon[0]) for polygon in polygons]
        result.append({"iso": iso, "name": name, "rings": rings})
    result.sort(key=lambda c: c["iso"])
    return result


def cities(zip_path, admin1_path, forbidden=None):
    regions = {}
    with open(admin1_path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                regions[parts[0]] = parts[1]
    rows = []
    with zipfile.ZipFile(zip_path) as archive:
        member = next(n for n in archive.namelist() if n.endswith(".txt"))
        with io.TextIOWrapper(archive.open(member), encoding="utf-8") as handle:
            for line in handle:
                f = line.rstrip("\n").split("\t")
                if len(f) < 15:
                    continue
                name, ascii_name, lat, lon, cc, admin1, population = f[1], f[2], float(f[4]), float(f[5]), f[8], f[10], int(f[14] or 0)
                region = regions.get(f"{cc}.{admin1}", "")
                if forbidden and forbidden.search(f"{name} {ascii_name} {region}"):
                    continue
                rows.append((cc, -population, name, "" if ascii_name == name else ascii_name, region, lat, lon, population))
    rows.sort()
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--natural-earth", required=True)
    parser.add_argument("--cities", required=True)
    parser.add_argument("--admin1", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--drop-matching")
    args = parser.parse_args()
    forbidden = load_forbidden(args.drop_matching)
    os.makedirs(args.out, exist_ok=True)

    world = countries(args.natural_earth, forbidden)
    with open(os.path.join(args.out, "world-110m.json"), "w", encoding="utf-8") as handle:
        json.dump({"countries": world}, handle, ensure_ascii=False, separators=(",", ":"))
    points = sum(len(r) // 2 for c in world for r in c["rings"])
    print(f"world-110m.json: {len(world)} countries, {points} points")

    rows = cities(args.cities, args.admin1, forbidden)
    with open(os.path.join(args.out, "cities5000.tsv"), "w", encoding="utf-8") as handle:
        for cc, _, name, ascii_name, region, lat, lon, population in rows:
            handle.write(f"{name}\t{ascii_name}\t{cc}\t{region}\t{lat:.4f}\t{lon:.4f}\t{population}\n")
    print(f"cities5000.tsv: {len(rows)} places")


if __name__ == "__main__":
    sys.exit(main())
