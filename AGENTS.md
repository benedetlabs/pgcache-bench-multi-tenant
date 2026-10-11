# Repository Guidelines: pgcache-bench-multi-tenant

This repository contains a rigorous, reproducible benchmark comparing PostgreSQL (Path A / Origin) against PgCache (Path B / Read Cache Proxy) under a multi-tenant SaaS workload.

## 1. Repository Language Policy

- **English by Default**: All repository files, documentation, code, configuration, comments, scripts, and skills MUST be written exclusively in English.
- Generate Portuguese content only when explicitly requested by the user.

## 2. Measurement and Protocol Invariants

1. **Simple Protocol (`-M simple`) and No Explicit Transactions**:
   - PgCache intercepts and caches queries only under simple query protocol with interpolated literals in the SQL text.
   - **NEVER** wrap benchmark scripts in `BEGIN ... COMMIT` blocks. PgCache passes transactions straight through to the origin, invalidating cache measurements.
2. **Mandatory Dynamic Warm-up (`warm_until_settled`)**:
   - **NEVER** use a fixed warm-up duration. Fixed warm-up times produce flawed hit ratio conclusions.
   - Always run iterative passes until the hit ratio settles (< 1% variation between consecutive passes).
3. **Writes and DDL Exclusively on Origin**:
   - All schema migrations, setup scripts (`00-setup.sh`), seeds, and maintenance writes must target the origin (`$ORIGIN_HOST`) directly, never PgCache.
4. **PgCache Environment Variables (`ALLOWED_TABLES`)**:
   - If new tables are added to queries, they MUST be included in `ALLOWED_TABLES`. Queries referencing unlisted tables will silently miss cache.
5. **Pod Tooling Constraints**:
   - The `loadgen` pod uses `postgres:17` and contains neither `curl` nor `wget`.
   - Prometheus metrics scraping from PgCache (`:9090/metrics`) MUST be performed via the `metrics-reader` pod.

## 3. Infrastructure Invariants

1. **Kubernetes Topology (Three Distinct Nodes)**:
   - For official benchmark numbers, `origin`, `pgcache`, and `loadgen` MUST run on separate physical nodes/VMs (enforced via `podAntiAffinity`) within the same Availability Zone (AZ).
   - NEVER set hard CPU limits (`resources.limits.cpu`), as CFS throttling introduces p99 latency spikes indistinguishable from cache misses.
2. **Docker Compose (`infra/docker-compose.yml`)**:
   - The local Docker Compose setup is strictly for query development, debugging, and SQL syntax checks. It must not be used to produce official benchmark numbers due to near-zero network latency and shared CPU core contention.

## 4. Dataset Sizing and Scale Factors

- **Default Scale (`SCALE=1`)**: Produces 500k orders, 2M order items (~463 MB to 650 MB database size), fitting inside `shared_buffers=1GB` to evaluate the cache against an in-memory database.
- **Large Scales (`SCALE=5`, `SCALE=10`)**:
  - `SCALE=5`: 2.5M orders, 10M items (~2.3 GB).
  - `SCALE=10`: 5.0M orders, 20M items (~4.6 GB).
  - Used on the 3-node Kubernetes cluster to evaluate performance when the database exceeds `shared_buffers` and tests query aggregation over large tables.
- **Tenant Scaling (`TENANTS`)**: Configurable via `TENANTS` (default: 200). Expanding to 1,000+ tenants evaluates key-space explosion and cache eviction behavior.
