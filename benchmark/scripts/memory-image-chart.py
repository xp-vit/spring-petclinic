#!/usr/bin/env python3
"""Combined memory (peak RSS) + image-size bar chart, JVM vs Native.
Usage: memory-image-chart.py [results dir]"""
import sys, re
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

D = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmark/results/aws-v2")
OUT = D / "charts" / "memory-image-bar.png"
OUT.parent.mkdir(parents=True, exist_ok=True)
COLORS = {"jvm": "#e67e22", "native": "#2980b9"}
VARIANTS = ("jvm", "native")


def read_mib(p):
    try:
        s = Path(p).read_text().strip().split("/")[0].strip()
        m = re.match(r"([0-9.]+)\s*([KMG]i?B)", s)
        val, unit = float(m.group(1)), m.group(2)
        return {"GiB": val * 1024, "MiB": val, "KiB": val / 1024}.get(unit, val)
    except Exception:
        return None


def read_mb(p):
    try:
        return float(Path(p).read_text().strip()) / 1e6
    except Exception:
        return None


rss = {v: read_mib(D / f"{v}-stats-after-mixed.txt") for v in VARIANTS}
img = {v: read_mb(D / f"{v}-image-size-bytes.txt") for v in VARIANTS}

fig, ax = plt.subplots(figsize=(9, 5))
x = [0, 1]; w = 0.36
ax.bar([i - w/2 for i in x], [rss["jvm"] or 0, img["jvm"] or 0], w, color=COLORS["jvm"], label="JVM")
ax.bar([i + w/2 for i in x], [rss["native"] or 0, img["native"] or 0], w, color=COLORS["native"], label="Native")
ax.set_xticks(x); ax.set_xticklabels(["Peak RSS under load (MiB)", "Container image (MB)"])
ax.set_ylabel("lower is better")
ax.set_title("Memory & image size: JVM vs Native")
ax.legend()
ax.grid(axis="y", alpha=0.3)
for i, d in enumerate((rss, img)):
    for j, v in enumerate(VARIANTS):
        val = d.get(v)
        if val:
            ax.text(i + (j - 0.5) * w, val, f"{val:.0f}", ha="center", va="bottom", fontsize=10, weight="bold")
fig.tight_layout()
fig.savefig(OUT, dpi=120)
print(f"wrote {OUT}")
