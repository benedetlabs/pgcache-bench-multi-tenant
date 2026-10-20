# Repository Guidelines: pgcache-bench-multi-tenant

This repository contains a rigorous, reproducible benchmark comparing PostgreSQL (Path A / Origin) against PgCache (Path B / Read Cache Proxy) under multi-tenant SaaS workloads — covering both lightweight operational dashboards and complex enterprise screens (substring text search, 4-to-6 table `JOIN` & `LEFT JOIN` chains, and multi-dimensional analytical aggregations).

## 1. Repository Language Policy

- **English by Default**: All repository files, documentation, code, configuration, comments, scripts, skills, and artifacts MUST be written exclusively in English.
- Keep existing Portuguese documentation counterparts (`README-pt.md`, `results/**/README-pt.md`) synchronized when updating benchmark results.

## 2. Measurement and Protocol Invariants

1. **Simple Protocol (`-M simple`) and No Explicit Transactions**:
   - PgCache intercepts and caches queries only under simple query protocol with interpolated literals in the SQL text.
   - **NEVER** wrap benchmark scripts in `BEGIN ... COMMIT` blocks. PgCache passes transactions straight through to the origin, invalidating cache measurements.
2. **100% Cacheability & Materialized View Admission Gate (`pgcache_queries_uncacheable == 0` & `pgcache_cache_mv_gate{outcome="reject"} == 0`)**:
   - In multi-table `JOIN` and `LEFT JOIN` queries, always include explicit `:t` literal predicates (`o.tenant_id = :t`, `oi.tenant_id = :t`, `c.tenant_id = :t`) on every joined tenant-scoped table so PgCache isolates CDC invalidations per tenant and pushes down tenant index predicates during population.
   - Omit `OFFSET` (or use `OFFSET 0`) on complex multi-table `JOIN` and aggregation queries so 100% of queries pass PgCache 0.7+'s Materialized View gate (`pgcache_cache_mv_gate{outcome="admit"}`) and serve hits via `pgcache_cache_mv_hits`.
   - In `pgbench` scripts, pre-compute any arithmetic expressions using `\set` before interpolating them into SQL `WHERE` or `HAVING` clauses, and group directly on base columns (`GROUP BY o.status`) rather than expressions (`SELECT coalesce(o.status, 'no_orders')`).
   - Run `./scripts/verify-correctness.sh` to verify `uncacheable_delta == 0`, `mv_gate_reject_delta == 0`, `mv_hits_delta == 12`, and byte-for-byte differential output equality between Origin and PgCache across all 8 baseline queries, all 12 complex static queries, and all 12 post-CDC live mutation queries (Pass 4).
   - Always include `pgcache_queries_uncacheable` in the total query denominator (`hit / (hit + miss + uncacheable)`) so uncacheable queries never masquerade as 100% cache hit ratios.
3. **Mandatory Dynamic Warm-up (`warm_until_settled`) & Multi-Trial Pod Recreation (`TRIALS=3..5`)**:
   - **NEVER** use a fixed warm-up duration. Fixed warm-up times produce flawed hit ratio conclusions.
   - Always run iterative passes until the hit ratio settles (< 1% variation between consecutive passes).
   - For official benchmark campaigns, run multiple independent trials (`TRIALS=3` or `TRIALS=5`) recreating the Kubernetes pods (`origin`, `pgcache`, `loadgen`) between trials via `reset_all_pods` (without recreating the K8s cluster) to capture positive/negative deviation bounds (`-Δ/+Δ`) and standard deviation (`stddev`), eliminating single-run anomalies.
4. **Writes and DDL Exclusively on Origin**:
   - All schema migrations, setup scripts (`00-setup.sh`), seeds, and maintenance writes must target the origin (`$ORIGIN_HOST`) directly, never PgCache.
5. **PgCache Environment Variables (`ALLOWED_TABLES`, `MEMO_CACHE_SIZE`, & `MEMORY_LIMIT`)**:
   - If new tables are added to queries, they MUST be included in `ALLOWED_TABLES`. Queries referencing unlisted tables will silently miss cache.
   - `MEMO_CACHE_SIZE` and `MEMORY_LIMIT` MUST be passed as raw integer numbers of bytes (e.g., `"1073741824"` for 1 GiB or `"3758096384"` for 3.5 GiB), never with human-readable suffixes like `"1GB"` or `"1Gi"`, which fail Rust integer parsing at startup. In shared 8 GB Docker VMs, setting `MEMORY_LIMIT: "3758096384"` prevents PgCache from over-allocating host RAM and triggering Linux OOM-killer `SIGKILL` (`signal 9`).
6. **Pod Tooling Constraints**:
   - The `loadgen` pod uses `postgres:17` and contains neither `curl` nor `wget`.
   - Prometheus metrics scraping from PgCache (`:9090/metrics` or `:9091/metrics`) MUST be performed via the `metrics-reader` pod (or host port `59090` in local Docker).
7. **Non-Destructive Results Preservation**:
   - **NEVER** delete or overwrite existing historical benchmark results (`results/0.6.3/`, `results/0.6.4/`, `results/0.7.0/`, `results/tuned/`). New version runs (such as `0.7.1`) and new complex scenario runs must be stored in their respective directories (`results/0.7.1/`) and added side-by-side in comparative tables.

## 3. Infrastructure Invariants

1. **Kubernetes Topology (Three Distinct Nodes)**:
   - For official cloud benchmark numbers, `origin`, `pgcache`, and `loadgen` MUST run on separate physical nodes/VMs (enforced via `podAntiAffinity`) within the same Availability Zone (AZ).
   - NEVER set hard CPU limits (`resources.limits.cpu`), as CFS throttling introduces p99 latency spikes indistinguishable from cache misses.
   - When using DigitalOcean Kubernetes (DOKS), provision via `./scripts/do-cluster.sh create` and tear down cluster + CSI block volumes via `./scripts/do-cluster.sh destroy` immediately after collecting artifacts to prevent idle cloud billing.
   - When using Azure Kubernetes Service (AKS), provision the ultra-low-cost Free-tier + 3-node Single-AZ Spot stack (`infra/terraform/aks/`) via `./scripts/aks-cluster.sh create`, deploy via `./scripts/aks-cluster.sh deploy 0.7.1`, and tear down cluster + Resource Group via `./scripts/aks-cluster.sh destroy` immediately after collecting artifacts.
2. **Docker Compose (`infra/docker-compose.yml`) — Setup & Correctness Testing Only**:
   - Local Docker MUST be used **exclusively** to assemble the environment locally, test SQL schema/seeds (`00-setup.sh`), and run the functional/differential correctness gate (`./scripts/run-tag-verification.sh --smoke-docker` or `DOCKER=1 ./scripts/verify-correctness.sh`).
   - **NEVER** include or publish local Docker performance numbers in benchmark result tables (`README.md`, `README-pt.md`, `results/`). Because local Docker shares host CPU cores and has near-zero loopback latency, all official benchmark performance results MUST come strictly from the 3-node Kubernetes topology (DOKS / AKS).

## 4. Dataset Sizing and Scale Factors

- **Default Scale (`SCALE=1`)**: Produces 500k orders, 2M order items, 300k reviews, 200k products, 100k customers (~463 MB to 600 MB database size), fitting inside `shared_buffers=1GB` to evaluate the cache against an in-memory database.
- **Large Scales (`SCALE=5`, `SCALE=10`)**:
  - `SCALE=5`: 2.5M orders, 10M items (~2.3 GB).
  - `SCALE=10`: 5.0M orders, 20M items (~4.6 GB).
- **Tenant Scaling (`TENANTS`)**: Configurable via `TENANTS` (default: 200; verification sweeps scale up to 1,000 in Docker and 2,000 in DOKS).

## 5. Specialized Benchmark Agent Team & Coordination

Benchmark design, execution, verification, and reporting are organized into a specialized 3-agent skill team under `.agents/skills/`:

1. **Benchmark Coordinator (`pgcache-benchmark`)** — [`.agents/skills/pgcache-benchmark/SKILL.md`](.agents/skills/pgcache-benchmark/SKILL.md):
   - Orchestrates end-to-end benchmark campaigns across Local Docker and 3-node Kubernetes (DOKS).
   - Manages pre-flight checks, seeding (`00-setup.sh`), baseline sweeps (`01`–`03`), complex sweeps (`04-complex-sweep.sh`), and automated tag verification (`run-tag-verification.sh`).
2. **Complex Multi-Tenant Scenario Specialist (`pgcache-complex-scenarios`)** — [`.agents/skills/pgcache-complex-scenarios/SKILL.md`](.agents/skills/pgcache-complex-scenarios/SKILL.md):
   - Designs and maintains complex multi-tenant SQL workloads:
     - `workload/complex-search.sql` (Substring `ILIKE '%...%'` text search across customers, products, sellers, and reviews)
     - `workload/complex-joins.sql` (Deep 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains preserving zero-order customers and unreviewed products)
     - `workload/complex-analytics.sql` (Multi-dimensional `GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, and `HAVING` rollups)
     - `workload/complex-dashboard.sql` (Unified 8-statement enterprise analytics & search screen)
   - Executes `./scripts/verify-correctness.sh` to enforce `pgcache_queries_uncacheable == 0` and byte-for-byte differential result identity against Origin.
3. **Telemetry & Performance Analyst (`pgcache-metrics-analyst`)** — [`.agents/skills/pgcache-metrics-analyst/SKILL.md`](.agents/skills/pgcache-metrics-analyst/SKILL.md):
   - Scrapes and audits Prometheus telemetry (`pgcache_queries_cache_hit`, `pgcache_queries_cache_miss`, `pgcache_queries_cacheable`, `pgcache_queries_uncacheable`, `pgcache_cache_memory_used_bytes`).
   - Analyzes query-cost vs proxy-floor dynamics (Amdahl's Law) across simple and complex workloads and maintains synchronized reports in `results/` and root `README.md` / `README-pt.md`.
