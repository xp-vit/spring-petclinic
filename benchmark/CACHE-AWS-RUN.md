# Cache benchmark on AWS — run book

Caffeine vs Redis vs no-cache, on the v2 Terraform stack (app EC2 + k6 EC2 + RDS Postgres).
Network-distant RDS is the point: it makes the cached DB work expensive, which is when an
external cache earns its keep.

## One command

```bash
AWS_PROFILE=govplus-development ./benchmark/scripts/benchmark-cache-aws.sh
```

That orchestrator (local) drives everything: `terraform apply`, build + push `petclinic:jvm`
to ECR, deploy the EC2-side scripts, run all variants × workloads × phases, pull results from
S3, print the comparison table, then `terraform destroy`.

## What runs

- **Variants** (same image, profile switch): `cache-none` `cache-caffeine` `cache-redis`
- **Workloads**:
  - `vets`  — tiny 6-row cached query (baseline; cache barely matters even over network)
  - `stats` — heavy aggregation (`COUNT(DISTINCT)` over a LEFT JOIN of pets×visits) on a
    seeded **100k owners / 300k pets / 2M visits** dataset; ~seconds per miss, small cached
    result. This is where caching obviously pays and Caffeine-vs-Redis separates.
- **Phases**: `smoke` (3m/20VU + think-time) and `peak` (3m/50VU, no think-time)
- **Headline = cache-warm HIT comparison** (`WRITE_RATIO=0`): cache stays populated, reads are
  hits. A separate churn pass is `WRITE_RATIO=0.1 ... benchmark-cache-aws.sh`.

## Env knobs

| var | default | note |
|-----|---------|------|
| `AWS_PROFILE` | `govplus-development` | SSO; expires ~2-3h, re-login before final S3 sync/destroy |
| `AWS_REGION` | `eu-central-1` | |
| `VARIANTS` | `cache-none cache-caffeine cache-redis` | |
| `WORKLOADS` | `vets stats` | |
| `WRITE_RATIO` | `0` | set `0.1` for a write/evict churn pass |
| `SEED_OWNERS/PETS/VISITS` | `100000/300000/2000000` | stats dataset volume (set on app EC2 side) |
| `SKIP_BUILD` | unset | reuse `petclinic:jvm` already in ECR |
| `KEEP_INFRA` | unset | leave EC2+RDS up (chain a churn pass); destroy manually after |
| `SSH_KEY` | `~/.ssh/id_ed25519` | |

## Gotchas (already handled, don't re-hit)

- RDS is `db.m7i.large` (non-burstable) — a >90-min run on `t3.micro` drains CPU credits and
  throttles mid-run.
- `seed-stats` runs `psql` via `docker run -i` (stdin must reach psql) + verifies the visits row
  count, so a silent partial seed fails loudly.
- Redis runs as a container on the app EC2 (`--network host`), so `SPRING_DATA_REDIS_HOST=localhost`.
- Reported numbers are **read-only** (write/evict calls excluded) so a no-op evict can't pollute RPS.
- The Redis health indicator is disabled (`management.health.redis.enabled=false`) so the startup
  probe + non-redis profiles don't go DOWN.

## Results

Synced to `benchmark/results/aws-cache/` and gitignored. Table is printed at the end; preserve
the numbers in `benchmark/results-summary-cache.md` (raw CSVs are not committed).
