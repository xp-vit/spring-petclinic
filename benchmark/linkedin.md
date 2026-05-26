# LinkedIn post — JVM vs GraalVM Native vs Native+PGO

I ran the same Spring Boot PetClinic on AWS in three configurations and
the numbers told a more nuanced story than the usual "native is faster"
headlines.

Setup: c7i.large for the app, separate c5.large for k6, RDS db.t3.micro
for Postgres. Same Java 25 LTS for all three. 10-minute mixed workload
(50 VUs), then a 5-min ramp to find peak RPS. All numbers below drop the
first 60 s so the JIT has time to warm up.

🏁 **Cold start (no load):** JVM 20.0s → Native 1.2s — **~17× faster**
🚦 **Cold start under live traffic:** JVM 19.4s → Native 255 ms — **~76× faster**
💾 **Memory under load:** JVM 422 MiB → Native 165 MiB — **~2.5× less RAM**
📈 **Peak RPS at saturation:** JVM 374 → Native 391 — **+5%** on the same 2 vCPU
📉 **p99 at saturation:** JVM 4.0s → Native 3.0s — **-25%**
📦 **Container image:** 171 MB → 90 MB

But here is the part I didn't expect: **once the JIT is warm, the JVM has
a lower p50 than native** (10 ms vs 20 ms) on sustained moderate load.
C2 has runtime profile data the AOT compiler doesn't get. Native wins
the tail (p95/p99), JIT wins the median.

And the cherry on top — **GraalVM PGO lost on AWS**.

I trained the PGO profile on my dev box, where Postgres ran on
localhost. On AWS the database is RDS, query latency goes from
microseconds to 1-3 ms, and the hot paths shifted entirely. The PGO
build had carefully optimized code that production never executes. p50
went up 60 %, peak RPS dropped 25 %.

PGO is only as good as the workload you train it on. A localhost profile
optimizing for production is like a runner doing high-altitude training
at sea level.

When to switch to native:
✅ Scale-from-zero / serverless / Fargate / Lambda — startup wins
✅ Tight p99 SLOs and saturation-prone workloads
✅ Dense bin-packing — 4× less RSS per replica
✅ Memory-constrained instances

When to stay on the JVM:
🤷 Long-running workers with warm pools — JIT catches up anyway
🤷 Heavy reflection / dynamic loading you can't easily annotate
🤷 Workloads where median (not tail) matters

Full write-up + reproducible Terraform + k6 + matplotlib scripts:
<https://github.com/xp-vit/spring-petclinic/tree/main/benchmark>

#java #springboot #graalvm #aws #performance #pgo
