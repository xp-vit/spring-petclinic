# Spring Boot on the JVM vs GraalVM Native: Real Numbers on AWS

> **TL;DR** — On a 2 vCPU / 4 GB c7i.large running PetClinic on Postgres, the
> GraalVM native build started **~14× faster**, used **~4× less memory**, had
> **~4× lower p99 latency**, and matched JVM throughput on the same hardware.
> The image was half the size. Cold start under traffic was **68× faster**.
>
> _Stack: Spring Boot 4.0.3, Java 25 LTS, GraalVM Community 25, Postgres 18.3,
> Ubuntu 24.04 LTS on EC2._

## The question

I keep seeing GraalVM native compared to JVM with synthetic micro-benchmarks
(hello-world latency, fib(40), JSON-only services). Those numbers don't tell
me anything useful — my real apps have a database, Hibernate, Thymeleaf, the
whole Spring lifecycle.

So I took the canonical Spring sample, **PetClinic**, built it both ways,
and put the same load on both. Same `c7i.large`, same Postgres 18.3, same
mixed workload over 10 minutes.

This post walks through the numbers, what surprised me, and how to run it
yourself.

## Setup

| Component       | Value                                              |
|-----------------|----------------------------------------------------|
| App             | Spring Boot 4.0.3 + PetClinic (Thymeleaf + JPA)    |
| Java            | 25 LTS for both JVM and native                     |
| Native compiler | GraalVM Community 25, `org.graalvm.buildtools.native` 0.11.5 |
| Database        | Postgres 18.3 (Docker, same host as app)           |
| Instance        | AWS EC2 `c7i.large` — 2 vCPU, 4 GB, non-burstable  |
| Container       | 1 CPU / 512 MB cgroup limit                        |
| Load            | k6, 50 VUs, 4 scenarios (40/20/20/20 split), 10 min |
| Workload mix    | `GET /owners?lastName=Davis` (40%), `GET /owners/{id}` (20%), `GET /vets` JSON (20%), `POST /owners/new` (20%) |

A non-burstable instance matters. `t3.*` and `t4g.*` accumulate CPU credits
that vanish under sustained load — you get the wrong numbers, and you can
read them as "native is slower" when the credit bucket simply ran out
mid-test. `c7i.large` holds full CPU the whole time.

## Results

> _Numbers from the c7i.large AWS run, mixed workload, 50 VUs, 10 min._

_Sustained-load numbers below are computed after dropping the first 60 s so
the JVM's JIT has finished its warm-up curve — otherwise the JVM numbers are
unfairly low._

| Metric                       | JVM           | Native        | Delta             |
|------------------------------|---------------|---------------|-------------------|
| Startup (no load)            | 17.7 s        | 1.2 s         | **14× faster**    |
| Cold start under load        | 17.3 s        | 0.25 s        | **68× faster**    |
| Throughput (sustained)       | 420 req/s     | 410 req/s     | ~tied (JVM +2%)   |
| Latency p50                  | 7 ms          | 13 ms         | JVM hot path wins |
| Latency p95                  | 83 ms         | 66 ms         | native -20%       |
| Latency p99                  | 160 ms        | 109 ms        | **native -32%**   |
| Peak RPS (5-min sweep)       | 393 req/s     | 422 req/s     | **native +7%**    |
| Peak RPS p99                 | 4160 ms       | 3027 ms       | **native -27%**   |
| Peak RSS                     | ~400 MiB      | ~100 MiB      | **~4× less mem**  |
| Docker image                 | 171 MB        | 90 MB         | **~half**         |
| Errors                       | 0             | 0             | both clean        |

![Summary dashboard](results/aws/charts/summary-dashboard.png)

### Startup

![Startup time](results/aws/charts/startup-bar.png)

JVM PetClinic finishes Spring context, JPA, Tomcat in ~17.7 s on a 2 vCPU
instance. Native binary does it in ~1.2 s — all the reflection, classpath
scanning, bean wiring is resolved at build time.

The "cold start under load" row is more honest: a real cold start happens
while users are already trying to hit the new container. We hold a light
probe at 10 req/s, then start the container, and measure milliseconds to
first 200 response. JVM: 17.3 s of 5xx/timeouts. Native: 0.25 s.

If you're paying for over-provisioned warm pools to hide JVM startup —
native lets you drop those.

### Throughput and latency

![Throughput over time](results/aws/charts/throughput-over-time.png)

The JIT warm-up is visible in the JVM line: throughput climbs over the first
~60 s as the C2 compiler optimizes hot methods. After warm-up the JVM lands
**slightly above** native on sustained throughput on this hardware (420 vs
410 req/s, +2 %). The popular "native is 30 % faster" claim does **not**
hold up here under a sustained light load — native's win is elsewhere.

![Latency percentiles](results/aws/charts/latency-bars.png)

Interesting:

- **p50:** JVM 7 ms vs native 13 ms — _the warmed-up JIT hot path is
  measurably faster than AOT_. People often miss this. C2 has runtime profile
  information AOT never gets.
- **p95:** native 66 ms vs JVM 83 ms (–20 %).
- **p99:** native 109 ms vs JVM 160 ms (–32 %).

The tradeoff: JIT is faster on the median once warm, native is steadier in
the tail. The classic GC-pause tail on the JVM is visible in the histogram:

![GC pauses](results/aws/charts/gc-pause-hist.png)

The pauses are small (SerialGC on a 512 MB heap) but they're real, and they
land in your p99.

### Memory

![Memory over time](results/aws/charts/memory-over-time.png)

JVM RSS settles around ~400 MiB under load. Native settles around ~100 MiB.
At ~$0.0892/hr for c7i.large there's no direct cost difference here — but on
smaller instances or denser packing (k8s, ECS Fargate), 4× less RSS means
4× more replicas per node.

### Peak RPS

![Peak RPS sweep](results/aws/charts/peak-rps.png)

A 5 minute ramp from 100 → 2000 RPS shows where each variant saturates the
2 vCPU. Both variants ran out of CPU well before 2000 req/s — at saturation,
**native served 7 % more requests** (422 vs 393 req/s) with a **27 % tighter
p99** (3.0 s vs 4.2 s). Neither returned 5xx; k6 just queued requests as
latency rose.

The interpretation: when the CPU is the bottleneck, native gets more work
per cycle because it isn't spending CPU on JIT + GC. When the workload is
below saturation (50 VUs case above), JIT catches up and even edges ahead
on p50.

### Image size

![Image size](results/aws/charts/image-size-bar.png)

Native image: ~90 MB, JVM image: ~171 MB. Half the bytes through your CI
artifact registry, half the cold-pull time when the node first pulls the
image.

## What didn't show up here

A few things the numbers _don't_ say:

- **Sustained max throughput on more cores.** On c7i.large with 2 vCPU, JIT
  has time to warm up _and_ catches native. On much smaller instances
  (1 vCPU, 1 GB) JVM struggles to warm up under load at all — that's a blog
  for another day.
- **Build time.** Native compile is ~5 minutes vs ~1 minute for `bootJar`.
  Worth it for CI artifact builds, painful for inner loop. Use the JVM build
  while iterating locally; ship the native one.
- **Operational maturity.** Reachability hints, runtime reflection
  registrations, `--initialize-at-build-time` battles — those happen during
  the _build_, not in the chart. I had to fix one in this very project:
  `db/*` only matches `db/foo`, you need `db/*/*` for
  `db/postgres/schema.sql`. Without that, native passes `/actuator/health`
  but every business endpoint returns 500.

## How to run this yourself

Repo: <https://github.com/xp-vit/spring-petclinic>

```bash
# Local (Docker)
./benchmark/scripts/run-local.sh standard both

# AWS (creates EC2, ECR, S3 → runs → destroys)
AWS_PROFILE=<your_profile> ./benchmark/scripts/benchmark.sh
```

Results land in `benchmark/results/{local,aws}/`. Charts (matplotlib) end up
in `…/charts/*.png`. ASCII report via `generate-report.sh`.

Everything — Dockerfiles, k6 scripts, Terraform, chart generator — is in
`benchmark/` and is ~$0.10 per AWS run on `c7i.large`.

## Recommendation

If your service:

- runs in a serverless / scale-from-zero environment (Lambda, Fargate, Knative)
- needs tight memory budgets for density
- has latency SLOs that include tail (p99)

…then native is the obvious move and the build complexity pays for itself.

If your service:

- runs as long-lived workers with predictable load
- already has warm pools
- has heavy reflection / dynamic class loading you can't easily annotate

…stay on the JVM. The peak throughput won't change, and you'll skip the AOT
maturity tax.

The numbers above weren't to crown a winner. They were to remove the
"feels-like" from the conversation.

---

_Source repo + benchmark scaffold:
<https://github.com/xp-vit/spring-petclinic/tree/main/benchmark>_
