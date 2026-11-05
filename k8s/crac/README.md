# CRaC on Kubernetes — checkpoint-at-build, restore-on-every-pod

Working example for the "CRaC vs GraalVM Native vs the JVM" benchmark. It shows
the pattern the AWS EKS / Azul / BellSoft guides converge on: **create the warm
checkpoint once at image build time, bake it into the image, and have every pod
restore from it on start** (not a runtime checkpoint).

## Pipeline

```
Dockerfile.crac-warmup   -> jar + Azul Zulu CRaC JDK (engine=warp) + warmup entrypoint
make-crac-checkpoint.sh  -> run it: start app, warm the JIT, `jcmd JDK.checkpoint`
Dockerfile.crac-restore  -> bake /crac-files into the deployed image
petclinic-crac.yml       -> every pod: `java -XX:CRaCRestoreFrom=/crac-files`
```

`restore-or-start.sh` restores if the checkpoint is present, else cold-starts —
so the same image still runs on a non-CRaC node instead of crash-looping.

## The four sharp edges (all handled here)

1. **Secrets in the image layer.** A checkpoint is a full JVM memory dump, so any
   secret loaded before it is baked into a layer. We warm with a *placeholder*
   and re-read the real secret + DB password in `afterRestore()`
   (`CracSupport.java`). Prove it: `curl /crac/secret-status` returns the SHA-256
   prefix + source — `restored-env` after restore, and a different hash than the
   build placeholder. No secret is ever in the image.

2. **Privileges vs Pod Security Standards.** Warp needs **no** extra capabilities
   or privileged pod (see `securityContext` — caps dropped). The CRIU engine
   needs `CAP_CHECKPOINT_RESTORE` (+ usually `SYS_PTRACE`) and an unconfined
   seccomp profile, which clashes with hardened PSS — the commented block shows
   it if you must use CRIU.

3. **CPU / kernel homogeneity.** Restore replays the checkpoint host's CPU
   instruction set; a leaner node → `SIGILL`. Pin pods to a matching node pool
   (`nodeSelector`) or checkpoint with `-XX:CPUFeatures=generic` (small peak-
   throughput cost). Architecture must match — no x86_64 → arm64.

4. **Every resource must coordinate.** DB pool, cache, message consumers and
   `@Scheduled` tasks must release in `beforeCheckpoint()` / reacquire in
   `afterRestore()`. Spring Boot 3.2+ does this for its managed beans (Hikari,
   Tomcat) via `Lifecycle`; app + non-Spring libs do their own. Hikari also needs
   `spring.datasource.hikari.allow-pool-suspension=true` or the checkpoint aborts
   on the open DB socket. `@Scheduled(fixedRate)` misfires on restore — use
   `fixedDelay`/cron.

## Deploy

```sh
# 1. build + checkpoint (run on a host whose CPU matches the target node pool)
BUILD_WARMUP=1 EXTERNAL_DB_URL=jdbc:postgresql://<db>:5432/petclinic \
  RESTORE_IMAGE=REGISTRY/petclinic:crac ./benchmark/scripts/make-crac-checkpoint.sh
docker push REGISTRY/petclinic:crac

# 2. secrets (never baked; read post-restore)
kubectl create secret generic petclinic-db  --from-literal=username=petclinic --from-literal=password='<real>'
kubectl create secret generic petclinic-api --from-literal=token='<real>'

# 3. deploy (edit REGISTRY in petclinic-crac.yml)
kubectl apply -f k8s/crac/petclinic-crac.yml
```

**Verdict:** workable and shipping in 2026, but it trades JVM operational
simplicity for a build-and-security pipeline you own. Warp + Spring Boot support
removed the sharpest 2023 edges (privileges, coordination); secrets, CPU
homogeneity, and the checkpoint step remain deliberate work.
