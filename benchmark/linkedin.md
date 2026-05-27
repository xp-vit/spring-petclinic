# LinkedIn post — JVM vs GraalVM Native

A few weeks ago I posted about migrating a high-load Spring Boot service
to a GraalVM native binary: memory per replica dropped from ~450 MB to
~135 MB, startup from 45 s to 1.5 s. The chart was satisfying. The
comments were better.

The best one came from my friend and ex-colleague Siarhei Sushko, who
pointed out the trade-off I had glossed over: **going native costs you
JIT throughput**. He linked Quarkus's own benchmark write-up
(https://quarkus.io/blog/new-benchmarks/#native-tradeoffs), which is
honest enough to say it out loud.

So I decided to actually measure it on Spring Boot. Same app
(PetClinic — Thymeleaf + JPA, the canonical sample), two builds (JVM
and GraalVM native), one cloud setup, head-to-head.

Setup: AWS c7i.large (2 vCPU) for the app, separate c5.large for k6,
RDS Postgres db.t3.micro. Java 25 LTS for both. 10-min mixed workload at
50 VUs, then a 5-min ramp to find peak RPS — and I ran the peak sweep
five times per variant, because the first results refused to reproduce.

**Where native wins, every time:**
🏁 Cold start: ~15 s → ~0.3 s — **~40× faster** (from Spring's own log)
💾 Peak RSS under load: ~400 MiB → ~120 MiB — **2.5–4× less RAM**
📦 Container image: ~180 MB → ~95 MB — about half
📊 Sustained tail: native is the *predictable* one — p99 ~150 ms every run, while the JVM's swings 110–171 ms with GC luck

**The throughput trade-off Siarhei called out — confirmed:**
Sustained moderate load: JVM p50 ~8–10 ms vs native ~18 ms; JVM serves a
few % more RPS once warm.

And peak/saturation is where it got interesting. A single run flip-flopped
the winner, so I ran it 5×:
- Native: **386 RPS ± 2** — identical from the very first request.
- JVM: **~470 RPS once warm (+22 %)** — but its first saturation burst is
  its *worst* (336 RPS, p99 4.8 s), and the warm ceiling drifts run to run.

So Siarhei was right: the JIT gives the JVM a higher throughput ceiling.
What the native side buys you isn't more peak — it's **predictability**:
the same number every time, no warm-up window.

And here's the kicker for cost: that lower per-instance ceiling can flip in
an autoscaled fleet. ~0.3 s starts + 2.5–4× less RAM = more small replicas
per dollar, no warm-pool waste, scale-out that tracks traffic in seconds.
Per box, the warm JVM wins; per dollar, elastic native can win the
throughput back. (Reasoned from the startup + memory numbers — I didn't
bench a full fleet.)

**Reach for native when:**
✅ Scale-from-zero / serverless / Fargate / Lambda — startup wins big
✅ You need predictable latency from the first request (no warm-up)
✅ Dense bin-packing / memory-constrained instances — 2.5–4× less RSS
✅ Predictable tail matters more than the lowest median (low variance)

**Stay on the JVM when:**
🤷 Long-running warm workers that can hit a high throughput ceiling
🤷 Median (not tail) is what matters
🤷 Heavy reflection / dynamic loading you can't easily annotate

So Siarhei was right, and so was the original post. Native isn't a free
upgrade — it's a different operating point: better startup, far less
memory, dead-predictable latency; in return a higher median, a lower peak
ceiling, and a tail that's steadier but not always lower than a warm JIT's.
The comment that made me measure it properly — and run it until it
reproduced — is what made the story honest.

Full write-up — all the charts, the reproducibility runs, and the
Terraform + k6 + matplotlib scripts to repeat it:
https://patotski.com/blog/spring-boot-jvm-vs-graalvm-native-benchmark

#java #springboot #graalvm #aws #performance
