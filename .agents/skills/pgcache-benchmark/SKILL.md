---
name: pgcache-benchmark
description: >-
  Use this skill when coordinating, running, preparing, reproducing, or validating
  benchmarks in the pgcache-bench-multi-tenant repository across Local Docker or
  3-node Kubernetes (DOKS), including pre-flight checks, seeding data, executing
  baseline and complex multi-tenant sweeps (01-04), and collecting metrics.
---

# PgCache Multi-Tenant Benchmark Coordinator Runbook

This skill defines the workflow for the **Benchmark Coordinator Agent**, responsible for orchestrating end-to-end benchmark campaigns across Local Docker (`pgcache/pgcache:0.7.1-arm64` / `0.7.1`) and 3-node Kubernetes (DOKS), coordinating with [`pgcache-complex-scenarios`](../pgcache-complex-scenarios/SKILL.md) and [`pgcache-metrics-analyst`](../pgcache-metrics-analyst/SKILL.md).

## 1. Pre-flight Environment Checks

### Option A: Local Docker Environment (`BENCH_ENV=docker`)
```bash
# 1. Start Docker Compose with PgCache 0.7.1 (use -arm64 on Apple Silicon)
PGCACHE_IMAGE=pgcache/pgcache:0.7.1-arm64 docker compose -f infra/docker-compose.yml up -d

# 2. Verify metrics endpoint is reachable
curl -sf http://127.0.0.1:59090/metrics | grep -E "^pgcache_queries_"
```

### Option B: 3-Node Kubernetes / DOKS (`BENCH_ENV=k8s`)
```bash
# 1. Verify that the 3 core pods landed on 3 distinct nodes within the same AZ
kubectl -n pgcache-mt get pods -o wide
kubectl get nodes -L topology.kubernetes.io/zone

# 2. Check for recent node evictions or preemptions
kubectl -n pgcache-mt get events --sort-by=.lastTimestamp | grep -iE 'preempt|evict|NodeNotReady'
```

> **Configuration Invariant**: When setting `MEMO_CACHE_SIZE` (e.g., in `infra/helm/pgcache-mt/values-do-tuned.yaml`) or `MEMORY_LIMIT` (in `infra/docker-compose.yml`), ALWAYS pass a raw integer byte string such as `"1073741824"` (1 GiB) or `"3758096384"` (3.5 GiB), never `"1GB"` or `"1Gi"`. In local Docker VMs (~8 GB RAM shared with `origin`), `MEMORY_LIMIT: "${MEMORY_LIMIT:-3758096384}"` prevents PgCache from claiming 6.3 GB and triggering Linux OOM-killer `SIGKILL` (`signal 9`) under sustained write loads.

## 2. Database Setup and Seeding

Run database schema creation, tenant denormalization, and seed data setup against the origin (`$ORIGIN_HOST`):

```bash
# Local Docker (1,000 tenants, Scale 1 -> ~463 MB):
DOCKER=1 TENANTS=1000 ./scripts/00-setup.sh

# Kubernetes (default 200 tenants or 2,000 tenants):
TENANTS=2000 ./scripts/00-setup.sh

# Larger datasets (e.g. Scale 5 -> ~2.3 GB; Scale 10 -> ~4.6 GB):
SCALE=5 ./scripts/00-setup.sh
```

## 3. Differential Correctness, Cacheability & Post-CDC Gate

Before running long benchmark sweeps, always run the correctness & cacheability gate (maintained by `pgcache-complex-scenarios`):

```bash
# In 3-node Kubernetes (Official Benchmark Environment):
./scripts/verify-correctness.sh

# In Local Docker (Environment Setup & Functional Smoke Test Only):
./scripts/run-tag-verification.sh --smoke-docker 0.7.1
```

This verifies across all 8 baseline queries, all 12 static complex queries (3 passes), and all 12 Post-CDC live mutation queries (Pass 4) that:
1. Every query returns byte-for-byte identical rows from Origin and PgCache (on initial miss, base-table hit, warm Materialized View hit, and after live CDC `UPDATE` mutations on `orders` and `order_item`).
2. `pgcache_queries_uncacheable` delta is `0`, `pgcache_queries_cache_error` delta is `0`, `pgcache_cache_mv_gate{outcome="admit"}` is `12` (`reject == 0`), and `pgcache_cache_mv_hits` delta is `12`.

## 4. Running Official Multi-Trial Benchmark Sweeps (3-Node Kubernetes Exclusively)

> **Environment Policy**: Local Docker (`infra/docker-compose.yml`) is used **only** for assembling the environment and running functional/correctness checks. Official performance results MUST be collected exclusively on the 3-node Kubernetes cluster (`BENCH_ENV=k8s`) using multiple trials (`TRIALS=3` or `TRIALS=5`) with full pod recreation (`reset_all_pods`) between trials to capture positive and negative deviation (`-Δ/+Δ` and `stddev`).

### A. Automated Full Multi-Trial Tag Campaign (3-Node K8s)
Runs baseline sweeps (`01`–`03`) plus complex multi-tenant sweeps (`04`) across `TRIALS` independent runs (recreating `origin`, `pgcache`, and `loadgen` pods between trials) and saves all artifacts under `results/<tag>/`:

```bash
# Run 5 trials (30s per cell, recreating origin + pgcache + loadgen pods per trial) on 3-node Kubernetes:
./scripts/run-tag-verification.sh 0.7.1 30 5
```

### B. Individual Baseline Sweeps (`workload/dashboard.sql` & `workload/write.sql`)
1. **Sweep 1: Tenant Count Sweep**:
   ```bash
   TRIALS=3 ./scripts/01-tenant-sweep.sh | tee data/run-tenants.txt
   ```
2. **Sweep 2: Client Concurrency Sweep**:
   ```bash
   TRIALS=3 ./scripts/02-concurrency-sweep.sh | tee data/run-clients.txt
   ```
3. **Sweep 3: Write Ratio and Concentration Sweep**:
   ```bash
   TRIALS=3 ./scripts/03-write-sweep.sh | tee data/run-writes.txt
   ```

### C. Complex Multi-Tenant Sweeps (`scripts/04-complex-sweep.sh`)
Evaluates text search (`complex-search.sql`), 4–6 table `JOIN` & `LEFT JOIN` chains (`complex-joins.sql`), heavy analytical aggregations (`complex-analytics.sql`), and the unified 8-statement complex screen (`complex-dashboard.sql` uniform and `complex-dashboard-zipfian.sql` Pareto 80/20):

```bash
# Compare all 5 scenario families side-by-side (3 trials on K8s):
TRIALS=3 TENANTS=200 ./scripts/04-complex-sweep.sh scenarios

# Sweep active tenants (1..1000 uniform) on complex-dashboard.sql:
TRIALS=3 ./scripts/04-complex-sweep.sh tenants

# Sweep active tenants (100..2000 Pareto/Zipfian 80-20) on complex-dashboard-zipfian.sql:
TRIALS=3 ./scripts/04-complex-sweep.sh zipfian

# Sweep client concurrency (1..32) on complex-dashboard.sql:
TRIALS=3 TENANTS=200 ./scripts/04-complex-sweep.sh clients

# Sweep write ratios (0%, 5%, 10%) on complex-dashboard.sql:
TRIALS=3 TENANTS=200 ./scripts/04-complex-sweep.sh writes
```

## 5. Non-Destructive Results & Cloud Lifecycle Hygiene

- **Preserve Prior Results**: Never overwrite or delete existing folders in `results/` (`0.6.3/`, `0.6.4/`, `0.7.0/`, `tuned/`).
- **Cloud Cost Hygiene**: When running on DOKS or Azure AKS, destroy the cluster and associated block storage volumes / Resource Group immediately after saving results to `results/`:
  ```bash
  # DigitalOcean DOKS:
  ./scripts/do-cluster.sh destroy

  # Azure AKS (Terraform Free Control Plane + 3-Node Spot Pool):
  ./scripts/aks-cluster.sh destroy
  ```
