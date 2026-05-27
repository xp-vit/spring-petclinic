#!/usr/bin/env python3
"""Corrected 2x2 summary dashboard for the JVM-vs-Native write-up.

Pulls sustained/startup/memory from the mixed-run results dir and the 5x
peak sweep from the peak results dir, so every panel reflects the
reproduced findings (not a single-run snapshot).

Usage: summary-dashboard.py [aws-v2 dir] [aws-v2-peak dir]
"""
import json, sys, glob, re
from pathlib import Path
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

MIX = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmark/results/aws-v2")
PEAK = Path(sys.argv[2] if len(sys.argv) > 2 else "benchmark/results/aws-v2-peak")
OUT = MIX / "charts" / "summary-dashboard.png"
OUT.parent.mkdir(parents=True, exist_ok=True)

COLORS = {"jvm": "#e67e22", "native": "#2980b9"}
VARIANTS = ("jvm", "native")
WARMUP_S = 60.0


def read_float(p):
    try:
        return float(Path(p).read_text().strip())
    except Exception:
        return None


def read_mib(p):
    """Parse '388.7MiB / 512MiB\t0.03%' -> 388.7."""
    try:
        s = Path(p).read_text().strip().split("/")[0].strip()
        m = re.match(r"([0-9.]+)\s*([KMG]i?B)", s)
        if not m:
            return None
        val, unit = float(m.group(1)), m.group(2)
        return {"GiB": val * 1024, "MiB": val, "KiB": val / 1024}.get(unit, val)
    except Exception:
        return None


def throughput(v):
    f = MIX / f"{v}-k6-results.csv"
    if not f.exists():
        return None, None
    times = []
    with open(f) as fh:
        for row in csv.DictReader(fh):
            if row.get("metric_name") == "http_reqs":
                times.append(float(row["timestamp"]))
    if not times:
        return None, None
    t0 = min(times)
    buckets = {}
    for t in times:
        b = int((t - t0) // 5) * 5
        buckets[b] = buckets.get(b, 0) + 1
    xs = sorted(buckets)[:-1]  # drop partial last bucket
    ys = [buckets[b] / 5.0 for b in xs]
    return xs, ys


def peak_iters(v):
    pts = []
    for f in glob.glob(str(PEAK / f"{v}-peak-rps-iter*-summary.json")):
        i = int(re.search(r"iter(\d+)", f).group(1))
        pts.append((i, json.load(open(f))["metrics"]["http_reqs"]["rate"]))
    pts.sort()
    return [p[0] for p in pts], [p[1] for p in pts]


fig, axes = plt.subplots(2, 2, figsize=(16, 9))
fig.suptitle("Spring PetClinic on AWS — JVM (JIT) vs GraalVM Native (AOT)",
             fontsize=17, weight="bold")

# (0,0) Cold start, log scale (0.4s vs 16s)
ax = axes[0, 0]
vals = {v: read_float(MIX / f"{v}-process-running-s.txt") for v in VARIANTS}
present = [v for v in VARIANTS if vals.get(v)]
ax.bar(range(len(present)), [vals[v] for v in present],
       color=[COLORS[v] for v in present], width=0.5)
ax.set_yscale("log")
ax.set_xticks(range(len(present))); ax.set_xticklabels(present)
ax.set_ylabel("seconds (log)")
ax.set_title("Cold start: process → ready")
for i, v in enumerate(present):
    ax.text(i, vals[v], f"{vals[v]:.2f}s", ha="center", va="bottom", fontsize=11, weight="bold")
ax.grid(axis="y", alpha=0.3)

# (0,1) Sustained throughput over time
ax = axes[0, 1]
for v in VARIANTS:
    xs, ys = throughput(v)
    if not xs:
        continue
    warm = [y for x, y in zip(xs, ys) if x >= WARMUP_S]
    avg = sum(warm) / len(warm) if warm else sum(ys) / len(ys)
    ax.plot(xs, ys, color=COLORS[v], linewidth=1.8,
            label=f"{v} ({avg:.0f}/s after {WARMUP_S:.0f}s)")
ax.axvline(WARMUP_S, color="gray", ls="--", lw=1, alpha=0.6)
ax.set_xlabel("elapsed (s)"); ax.set_ylabel("req/s (5s buckets)")
ax.set_title("Sustained throughput (50 VUs, 10 min)")
ax.legend(fontsize=9); ax.grid(alpha=0.3)

# (1,0) Peak RPS x5 (reproducibility)
ax = axes[1, 0]
for v in VARIANTS:
    xs, ys = peak_iters(v)
    if not xs:
        continue
    mean = sum(ys) / len(ys)
    ax.plot(xs, ys, "-o", color=COLORS[v], linewidth=2, markersize=7,
            label=f"{v} (mean {mean:.0f}/s)")
ax.set_xlabel("peak sweep iteration (warm container)")
ax.set_ylabel("achieved RPS")
ax.set_title("Peak RPS ×5: JVM warms up, native flat")
ax.set_xticks([1, 2, 3, 4, 5]); ax.legend(fontsize=9); ax.grid(alpha=0.3)

# (1,1) Memory + image size
ax = axes[1, 1]
rss = {v: read_mib(MIX / f"{v}-stats-after-mixed.txt") for v in VARIANTS}
img = {}
for v in VARIANTS:
    b = read_float(MIX / f"{v}-image-size-bytes.txt")
    img[v] = b / 1e6 if b else None
x = [0, 1]; width = 0.35
ax.bar([i - width/2 for i in x], [rss["jvm"] or 0, img["jvm"] or 0], width,
       color=COLORS["jvm"], label="jvm")
ax.bar([i + width/2 for i in x], [rss["native"] or 0, img["native"] or 0], width,
       color=COLORS["native"], label="native")
ax.set_xticks(x); ax.set_xticklabels(["Peak RSS (MiB)", "Image (MB)"])
ax.set_title("Memory & image size — lower is better")
ax.legend(fontsize=9); ax.grid(axis="y", alpha=0.3)
for i, key in enumerate((rss, img)):
    for j, v in enumerate(VARIANTS):
        val = key.get(v)
        if val:
            ax.text(i + (j - 0.5) * width, val, f"{val:.0f}", ha="center", va="bottom", fontsize=9)

fig.tight_layout(rect=[0, 0, 1, 0.97])
fig.savefig(OUT, dpi=110)
print(f"wrote {OUT} ({fig.get_size_inches()[0]/fig.get_size_inches()[1]:.3f} aspect)")
