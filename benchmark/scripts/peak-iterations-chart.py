#!/usr/bin/env python3
"""Plot peak-RPS per iteration (reproducibility view): JVM warms up across
runs while native is flat from the first. Reads {v}-peak-rps-iterN-summary.json."""
import json, sys, glob, re
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmark/results/aws-v2-peak")
out = results_dir / "charts" / "peak-iterations.png"
out.parent.mkdir(parents=True, exist_ok=True)

COLORS = {"jvm": "#e67e22", "native": "#2980b9"}
fig, ax = plt.subplots(figsize=(9, 5))
for v in ("jvm", "native"):
    pts = []
    for f in glob.glob(str(results_dir / f"{v}-peak-rps-iter*-summary.json")):
        i = int(re.search(r"iter(\d+)", f).group(1))
        rate = json.load(open(f))["metrics"]["http_reqs"]["rate"]
        pts.append((i, rate))
    if not pts:
        continue
    pts.sort()
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    mean = sum(ys) / len(ys)
    ax.plot(xs, ys, "-o", color=COLORS[v], linewidth=2, markersize=7,
            label=f"{v} (mean {mean:.0f}/s)")
    for x, y in pts:
        ax.annotate(f"{y:.0f}", (x, y), textcoords="offset points",
                    xytext=(0, 8), ha="center", fontsize=8, color=COLORS[v])

ax.set_xlabel("Peak-RPS sweep iteration (same warm container)")
ax.set_ylabel("Achieved RPS at saturation")
ax.set_title("Peak-RPS reproducibility: JVM warms up, native is flat from run 1")
ax.set_xticks([1, 2, 3, 4, 5])
ax.grid(alpha=0.3)
ax.legend()
fig.tight_layout()
fig.savefig(out, dpi=120)
print(f"wrote {out}")
