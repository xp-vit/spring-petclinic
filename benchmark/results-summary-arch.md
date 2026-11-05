# CPU price/performance — Intel vs AMD vs AWS Graviton (Spring PetClinic)

Same real Spring PetClinic app (identical multi-arch image, identical JDK 25 bytecode) on
same-rank compute-optimized `c7.large` instances across three CPU vendors, under a CPU-bound
load. Ran 2026-07-06 (07-08 rerun), eu-central-1, infra auto-destroyed after.

| | value |
|---|---|
| App instances | `c7i.large` (Intel Sapphire Rapids) · `c7a.large` (AMD 4th-gen EPYC) · `c7g.large` (Graviton3) — all 2 vCPU / 4 GB |
| Image | one multi-arch container (`amd64`+`arm64`) from one Dockerfile, JDK Corretto/Temurin 25 fat jar |
| DB | RDS Postgres `db.m7i.large`, OFF the instance under test, identical for every vendor (not touched by the driven endpoints) |
| Load | k6 on a separate `c5.large`, closed-loop, concurrency sweep `1 5 20 50 100 200`, 45 s/level, **5 runs/config, median reported** |
| Endpoints | **synthetic** `GET /api/cpu` (pure hash loop) · **real** `GET /api/render` (Spring MVC + Jackson JSON serialize, 400 owner rows, no DB) |
| On-demand $/hr | Intel **$0.10185** · AMD **$0.11713** · Graviton **$0.08250** (AWS Pricing API, EU Frankfurt, Linux, on-demand, 2026-07-08) |

**CPU was the bottleneck, verified:** app-container CPU pegged at **max 200–202 %** of the 2 vCPU
on every vendor/endpoint; RDS idle (endpoints touch no DB); k6 box never the limit; 0 errors
across all 180 runs. This measures CPUs, not the database or network.

---

## ⚠️ The one caveat that governs everything: "same vCPU" ≠ "same cores"

On AWS, a vCPU is **not** the same unit of silicon across these families:

- **`c7i` (Intel)** uses hyper-threading: **2 vCPU = 1 physical core** (2 threads).
- **`c7a` (AMD)** and **`c7g` (Graviton)** have **no SMT: 2 vCPU = 2 physical cores.**

The data shows it directly — scaling from 1 thread (c1) to both vCPUs (peak), synthetic endpoint:

| vendor | c1 RPS | peak RPS | scale-up |
|---|--:|--:|--:|
| Intel c7i | 236 | 419 | **1.78×** (SMT — two threads, one core) |
| AMD c7a | 287 | 676 | **2.35×** (two real cores) |
| Graviton c7g | 226 | 487 | **2.15×** (two real cores) |

So most of Intel's throughput deficit is **one physical core vs two**, not a slow
microarchitecture. You *rent* vCPUs and *pay* per vCPU-hour, so the per-vCPU price/perf below is
the real economic comparison — but read it knowing the mechanism. Normalize by physical core and
Intel's per-core standing is competitive.

---

## 1. SPEED — single-request latency @c1 (raw per-core speed, no queuing)

The synthetic endpoint (~4 ms of CPU/request) is the reliable per-core signal:

| vendor | synthetic p50 @c1 | vs Intel |
|---|--:|--:|
| Intel c7i | 4.1 ms | — |
| AMD c7a | **3.4 ms** | 17 % faster |
| Graviton c7g | 4.3 ms | 5 % slower |

**Per-core speed is close** (within ~20 %): AMD Zen4 fastest single-thread, Intel and Graviton3
roughly tied. (The `render` endpoint's ~1 ms/request at c1 is dominated by network/overhead, not
CPU, so it is not a trustworthy speed signal — synthetic is.)

## 2. THROUGHPUT — peak sustained RPS (both vCPUs busy)

| endpoint | Intel c7i | AMD c7a | Graviton c7g |
|---|--:|--:|--:|
| synthetic `/api/cpu` | 419 | **676** (161 %) | 487 (116 %) |
| real `/api/render` | 1257 | **2367** (188 %) | 1635 (130 %) |

AMD has the highest raw throughput (fastest core × 2 real cores). Graviton beats Intel largely on
core count. Reminder: Intel's number is one physical core's worth (SMT); the gap is not a
per-core-speed gap. Chart: `charts/raw-throughput.png`, `charts/speed-latency.png`.

## 3. PRICE / PERFORMANCE — the headline (req/s per on-demand $/hr)

| endpoint | Intel c7i | AMD c7a | Graviton c7g |
|---|--:|--:|--:|
| synthetic | 4,116 | 5,772 (+40.2 %) | **5,905 (+43.5 %)** |
| real render | 12,345 | 20,210 (+63.7 %) | **19,819 (+60.6 %)** |
| **$ / million req (render)** | $0.0225 | **$0.0137** | $0.0140 |

- **Graviton3 beats AWS's marketed ~40 % price-performance claim on this workload** — +43.5 %
  (synthetic) and +60.6 % (real) vs Intel. Charts: `charts/reqs-per-dollar.png`,
  `charts/cost-per-million.png`.
- **AMD and Graviton effectively tie on price/perf** (Graviton edges synthetic, AMD edges render).
  They get there differently: **AMD wins on raw speed, Graviton wins on price.** AMD is the most
  expensive per hour ($0.117) yet its extra throughput pays for it; Graviton is the cheapest
  ($0.0825) and merely needs to keep up.
- **Graviton is the price/perf winner despite being the slowest per core** — it delivers ~2 real
  cores at the lowest $/hr. That is the honest Graviton story: not "faster silicon," but "enough
  cores, cheap."
- **Intel c7i loses on per-vCPU price/perf primarily because of SMT** (1 core per 2 vCPU) plus a
  mid price. On a per-physical-core basis it is far closer.

## Bottom line

- **Price/perf, per vCPU-hour (what you actually pay):** Graviton3 ≈ AMD > Intel, both ~+40–60 %
  over Intel. Graviton beats AWS's ~40 % claim here.
- **Raw throughput:** AMD c7a wins (fastest core, 2 real cores). 
- **Single-request speed:** AMD fastest, Intel ≈ Graviton; all within ~20 %.
- **Why Intel trails:** mostly the vCPU/SMT asymmetry — `c7i.large` is 1 physical core where
  `c7a`/`c7g.large` are 2. Disclose this or the comparison misleads.
- **Pick:** cheapest to serve a fixed request volume → Graviton or AMD (~40 % less $/M req than
  Intel). Lowest single-request latency at low load → AMD. ARM-compatibility of your dependency
  stack is the gating risk for Graviton (all-JVM here, so a non-issue).

Raw: `benchmark/results/aws-arch/` (`results.csv`, `arch-priceperf.csv`, per-run `*-summary.json`,
`*-appstats.csv`, `prices.json`, `charts/`).
