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

# VARIANTS is overridable via $BENCH_VARIANTS (space-separated) so we can
# render a chart set that excludes a variant we don't want to publish.
_DEFAULT_VARIANTS = ["jvm", "native", "native-pgo"]
VARIANTS = os.environ.get("BENCH_VARIANTS", " ".join(_DEFAULT_VARIANTS)).split()
COLORS = {"jvm": "#e76f51", "native": "#2a9d8f", "native-pgo": "#1d3557"}

# Seconds to drop from the start of each k6 CSV when computing steady-state
# numbers (lets JIT warm up; native is unaffected).  Override with env
# BENCH_WARMUP_S.
WARMUP_S = float(os.environ.get("BENCH_WARMUP_S", "60"))


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


def steady_state_stats(results_dir: Path, variant: str, kind: str = "k6") -> dict:
    """Return {'rps', 'p50', 'p95', 'p99', 'count'} computed AFTER dropping
    WARMUP_S from the beginning of the k6 CSV.  Lets the JIT settle before
    we measure.  Returns {} if data missing."""
    suffix = "k6-results.csv" if kind == "k6" else "peak-rps.csv"
    p = results_dir / f"{variant}-{suffix}"
    df = load_k6_csv(p)
    if df is None or df.empty:
        return {}
    df = df[df["t"] >= WARMUP_S]
    if df.empty:
        return {}
    reqs = df[df["metric_name"] == "http_reqs"]
    dur = df[df["metric_name"] == "http_req_duration"]
    if reqs.empty or dur.empty:
        return {}
    span = df["t"].max() - WARMUP_S
    rps = len(reqs) / max(span, 1.0)
    durs = pd.to_numeric(dur["metric_value"], errors="coerce").dropna()
    return {
        "rps": rps,
        "p50": durs.quantile(0.50),
        "p95": durs.quantile(0.95),
        "p99": durs.quantile(0.99),
        "count": int(len(reqs)),
        "span_s": span,
    }


def write_steady_state_report(results_dir: Path, out: Path):
    rows = []
    for kind, label in (("k6", "Sustained (50 VUs, 10 min)"),
                        ("peak", "Peak-RPS sweep (5 min ramp)")):
        rows.append(f"## {label} — first {WARMUP_S:.0f}s dropped")
        rows.append("")
        rows.append("| Variant | RPS | p50 | p95 | p99 | Samples | Window |")
        rows.append("|---------|-----|-----|-----|-----|---------|--------|")
        for v in VARIANTS:
            s = steady_state_stats(results_dir, v, kind)
            if s:
                rows.append(
                    f"| {v} | {s['rps']:.1f}/s | {s['p50']:.1f}ms | "
                    f"{s['p95']:.1f}ms | {s['p99']:.1f}ms | {s['count']} | "
                    f"{s['span_s']:.0f}s |"
                )
            else:
                rows.append(f"| {v} | N/A | N/A | N/A | N/A | 0 | 0s |")
        rows.append("")
    out.write_text("\n".join(rows))


def chart_throughput_over_time(results_dir: Path, out: Path):
    # 16:9 aspect (1.778) so it survives the blog hero's object-fit:cover
    # crop without losing the axis labels or legend.
    fig, ax = plt.subplots(figsize=(10, 5.625))
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
        # Drop the last partial bucket -- k6's gracefulStop trims VUs in the
        # final ~second, leaving the last 5-s bucket with only a fraction of
        # its requests and producing a spurious vertical drop to ~0 on the
        # chart.  We strip it as a cosmetic fix; the mean is computed on the
        # trimmed series too.
        if len(rps) > 1:
            rps = rps.iloc[:-1]
        # Plot the full series (so the JIT warm-up ramp stays visible) but
        # compute the legend average on the post-warm-up window only -- the
        # ramp would otherwise drag the JVM's average unfairly low.
        warm = rps[rps.index >= WARMUP_S]
        avg = warm.mean() if len(warm) else rps.mean()
        ax.plot(rps.index, rps.values,
                label=f"{v} ({avg:.0f} req/s avg, after {WARMUP_S:.0f}s warm-up)",
                color=COLORS[v], linewidth=2)
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax.axvline(WARMUP_S, color="gray", linestyle="--", linewidth=1, alpha=0.6)
    ax.text(WARMUP_S + 4, ax.get_ylim()[0] + 10, f"warm-up cutoff ({WARMUP_S:.0f}s)",
            color="gray", fontsize=8, rotation=90, va="bottom")
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
    fig, ax = plt.subplots(figsize=(9, 5))
    present = [v for v in VARIANTS if v in data]
    n = len(present)
    x = list(range(len(labels)))
    width = 0.8 / max(n, 1)
    for idx, v in enumerate(present):
        offset = (idx - (n - 1) / 2.0) * width
        positions = [i + offset for i in x]
        bars = ax.bar(positions, data[v], width, label=v, color=COLORS[v])
        for pos, val in zip(positions, data[v]):
            ax.text(pos, val, f"{val:.1f}", ha="center", va="bottom", fontsize=8)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Latency (ms)")
    ax.set_title("HTTP request latency percentiles")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def chart_startup_bar(results_dir: Path, out: Path):
    cold = {v: read_int(results_dir / f"{v}-startup-ms.txt") for v in VARIANTS}
    if not any(cold.values()):
        return
    present = [v for v in VARIANTS if cold.get(v)]
    fig, ax = plt.subplots(figsize=(9, 5))
    x = list(range(len(present)))
    cold_vals = [cold.get(v) or 0 for v in present]
    ax.bar(x, cold_vals, 0.5, color=[COLORS[v] for v in present])
    ax.set_xticks(x)
    ax.set_xticklabels(present)
    ax.set_ylabel("Time to first 200 (ms)")
    ax.set_title("Cold start time")
    ax.grid(axis="y", alpha=0.3)
    for i, val in enumerate(cold_vals):
        if val: ax.text(i, val, f"{val}", ha="center", va="bottom", fontsize=9)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


_MEM_UNITS = {
    "GiB": 1024 ** 3, "MiB": 1024 ** 2, "KiB": 1024,
    "GB": 1000 ** 3, "MB": 1000 ** 2, "KB": 1000, "B": 1,
}


def _parse_mem(s: str) -> float | None:
    """Parse a docker-stats memory string like '405.6MiB' into bytes."""
    if not s:
        return None
    s = s.strip()
    for unit in sorted(_MEM_UNITS, key=len, reverse=True):
        if s.endswith(unit):
            try:
                return float(s[: -len(unit)]) * _MEM_UNITS[unit]
            except ValueError:
                return None
    return None


def _peak_rss_mib(results_dir: Path, variant: str):
    """Prefer the docker-stats post-load snapshot in *-stats-after-mixed.txt
    (the steady-state phase), then *-stats-after.txt (legacy), then fall
    back to the time-series stats.csv if available."""
    candidates = [
        results_dir / f"{variant}-stats-after-mixed.txt",
        results_dir / f"{variant}-stats-after.txt",
        results_dir / f"{variant}-stats-after-peak.txt",
    ]
    for after in candidates:
        if not after.exists():
            continue
        line = after.read_text(errors="ignore").strip()
        # Format: "405.6MiB / 512MiB\t0.12%"
        mem_part = line.split("/", 1)[0].strip() if "/" in line else line.split()[0]
        b = _parse_mem(mem_part)
        if b is not None:
            return b / (1024 ** 2)
    for stats_csv in (
        results_dir / f"{variant}-stats-mixed.csv",
        results_dir / f"{variant}-stats.csv",
    ):
        df = load_stats(stats_csv)
        if df is not None and not df.empty:
            peak = df["mem_mib"].max()
            if peak and peak > 0:
                return peak
    return None


def chart_memory_peak_bar(results_dir: Path, out: Path):
    """Single peak-RSS bar per variant.  Reads the post-load docker-stats
    snapshot in {variant}-stats-after.txt — the time-series stats.csv from
    earlier benchmark runs has zeroed memory due to a parser bug fixed in
    a later commit, so we don't rely on it here."""
    peaks = {}
    for v in VARIANTS:
        p = _peak_rss_mib(results_dir, v)
        if p is not None and p > 0:
            peaks[v] = p
    if not peaks:
        return
    fig, ax = plt.subplots(figsize=(6, 4))
    names = list(peaks.keys())
    vals = [peaks[v] for v in names]
    ax.bar(names, vals, color=[COLORS[v] for v in names])
    ax.set_ylabel("Peak RSS (MiB)")
    ax.set_title("Memory (peak RSS during load)")
    for i, val in enumerate(vals):
        ax.text(i, val, f"{val:.0f} MiB", ha="center", va="bottom", fontsize=10)
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=120)
    plt.close(fig)


def _load_stats_for_phase(results_dir: Path, variant: str, phase: str):
    """Prefer the phase-specific CSV (variant-stats-{phase}.csv), fall back
    to the legacy single-CSV file."""
    p = results_dir / f"{variant}-stats-{phase}.csv"
    if p.exists():
        return load_stats(p), phase
    return load_stats(results_dir / f"{variant}-stats.csv"), "legacy"


def chart_cpu_over_time(results_dir: Path, out: Path):
    """CPU over time, preferring the mixed-workload phase (sustained
    steady-state) if available, falling back to whatever stats.csv holds."""
    fig, ax = plt.subplots(figsize=(10, 5))
    plotted = False
    phases_seen = set()
    for v in VARIANTS:
        df, phase = _load_stats_for_phase(results_dir, v, "mixed")
        if df is None or df.empty:
            continue
        phases_seen.add(phase)
        ax.plot(df["elapsed"], df["cpu_pct"],
                label=f"{v} (mean {df['cpu_pct'].mean():.0f}%)",
                color=COLORS[v], linewidth=2, alpha=0.85)
        plotted = True
    if not plotted:
        plt.close(fig); return
    ax.set_xlabel("Elapsed time (s)")
    ax.set_ylabel("CPU (% of one core × N)")
    phase_note = "mixed-workload phase" if phases_seen == {"mixed"} else "last sampled phase"
    ax.set_title(f"CPU usage over time ({phase_note})")
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


def chart_peak_rps(results_dir: Path, out: Path):
    """Achieved RPS over time + p95 latency overlay from the peak-RPS sweep.
    Title shows the *sustained* steady-state RPS (post-warmup average from
    steady_state_stats), not the per-bucket maximum -- the per-bucket max
    on JVM is dominated by late queue drain, not true throughput."""
    fig, ax1 = plt.subplots(figsize=(10, 5))
    ax2 = ax1.twinx()
    plotted = False
    summary_bits = []
    for v in VARIANTS:
        df = load_k6_csv(results_dir / f"{v}-peak-rps.csv")
        if df is None:
            continue
        reqs = df[df["metric_name"] == "http_reqs"]
        dur = df[df["metric_name"] == "http_req_duration"]
        if reqs.empty:
            continue
        bucket = (reqs["t"] // 5).astype(int) * 5
        rps = reqs.groupby(bucket).size() / 5.0
        if len(rps) > 1:
            rps = rps.iloc[:-1]  # trim partial final bucket
        ax1.plot(rps.index, rps.values, label=f"{v} RPS",
                 color=COLORS[v], linewidth=2)
        if not dur.empty:
            dur_bucket = (dur["t"] // 5).astype(int) * 5
            p95 = dur.groupby(dur_bucket)["metric_value"].quantile(0.95)
            if len(p95) > 1:
                p95 = p95.iloc[:-1]
            ax2.plot(p95.index, p95.values, label=f"{v} p95 (ms)",
                     color=COLORS[v], linewidth=1.5, linestyle="--", alpha=0.7)
        s = steady_state_stats(results_dir, v, kind="peak")
        if s:
            summary_bits.append(f"{v}: {s['rps']:.0f} req/s sustained, "
                                f"p99 {s['p99']:.0f} ms")
        plotted = True
    if not plotted:
        plt.close(fig)
        return
    ax1.set_xlabel("Elapsed (s)")
    ax1.set_ylabel("Achieved RPS (5s bucket)")
    ax2.set_ylabel("p95 latency (ms, dashed)")
    title = "Peak-RPS sweep (100 → 2000 req/s ramp over 5 min)"
    if summary_bits:
        title += "\n" + "  |  ".join(summary_bits)
    ax1.set_title(title, fontsize=10)
    ax1.grid(alpha=0.3)
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper left", fontsize=9)
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
    present_s = [v for v in VARIANTS if cold.get(v)]
    x = list(range(len(present_s)))
    cold_vals = [cold.get(v) or 0 for v in present_s]
    ax.bar(x, cold_vals, 0.5, color=[COLORS[v] for v in present_s])
    ax.set_xticks(x); ax.set_xticklabels(present_s)
    ax.set_ylabel("Time to first 200 (ms)")
    ax.set_title("Cold start time")
    ax.grid(axis="y", alpha=0.3)
    for i, val in enumerate(cold_vals):
        if val: ax.text(i, val, f"{val}", ha="center", va="bottom", fontsize=8)

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
        if len(rps) > 1:
            rps = rps.iloc[:-1]  # trim partial final bucket
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
        present_l = [v for v in VARIANTS if v in data]
        n = len(present_l)
        xs = list(range(len(labels)))
        width = 0.8 / max(n, 1)
        for idx, v in enumerate(present_l):
            offset = (idx - (n - 1) / 2.0) * width
            positions = [i + offset for i in xs]
            ax.bar(positions, data[v], width, label=v, color=COLORS[v])
            for pos, val in zip(positions, data[v]):
                ax.text(pos, val, f"{val:.1f}", ha="center", va="bottom", fontsize=7)
        ax.set_xticks(xs); ax.set_xticklabels(labels)
        ax.set_ylabel("Latency (ms)")
        ax.set_title("Latency percentiles")
        ax.legend(fontsize=9); ax.grid(axis="y", alpha=0.3)

    # 4) Peak memory (bottom-right)
    ax = axes[1, 1]
    peaks = {}
    for v in VARIANTS:
        p = _peak_rss_mib(results_dir, v)
        if p is not None and p > 0:
            peaks[v] = p
    if peaks:
        names = list(peaks.keys())
        vals = [peaks[v] for v in names]
        ax.bar(names, vals, color=[COLORS[v] for v in names])
        ax.set_ylabel("Peak RSS (MiB)")
        ax.set_title("Memory (peak RSS during load)")
        ax.grid(axis="y", alpha=0.3)
        for i, val in enumerate(vals):
            ax.text(i, val, f"{val:.0f} MiB", ha="center", va="bottom", fontsize=8)

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
    chart_memory_peak_bar(results_dir, out_dir / "memory-peak-bar.png")
    chart_cpu_over_time(results_dir, out_dir / "cpu-over-time.png")
    chart_image_size(results_dir, out_dir / "image-size-bar.png")
    chart_gc_pauses(results_dir, out_dir / "gc-pause-hist.png")
    chart_peak_rps(results_dir, out_dir / "peak-rps.png")
    chart_summary_dashboard(results_dir, out_dir / "summary-dashboard.png")
    write_steady_state_report(results_dir, results_dir / "steady-state-report.md")

    pngs = sorted(out_dir.glob("*.png"))
    print(f"Wrote {len(pngs)} charts to {out_dir}")
    for p in pngs:
        print(f"  - {p.name}")


if __name__ == "__main__":
    main()
