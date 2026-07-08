# Virtual Threads (Project Loom) vs Platform Threads — Spring Boot Benchmark

A reproducible, honest load benchmark of how Java **virtual threads** affect a
thread-per-request Spring Boot web app under high concurrency. Base app: Spring PetClinic.

The answer this measures is **not** "virtual threads are always faster." It is *it depends* —
and the point is to show exactly **when they help, when they don't, and what the new
bottleneck becomes.**

---

## Why vanilla PetClinic shows nothing (and what we inject)

Virtual threads only pay off when request-handling threads spend a long time **blocked**, so
that the platform thread pool (Tomcat default **200**) is exhausted. Vanilla PetClinic hits a
fast local DB in sub-millisecond time — a platform thread is never busy long enough to run
out. So we engineer the condition explicitly:

- **Blocking downstream with real, controllable latency.** A co-located async HTTP **stub**
  (`slow-stub.py`) sleeps a fixed number of milliseconds, standing in for a slow external API.
  The app calls it with a blocking `RestClient` on a hot path (`GET /api/slow?ms=200`). A slow
  *external* call (not a DB call) is used deliberately: it avoids the connection-pool confound,
  so the clean thread story isn't muddied. (A DB call would also be too fast — even
  network-distant RDS is single-digit ms — and would hit the pool limit before the thread
  limit.)
- **High concurrency.** k6 drives rising concurrency (50 → 2000 concurrent) so the platform
  pool saturates. Each closed-loop VU keeps one request in flight, so concurrency == VUs.

Both are required. Without them the benchmark is meaningless.

### Endpoints (all profile-gated behind `loom`, same code both thread modes)

| Endpoint | What it does | Story it tells |
|----------|--------------|----------------|
| `GET /api/slow?ms=200` | Blocking HTTP call to the stub | **The crossover**: platform saturates ~200, virtual scales |
| `GET /api/slow-db?ms=200` | Same call **while holding a pooled DB connection** (`@Transactional`) | **The new bottleneck**: once threads are cheap, the JDBC pool caps throughput |
| `GET /api/cpu?iters=N` | Pure CPU-bound work, no blocking | **When Loom does NOT help** — bottleneck is cores, not threads |
| `GET /api/threadstats` | Live **platform** thread count (`ThreadMXBean`) | Evidence: platform mode climbs to ~200, virtual stays near carrier count |

`/api/threadstats` returns the JVM platform thread count. In **platform** mode Tomcat spawns up
to 200 worker threads → the count climbs to ~200 under load. In **virtual** mode workers are
virtual threads (not counted by `ThreadMXBean`), so the count stays near the carrier-pool size
(≈ CPU count). That difference is the mechanism, made visible.

---

## Two run modes — config only, identical code path

| Mode | Toggle |
|------|--------|
| Platform threads (default) | `spring.threads.virtual.enabled=false` |
| Virtual threads | `spring.threads.virtual.enabled=true` |

Everything else (hardware, JDK, heap, DB, warmup, image) is held identical between the two.

---

## Reproducibility disclosure

**Consistency across runs matters more than absolute numbers.** Every variable that moves the
result:

| Variable | Value |
|----------|-------|
| JDK | Amazon Corretto **25.0.3** (LTS, build 25.0.3+9) — pinning on `synchronized` was largely fixed in JDK 24/25 |
| Spring Boot | **4.0.3** (Tomcat, thread-per-request MVC) |
| Java toolchain | 25 (`build.gradle`) |
| Load generator | **k6** (grafana/k6 latest, Docker) |
| Local host | AMD Ryzen 9 7950X3D (16C/32T), 93 GiB RAM, Linux 6.12 (Manjaro) |
| Local app limits | container capped **2 CPUs / 1 GB** (so the platform pool is a real limit, not hidden by 32 cores) |
| AWS app EC2 | `c7i.large` (2 vCPU, 4 GB) |
| AWS k6 EC2 | `c5.large` |
| AWS DB | RDS Postgres `db.m7i.large` (non-burstable) — only used by `/api/slow-db` |
| Injected latency | stub delay **200 ms** (`MS`), CPU work `iters=2000000` (AWS) / `500000` (local) |
| Concurrency levels | 50 / 100 / 200 / 500 / 1000 / 2000 |
| Tomcat max threads | 200 (framework default; `server.tomcat.threads.max`) |
| Hikari pool | 10 (default) and 100 (pool-story sweep) |
| JVM flags | GC logging only (see `benchmark/docker/Dockerfile.jvm`); no tuning, defaults otherwise |

Metrics captured per (mode, concurrency): throughput (req/s), latency p50/p95/p99/max, error
rate, live platform thread count, container CPU + memory.

---

## Run it

### Local (validation; free, fully reproducible)

```bash
# both modes, default levels, /api/slow at 200ms
./benchmark/scripts/run-loom-local.sh "platform virtual" "50 100 200 500 1000"

# pool story: virtual only, sweep Hikari
ENDPOINT=slow-db HIKARI_MAX_POOL=10  ./benchmark/scripts/run-loom-local.sh virtual "200 500 1000"
ENDPOINT=slow-db HIKARI_MAX_POOL=100 ./benchmark/scripts/run-loom-local.sh virtual "200 500 1000"

# CPU-bound (Loom-does-not-help) case
ENDPOINT=cpu ITERS=2000000 ./benchmark/scripts/run-loom-local.sh "platform virtual" "50 200 500"
```

Results land in `benchmark/results/local-loom/` (`comparison.txt` + per-run `*-summary.json`
+ `*-threads.csv`).

### AWS (the headline run)

```bash
AWS_PROFILE=govplus-development ./benchmark/scripts/benchmark-loom-aws.sh
```

Provisions the v2 Terraform stack, builds + pushes the image, runs every combination
(`slow` platform/virtual, `slow-db` Hikari 10/100, `cpu` platform/virtual) across the
concurrency sweep, syncs results to `benchmark/results/aws-loom/`, then **auto-destroys** the
infra (even on failure — set `KEEP_INFRA=1` to keep it). See `loom-summarize.py` output
(`comparison.txt`, `results.csv`).

---

## The pinning trap (detection + why it's mostly gone on JDK 25)

**What it is.** A virtual thread that blocks *while pinned* to its carrier cannot unmount, so
the carrier is stuck too. Before JDK 24, blocking inside a `synchronized` block (or a native
frame) pinned the carrier — enough pinned carriers and virtual threads stop scaling, silently
collapsing back to platform-thread behaviour.

**Why this benchmark doesn't build a pinned variant.** On **JDK 24+/25** the JDK no longer pins
on `synchronized` — the monitor was reworked so a virtual thread can unmount while holding it.
On Corretto 25 (used here) wrapping the blocking call in `synchronized` shows **no meaningful
regression**, so a dedicated pinned run axis would mostly demonstrate a non-event. We document
it and show the detection instead (the honest result: *on a modern JDK this trap is largely
closed*).

**How to detect it** (run against any variant and confirm ~zero pinning events):

```bash
# 1) JVM flag — logs a stack trace on every pinning event
java -Djdk.tracePinnedThreads=full -jar app.jar
#    (empty output under load == no pinning)

# 2) JDK Flight Recorder — count jdk.VirtualThreadPinned events
java -XX:StartFlightRecording=filename=rec.jfr,duration=60s -jar app.jar
jfr print --events jdk.VirtualThreadPinned rec.jfr    # expect none on JDK 24+
```

If you *do* still see pinning on your stack, the usual culprits are `synchronized` around I/O
on older JDKs (replace with `ReentrantLock`) and blocking native calls.

---

## Honesty notes (read before quoting numbers)

- **Virtual threads help only in the blocking + high-concurrency regime.** At low concurrency,
  or below the ~200-thread saturation point, platform and virtual are ~equal. Measured, not
  asserted — see the low-concurrency rows.
- **CPU-bound work: no benefit, slight regression possible.** `/api/cpu` is bounded by cores;
  virtual threads add scheduling overhead with nothing to unmount for. Shown with data.
- **The connection pool is the real ceiling for DB-bound work.** `/api/slow-db` shows that once
  threads are cheap, throughput ≈ `pool_size / hold_time`. Raising Hikari from 10 → 100 lifts
  the cap far more than the thread mode does. **Cheap threads move the bottleneck; they don't
  remove it.**
- **Fastest ≠ right.** Virtual threads trade some debuggability (huge thread dumps, tooling
  still catching up), carry residual pinning risk on older JDKs/libraries, and demand you
  re-size downstream pools. For CPU-bound or already-async (WebFlux) workloads the win is
  small-to-none. The clean use case is **blocking I/O at high concurrency on a modern JDK.**
- Numbers are steady-state after warmup within each level's window; each level is a separate
  closed-loop k6 run so percentiles aren't smeared across a ramp.
