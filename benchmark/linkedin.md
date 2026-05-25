# LinkedIn post — JVM vs GraalVM Native on a real Spring Boot app

I got tired of GraalVM Native vs JVM benchmarks that don't actually load a
database or template engine. So I ran the real thing: Spring Boot PetClinic
on Postgres, on AWS c7i.large, k6 mixed workload, 10 minutes.

Same code, same hardware, Java 25 LTS both sides.

🏁 **Cold start (no load):** JVM 17.7s → Native 1.2s — **14× faster**
🚦 **Cold start while traffic is hitting the port:** JVM 17.3s → Native 0.25s — **68× faster**
💾 **Memory under load:** JVM ~400 MiB → Native ~110 MiB — **~4× less RAM**
📉 **p99 latency (sustained):** JVM 160 ms → Native 109 ms — **-32%** (GC pauses gone)
📈 **Peak RPS at saturation:** JVM 393 → Native 422 — **+7%** on the same 2 vCPU
📦 **Container image:** 171 MB → 90 MB — half
🟰 **Sustained throughput (50 VUs, after JIT warmup):** JVM 420 / Native 410 req/s — JVM actually slightly higher post-warmup

Counter-intuitive: **JVM p50 was 7 ms vs native 13 ms** once warm. C2 has runtime profile info AOT doesn't get. Native wins the tail, not the median.

Surprises:
1. JIT actually edges native on p50 once warm. The "native is always faster" claim is too simple.
2. Native wins the tail (p99) and saturation peak RPS — that's the real story.
3. One AOT gotcha cost me an hour: `RuntimeHints.resources().registerPattern("db/*")` only matches `db/foo`, not `db/postgres/schema.sql`. App passed health checks, every business endpoint returned 500. `db/*/*` fixed it.

When to switch:
✅ Scale-from-zero / serverless / Fargate / Lambda — the 14× startup wins
✅ Tight tail latency SLOs — the GC pauses disappear
✅ Dense bin-packing — 4× less RSS per replica

When to stay on JVM:
🤷 Long-running workers w/ warm pool — JIT catches up anyway
🤷 Heavy reflection / dynamic loading you can't easily annotate
🤷 You can't afford the 5-min native compile in your inner loop

Full write-up + reproducible scripts (Terraform + Docker + k6 + matplotlib):
<https://github.com/xp-vit/spring-petclinic/tree/main/benchmark>

What are _you_ seeing on your real workloads?

#java #springboot #graalvm #aws #performance
