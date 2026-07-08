#!/usr/bin/env python3
"""Per-concurrency-level footprint for the virtual-thread benchmark + memory curve chart.

Correlates the app-side resource samples (`<tag>-appstats.csv`: ts,cpu_pct,mem_bytes) with the
k6-side thread samples (`<tag>-threads.csv`: ts,level,platform_threads) by timestamp: each
concurrency level defines a time window (its min..max sample ts), and every appstats sample
falling in that window is attributed to that level. Emits:
  - results-perlevel.csv : tag,concurrency,peak_mem_mb,avg_mem_mb,avg_cpu_pct,peak_threads
  - charts/memory-vs-concurrency.png : peak heap MB vs concurrency, platform vs virtual (slow)

Usage: loom-charts.py [results dir]   (default benchmark/results/aws-loom)
"""
import sys
import csv
import os
from pathlib import Path
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

D = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmark/results/aws-loom")


def level_windows(tag):
    """min/max ts per concurrency level from the threads CSV."""
    f = D / f"{tag}-threads.csv"
    if not f.is_file():
        return {}
    lo, hi = {}, {}
    with open(f) as fh:
        next(fh, None)
        for line in fh:
            p = line.strip().split(",")
            if len(p) != 3:
                continue
            try:
                ts, lvl = float(p[0]), int(p[1])
            except ValueError:
                continue
            lo[lvl] = min(lo.get(lvl, ts), ts)
            hi[lvl] = max(hi.get(lvl, ts), ts)
    return {lvl: (lo[lvl], hi[lvl]) for lvl in lo}


def appstats(tag):
    f = D / f"{tag}-appstats.csv"
    rows = []
    if not f.is_file():
        return rows
    with open(f) as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append((float(r["ts"]), float(r["cpu_pct"]), int(r["mem_bytes"])))
            except (ValueError, KeyError):
                pass
    return rows


def peak_threads_for(tag, lvl):
    f = D / f"{tag}-threads.csv"
    mx = 0
    if not f.is_file():
        return ""
    with open(f) as fh:
        next(fh, None)
        for line in fh:
            p = line.strip().split(",")
            if len(p) == 3 and p[1] == str(lvl):
                try:
                    mx = max(mx, int(p[2]))
                except ValueError:
                    pass
    return mx or ""


# Discover tags from appstats files.
tags = sorted(p.name[:-len("-appstats.csv")] for p in D.glob("*-appstats.csv"))

rows_out = ["tag,concurrency,peak_mem_mb,avg_mem_mb,avg_cpu_pct,peak_threads"]
# per-tag: {level: (peak_mb, avg_mb, avg_cpu)}
perlevel = defaultdict(dict)
for tag in tags:
    wins = level_windows(tag)
    stats = appstats(tag)
    if not wins or not stats:
        continue
    buckets = defaultdict(list)  # level -> list of (cpu, mem)
    for ts, cpu, mem in stats:
        for lvl, (a, b) in wins.items():
            if a <= ts <= b:
                buckets[lvl].append((cpu, mem))
                break
    for lvl in sorted(buckets):
        vals = buckets[lvl]
        mems = [m for _, m in vals]
        cpus = [c for c, _ in vals]
        peak_mb = max(mems) / 1e6
        avg_mb = sum(mems) / len(mems) / 1e6
        avg_cpu = sum(cpus) / len(cpus)
        perlevel[tag][lvl] = (peak_mb, avg_mb, avg_cpu)
        rows_out.append(f"{tag},{lvl},{peak_mb:.1f},{avg_mb:.1f},{avg_cpu:.1f},{peak_threads_for(tag,lvl)}")

(D / "results-perlevel.csv").write_text("\n".join(rows_out) + "\n")
print("Wrote", D / "results-perlevel.csv")
print("\n".join(rows_out))

# --- Chart: peak heap MB vs concurrency, platform vs virtual (slow endpoint) ---
COLORS = {"slow-platform": "#e67e22", "slow-virtual": "#2980b9"}
LABELS = {"slow-platform": "platform threads", "slow-virtual": "virtual threads"}
fig, ax = plt.subplots(figsize=(9, 5.2))
plotted = False
for tag in ("slow-platform", "slow-virtual"):
    if tag not in perlevel:
        continue
    lvls = sorted(perlevel[tag])
    peaks = [perlevel[tag][l][0] for l in lvls]
    ax.plot(lvls, peaks, marker="o", linewidth=2.2, color=COLORS[tag], label=LABELS[tag])
    for x, y in zip(lvls, peaks):
        ax.annotate(f"{y:.0f}", (x, y), textcoords="offset points", xytext=(0, 8),
                    ha="center", fontsize=8, color=COLORS[tag])
    plotted = True

ax.set_xscale("log")
ax.set_xticks(sorted({l for t in ("slow-platform", "slow-virtual") if t in perlevel for l in perlevel[t]}))
ax.get_xaxis().set_major_formatter(matplotlib.ticker.ScalarFormatter())
ax.set_xlabel("Concurrency (in-flight requests)")
ax.set_ylabel("Peak app heap during level (MB)")
ax.set_title("Memory footprint vs concurrency — /api/slow (200ms downstream)\n"
             "Virtual threads keep more requests live at once, so they use more heap")
ax.grid(True, alpha=0.3)
ax.legend()
out = D / "charts" / "memory-vs-concurrency.png"
out.parent.mkdir(parents=True, exist_ok=True)
if plotted:
    fig.tight_layout()
    fig.savefig(out, dpi=130)
    print("Wrote", out)
else:
    print("No slow-platform/slow-virtual data to chart")
