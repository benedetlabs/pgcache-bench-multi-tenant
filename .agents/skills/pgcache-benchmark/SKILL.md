---
name: pgcache-benchmark
description: >-
  Use this skill when running, preparing, reproducing, or validating benchmarks in the
  pgcache-bench-multi-tenant repository, including Kubernetes environment pre-flight
  checks, seeding data, executing sweeps (tenant, concurrency, write), and collecting metrics.
---

# PgCache Multi-Tenant Benchmark Runbook

This skill provides step-by-step procedures for running, reproducing, and validating benchmark measurements.

## Pre-flight Environment Checks

Before starting any measurement sweep, verify pod placement and spot node preemption events:

```bash
# 1. Verify that the 3 pods landed on distinct nodes within the same AZ
kubectl -n pgcache-mt get pods -o wide
kubectl get nodes -L topology.kubernetes.io/zone

# 2. Check for recent node evictions or preemptions
kubectl -n pgcache-mt get events --sort-by=.lastTimestamp | grep -iE 'preempt|evict|NodeNotReady'
```

## Step 1: Database Setup and Seeding

Run database schema creation, tenant denormalization, and seed data setup against the origin:

```bash
# Default scale (~463 MB in-memory baseline):
./scripts/00-setup.sh

# Larger datasets (e.g. Scale 5 -> ~2.3 GB; Scale 10 -> ~4.6 GB):
SCALE=5 ./scripts/00-setup.sh
SCALE=10 TENANTS=500 ./scripts/00-setup.sh

# Force re-seed:
FORCE=1 SCALE=5 ./scripts/00-setup.sh
```

This applies `sql/01-schema.sql` (scaled via `-v scale`), denormalizes `tenant_id` via `sql/02-tenant.sql`, and copies the workload scripts to `/tmp/mt/` inside the `loadgen` pod.

## Step 2: Running Benchmark Sweeps

Run the desired sweep scripts (each takes ~15–25 minutes):

1. **Sweep 1: Tenant Count Sweep (1, 10, 50, 200)**:
   ```bash
   ./scripts/01-tenant-sweep.sh | tee data/run-tenants.txt
   ```
2. **Sweep 2: Client Concurrency Sweep (1, 4, 8, 16, 32)**:
   ```bash
   ./scripts/02-concurrency-sweep.sh | tee data/run-clients.txt
   ```
3. **Sweep 3: Write Ratio and Concentration Sweep (0%, 5%, 10%)**:
   ```bash
   ./scripts/03-write-sweep.sh | tee data/run-writes.txt
   ```

## Step 3: Metrics Validation and Results Collection

1. Confirm that warmup reached stability (< 1% hit ratio variance between consecutive passes):
   - Handled dynamically by `warm_until_settled` in `scripts/lib.sh`.
2. To manually scrape PgCache Prometheus metrics:
   ```bash
   kubectl -n pgcache-mt exec deploy/metrics-reader -- \
     wget -qO- http://$(kubectl -n pgcache-mt get pod -l app=pgcache -o jsonpath='{.items[0].status.podIP}'):9090/metrics
   ```
3. Update or compare results against `data/results.tsv`.
