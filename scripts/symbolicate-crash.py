#!/usr/bin/env python3
"""Reads a macOS crash report (.ips) for Scroblytics and prints what crashed, with function names from the matching dSYM.

    python3 -I scripts/symbolicate-crash.py <crash.ips> [<dsyms-folder>]

The dSYM folder defaults to build/release/dsyms (release.sh keeps one folder per version there). The report's own build ID (UUID) is
matched to a dSYM; if none matches, the frames are printed unsymbolicated and it says so. Only function names and offsets are printed
(no file paths from the report, no user names). Needs `atos` (Xcode command line tools).
"""
import glob
import json
import os
import subprocess
import sys


def load(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    lines = text.split("\n", 1)
    header = {}
    body = None
    try:
        header = json.loads(lines[0])
        body = json.loads(lines[1]) if len(lines) > 1 and lines[1].strip() else None
    except json.JSONDecodeError:
        pass
    if body is None:
        body = json.loads(text)  # a report that is a single JSON object
    return header, body


def find_dsym(uuid, folder):
    wanted = uuid.replace("-", "").lower()
    for dsym in glob.glob(os.path.join(folder, "**", "*.dSYM"), recursive=True):
        for dwarf in glob.glob(os.path.join(dsym, "Contents", "Resources", "DWARF", "*")):
            out = subprocess.run(["dwarfdump", "--uuid", dwarf], capture_output=True, text=True).stdout
            for line in out.splitlines():
                if line.startswith("UUID:") and line.split()[1].replace("-", "").lower() == wanted:
                    return dwarf
    return None


def atos(dwarf, arch, load_address, address):
    out = subprocess.run(["atos", "-o", dwarf, "-arch", arch, "-l", hex(load_address), hex(address)], capture_output=True, text=True)
    return out.stdout.strip() or "?"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    folder = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "build", "release", "dsyms")
    header, report = load(sys.argv[1])

    bundle = report.get("bundleInfo", {})
    print("App:       ", bundle.get("CFBundleShortVersionString") or header.get("app_version"), "build", bundle.get("CFBundleVersion") or header.get("build_version"))
    print("macOS:     ", (report.get("osVersion") or {}).get("train") or header.get("os_version"))
    print("Model:     ", report.get("modelCode"), "| arch", report.get("cpuType"))
    exc = report.get("exception", {})
    print("Exception: ", exc.get("type"), exc.get("signal"), exc.get("subtype"))
    term = report.get("termination", {})
    if term.get("indicator"):
        print("Termination:", term.get("indicator"))
    if report.get("asi"):
        print("Crash info:", json.dumps(report["asi"])[:400])

    images = report.get("usedImages", [])
    app_index = next((i for i, im in enumerate(images) if im.get("name") == "Scroblytics" or str(im.get("path", "")).endswith("/Scroblytics.app/Contents/MacOS/Scroblytics")), None)
    dwarf, arch, base = None, "arm64", 0
    if app_index is not None:
        image = images[app_index]
        arch = image.get("arch", "arm64")
        base = image.get("base", 0)
        print("Build ID:  ", image.get("uuid"), "(", arch, ")")
        dwarf = find_dsym(image["uuid"], folder)
        print("dSYM:      ", "found" if dwarf else "NOT FOUND for this build ID in " + folder + " (frames below are unsymbolicated)")

    threads = report.get("threads", [])
    faulting = report.get("faultingThread")
    for index, thread in enumerate(threads):
        crashed = thread.get("triggered") or index == faulting
        if not crashed and index > 8:
            continue
        label = "CRASHED THREAD" if crashed else "thread"
        details = " ".join(str(x) for x in (thread.get("name"), thread.get("queue")) if x)
        print(f"\n--- {label} {index} {details}")
        limit = 40 if crashed else 6
        for n, frame in enumerate(thread.get("frames", [])[:limit]):
            im = images[frame["imageIndex"]] if frame.get("imageIndex") is not None and frame["imageIndex"] < len(images) else {}
            name = im.get("name", "?")
            if dwarf and frame.get("imageIndex") == app_index:
                where = atos(dwarf, arch, base, base + frame["imageOffset"])
            elif frame.get("symbol"):
                where = f'{frame["symbol"]} + {frame.get("symbolLocation", 0)}'
            else:
                where = f'+{frame.get("imageOffset")}'
            print(f"  {n:2d}  {name:<28} {where}")


if __name__ == "__main__":
    main()
