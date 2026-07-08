#!/usr/bin/env python3
"""Summarize the CPU-architecture price/perf benchmark.

Reads k6 per-run summary JSONs named:
    {endpoint}-{vendor}-r{run}-c{level}-summary.json
and produces, per (endpoint, vendor, level), the MEDIAN across the RUNS repeats plus the
min/max spread. Then picks each config's peak sustained RPS (the max median-RPS over the
concurrency levels, among levels with acceptable error). Writes results.csv + comparison.txt.

Price/perf ($ per hour -> req/s per $) is applied later in arch-charts.py so this stays
price-agnostic and re-runnable.

Usage: arch-summarize.py RESULTS_DIR RUNS "LEVELS..."
"""
import json
import os
import statistics
import sys

rd = sys.argv[1]
runs = int(sys.argv[2])
levels = sys.argv[3].split()

ENDPOINTS = ["cpu", "render"]
VENDORS = ["c7i", "c7a", "c7g"]
VENDOR_LABEL = {"c7i": "Intel c7i.large", "c7a": "AMD c7a.large", "c7g": "Graviton3 c7g.large"}
ENDPOINT_LABEL = {"cpu": "synthetic (/api/cpu)", "render": "real (/api/render JSON serialize)"}


def load(endpoint, vendor, run, level):
    f = os.path.join(rd, f"{endpoint}-{vendor}-r{run}-c{level}-summary.json")
    if not os.path.isfile(f):
        return None
    try:
        m = json.load(open(f)).get("metrics", {})
    except Exception:
        return None
    d = m.get("http_req_duration", {})
    return {
        "rps": m.get("http_reqs", {}).get("rate", float("nan")),
        "p50": d.get("med", float("nan")),
        "p95": d.get("p(95)", float("nan")),
        "p99": d.get("p(99)", float("nan")),
        "max": d.get("max", float("nan")),
        "err": m.get("http_req_failed", {}).get("rate", 0.0) * 100,
    }


def med(xs):
    xs = [x for x in xs if x == x]  # drop NaN
    return statistics.median(xs) if xs else float("nan")


rows = []  # (endpoint, vendor, level, n, rps_med, rps_min, rps_max, p50_med, p95_med, p99_med, max_med, err_med)
for endpoint in ENDPOINTS:
    for vendor in VENDORS:
        for level in levels:
            samples = [load(endpoint, vendor, r, level) for r in range(1, runs + 1)]
            samples = [s for s in samples if s]
            if not samples:
                continue
            rps = [s["rps"] for s in samples]
            rows.append((
                endpoint, vendor, level, len(samples),
                med(rps), min(rps), max(rps),
                med([s["p50"] for s in samples]),
                med([s["p95"] for s in samples]),
                med([s["p99"] for s in samples]),
                med([s["max"] for s in samples]),
                med([s["err"] for s in samples]),
            ))

# results.csv (per level)
csv_path = os.path.join(rd, "results.csv")
with open(csv_path, "w") as fh:
    fh.write("endpoint,vendor,concurrency,n_runs,rps_median,rps_min,rps_max,"
             "p50_ms,p95_ms,p99_ms,max_ms,err_pct\n")
    for r in rows:
        fh.write("{},{},{},{},{:.1f},{:.1f},{:.1f},{:.1f},{:.1f},{:.1f},{:.1f},{:.2f}\n".format(*r))

# Peak sustained RPS per (endpoint, vendor): max median-RPS over levels with err < 1%.
peaks = {}
for r in rows:
    endpoint, vendor, level, n, rps_med = r[0], r[1], r[2], r[3], r[4]
    err = r[11]
    if err >= 1.0:
        continue
    key = (endpoint, vendor)
    if key not in peaks or rps_med > peaks[key][0]:
        peaks[key] = (rps_med, level, r[7], r[9])  # rps, level, p50, p99

# comparison.txt
lines = []
lines.append(f"CPU-arch price/perf benchmark -- {runs} runs/config, median reported\n")
for endpoint in ENDPOINTS:
    lines.append(f"\n=== {ENDPOINT_LABEL[endpoint]} ===")
    hdr = f"{'vendor':<22}{'conc':>6}{'RPS(med)':>10}{'RPS range':>16}{'p50':>8}{'p95':>8}{'p99':>8}{'err%':>7}"
    lines.append(hdr)
    lines.append("-" * len(hdr))
    for vendor in VENDORS:
        for level in levels:
            match = [r for r in rows if r[0] == endpoint and r[1] == vendor and r[2] == level]
            if not match:
                continue
            r = match[0]
            rng = f"{r[5]:.0f}-{r[6]:.0f}"
            lines.append(f"{VENDOR_LABEL[vendor]:<22}{level:>6}{r[4]:>10.1f}{rng:>16}"
                         f"{r[7]:>8.1f}{r[8]:>8.1f}{r[9]:>8.1f}{r[11]:>7.2f}")
    lines.append("")
    lines.append(f"  Peak sustained RPS ({ENDPOINT_LABEL[endpoint]}, err<1%):")
    for vendor in VENDORS:
        key = (endpoint, vendor)
        if key in peaks:
            rps, lvl, p50, p99 = peaks[key]
            lines.append(f"    {VENDOR_LABEL[vendor]:<22} {rps:8.1f} RPS  @c{lvl}  (p50 {p50:.1f}ms, p99 {p99:.1f}ms)")
    # relative to Intel baseline
    base = peaks.get((endpoint, "c7i"), (None,))[0]
    if base:
        lines.append(f"    -- relative to Intel c7i (raw throughput, NOT yet price-normalized):")
        for vendor in VENDORS:
            key = (endpoint, vendor)
            if key in peaks:
                lines.append(f"       {VENDOR_LABEL[vendor]:<22} {peaks[key][0] / base * 100:6.1f}% of Intel")

lines.append("\nNOTE: raw throughput only. Price/perf (req/s per $) is computed in arch-charts.py")
lines.append("with date-stamped on-demand prices -- that is the headline, since Graviton/AMD")
lines.append("list prices differ from Intel. A vendor can trail on raw RPS yet win per dollar.")
txt = "\n".join(lines) + "\n"
open(os.path.join(rd, "comparison.txt"), "w").write(txt)
print(txt)
print(f"[arch-summarize] wrote {csv_path} and comparison.txt")
