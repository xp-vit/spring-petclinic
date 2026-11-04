# Reproduce

Local verify (free, no AWS; Python 3 + `zstd`), from the repo root on branch `hq/crac-results`:

    python3 -I benchmark/crac/verify.py benchmark/results-crac

Chart: `python3 -I benchmark/crac/make_chart.py benchmark/results-crac cold-start.svg` (same values as `cold-start.csv`).

Full re-run needs AWS (EC2 c7i.large + c5.large + RDS db.m7i.large, ~10 h; costs money, needs Owner approval):

    AWS_PROFILE=<your-aws-profile> VARIANTS="jvm crac-jvm crac crac-onrefresh native" ./benchmark/scripts/benchmark-v2.sh
