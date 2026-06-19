# Cache benchmark: no-cache vs Caffeine vs Redis (single-node, 3-way)

Local smoke results + harness notes. `benchmark/results/` is gitignored, so the numbers
that matter are preserved here.

## What it tests

Same `petclinic:jvm` fat JAR, three cache strategies selected by Spring profile (no
app-code change between them):

| variant          | profile                | CacheManager           | `/vets` hit cost                  |
|------------------|------------------------|------------------------|-----------------------------------|
| `cache-none`     | `postgres,cache-none`  | `NoOpCacheManager`     | full DB query every request       |
| `cache-caffeine` | `postgres,cache-caffeine` | `CaffeineCacheManager` | in-heap map lookup (no network)   |
| `cache-redis`    | `postgres,cache-redis` | `RedisCacheManager`    | JDK-serialize + TCP round-trip    |

`vets` is cached via the existing `@Cacheable("vets")` on `VetRepository.findAll()`.
Redis uses Spring's out-of-the-box default serializer (JDK serialization); the PetClinic
`BaseEntity` graph already implements `Serializable`, so `Collection<Vet>` round-trips
cleanly. (A JSON serializer was tried first and abandoned: Jackson 3 default-typing chokes
on Hibernate's `PersistentSet` runtime type for `Vet.specialties`.)

Workload `benchmark/k6/cache-workload.js`: 90% `GET /vets` (cache hits) + 10%
`POST /vets/{id}/touch` (DB UPDATE + `@CacheEvict("vets")` -> next read repopulates).

## Files

- `src/.../system/CacheConfiguration.java` — profile-selected CacheManager beans (rewritten)
- `src/.../vet/VetRepository.java` — added `findById` + `@CacheEvict` `save`
- `src/.../vet/VetController.java` — added `POST /vets/{id}/touch`
- `build.gradle` — added `spring-boot-starter-data-redis`; caffeine `runtimeOnly`->`implementation`
- `benchmark/k6/cache-workload.js` (NEW)
- `benchmark/scripts/run-cache-local.sh` (NEW) — pg + redis + 3 variants, `APP_PORT` overridable

## Local smoke result (2026-06-18; 3min/20VU, laptop, 512MB/1cpu, localhost PG + Redis)

Overall (latency ms; RPS is sleep-bound ~188 by design — not a throughput test):

| variant        | RPS  | p50  | p95  | p99  |
|----------------|------|------|------|------|
| cache-none     | 188.3| 0.82 | 1.45 | 2.68 |
| cache-caffeine | 188.1| 0.49 | 1.47 | 2.48 |
| cache-redis    | 187.3| 0.90 | 1.86 | 3.01 |

Split by operation (n = request count after 30s warmup):

| variant        | READ p50/p95/p99 (n~26.6k) | WRITE p50/p95/p99 (n~1.5k) |
|----------------|----------------------------|----------------------------|
| cache-none     | 0.81 / 1.45 / 2.71         | 0.91 / 1.37 / 1.77         |
| cache-caffeine | 0.41 / 1.47 / 2.49         | 1.06 / 1.50 / 2.31         |
| cache-redis    | 0.86 / 1.88 / 3.03         | 1.19 / 1.62 / 1.89         |

## Findings (local, single-node)

- **Read hit:** Caffeine halves read p50 (0.41 vs 0.81 no-cache). Redis ≈ no-cache (0.86)
  — locally, a Redis round-trip costs about as much as the 6-row query it replaces, so the
  network cache buys nothing.
- **Write/evict:** ordered exactly as predicted — Redis costliest (1.19, network DEL) >
  Caffeine (1.06, local map remove) > none (0.91, no evict).
- **Thesis:** cache payoff = (DB query cost) − (cache access cost). Cheap query + fast
  local DB => Caffeine still wins (in-heap ≈ free), Redis is net-negative. The expectation
  for AWS: network-distant RDS raises query cost, so Redis should flip to net-positive vs
  no-cache, while Caffeine stays ahead on raw latency.

## Heavy-payload peak runs (2026-06-18; profile=peak NO think-time, WORKLOAD=report, 50VU, 512MB/1cpu)

### The Redis collapse — ROOT-CAUSED + FIXED

First heavy run (SIZE=2000 ≈400KB, NO connection pool) cache-redis cratered to **20.3 RPS**,
p99 = 60s (k6 timeout), 1.28% fail, k6 errors `EOF` / `"too many transfer encodings:
[chunked chunked]"` / `request timeout`. Not graceful slowness — a failure cascade.

**Cause: default Lettuce uses ONE multiplexed connection.** A large GET/SET ties up the single
pipe (head-of-line blocking) while all other requests wait; under 50 no-sleep VUs with 400KB
values the app's Tomcat threads pile up behind the one connection and time out.

**Fix:** add `commons-pool2` + enable the Lettuce pool (`spring.data.redis.lettuce.pool.*`,
max-active=64) in `application-cache-redis.properties`. Result at SIZE=2000 jumped **20.3 ->
2071 RPS**, no cliff. So the 20 RPS was a default-config artifact, NOT Redis itself. (Real
takeaway worth a paragraph: the out-of-the-box single-connection Lettuce setup collapses on
large cached values; a pool is mandatory.)

### Cache-warm HIT cost vs payload size (pooled; WRITE_RATIO=0, pure cache hits)

RPS / p50 ms (higher RPS = better; reads only, cache stays warm):

| payload (rows / ~bytes) | cache-none      | cache-caffeine     | cache-redis      |
|-------------------------|-----------------|--------------------|------------------|
| 100  / ~20KB            | 5394 / 0.69     | **6291 / 0.58**    | 2895 / 1.74      |
| 500  / ~100KB           | 1838 / 3.35     | **2430 / 2.00**    | 875  / 80.8      |
| 2000 / ~400KB           | 408  / 99.8     | **683  / 94.6**    | 239  / 206       |

- **Caffeine wins at every size** (in-heap hit ≈ free): 1.2–1.7× over no-cache.
- **Redis is net-negative vs no-cache at every size**, hit cost scaling with payload
  (p50 1.7 -> 81 -> 206ms). Deserialize+transfer the value costs MORE than rebuilding it
  locally — because the synthetic "DB" is a cheap in-memory loop, so Redis replaces cheap work.
- At 2000 rows all three converge (~95–206ms): the 400KB **JSON response** serialization is a
  common floor; the cache backend is the delta on top.

### Write-churn read cost (pooled; WRITE_RATIO=0.1, constant allEntries evict — cache stays COLD)

Read-only RPS / p50 ms (cache continuously invalidated => reads are mostly MISSES):

| payload | cache-none   | cache-caffeine | cache-redis  |
|---------|--------------|----------------|--------------|
| 100     | 5132 / 0.60  | 5498 / 0.61    | 1371 / 5.06  |
| 500     | 1712 / 3.12  | 2058 / 2.24    | 496  / 94.2  |
| 2000    | 460  / 97.3  | 581  / 94.9    | 117  / 360   |

Under constant invalidation Redis is even worse (re-serialize+PUT 400KB on every repopulate).
NOTE workload caveat: the `report` write path (`/cache/report/evict`) is a no-op cache-clear
(no DB write, unlike the vets `touch`), so with no think-time the write VUs spam evict; the
*overall* RPS/p50 in `comparison.txt` for these runs is polluted by trivial evict calls (e.g.
redis "2071 RPS / p50 0.11ms" at SIZE=2000 is mostly evicts). Use the read-only numbers above.

### Heavy DB aggregation — the representative case (WORKLOAD=stats, pooled, WRITE_RATIO=0, peak)

The earlier `vets`/`report` cached ops were too cheap (6-row query / in-memory loop), so the cache
avoided almost nothing. `stats` caches a genuinely expensive query: a per-pet-type aggregation
(`COUNT(DISTINCT ...)` over a LEFT JOIN of pets×visits) on a seeded dataset of 100k owners /
300k pets / **2M visits**. Single-query miss cost ≈ **2.7s** (read p50 2664ms; under 50-VU
saturation it climbs to ~7.6s).

| variant        | RPS    | p50    | p95   | p99   | reads     | fail |
|----------------|--------|--------|-------|-------|-----------|------|
| cache-none     | 6.5    | 7592ms | 8419  | 8626  | 1,021     | 0%   |
| cache-caffeine | 13761  | 0.33ms | 1.97  | 88.6  | 2,036,653 | 0%   |
| cache-redis    | 7425   | 0.82ms | 83.9  | 89.0  | 1,098,914 | 0%   |

- cache-none 6.5 RPS / p50 7.6s checks out: 50 VUs each blocking on the heavy query, contention
  pushes 2.7s -> ~7.6s, 50/7.6 ≈ 6.6 RPS.
- **Both caches are ~1100–2100× faster than no-cache** — the regime where caching obviously pays,
  because it skips a multi-second query. This is the representative result the cheap workloads
  could not produce.
- **Caffeine ≈ 1.85× Redis** (13761 vs 7425; p50 0.33 vs 0.82ms; Redis tail worse, p95 84 vs 2ms):
  in-heap hit beats a network round-trip. But **Redis is still 1142× no-cache — hugely net-positive.**
- Payload here is tiny (a few rows), so Caffeine-vs-Redis is pure access-cost. The `report` sweep
  shows how a large payload widens that gap further (Redis deserialize/transfer scales with size).

## AWS run (2026-06-19; v2 stack: app c7i.large + Redis container, k6 c5.large, RDS db.m7i.large, network-distant)

WRITE_RATIO=0 (cache-warm hits). Numbers from k6 summary-export (reads only). RPS / p50 / p95 / p99 ms.

### vets (tiny 6-row query) — the predicted FLIP

| phase | cache-none | cache-caffeine | cache-redis |
|-------|------------|----------------|-------------|
| smoke (20VU, think-time) | 190.5 RPS / 3.35 / 6.08 / 19.96 | 196.4 / 1.00 / 1.85 / 3.93 | 194.1 / **1.34** / 3.17 / 5.79 |
| peak (50VU, no sleep)    | 1753 RPS / 10.7 / 106 / 210     | 7805 / 4.27 / 14.0 / 57.9     | 3881 / 5.31 / 55.6 / 72.8   |

The query that was ~0.8ms on localhost is **3.35ms against network-distant RDS**. That extra cost is
what flips the verdict: locally Redis (0.86) ≈ no-cache (0.81); **on AWS Redis (1.34) clearly beats
no-cache (3.35)** — the network hop to RDS makes even the tiny query worth caching externally.
Caffeine still best (1.00). At peak, both caches crush no-cache (Redis 2.2×, Caffeine 4.5×).

### stats (heavy aggregation, 2M visits) — transformative

| phase | cache-none | cache-caffeine | cache-redis |
|-------|------------|----------------|-------------|
| smoke | 0.9 RPS / 22750 / 25086 / 26303 | 178.6 / 0.90 / 1.63 / 3.29 | 177.1 / 1.08 / 2.23 / 3.91 |
| peak  | 1.4 RPS / 33219 / 41134 / 41940 | 8298 / 3.96 / 11.0 / 25.5  | 5469 / 4.40 / 30.9 / 58.0  |

No-cache melts (~1 RPS, p50 22–33s) under 20–50 concurrent `COUNT(DISTINCT)` aggregations on a
2-vCPU RDS; caches serve from memory at ~1–4ms, **~1000–6000× the throughput**. Caffeine ~1.5× Redis.
CAVEAT: the no-cache p50 (22–33s) is contention on a small RDS, not a clean single-query latency
(local single-query ≈ 2.7s); sample is tiny (170–290 reqs). Directionally unambiguous: an uncached
expensive query collapses under load, the cache removes it entirely.

### AWS verdict

- **Caffeine wins on raw speed everywhere** (in-heap hit), 1.5–2× Redis at peak.
- **Redis is net-positive on AWS even for the tiny query** (unlike locally) — network-distant RDS
  raises avoided-work cost above Redis's access cost. This is the hypothesis confirmed.
- For the expensive query, the cache backend choice barely matters next to *having* a cache: both are
  ~1000×+ no-cache. Choose Redis for sharing/persistence/capacity; Caffeine for lowest latency.

### Run mechanics / gotcha hit

The orchestrator finished all load phases but exited 1 on the final `k6_run upload`: empty `""`
positional args collapse when passed through `ssh "... $*"`, leaving `AWS_REGION` empty. That aborted
before `tf_destroy`, so infra was left up and the k6 CSVs (multi-GB at peak) hadn't uploaded. Recovered
by pulling the small `summary.json` files directly + manual destroy. FIX applied: pass args through
`printf %q` in `app_run`/`k6_run`, and make uploads non-fatal so teardown always runs.

### Unifying law (now demonstrated, not asserted)

cache payoff = (avoided-work cost) − (cache-access cost).
- Cheap avoided work (vets 1ms query / report in-memory loop): Caffeine barely wins, Redis is
  net-NEGATIVE (access cost > work saved).
- Expensive avoided work (stats 2.7s query): BOTH win ~1000×+, Caffeine ~2× Redis on raw speed,
  Redis trades that ~2× / fatter tail for sharing + persistence + capacity.

**AWS dimension still to add:** network-distant RDS raises avoided-work cost for *every* query (not
just the synthetic-heavy one), and multi-node tests the shared-warm-Redis vs N-cold-Caffeine story.

## Caveats / NOT done

- DONE: peak (no-sleep) profile, heavy-payload `report` endpoint with size knob, Lettuce pool
  fix, size sweep (100/500/2000), and hit-vs-churn separation. Light `vets` smoke + heavy
  `report` hit curve are clean and trustworthy.
- Workload fix still wanted: make the `report` write path do real work (or add think-time) so
  the churn-scenario *overall* RPS isn't dominated by no-op evict spam. For now read-only
  numbers are the source of truth in churn runs.
- The synthetic report "miss" is a cheap CPU loop, not real DB I/O — which is exactly why Redis
  loses locally. The AWS run (real network-distant RDS query) is what tests the flip.
- Single-node only — the multi-instance story (shared warm Redis vs N cold/divergent
  Caffeine caches, stampede, cross-node staleness) is NOT measured. That is the strongest
  *why-Redis* argument and would need a load-balanced multi-node AWS setup.
- AWS paired rounds NOT run. Add the 3 cache variants to the v2 harness (ElastiCache or a
  Redis container on the EC2 host; set `SPRING_DATA_REDIS_HOST`).
- `/actuator/caches` shows `{}` for the Redis variant (RedisCacheManager creates caches
  lazily on first use) — caches confirmed working via 200s + the latency delta, not the
  endpoint.
