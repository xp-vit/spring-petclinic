# Virtual Threads vs Platform Threads — AWS results

Spring PetClinic, Spring Boot 4.0.3, JDK Corretto 25.0.3. App EC2 `c7i.large` (2 vCPU, 4 GB) +
co-located async slow-HTTP stub; k6 EC2 `c5.large`; RDS Postgres `db.m7i.large`. Blocking
downstream delay = **200 ms**. Thread mode toggled by `spring.threads.virtual.enabled` only —
identical image, identical code path. Each concurrency level is a separate closed-loop k6 run
(VUs == concurrency, no think-time); latency ms, RPS after warmup, peakThr = peak platform
thread count during the level. Ran 2026-07-06, infra auto-destroyed after.

## 1. `slow` — blocking downstream, no DB (the crossover)

| conc | platform RPS / p50 | virtual RPS / p50 | plat peakThr | virt peakThr |
|-----:|--------------------|--------------------|-------------:|-------------:|
| 50   | 245 / 202ms  | 246 / 202ms  | 122 | 48  |
| 100  | 493 / 202ms  | 494 / 202ms  | 148 | 51  |
| 200  | 984 / 202ms  | 985 / 202ms  | 256 | 63  |
| 500  | **984 / 509ms** | **2377 / 206ms** | 267 | 99  |
| 1000 | **983 / 1014ms** | **4036 / 235ms** | 267 | 142 |
| 2000 | 983 / 2031ms | 3125 / 301ms | 266 | 162 |

- **Below 200 concurrency: identical.** Requests fit inside Tomcat's 200-thread budget; nobody
  queues; virtual threads add nothing. (The honest "no benefit" zone.)
- **Platform ceiling = 983 RPS**, dead flat from c200 to c2000. Extra load only queues:
  p50 grows 202→509→1014→2031ms in lockstep with concurrency (conc/latency ≈ 1000 throughout).
  peakThr pinned at ~266 (200 Tomcat workers + ~66 JVM). Textbook thread-pool saturation.
- **Virtual scales:** 2.4× at c500, **4.1× at c1000** (4036 vs 983), latency stays near the
  200 ms real work. peakThr stays 48–162 — it never needs 200 OS threads because a *waiting*
  request doesn't hold one.
- **c2000 virtual dips to 3125** (below its own c1000) with a 60 s max outlier. This is a
  **hardware ceiling, not a thread-model failure**: at 2000 concurrent the 2-vCPU app —
  sharing those 2 cores with the co-located stub — saturates on connection + scheduling +
  GC overhead. Bigger app/stub separation would push the knee higher. Disclosed, not hidden.

## 2. `slow-db` — same call while holding a pooled DB connection (the new bottleneck)

Both runs are **virtual threads**; only HikariCP `maximum-pool-size` changes.

| conc | Hikari=10 RPS / p50 | Hikari=100 RPS / p50 |
|-----:|---------------------|----------------------|
| 50   | 49 / 1024ms   | 242 / 204ms   |
| 200  | 49 / 4075ms   | 490 / 406ms   |
| 500  | 49 / 10169ms  | 490 / 1015ms  |
| 1000 | 50 / 20144ms  | 489 / 2030ms  |
| 2000 | 61 / 29829ms  | 487 / 4065ms  |

- **Cheap threads move the bottleneck; they don't remove it.** With pool=10, throughput is
  pinned at **~49 RPS** no matter the concurrency — exactly `pool / hold_time = 10 / 0.2s = 50`.
  Latency explodes to 30 s because 2000 virtual threads all queue for 10 connections.
- Raising the pool 10→100 lifts throughput **10×** (49 → ~490 ≈ `100/0.2`). The thread model was
  identical — **the pool size, not the thread count, was the ceiling.** Once threads are cheap,
  DB pool sizing is the thing that matters.

## 3. `cpu` — pure CPU-bound work (when Loom does NOT help)

| conc | platform RPS / p50 | virtual RPS / p50 | plat peakThr | virt peakThr |
|-----:|--------------------|--------------------|-------------:|-------------:|
| 50   | 385 / 121ms  | 398 / 113ms  | 71  | 23 |
| 200  | 430 / 437ms  | 439 / 450ms  | 218 | 22 |
| 1000 | 432 / 2210ms | 438 / 2270ms | 218 | 22 |
| 2000 | 434 / 4536ms | 437 / 4531ms | 218 | 22 |

- **No throughput benefit.** Both modes plateau at **~435 RPS** — the 2-vCPU ceiling for the
  CPU work. The bottleneck is *cores*, not threads, so making threads cheap changes nothing.
- Virtual uses far fewer OS threads (22 vs 218) for the *same* throughput — confirming the
  work is CPU-bound. Virtual's tail latency is occasionally worse under CPU saturation (a
  52 s max at c500) — scheduling overhead with nothing to unmount for. Don't reach for virtual
  threads on CPU-bound paths.

## 4. Memory & CPU footprint — the throughput win costs heap

Sampled on the app container (`docker stats`, 1 Hz) and attributed to each concurrency level by
timestamp. Peak app heap (MB) during each level, `/api/slow`:

| conc | platform peak MB / avg CPU | virtual peak MB / avg CPU |
|-----:|----------------------------|----------------------------|
| 50   | 390 / 34%  | 381 / 36%  |
| 100  | 405 / 22%  | 390 / 22%  |
| 200  | 455 / 38%  | 424 / 38%  |
| 500  | 470 / 39%  | **608 / 73%**  |
| 1000 | 493 / 36%  | **1082 / 117%** |
| 2000 | 533 / 35%  | **1131 / 101%** |

(CPU % is of 200% = 2 vCPU. Chart: `charts/memory-vs-concurrency.png`.)

- **The two lines diverge at the same point throughput does (~c200).** Below saturation, memory
  is identical (~380–455 MB). Above it they split hard.
- **Platform stays flat (~455→533 MB)** past c200: it only ever keeps ~200 requests in flight;
  the rest queue at the acceptor holding no request state, so more load ≠ more heap.
- **Virtual climbs to ~1130 MB (2.2× platform at c1000).** It keeps *all* ~4000 requests genuinely
  live, each holding a stack + downstream connection + buffers. **That is the cost of the 4×
  throughput** — you trade heap for concurrency, and you must budget for it.
- **CPU tells the same story:** platform sits at ~35% (throttled — threads idle-waiting behind
  the 200 cap), virtual rises to ~100–117% because it's actually doing ~4× the work.
- **DB-bound (`slowdb`) CPU is near-idle (5–30%)** at every level — cores starved while requests
  wait on the pool/downstream. **CPU-bound (`cpu`) pegs ~198%** in both modes with near-flat
  memory — confirming the bottleneck is cores, and virtual threads (22 live) buy nothing over
  platform (218 live).

Per-level detail: `results-perlevel.csv`.

## 5. The fair fight — "just add platform threads" (local, 2 vCPU / 3 GB)

The default-200 vs virtual comparison is a strawman unless you also try raising the platform
pool. So we bumped Tomcat `threads.max` to 1000 and 2000 and re-ran `/api/slow`:

| config | c1000 RPS / p50 | c2000 RPS / p50 | mem @c1000 |
|--------|-----------------|-----------------|-----------|
| platform@200  | 987 / 1007ms  | 984 / 2018ms  | 597 MB |
| platform@1000 | **4851 / 202ms** | 4832 / 403ms  | 914 MB |
| platform@2000 | 4828 / 202ms  | 2402 / 205ms  | 910 MB |
| virtual       | **4843 / 202ms** | 2429 / 204ms  | 779 MB |

**Yes — sizing the pool to the load fully closes the throughput gap.** platform@1000 at c1000
matches virtual exactly (4851 vs 4843, both p50 202ms). For pure blocking work, `threads ≈
concurrency` buys the same throughput. The gap doesn't vanish, though — it **moves**:

1. **More memory at equal throughput.** 914 MB (platform@1000) vs 779 MB (virtual) at c1000 —
   +135 MB of native thread stacks. **Correction to a common myth (and to an earlier draft of
   this doc):** platform threads are often quoted at "~1 MB each" — that's *reserved* address
   space, not committed RSS. Measured, an idle blocked stack commits far less: **~135 MB for
   1000 threads ≈ ~135 KB each.** The penalty is real but ~7× smaller than the 1 MB figure
   implies.
2. **You must tune the pool to peak concurrency.** platform@1000 re-saturates at c2000 (p50
   doubles to 403 ms — 2000 requests, 1000 threads, half queue); platform@2000 fixes that but
   wastes memory at low load. Wrong size = throttle or bloat. Virtual self-scales — no number
   to pick.
3. **Threads can't buy cores.** At c2000 everything collapses to ~2400 RPS regardless of mode —
   the 2-vCPU wall.

**Takeaway:** "just add threads" works for throughput *if* you own the tuning knob and pay
per-thread stack. Virtual threads deliver the same throughput without that knob — that's the
real win, not raw speed.

## Bottom line

- Virtual threads win big **only** in the blocking + high-concurrency regime (here 4× at c1000).
- They give **nothing** below thread saturation, and **nothing** for CPU-bound work.
- For DB-bound work the **connection pool** becomes the ceiling — size it, don't just flip the
  flag.
- The throughput win **costs memory**: virtual used 2.2× the heap at c1000 (1082 vs 493 MB)
  because it keeps every in-flight request live. Budget heap for your peak concurrency.
- **"Just add platform threads" also closes the throughput gap** — if you size the pool to peak
  concurrency (platform@1000 == virtual at c1000). Virtual's edge is then *not* speed but no
  pool to tune and lower per-thread cost (~135 KB committed stack each, not the myth's 1 MB).
- Pinning: on JDK 25 the `synchronized` trap is largely closed (detection commands in the
  loom README; not a run axis because it's a non-event on this JDK).
- Fastest ≠ right: weigh debuggability, pinning risk on older JDKs/libs, and downstream pool
  sizing. The clean case for virtual threads is **blocking I/O at high concurrency on a
  modern JDK.**

Raw: `benchmark/results/aws-loom/` (`results.csv`, per-run `*-summary.json`, `*-threads.csv`).
