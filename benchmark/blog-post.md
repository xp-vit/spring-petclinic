# Spring Boot on the JVM vs GraalVM Native (+ PGO): What Actually Wins on AWS

> **TL;DR** — On a 2 vCPU / 4 GB AWS c7i.large with Postgres on a separate
> RDS db.t3.micro and k6 on its own EC2:
> - GraalVM native starts in **~0.3 s vs ~15 s** — roughly **40× faster**,
>   measured from Spring Boot's own startup log and steady across runs.
> - The JVM, _once warm_, has a lower **p50** (≈8–10 ms vs ≈18–20 ms
>   native) and serves a few % more sustained RPS at moderate load.
> - At saturation it depends on warm-up: a fully-warm JVM serves **~22 %
>   more peak RPS** (~470 vs ~386), but **native hits its peak from the
>   first request** with near-zero variance — the JVM's first burst is its
>   *worst*.
> - Native's sustained **tail is the predictable one** (p99 ~150 ms every
>   run; the warm JVM is often lower but swings 110–171 ms), and it uses
>   **~2.5–4× less memory** (≈100–165 MiB vs ≈390–420 MiB).
> - GraalVM PGO did **not** win on AWS — because we trained the profile on
>   the dev box against a localhost Postgres, so the PGO build optimized
>   for the wrong hot path. Lesson: PGO is only as good as the workload
>   you train it on.
>
> _Stack: Spring Boot 4.0.3, Java 25 LTS, GraalVM Community 25 (and Oracle
> GraalVM 25 for PGO), Postgres 18.3 on RDS, Ubuntu 24.04 LTS on EC2._

## The question

JVM vs native benchmarks usually compare hello-world startup or fib(40).
Real services have a database, Hibernate, Thymeleaf, the whole Spring
lifecycle. So I took the canonical Spring sample — **PetClinic** — built
it three ways, and put the same load on each on the same cloud hardware.

Three variants:

1. **JVM** — Spring Boot fat JAR on Eclipse Temurin 25, default SerialGC.
2. **Native** — GraalVM Community 25, default `nativeCompile`.
3. **Native + PGO** — Oracle GraalVM 25, two-stage build:
   instrument → 60 s training workload → `--pgo=<profile> -O3 --gc=G1
   -march=x86-64-v3`.

## Setup

| Component       | Value                                                            |
|-----------------|------------------------------------------------------------------|
| App             | Spring Boot 4.0.3 + PetClinic (Thymeleaf + JPA)                  |
| Java            | 25 LTS for all three                                             |
| Native compiler | GraalVM CE 25 (default) and Oracle GraalVM 25 (PGO)              |
| Database        | **AWS RDS Postgres 18.3 (db.t3.micro)** — separate instance     |
| App host        | EC2 **c7i.large** (2 vCPU, 4 GB, non-burstable)                  |
| Load host       | EC2 **c5.large** (separate, runs k6 only)                        |
| Container limit | 1 CPU / 512 MB cgroup                                            |
| Sustained load  | k6 mixed workload, **50 VUs, 10 min**, 4 scenarios (40/20/20/20) |
| Saturation load | k6 `ramping-arrival-rate`, **100 → 2000 req/s over 5 min**       |
| Cold start      | container start → time until `/actuator/health` answers 200     |

Workload mix: `GET /owners?lastName=Davis` (40 %), `GET /owners/{id}` (20 %),
`GET /vets` JSON (20 %), `POST /owners/new` (20 %).

Why a separate load EC2 and a real RDS instead of running both in
containers on the same host? Because the v1 run with everything on one
EC2 had the JVM CPU sitting around 90 % and native at 100 % — that 10 %
isn't free, it's the load generator stealing cycles. With k6 on its own
2 vCPU c5.large and Postgres on RDS, the app instance has its full 2
vCPU for handling requests. That's how production deployments are
shaped, and that's what the numbers below describe.

A non-burstable instance matters too. `t3.*` and `t4g.*` accumulate CPU
credits that vanish under sustained load — you get the wrong numbers,
and you can read them as "native is slower" when the credit bucket simply
ran out mid-test. `c7i.large` holds full CPU the whole time.

## Results — v2 architecture (2 EC2 + RDS)

> _Sustained-load numbers are computed after dropping the first 60 s so
> the JVM's JIT has finished its warm-up curve — otherwise the JVM numbers
> are unfairly low._

![Summary dashboard](results/aws-v2/charts/summary-dashboard.png)

### Sustained mixed workload (50 VUs, 10 min)

| Variant | RPS     | p50    | p95    | p99     | Errors |
|---------|---------|--------|--------|---------|--------|
| JVM     | **434** | **8**  | **64** | **110** | 0      |
| Native  | 396     | 18     | 69     | 152     | 0      |

_The tail is the catch: across two runs the JVM's p99 swung **110–171 ms**
while native's barely moved (**147–152 ms**). This run the warm JVM had the
lower tail; the previous run native did. Native's tail is the_ predictable
_one, not reliably the lowest._

![Throughput over time](results/aws-v2/charts/throughput-over-time.png)

The periodic dips on _both_ lines are SerialGC stop-the-world pauses (the
default GC at this heap size, for native too): a sub-second freeze shows up
as one low 5-second bucket and recovers in the next, with zero failed
requests. G1 would smooth them out — at a higher memory cost, which is
exactly the trade you don't want on a memory-constrained container.

The JIT warm-up is visible in the orange line: JVM throughput ramps from
~100 req/s at boot to ~450 req/s after about two minutes. Native serves
~400 req/s from the first second. After warm-up, JVM serves a bit more
sustained throughput (434 vs 396, +10 %) on moderate load.

The hot-path p50 belongs to the JIT (8 ms vs 18 ms native): C2 has runtime
profile data the AOT compiler doesn't get, and PetClinic's most-frequent
path is small enough that it fits well in C2's optimized form. The tail is
subtler than I first thought: I originally wrote that native wins p95/p99
(no GC pauses), and in one run it did — but re-running showed the JVM's tail
swinging run-to-run while native's stays flat. The honest read: native gives
a _predictable_ tail, not a guaranteed-lower one; a warm JVM is often lower
but rolls the dice on GC.

### Peak-RPS saturation sweep (100 → 2000 req/s over 5 min)

This is the number that fooled me first. A single peak sweep picked a
different winner almost every run, so I ran the sweep **five times
back-to-back against the same warm container** per variant:

![Peak-RPS across five runs](results/aws-v2-peak/charts/peak-iterations.png)

| Variant              | Peak RPS  | p50      | p95       | p99       | Errors |
|----------------------|-----------|----------|-----------|-----------|--------|
| JVM (warm, runs 2–5) | **~470**  | ~615 ms  | ~2000 ms  | ~2800 ms  | 0      |
| JVM (run 1, cold)    | 336       | 1109 ms  | 3295 ms   | 4823 ms   | 0      |
| Native (all 5 runs)  | 386 ± 2   | ~800 ms  | ~2500 ms  | ~3388 ms  | 0      |

Once the JVM is fully warm it wins peak throughput by ~22 % (≈470 vs 386
RPS) at a lower median — C2 has compiled the hot path and the larger heap
absorbs the burst. But native is boringly consistent: 386 RPS with a
standard deviation of *2*, identical from the first request. The JVM's
first saturation burst is its *worst* (336 RPS, p99 4.8 s) even after a
warm-up, and its warm ceiling drifts run to run. "Who wins peak" is the
wrong question: JVM has the higher warm ceiling, native gives the same
predictable number every time with no warm-up. No 5xx either way — k6 just
queued as latency grew.

### The autoscaling angle (where the per-instance loss can flip on cost)

That ~470-vs-386 win is a *single-instance* number. In an autoscaled fleet
the economics can invert. Native starts in ~0.3 s and uses 2.5–4× less
memory: you can pack more replicas per node when memory is the binding
limit, drop the warm-pool over-provisioning needed to hide 15 s JVM starts,
and scale out in lockstep with traffic instead of minutes behind. For the
same monthly spend you can often run more small native replicas — and more
*aggregate*, predictable throughput — than a handful of larger JVM boxes,
even though each JVM box wins head-to-head when warm. Caveats: I didn't
benchmark a full fleet (this is the implication of the startup + memory
numbers, not a measured result), and the win comes from right-sizing on
memory *without giving up cores* — at a fixed 2 vCPU you can drop from
r7i.large (16 GB) or m7i.large (8 GB) to c7i.large (4 GB), same cores lower
bill, or bin-pack more containers per node. What native doesn't do is
conjure free CPU: here the 2 vCPU saturated long before the ~120 MiB of RAM
mattered, so a genuinely smaller (fewer-core) instance would serve less.

### Startup

Measured straight from Spring Boot's own `Started … in X seconds (process
running for Y)` log line — no health-poll quantisation:

| Metric               | JVM      | Native          |
|----------------------|----------|-----------------|
| Spring "Started in"  | 14–17 s  | **0.30–0.39 s** |
| Process exec → ready | 16–18 s  | **0.36–0.39 s** |

Native boots roughly **40–50× faster**, rock-steady across runs. If you're
paying for over-provisioned warm pools to hide JVM startup, native lets you
drop them. (An earlier draft quoted native at 1.16 s — that was a 1-second
health-poll rounding a sub-second boot up to the next tick; Spring's own
log says ~0.3 s.)

### Memory and image size

JVM peak RSS lands around **390–420 MiB** under load, native around
**100–165 MiB** — **2.5–4× less memory** (varies run to run, native always
far lower). JVM container image is ~180 MB, native ~95 MB — **about half**.
On 4 GB instances the absolute number is small, but on bin-packed nodes
(k8s, Fargate) it means more replicas per host.

## The PGO surprise

The PGO variant lost on every dimension that matters at runtime on AWS.
On my local AMD box, PGO had won everything in the smoke run. Why the
flip?

The training stage of GraalVM PGO needs a real workload. We trained on
the dev machine against a **localhost Postgres container** — query
roundtrips of microseconds. On AWS, Postgres lives on a separate RDS
instance — query roundtrips of **1–3 ms**. The hot paths are completely
different. PGO had carefully optimized code that was, in production, no
longer the hot path. The optimizer chased shadows.

The lesson is simple but easy to miss: **a PGO profile is only useful
where the workload it was trained on matches the workload it will see**.
A profile collected against your dev laptop's localhost is not
production. Either train in CI against representative infrastructure, or
don't ship PGO.

I also re-trained the PGO profile against the actual RDS topology and
re-measured — and it got _worse_ (291 RPS sustained, 232 RPS at peak
saturation, both significantly below the plain native build). PGO on a
Spring Boot Tomcat app with this much reflection and AOP isn't a
free win even with representative training; 60 s of mixed-workload
training was not enough to surface the right hot paths, and `-O3` +
`--gc=G1` together appear to introduce regressions for this kind of
workload. Worth deeper investigation, but the headline is: **default
native is the safe bet; PGO needs careful tuning per-application**.

## What the numbers don't show

- **Native build time.** ~5 min for plain native, ~12 min for PGO (build
  + 60 s training + build again). Tolerable for CI, painful for the
  inner dev loop. Use the JVM build while iterating locally; ship the
  native one.
- **AOT-maturity tax.** Reachability hints, runtime reflection
  registrations, `--initialize-at-build-time` battles — they happen at
  build time, but they happen. PetClinic itself shipped a bug:
  `RuntimeHints.resources().registerPattern("db/*")` only matches files
  directly in `db/`, not `db/postgres/schema.sql`. The native image
  passed `/actuator/health` and then 500'd every business endpoint until
  I patched it to `db/*/*`.
- **Cross-architecture PGO.** Profile data is portable, _generated
  machine code is not_. The PGO build pinned `-march=x86-64-v3` so the
  AMD-built image still runs on Intel c7i — but the profile mismatch (DB
  latency) bit much harder than the architecture mismatch ever would
  have.

## When to switch

If your service:

- runs in a serverless / scale-from-zero environment (Lambda, Fargate, Knative)
- needs tight memory budgets for density
- has latency SLOs that include the tail (p99)
- saturates CPU under peak load

…then native pays for itself in startup time and predictability.

If your service:

- runs as long-lived workers with stable load and warm pools
- relies on heavy reflection / dynamic class loading you can't easily annotate
- doesn't have p99 SLOs

…stay on the JVM. You'll get the lower median and avoid the AOT tax.

## How to run this yourself

Repo: <https://github.com/xp-vit/spring-petclinic>

```bash
# Local (Docker only)
./benchmark/scripts/run-local.sh standard all     # jvm + native + native-pgo

# AWS v2 architecture (2 EC2 + RDS)
AWS_PROFILE=<your_profile> ./benchmark/scripts/benchmark-v2.sh
```

Results land in `benchmark/results/{local,aws,aws-v2}/`. Matplotlib
generates `charts/*.png`. Cost per AWS v2 run: ~$0.20 for 70 min including
RDS. The terraform tears everything down at the end.

---

_Source repo + benchmark scaffold:
<https://github.com/xp-vit/spring-petclinic/tree/main/benchmark>_
