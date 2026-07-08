#!/usr/bin/env python3
"""Price/performance charts + tables for the CPU-arch benchmark (Intel vs AMD vs Graviton).

Consumes results.csv (from arch-summarize.py) and on-demand prices, and emits the headline
money charts:
  charts/reqs-per-dollar.png     req/s per $/hr, grouped by endpoint  (THE headline)
  charts/cost-per-million.png    $ per million requests
  charts/raw-throughput.png      peak sustained RPS (raw, not normalized)
  charts/p99-latency.png         p99 at the peak-throughput level
  arch-priceperf.csv             machine-readable price/perf table
It also prints the price/perf table and compares the measured Graviton advantage against
AWS's ~40% price-performance marketing claim -- honestly, with whatever the data says.

PRICES: pass a prices.json in the results dir:
  {"_region":"eu-central-1","_date":"2026-07-08","c7i":0.0,"c7a":0.0,"c7g":0.0}
pulled from live on-demand pricing on run day. If absent, a DATED built-in ESTIMATE is used
and every output is stamped with a loud "ESTIMATE -- verify before publish" warning, because
on-demand prices move and vary by region.

Usage: arch-charts.py [results dir]   (default benchmark/results/aws-arch)
"""
import csv
import json
import os
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

D = Path(sys.argv[1] if len(sys.argv) > 1 else "benchmark/results/aws-arch")

VENDORS = ["c7i", "c7a", "c7g"]
VENDOR_LABEL = {"c7i": "Intel\nc7i.large", "c7a": "AMD\nc7a.large", "c7g": "Graviton3\nc7g.large"}
VENDOR_COLOR = {"c7i": "#3b6fb0", "c7a": "#c0504d", "c7g": "#e59400"}
ENDPOINTS = ["cpu", "render"]
ENDPOINT_LABEL = {"cpu": "synthetic (/api/cpu)", "render": "real (/api/render)"}

# Built-in DATED estimate -- eu-central-1 on-demand Linux $/hr. MUST be re-verified on run day.
PRICE_FALLBACK = {"_region": "eu-central-1", "_date": "2026-07-08-ESTIMATE",
                  "c7i": 0.0952, "c7a": 0.10264, "c7g": 0.0723}


def load_prices():
    f = D / "prices.json"
    if f.is_file():
        p = json.load(open(f))
        return p, False
    return PRICE_FALLBACK, True


def load_results():
    """Returns (peaks, speed):
       peaks[(endpoint,vendor)] = peak sustained throughput (max median-RPS at err<1%).
       speed[(endpoint,vendor)] = single-request p50 at the lowest concurrency (raw speed).
    """
    peaks = {}
    rows = []
    f = D / "results.csv"
    if not f.is_file():
        sys.exit(f"ERROR: {f} not found -- run arch-summarize.py first")
    for row in csv.DictReader(open(f)):
        rows.append(row)
        if float(row["err_pct"]) >= 1.0:
            continue
        key = (row["endpoint"], row["vendor"])
        rps = float(row["rps_median"])
        if key not in peaks or rps > peaks[key]["rps"]:
            peaks[key] = {"rps": rps, "level": row["concurrency"],
                          "p99": float(row["p99_ms"]), "p50": float(row["p50_ms"])}
    # speed = p50 at the minimum concurrency level present per (endpoint, vendor)
    speed = {}
    minlvl = {}
    for row in rows:
        key = (row["endpoint"], row["vendor"])
        lvl = int(row["concurrency"])
        if key not in minlvl or lvl < minlvl[key]:
            minlvl[key] = lvl
            speed[key] = {"p50": float(row["p50_ms"]), "p99": float(row["p99_ms"]), "level": row["concurrency"]}
    return peaks, speed


def bar(ax, vals, title, ylabel, fmt="{:.0f}"):
    xs = range(len(VENDORS))
    ax.bar(xs, [vals.get(v, 0) for v in VENDORS], color=[VENDOR_COLOR[v] for v in VENDORS])
    ax.set_xticks(list(xs))
    ax.set_xticklabels([VENDOR_LABEL[v] for v in VENDORS])
    ax.set_title(title)
    ax.set_ylabel(ylabel)
    for i, v in enumerate(VENDORS):
        if v in vals:
            ax.text(i, vals[v], fmt.format(vals[v]), ha="center", va="bottom", fontsize=9)
    ax.grid(axis="y", alpha=0.3)


def main():
    prices, is_estimate = load_prices()
    peaks, speed = load_results()
    (D / "charts").mkdir(exist_ok=True)
    warn = "  [PRICES ESTIMATE -- verify before publish]" if is_estimate else ""
    region, date = prices.get("_region", "?"), prices.get("_date", "?")

    # req/s per $ and $/million per (endpoint, vendor)
    rpd = {}   # endpoint -> vendor -> reqs per dollar-hour
    cpm = {}   # endpoint -> vendor -> $ per million reqs
    for endpoint in ENDPOINTS:
        rpd[endpoint], cpm[endpoint] = {}, {}
        for v in VENDORS:
            key = (endpoint, v)
            if key not in peaks or v not in prices:
                continue
            rps = peaks[key]["rps"]
            usd_hr = prices[v]
            rpd[endpoint][v] = rps / usd_hr
            cpm[endpoint][v] = usd_hr / (rps * 3600.0) * 1e6 if rps > 0 else 0

    # --- CSV ---
    with open(D / "arch-priceperf.csv", "w") as fh:
        fh.write("endpoint,vendor,peak_rps,usd_per_hr,reqs_per_usd_hr,usd_per_million_reqs,p50_ms,p99_ms,region,price_date\n")
        for endpoint in ENDPOINTS:
            for v in VENDORS:
                if (endpoint, v) not in peaks or v not in prices:
                    continue
                pk = peaks[(endpoint, v)]
                fh.write(f"{endpoint},{v},{pk['rps']:.1f},{prices[v]:.5f},{rpd[endpoint][v]:.1f},"
                         f"{cpm[endpoint][v]:.4f},{pk['p50']:.1f},{pk['p99']:.1f},{region},{date}\n")

    # --- charts ---
    # money chart: reqs per dollar, grouped bars per endpoint
    fig, axes = plt.subplots(1, len(ENDPOINTS), figsize=(11, 5), sharey=False)
    for ax, endpoint in zip(axes, ENDPOINTS):
        bar(ax, rpd[endpoint], f"req/s per $/hr\n{ENDPOINT_LABEL[endpoint]}", "req/s per $/hr")
    fig.suptitle(f"Price/performance -- req/s per on-demand $/hr ({region}, {date}){warn}", fontsize=11)
    fig.tight_layout()
    fig.savefig(D / "charts" / "reqs-per-dollar.png", dpi=130)
    plt.close(fig)

    for name, data, ylabel, fmt, title in [
        ("cost-per-million", cpm, "$ per million req", "${:.3f}", "Cost to serve 1M requests"),
        ("raw-throughput", {e: {v: peaks[(e, v)]["rps"] for v in VENDORS if (e, v) in peaks} for e in ENDPOINTS},
         "peak sustained req/s", "{:.0f}", "Raw throughput (NOT price-normalized)"),
        ("p99-latency", {e: {v: peaks[(e, v)]["p99"] for v in VENDORS if (e, v) in peaks} for e in ENDPOINTS},
         "p99 latency (ms)", "{:.0f}", "p99 latency at peak throughput"),
        ("speed-latency", {e: {v: speed[(e, v)]["p50"] for v in VENDORS if (e, v) in speed} for e in ENDPOINTS},
         "single-request p50 (ms)", "{:.1f}", "SPEED: single-request latency (lower = faster per core)"),
    ]:
        fig, axes = plt.subplots(1, len(ENDPOINTS), figsize=(11, 5))
        for ax, endpoint in zip(axes, ENDPOINTS):
            bar(ax, data[endpoint], f"{ENDPOINT_LABEL[endpoint]}", ylabel, fmt)
        fig.suptitle(f"{title}{warn if name=='cost-per-million' else ''}", fontsize=11)
        fig.tight_layout()
        fig.savefig(D / "charts" / f"{name}.png", dpi=130)
        plt.close(fig)

    # --- printed table + AWS ~40% claim comparison ---
    print(f"\n=== Price/performance ({region}, {date}){warn} ===")
    print(f"on-demand $/hr: " + "  ".join(f"{v}={prices.get(v,'?')}" for v in VENDORS))
    for endpoint in ENDPOINTS:
        print(f"\n--- {ENDPOINT_LABEL[endpoint]} ---")
        print(f"{'vendor':<14}{'peak RPS':>10}{'$/hr':>9}{'req/s per $':>13}{'$/1M req':>11}")
        for v in VENDORS:
            if (endpoint, v) not in peaks or v not in prices:
                continue
            pk = peaks[(endpoint, v)]
            print(f"{v:<14}{pk['rps']:>10.0f}{prices[v]:>9.4f}{rpd[endpoint][v]:>13.0f}{cpm[endpoint][v]:>11.4f}")
        # SPEED (single-request p50) vs Intel -- can diverge from throughput
        sbase = speed.get((endpoint, "c7i"), {}).get("p50")
        if sbase:
            print("  single-request speed (p50, lower=faster):")
            for v in VENDORS:
                key = (endpoint, v)
                if key in speed:
                    d = (speed[key]["p50"] / sbase - 1) * 100
                    tag = "same" if abs(d) < 2 else (f"{d:+.0f}% slower" if d > 0 else f"{-d:.0f}% faster")
                    print(f"    {v:<6} p50 {speed[key]['p50']:6.1f}ms @c{speed[key]['level']}  ({tag} vs Intel)")
        # Graviton price/perf advantage vs Intel, compared to AWS's ~40% claim
        base = rpd[endpoint].get("c7i")
        grav = rpd[endpoint].get("c7g")
        if base and grav:
            adv = (grav / base - 1) * 100
            print(f"  Graviton3 price/perf vs Intel: {adv:+.1f}%  (AWS markets ~40% better price-performance)")
            verdict = "BEATS" if adv >= 40 else ("approaches" if adv >= 25 else "falls short of")
            print(f"  -> measured {verdict} the ~40% claim on this workload.")
        amd = rpd[endpoint].get("c7a")
        if base and amd:
            print(f"  AMD price/perf vs Intel:       {(amd/base-1)*100:+.1f}%")
    if is_estimate:
        print("\nWARNING: no prices.json found -- used DATED BUILT-IN ESTIMATE. Pull live on-demand")
        print("prices for the run region/date and re-run before publishing any dollar figure.")
    print(f"\n[arch-charts] wrote charts/ + arch-priceperf.csv under {D}")


if __name__ == "__main__":
    main()
