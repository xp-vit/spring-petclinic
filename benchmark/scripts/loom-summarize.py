#!/usr/bin/env python3
"""Summarize virtual-thread benchmark results.

Reads k6 summary-export JSON (`<tag>-c<level>-summary.json`) and the per-tag thread-count
samples (`<tag>-threads.csv`) from a results directory, and emits:
  - comparison.txt : human-readable table per tag
  - results.csv    : tag,concurrency,rps,p50,p95,p99,max,err_pct,peak_platform_threads

Usage: loom-summarize.py RESULTS_DIR ["50 100 200 ..."]
"""
import sys
import os
import json
import glob
import re


def peak_threads(rd, tag, level):
    f = os.path.join(rd, f"{tag}-threads.csv")
    if not os.path.isfile(f):
        return ""
    mx = 0
    with open(f) as fh:
        next(fh, None)
        for line in fh:
            p = line.strip().split(",")
            if len(p) == 3 and p[1] == str(level):
                try:
                    mx = max(mx, int(p[2]))
                except ValueError:
                    pass
    return mx or ""


def main():
    rd = sys.argv[1]
    levels = sys.argv[2].split() if len(sys.argv) > 2 and sys.argv[2].strip() else None

    # Discover tags + levels from the summary files present.
    found = {}
    for f in glob.glob(os.path.join(rd, "*-c*-summary.json")):
        m = re.match(r"(.+)-c(\d+)-summary\.json$", os.path.basename(f))
        if not m:
            continue
        tag, lvl = m.group(1), int(m.group(2))
        found.setdefault(tag, set()).add(lvl)
    if not found:
        print("No summary files found in", rd)
        return

    rows_csv = ["tag,concurrency,rps,p50,p95,p99,max,err_pct,peak_platform_threads"]
    out = []
    for tag in sorted(found):
        lvls = sorted(found[tag]) if levels is None else [int(x) for x in levels if int(x) in found[tag]]
        out.append(f"\n=== {tag} ===")
        hdr = f"{'conc':>6}{'RPS':>11}{'p50':>9}{'p95':>9}{'p99':>9}{'max':>10}{'err%':>7}{'peakThr':>9}"
        out.append(hdr)
        out.append("-" * len(hdr))
        for lvl in lvls:
            f = os.path.join(rd, f"{tag}-c{lvl}-summary.json")
            if not os.path.isfile(f):
                out.append(f"{lvl:>6}   (no results)")
                continue
            m = json.load(open(f)).get("metrics", {})
            d = m.get("http_req_duration", {})
            rps = m.get("http_reqs", {}).get("rate", float("nan"))
            err = m.get("http_req_failed", {}).get("rate", 0.0) * 100
            pk = peak_threads(rd, tag, lvl)
            out.append(f"{lvl:>6}{rps:>11.1f}{d.get('med',float('nan')):>9.1f}"
                       f"{d.get('p(95)',float('nan')):>9.1f}{d.get('p(99)',float('nan')):>9.1f}"
                       f"{d.get('max',float('nan')):>10.1f}{err:>7.2f}{str(pk):>9}")
            rows_csv.append(f"{tag},{lvl},{rps:.2f},{d.get('med','')},{d.get('p(95)','')},"
                            f"{d.get('p(99)','')},{d.get('max','')},{err:.3f},{pk}")
    out.append("\n(latency ms; RPS=req/s; peakThr=peak PLATFORM thread count during the level)")

    text = "\n".join(out)
    print(text)
    with open(os.path.join(rd, "comparison.txt"), "w") as fh:
        fh.write(text + "\n")
    with open(os.path.join(rd, "results.csv"), "w") as fh:
        fh.write("\n".join(rows_csv) + "\n")
    print(f"\nWrote {os.path.join(rd, 'comparison.txt')} and results.csv")


if __name__ == "__main__":
    main()
