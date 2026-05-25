# Spring PetClinic: JVM vs Native Benchmark

Compare Spring Boot **JVM (JIT)** vs **GraalVM Native (AOT)** on throughput, latency,
startup time, memory, CPU, GC pauses, and image size. Runs locally (Docker) or on
AWS EC2 (Terraform).

Project Java version: **25 (LTS)** for both variants.

## Layout

```
benchmark/
  docker/             Dockerfile.jvm, Dockerfile.native
  docker-compose.local.yml
  k6/                 mixed-workload.js + per-endpoint scripts
  scripts/
    run-local.sh                  Local orchestrator (THIS is the main local entry)
    cold-start-under-load.sh      Cold start while requests are arriving
    build.sh                      Build JVM + native images
    charts.py                     PNG chart generator (matplotlib)
    requirements.txt              Python deps (matplotlib, pandas)
    benchmark.sh                  AWS end-to-end (build → terraform → run → destroy)
    run-on-ec2.sh                 Runs on the EC2 instance
    generate-report.sh            ASCII report (legacy / quick view)
  terraform/                      AWS infra (c7i.large)
  results/local/                  Local results + charts/
  results/aws/                    AWS results + charts/
```

## Quick start — local

```bash
# Smoke run: build images, then 3-min mixed workload per variant.
./benchmark/scripts/run-local.sh smoke both

# Standard run: 10 min / 50 VUs (matches AWS).
./benchmark/scripts/run-local.sh standard both

# Reuse already-built images:
SKIP_BUILD=1 ./benchmark/scripts/run-local.sh smoke both

# Cold start under load (separate scenario):
./benchmark/scripts/cold-start-under-load.sh both
```

Outputs land in `benchmark/results/local/`:
- `{variant}-startup-ms.txt`, `{variant}-cold-start-ms.txt`, `{variant}-image-size-bytes.txt`
- `{variant}-stats.csv` (CPU + RSS time-series)
- `{variant}-k6-results.csv` (per-request data) + `{variant}-k6-summary.json`
- `jvm-gc/gc.log*` (JVM GC log)
- `charts/*.png` (PNG charts)

Charts use a Python venv at `benchmark/.venv` (auto-created on first run).

## Quick start — AWS

Prereqs: AWS CLI configured, Terraform >= 1.5, jq, SSH key at `~/.ssh/id_rsa.pub`.

```bash
./benchmark/scripts/benchmark.sh           # full cycle: provision → run → destroy
AWS_REGION=us-east-1 ./benchmark/scripts/benchmark.sh
```

Defaults: `c7i.large` (2 vCPU, 4 GB, non-burstable). ~$0.10/run.

To debug, leave infra up — skip the `terraform_destroy` call at the end of `benchmark.sh`.

## Profile / configuration

| Profile  | Duration | VUs total | When to use         |
|----------|----------|-----------|---------------------|
| smoke    | 3 min    | 20        | Quick iteration     |
| standard | 10 min   | 50        | Real numbers / blog |

VU mix (proportional): 40% list reads, 20% detail reads, 20% JSON vets, 20% writes.

## Metrics captured

- **Throughput** (req/s, over time)
- **Latency** p50/p95/p99 (per scenario + overall)
- **Startup time** (container start → first `/actuator/health` 200)
- **Cold start under load** (container start → first 200 while load is already arriving)
- **Peak RSS + RSS over time** (`docker stats` sampled @ 1 Hz)
- **CPU over time** (same sampler)
- **GC pause distribution** (JVM only, parsed from `-Xlog:gc*` log)
- **Image size** (Docker)
- **Error rate** (`http_req_failed`)

## Charts

PNGs written to `results/<env>/charts/`:
- `throughput-over-time.png`
- `latency-bars.png`
- `startup-bar.png`
- `memory-over-time.png`
- `cpu-over-time.png`
- `image-size-bar.png`
- `gc-pause-hist.png` (JVM)

Regenerate from existing results:
```bash
benchmark/.venv/bin/python benchmark/scripts/charts.py benchmark/results/local
```

## Notes

- JVM image enables GC logging via `-Xlog:gc*,gc+heap=debug:file=/var/log/petclinic/gc.log`.
  Host mount captures it. Native has no GC pauses.
- Native build uses `ghcr.io/graalvm/native-image-community:25`. Takes 5–10 min the
  first time (no Gradle cache in the image).
- Postgres 18.3 in both local and AWS paths — apples-to-apples.
- Local container resources capped to 1 CPU / 512 MB to match the AWS app container
  (instance has 2 cores; Postgres uses the other).
