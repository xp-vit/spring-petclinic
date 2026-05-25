#!/usr/bin/env python3
"""Generate PNG charts from local benchmark results.

Inputs (per variant in {jvm, native}, in RESULTS_DIR):
  {v}-startup-ms.txt
  {v}-cold-start-ms.txt        (optional)
  {v}-image-size-bytes.txt
  {v}-stats.csv                (ts,cpu_pct,mem_bytes)
  {v}-k6-results.csv           (k6 native CSV output)
  {v}-k6-summary.json          (k6 summary)
  {v}-gc/gc.log                (JVM only)

Outputs (PNGs in RESULTS_DIR/charts):
  throughput-over-time.png, latency-bars.png, startup-bar.png,
  memory-over-time.png, cpu-over-time.png, image-size-bar.png,
  gc-pause-hist.png (JVM)
"""
import json
import os
import re
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

VARIANTS = ["jvm", "native"]
COLORS = {"jvm": "#e76f51", "native": "#2a9d8f"}


def read_text(p: Path):
    try:
        return p.read_text().strip()
    except FileNotFoundError:
        return None


def read_int(p: Path):
    v = read_text(p)
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def load_summary(p: Path):
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError:
        return {}


def load_stats(p: Path):
    if not p.exists():
        return None
    try:
        df = pd.read_csv(p)
    except (pd.errors.EmptyDataError, FileNotFoundError):
        return None
    if df.empty:
        return None
    df["ts"] = df["ts"].astype(float)
    df["elapsed"] = df["ts"] - df["ts"].iloc[0]
    df["mem_mib"] = df["mem_bytes"] / (1024 ** 2)
    df["cpu_pct"] = pd.to_numeric(df["cpu_pct"], errors="coerce")
    return df


def load_k6_csv(p: Path):
    if not p.exists():
        return None
    df = pd.read_csv(p, low_memory=False)
    df["timestamp"] = pd.to_numeric(df["timestamp"], errors="coerce")
    df = df.dropna(subset=["timestamp"])
    df["t"] = df["timestamp"] - df["timestamp"].min()
    return df


def chart_throughput_over_time(results_dir: Path, out: Path):
    fig, ax = plt.subplots(figsize=(10, 5))
    plotted = False
    for v in VARIANTS:
        df = load_k6_csv(results_dir / f"{v}-k6-results.csv")
        if df is None:
            continue
        reqs = df[df["metric_name"] == "http_reqs"]
        if reqs.empty:
            continue
        bucket = (reqs["t"] // 5).astype(int) * 5
        rps = reqs.groupby(bucket).size() / 5.0
        ax.plot(rps.index, rps.values, label=f"{v} ({rps.mean():.0f} req/s avg)",
                color=COLORS[v], linewidth=2)
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("Throughput (req/s, 5s buckets)")
    ax.set_title("Throughput over time: JVM (JIT warmup) vs Native (AOT)")
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_latency_bars(results_dir: Path, out: Path):
    # k6 summary fields: med (p50), p(90), p(95), p(99) when summaryTrendStats configured.
    metric_keys = ["med", "p(95)", "p(99)"]
    labels = ["p50", "p95", "p99"]
    data = {}
    for v in VARIANTS:
        s = load_summary(results_dir / f"{v}-k6-summary.json")
        d = s.get("metrics", {}).get("http_req_duration", {})
        if d:
            data[v] = [d.get(k, 0) for k in metric_keys]
    if not data:
        return
    fig, ax = plt.subplots(figsize=(8, 5))
    x = range(len(labels))
    width = 0.35
    if "jvm" in data:
        ax.bar([i - width/2 for i in x], data["jvm"], width, label="JVM",
               color=COLORS["jvm"])
    if "native" in data:
        ax.bar([i + width/2 for i in x], data["native"], width, label="Native",
               color=COLORS["native"])
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels)
    ax.set_ylabel("Latency (ms)")
    ax.set_title("HTTP request latency percentiles")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    for i, l in enumerate(labels):
        if "jvm" in data:
            ax.text(i - width/2, data["jvm"][i], f"{data['jvm'][i]:.1f}",
                    ha="center", va="bottom", fontsize=9)
        if "native" in data:
            ax.text(i + width/2, data["native"][i], f"{data['native'][i]:.1f}",
                    ha="center", va="bottom", fontsize=9)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_startup_bar(results_dir: Path, out: Path):
    cold = {}
    under_load = {}
    for v in VARIANTS:
        cold[v] = read_int(results_dir / f"{v}-startup-ms.txt")
        under_load[v] = read_int(results_dir / f"{v}-cold-start-ms.txt")
    if not any(cold.values()) and not any(under_load.values()):
        return
    fig, ax = plt.subplots(figsize=(8, 5))
    x = [0, 1]
    width = 0.35
    cold_vals = [cold.get("jvm") or 0, cold.get("native") or 0]
    load_vals = [under_load.get("jvm") or 0, under_load.get("native") or 0]
    ax.bar([i - width/2 for i in x], cold_vals, width, label="Cold start (no load)",
           color=["#e76f51", "#2a9d8f"])
    ax.bar([i + width/2 for i in x], load_vals, width,
           label="Cold start under load", color=["#f4a261", "#264653"])
    ax.set_xticks(x)
    ax.set_xticklabels(["JVM", "Native"])
    ax.set_ylabel("Time to first 200 (ms)")
    ax.set_title("Startup time")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    for i, val in enumerate(cold_vals):
        if val: ax.text(i - width/2, val, f"{val}", ha="center", va="bottom", fontsize=9)
    for i, val in enumerate(load_vals):
        if val: ax.text(i + width/2, val, f"{val}", ha="center", va="bottom", fontsize=9)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_memory_over_time(results_dir: Path, out: Path):
    fig, ax = plt.subplots(figsize=(10, 5))
    plotted = False
    for v in VARIANTS:
        df = load_stats(results_dir / f"{v}-stats.csv")
        if df is None or df.empty:
            continue
        ax.plot(df["elapsed"], df["mem_mib"],
                label=f"{v} (peak {df['mem_mib'].max():.0f} MiB)",
                color=COLORS[v], linewidth=2)
        plotted = True
    if not plotted:
        plt.close(fig); return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("RSS (MiB)")
    ax.set_title("Memory (RSS) over time during load")
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_cpu_over_time(results_dir: Path, out: Path):
    fig, ax = plt.subplots(figsize=(10, 5))
    plotted = False
    for v in VARIANTS:
        df = load_stats(results_dir / f"{v}-stats.csv")
        if df is None or df.empty:
            continue
        ax.plot(df["elapsed"], df["cpu_pct"],
                label=f"{v} (mean {df['cpu_pct'].mean():.0f}%)",
                color=COLORS[v], linewidth=2, alpha=0.85)
        plotted = True
    if not plotted:
        plt.close(fig); return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("CPU (% of one core × N)")
    ax.set_title("CPU usage over time (JIT warmup curve vs native flat)")
    ax.legend()
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_image_size(results_dir: Path, out: Path):
    sizes = {}
    for v in VARIANTS:
        b = read_int(results_dir / f"{v}-image-size-bytes.txt")
        if b:
            sizes[v] = b / (1024 ** 2)
    if not sizes:
        return
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.bar(list(sizes.keys()), list(sizes.values()),
           color=[COLORS[v] for v in sizes.keys()])
    ax.set_ylabel("Image size (MB)")
    ax.set_title("Docker image size")
    for i, (k, val) in enumerate(sizes.items()):
        ax.text(i, val, f"{val:.0f} MB", ha="center", va="bottom", fontsize=10)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


GC_PAUSE_RE = re.compile(r"Pause.*?(\d+\.\d+)ms")


def parse_gc_log(p: Path):
    if not p.exists():
        return []
    pauses = []
    for line in p.read_text(errors="ignore").splitlines():
        m = GC_PAUSE_RE.search(line)
        if m:
            try:
                pauses.append(float(m.group(1)))
            except ValueError:
                pass
    return pauses


def chart_gc_pauses(results_dir: Path, out: Path):
    gc_dir = results_dir / "jvm-gc"
    pauses = []
    if gc_dir.exists():
        for log in gc_dir.glob("gc.log*"):
            pauses.extend(parse_gc_log(log))
    if not pauses:
        return
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.hist(pauses, bins=30, color=COLORS["jvm"], edgecolor="black", alpha=0.85)
    ax.set_xlabel("Pause (ms)")
    ax.set_ylabel("Count")
    ax.set_title(f"JVM GC pause distribution (n={len(pauses)}, "
                 f"mean={sum(pauses)/len(pauses):.2f}ms, "
                 f"max={max(pauses):.2f}ms)")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_summary_dashboard(results_dir: Path, out: Path):
    """Single 2x2 PNG combining startup, throughput, latency, memory.
    Designed for LinkedIn / blog hero image."""
    fig, axes = plt.subplots(2, 2, figsize=(14, 9))
    fig.suptitle("Spring PetClinic: JVM (JIT) vs Native (AOT)", fontsize=15, weight="bold")

    # 1) Startup bars (top-left)
    ax = axes[0, 0]
    cold = {v: read_int(results_dir / f"{v}-startup-ms.txt") for v in VARIANTS}
    load = {v: read_int(results_dir / f"{v}-cold-start-ms.txt") for v in VARIANTS}
    x = [0, 1]
    width = 0.35
    cold_vals = [cold.get("jvm") or 0, cold.get("native") or 0]
    load_vals = [load.get("jvm") or 0, load.get("native") or 0]
    ax.bar([i - width/2 for i in x], cold_vals, width, label="Cold (no load)", color=["#e76f51", "#2a9d8f"])
    ax.bar([i + width/2 for i in x], load_vals, width, label="Cold under load", color=["#f4a261", "#264653"])
    ax.set_xticks(x); ax.set_xticklabels(["JVM", "Native"])
    ax.set_ylabel("Time to first 200 (ms)")
    ax.set_title("Startup time")
    ax.legend(fontsize=9)
    ax.grid(axis="y", alpha=0.3)
    for i, val in enumerate(cold_vals):
        if val: ax.text(i - width/2, val, f"{val}", ha="center", va="bottom", fontsize=8)
    for i, val in enumerate(load_vals):
        if val: ax.text(i + width/2, val, f"{val}", ha="center", va="bottom", fontsize=8)

    # 2) Throughput over time (top-right)
    ax = axes[0, 1]
    for v in VARIANTS:
        df = load_k6_csv(results_dir / f"{v}-k6-results.csv")
        if df is None:
            continue
        reqs = df[df["metric_name"] == "http_reqs"]
        if reqs.empty:
            continue
        bucket = (reqs["t"] // 5).astype(int) * 5
        rps = reqs.groupby(bucket).size() / 5.0
        ax.plot(rps.index, rps.values, label=f"{v} ({rps.mean():.0f}/s)", color=COLORS[v], linewidth=2)
    ax.set_xlabel("Elapsed (s)"); ax.set_ylabel("Throughput (req/s)")
    ax.set_title("Throughput over time")
    ax.legend(fontsize=9); ax.grid(alpha=0.3)

    # 3) Latency p50/p95/p99 (bottom-left)
    ax = axes[1, 0]
    metric_keys = ["med", "p(95)", "p(99)"]
    labels = ["p50", "p95", "p99"]
    data = {}
    for v in VARIANTS:
        s = load_summary(results_dir / f"{v}-k6-summary.json")
        d = s.get("metrics", {}).get("http_req_duration", {})
        if d:
            data[v] = [d.get(k, 0) for k in metric_keys]
    if data:
        xs = range(len(labels)); width = 0.35
        if "jvm" in data:
            ax.bar([i - width/2 for i in xs], data["jvm"], width, label="JVM", color=COLORS["jvm"])
        if "native" in data:
            ax.bar([i + width/2 for i in xs], data["native"], width, label="Native", color=COLORS["native"])
        ax.set_xticks(list(xs)); ax.set_xticklabels(labels)
        ax.set_ylabel("Latency (ms)")
        ax.set_title("Latency percentiles")
        ax.legend(fontsize=9); ax.grid(axis="y", alpha=0.3)
        for i, _ in enumerate(labels):
            if "jvm" in data:
                ax.text(i - width/2, data["jvm"][i], f"{data['jvm'][i]:.1f}", ha="center", va="bottom", fontsize=8)
            if "native" in data:
                ax.text(i + width/2, data["native"][i], f"{data['native'][i]:.1f}", ha="center", va="bottom", fontsize=8)

    # 4) Memory over time (bottom-right)
    ax = axes[1, 1]
    for v in VARIANTS:
        df = load_stats(results_dir / f"{v}-stats.csv")
        if df is None or df.empty:
            continue
        ax.plot(df["elapsed"], df["mem_mib"],
                label=f"{v} (peak {df['mem_mib'].max():.0f} MiB)",
                color=COLORS[v], linewidth=2)
    ax.set_xlabel("Elapsed (s)"); ax.set_ylabel("RSS (MiB)")
    ax.set_title("Memory (RSS) over time")
    ax.legend(fontsize=9); ax.grid(alpha=0.3)

    fig.tight_layout(rect=[0, 0, 1, 0.96])
    fig.savefig(out, dpi=130)
    plt.close(fig)


def main():
    if len(sys.argv) < 2:
        print("Usage: charts.py RESULTS_DIR")
        sys.exit(2)
    results_dir = Path(sys.argv[1]).resolve()
    out_dir = results_dir / "charts"
    out_dir.mkdir(parents=True, exist_ok=True)

    chart_throughput_over_time(results_dir, out_dir / "throughput-over-time.png")
    chart_latency_bars(results_dir, out_dir / "latency-bars.png")
    chart_startup_bar(results_dir, out_dir / "startup-bar.png")
    chart_memory_over_time(results_dir, out_dir / "memory-over-time.png")
    chart_cpu_over_time(results_dir, out_dir / "cpu-over-time.png")
    chart_image_size(results_dir, out_dir / "image-size-bar.png")
    chart_gc_pauses(results_dir, out_dir / "gc-pause-hist.png")
    chart_summary_dashboard(results_dir, out_dir / "summary-dashboard.png")

    pngs = sorted(out_dir.glob("*.png"))
    print(f"Wrote {len(pngs)} charts to {out_dir}")
    for p in pngs:
        print(f"  - {p.name}")


if __name__ == "__main__":
    main()
