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

> **Configuration Invariant**: When setting `MEMO_CACHE_SIZE` (e.g., in `infra/helm/pgcache-mt/values-do-tuned.yaml`), ALWAYS pass a raw integer byte string such as `"1073741824"` (1 GiB), never `"1GB"` or `"1Gi"`.

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

## 3. Differential Correctness & Cacheability Gate

Before running long benchmark sweeps, always run the correctness & cacheability gate (maintained by `pgcache-complex-scenarios`):

```bash
DOCKER=1 ./scripts/verify-correctness.sh
```

This verifies that:
1. Every complex query returns byte-for-byte identical rows from Origin and PgCache (both on cache miss and cache hit).
2. `pgcache_queries_uncacheable` delta is `0` and `pgcache_queries_cache_error` delta is `0`.

## 4. Running Benchmark Sweeps

### A. Automated Full Tag Verification (Local Docker)
Runs baseline sweeps (`01`–`03`) plus complex multi-tenant sweeps (`04`) and saves all artifacts under `results/<tag>/`:

```bash
./scripts/run-tag-verification.sh 0.7.1 5
```

### B. Individual Baseline Sweeps (`workload/dashboard.sql` & `workload/write.sql`)
1. **Sweep 1: Tenant Count Sweep**:
   ```bash
   ./scripts/01-tenant-sweep.sh | tee data/run-tenants.txt
   ```
2. **Sweep 2: Client Concurrency Sweep**:
   ```bash
   ./scripts/02-concurrency-sweep.sh | tee data/run-clients.txt
   ```
3. **Sweep 3: Write Ratio and Concentration Sweep**:
   ```bash
   ./scripts/03-write-sweep.sh | tee data/run-writes.txt
   ```

### C. Complex Multi-Tenant Sweeps (`scripts/04-complex-sweep.sh`)
Evaluates text search (`complex-search.sql`), 4–6 table `JOIN` & `LEFT JOIN` chains (`complex-joins.sql`), heavy analytical aggregations (`complex-analytics.sql`), and the unified 8-statement complex screen (`complex-dashboard.sql`):

```bash
# Compare all 5 scenario families side-by-side:
DOCKER=1 TENANTS=200 ./scripts/04-complex-sweep.sh scenarios

# Sweep active tenants (1..1000) on complex-dashboard.sql:
DOCKER=1 ./scripts/04-complex-sweep.sh tenants

# Sweep client concurrency (1..32) on complex-dashboard.sql:
DOCKER=1 TENANTS=1000 ./scripts/04-complex-sweep.sh clients

# Sweep write ratios (0%, 5%, 10%) on complex-dashboard.sql:
DOCKER=1 TENANTS=1000 ./scripts/04-complex-sweep.sh writes
```

## 5. Non-Destructive Results & Cloud Lifecycle Hygiene

- **Preserve Prior Results**: Never overwrite or delete existing folders in `results/` (`0.6.3/`, `0.6.4/`, `0.7.0/`, `tuned/`).
- **Cloud Cost Hygiene**: When running on DOKS, destroy the cluster and associated block storage volumes immediately after saving results to `results/`:
  ```bash
  ./scripts/do-cluster.sh destroy
  ```
