# Spring Boot on the JVM vs GraalVM Native (+ PGO): What Actually Wins on AWS

> **TL;DR** — On a 2 vCPU / 4 GB AWS c7i.large with Postgres on a separate
> RDS db.t3.micro and k6 on its own EC2:
> - GraalVM native starts **~17× faster** (1.2 s vs 20 s).
> - Cold start while traffic is hitting the port: native is **~76×
>   faster** (255 ms vs 19.4 s).
> - Native handles **+5 % more peak RPS** under saturation, with a
>   **~24 % tighter p99**.
> - The JVM, _once warm_, has a lower **p50** (10 ms vs 20 ms native)
>   and serves ~5 % more sustained RPS at moderate load.
> - Native peak RSS is **~2.5× lower** (165 MiB vs 422 MiB).
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
| Cold start      | 10 req/s probe + container start, measure first 200              |

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
| JVM     | **414** | **10** | 89     | 171     | 0      |
| Native  | 393     | 20     | **69** | **147** | 0      |

![Throughput over time](results/aws-v2/charts/throughput-over-time.png)

The JIT warm-up is visible in the orange line: JVM throughput ramps from
~100 req/s at boot to ~450 req/s after about 3 minutes. Native serves
~400 req/s from the first second. After warm-up, JVM serves slightly
more sustained throughput (414 vs 393, +5 %) on moderate load.

The hot-path p50 also belongs to the JIT (10 ms vs 20 ms native): C2 has
runtime profile data the AOT compiler doesn't get, and PetClinic's
most-frequent path is small enough that it fits well in C2's optimized
form. The tail (p95/p99) goes to native, because there are no GC pauses.

### Peak-RPS saturation sweep (100 → 2000 req/s over 5 min)

| Variant | Achieved RPS | p50  | p95      | p99      | Errors |
|---------|--------------|------|----------|----------|--------|
| JVM     | 374          | 1109 | 2822     | 3995     | 0      |
| Native  | **391**      | 1212 | **2356** | **3049** | 0      |

![Peak-RPS sweep](results/aws-v2/charts/peak-rps.png)

When the CPU is the bottleneck, native gets more work per cycle because
it isn't spending CPU on JIT compilation + GC. p99 latency at saturation
drops by ~24 % on native. Neither variant returned 5xx — k6 just queued
requests as latency grew.

### Startup

| Scenario                      | JVM    | Native     |
|-------------------------------|--------|------------|
| Cold start (no load)          | 20.0 s | 1.16 s     |
| Cold start under live traffic | 19.4 s | **255 ms** |

![Startup time](results/aws-v2/charts/startup-bar.png)

If you're paying for over-provisioned warm pools to hide JVM startup —
native lets you drop those. Cold-start-under-load is the honest number:
a container starts while users are already hitting the new endpoint, and
we measure ms until it answers 200.

### Memory and image size

JVM peak RSS lands at **422 MiB** under load, native at **165 MiB** —
**~2.5× less memory**. JVM container image is 171 MB, native is 91 MB
— **half the size**. On 4 GB instances the absolute memory number is
small, but on bin-packed nodes (k8s, Fargate) it means more replicas
per host.

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
