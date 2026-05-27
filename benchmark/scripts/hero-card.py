#!/usr/bin/env python3
"""Designed hero/OG card for the JVM-vs-Native post: dark branded background,
headline stat tiles, and a real-data throughput sparkline. 16:9.
Usage: hero-card.py [aws-v2 dir]"""
import sys, csv
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

D = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmark/results/aws-v2")
OUT = D / "charts" / "hero-card.png"
OUT.parent.mkdir(parents=True, exist_ok=True)

BG = "#0c1117"; CARD = "#161e27"; WHITE = "#f5f5f7"; GRAY = "#93a4b3"
TEAL = "#14b89c"; AMBER = "#f5a524"


def throughput(v):
    f = D / f"{v}-k6-results.csv"
    if not f.exists():
        return None, None
    t = []
    with open(f) as fh:
        for row in csv.DictReader(fh):
            if row.get("metric_name") == "http_reqs":
                t.append(float(row["timestamp"]))
    if not t:
        return None, None
    t0 = min(t); b = {}
    for x in t:
        k = int((x - t0) // 5) * 5
        b[k] = b.get(k, 0) + 1
    xs = sorted(b)[:-1]
    return xs, [b[k] / 5.0 for k in xs]


fig = plt.figure(figsize=(12, 6.75))
fig.patch.set_facecolor(BG)
ax = fig.add_axes([0, 0, 1, 1]); ax.axis("off")
ax.set_xlim(0, 1); ax.set_ylim(0, 1)

# Title
ax.text(0.055, 0.90, "JVM  vs  GraalVM Native", fontsize=33, color=WHITE,
        weight="bold", va="center")
ax.text(0.945, 0.90, "Spring Boot · AWS", fontsize=15, color=TEAL, va="center", ha="right")
ax.text(0.055, 0.815,
        "The same PetClinic, two builds, on real cloud hardware — re-run until the numbers reproduced.",
        fontsize=13.5, color=GRAY, va="center")

# Stat tiles
tiles = [
    (TEAL,  "~40×",  "faster cold start", "0.3 s  vs  ~15 s"),
    (TEAL,  "2.5–4×", "less memory",  "~100  vs  ~400 MiB"),
    (AMBER, "+22%",       "peak RPS, warm JVM", "470  vs  386"),
    (TEAL,  "386 ±2", "native RPS, run 1", "zero warm-up"),
]
x0, w, gap = 0.055, 0.205, 0.0167
y, h = 0.49, 0.25
for i, (c, big, lab, sub) in enumerate(tiles):
    x = x0 + i * (w + gap)
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.006,rounding_size=0.018",
                 fc=CARD, ec=c, lw=1.8))
    ax.text(x + w/2, y + h*0.64, big, fontsize=27, color=c, weight="bold", ha="center", va="center")
    ax.text(x + w/2, y + h*0.36, lab, fontsize=12, color=WHITE, ha="center", va="center")
    ax.text(x + w/2, y + h*0.15, sub, fontsize=10, color=GRAY, ha="center", va="center")

# Throughput sparkline
spark = fig.add_axes([0.055, 0.10, 0.89, 0.27])
spark.set_facecolor(BG)
for v, col in (("jvm", AMBER), ("native", TEAL)):
    xs, ys = throughput(v)
    if xs:
        spark.plot(xs, ys, color=col, linewidth=2)
        spark.text(xs[-1], ys[-1], f"  {v}", color=col, fontsize=11, va="center", weight="bold")
for s in spark.spines.values():
    s.set_visible(False)
spark.set_xticks([]); spark.set_yticks([])
spark.text(0.0, 1.02, "Throughput over 10 min — JVM warms up (orange), native flat from t0 (teal)",
           transform=spark.transAxes, color=GRAY, fontsize=10.5, va="bottom")

ax.text(0.945, 0.045, "patotski.com", fontsize=12, color=GRAY, ha="right", va="center")

fig.savefig(OUT, dpi=110, facecolor=BG)
print(f"wrote {OUT}")
