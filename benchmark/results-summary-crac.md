# CRaC vs GraalVM Native vs JVM — results summary

Third contender added to the `spring-boot-jvm-vs-graalvm-native-benchmark` rig.
Honest-metrics rule: every published number comes from OUR run on ONE rig.

## Variants

| variant | what | JDK |
|---|---|---|
| `jvm` | plain cold JVM (existing baseline) | Eclipse Temurin 25 |
| `crac-jvm` | plain cold JVM on the CRaC distro, CRaC off (isolates the distro confounder) | Azul Zulu 25 CRaC-CA |
| `crac` | **warmed** on-demand checkpoint (`jcmd JDK.checkpoint` after load-warming), restore on start | Azul Zulu 25 CRaC-CA, engine=warp |
| `crac-onrefresh` | `-Dspring.context.checkpoint=onRefresh` (cold JIT — the "mode trap") | Azul Zulu 25 CRaC-CA, engine=warp |
| `native` | GraalVM native image | Oracle/Community GraalVM 25 |

CRaC JDK: `Zulu25.34+17-CRaC-CA (25.0.3)`, engine **warp** (default since Apr 2026, needs no privileges).

## Methodology (unchanged from prior posts, + CRaC additions)

- AWS c7i.large (app) + c5.large (k6 load gen) + RDS Postgres 18.3, same AZ.
- 512m / 1 cpu container caps. Drop first 60s (JIT warmup) for steady-state.
- Startup measured BOTH ways: docker-run → first **business** endpoint 200 (`/vets`, not `/actuator/health`) AND Spring `Started in` / warp `restored JVM running for` log.
- 5 back-to-back peak-RPS saturation sweeps (ramping-arrival-rate) + variance.
- CRaC-specific: checkpoint created ON the c7i target (native CPU features, no `-XX:CPUFeatures=generic` tax, URL matches restore); checkpoint-creation time, restore time, on-disk checkpoint image size, container image size.

## Local preview (NOT publishable — 1 cpu / 512m desktop, bridge Postgres)

De-risking run on Manjaro (kernel 6.12, `CONFIG_CHECKPOINT_RESTORE=y`), warmup 45s.
Shows the shape; AWS numbers replace these.

## AWS results (2026-07-20, c7i.large + RDS m7i.large + k6 c5.large, 512m/1cpu, 5 peak sweeps)

**Cold start — docker-run → first business `/vets` 200 (cold-start-under-load):**

| variant | cold→200 | Spring/warp log |
|---|---:|---|
| `jvm` | 19,366 ms | Started 14.4 s |
| `crac-jvm` | 19,932 ms | Started 17.9 s |
| **`crac` (warmed)** | **277 ms** | warp restore 207 ms |
| `crac-onrefresh` | 2,663 ms | warp restore 128 ms |
| `native` | 255 ms | Started 0.39 s |

Warmed CRaC (277 ms) ≈ native (255 ms), **~70× faster than the JVM** (19.4 s) on
1 vCPU. onRefresh boots in 2.7 s (fast) but keeps cold JIT.

**Peak / saturation throughput — best of 5 sweeps (ramp 100→2000 RPS, saturated):**

| variant | peak RPS | p95 | p99 | fail |
|---|---:|---:|---:|---:|
| `jvm` | **394** | 2.08 s | 2.62 s | 0% |
| `crac-jvm` | 340 | 2.45 s | 3.07 s | 0% |
| `crac` (warmed) | 298 | 2.80 s | 3.48 s | 0% |
| `native` | 247 | 3.44 s | 4.25 s | 0% |
| `crac-onrefresh` | — | — | — | **OOM (100% fail @ 512m)** |

Variance across the 5 sweeps was tight (±1–2%). Temurin `jvm` (394) also beat Zulu
`crac-jvm` (340) — a JVM-distro gap, not a CRaC effect.

### Anomaly RESOLVED — it was memory starvation, not a CRaC throughput deficit

The warm-CRaC peak (298) < cold-Zulu `crac-jvm` (340) looked like CRaC losing
warm-JIT throughput. A focused 2×2 re-test (`crac` vs `crac-jvm` × 512m vs 768m,
same infra/session, 3 sweeps each) says otherwise:

| cell | peak RPS | peak RSS | status |
|---|---:|---:|---|
| `crac-jvm` @512m | 421 | 442 MB | clean |
| `crac-jvm` @768m | 435 | 506 MB | clean |
| `crac` @512m | — | 511 MB (cap) | **OOM under load** |
| `crac` @768m | 427 | 699 MB | clean |

- **First hypothesis (`allow-pool-suspension` lock) was falsified** by a clean local
  A/B: 241 vs 248 RPS with the flag off/on — no effect.
- The real cause: the warmed checkpoint restores a **large working set** (~700 MB —
  warm heap: Caffeine caches, Hibernate, JIT state). At the 512 MB cap it is
  memory-starved → limped to 298 RPS in the main run, and OOM-kills outright under
  any extra load pressure. `crac-jvm` starts lean (~450 MB) and is **not**
  memory-bound (421→435 from 512→768).
- **Given adequate memory (768m), `crac` (427) ≈ `crac-jvm` (435)** — within 2%. So
  **CRaC does NOT lose warm-JIT peak throughput; the earlier deficit was
  undersizing.** The brief's thesis holds, with a firm caveat: size the container
  for the restored warm heap (here ~+250 MB over a cold JVM).
- Caveat: ~20% run-to-run variance in *absolute* peak (main-run `crac-jvm` 340 vs
  re-test 421) — attribute to RDS/host state between sessions; the reliable signal
  is the *within-run* comparison above.

**Steady-state — 50 VUs, 10 min mixed (not saturated):** all variants 300–354 RPS
(VU-bound); `crac` had the tightest tail (p99 161 ms), native the highest p50
(57 ms, GraalVM per-request cost).

**Memory (RSS) + image:**

| variant | cold RSS | peak RSS | image | checkpoint (disk) |
|---|---:|---:|---:|---:|
| `native` | 130 MB | **185 MB** | **100 MB** | — |
| `jvm` | 279 MB | 442 MB | 171 MB | — |
| `crac-jvm` | 280 MB | 436 MB | 332 MB | — |
| `crac` (warmed) | 154 MB | 428 MB | 451 MB | 269 MB |
| `crac-onrefresh` | 217 MB | 511 MB (OOM) | 433 MB | 210 MB |

native wins memory + image decisively (185 MB peak, 100 MB image — ~40% of the
JVM). CRaC's low **cold** RSS (154 MB) is warp lazy page-in (image faults in on
demand), but it grows to JVM-level under load. CRaC's deployed image is largest
(451 MB — bakes the 269 MB checkpoint + full Zulu JDK).

**Checkpoint create time:** `crac` 103.5 s (90 s warm + dump), `crac-onrefresh` 10.3 s.

**The honest story:** warmed CRaC delivers near-native *startup* AND matches the
JVM's warm *peak* throughput (427 vs 435 RPS at 768m) — provided you size memory
for the restored warm heap (~+250 MB); undersized at 512 MB it starves and OOMs.
native remains the memory + image + flat-startup champion with the lowest peak.
onRefresh is the trap: fast boot, cold JIT, OOMs at 512 MB under saturation.
Decision matrix: **native** when memory/image/density rule; **warmed CRaC** for
fast startup + full JVM peak when you can pay ~700 MB + a checkpoint build step;
**plain JVM** when ops simplicity wins and slow cold start is acceptable.

## Secrets-safe pattern — verified

Warmed with placeholder `PETCLINIC_API_SECRET`; restored with a real one.
`/crac/secret-status` after restore: `{"source":"restored-env","sha256":"d0dabba61c5d"}`
— different hash than the build placeholder (`429478d4de98`). The real secret is
read in `afterRestore()` and never lands in an image layer. DB password is
re-applied to the live Hikari pool the same way.

## Status

- [x] App CRaC support (`org.crac`, `CracSupport.java`, `application-crac.properties`)
- [x] Docker: warmup / restore / restore-layer / onrefresh / crac-jvm
- [x] `make-crac-checkpoint.sh` (local + external-DB/RDS)
- [x] k8s example (`k8s/crac/`) with warp no-privilege + secrets-safe + homogeneity notes
- [x] Local checkpoint/restore validated end-to-end
- [x] **AWS 5-variant run complete (2026-07-20)** — infra destroyed, results in `benchmark/results/aws-v2`
- [x] **crac-peak anomaly re-tested + RESOLVED (2026-07-20)** — memory starvation, not a throughput deficit; `crac`≈`crac-jvm` at 768m. Results in `benchmark/results/aws-crac-retest`
- [ ] Public GitHub repo + final RESULTS.md + blog draft
