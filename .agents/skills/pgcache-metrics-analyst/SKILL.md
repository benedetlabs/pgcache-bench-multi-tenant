---
name: pgcache-metrics-analyst
description: >-
  Use this skill when scraping Prometheus telemetry from PgCache, analyzing
  benchmark performance across workload complexities, evaluating Amdahl's Law
  and read-vs-write clock share, or updating bilingual benchmark reports
  (README.md, README-pt.md, and results/).
---

# PgCache Telemetry & Performance Analyst

This skill defines the workflow for the **Telemetry & Performance Analyst Agent**, responsible for inspecting PgCache Prometheus metrics, verifying warm-up convergence, interpreting performance across simple and complex workloads, and maintaining synchronized English and Portuguese reports.

## 1. Key Prometheus Metrics to Audit

Scrape `:9090/metrics` (or `http://127.0.0.1:59090/metrics` in local Docker) and inspect:

```bash
curl -sf http://127.0.0.1:59090/metrics | grep -E "^pgcache_(queries_(total|cacheable|uncacheable|allowlist_skipped|cache_hit|cache_miss|cache_error)|cache_(queries_registered|memory_used_bytes|memo_entries|evictions|invalidations))"
```

| Metric | Expected Healthy Behavior | Diagnostic Meaning if Abnormal |
|---|---|---|
| `pgcache_queries_cacheable` | Increments on every benchmark `SELECT` | If not incrementing, queries are bypassing cache |
| `pgcache_queries_uncacheable` | `0` delta during read sweeps | Query uses non-immutable functions, expression `GROUP BY`, or arithmetic in `OFFSET` |
| `pgcache_queries_allowlist_skipped` | `0` | A table in the query is missing from `ALLOWED_TABLES` |
| `pgcache_queries_cache_error` | `0` | Internal cache execution error |
| `pgcache_queries_cache_hit` / `miss` | Hit ratio settles `>= 99%` after `warm_until_settled` | Cache capacity exhaustion (`MEMO_CACHE_SIZE`) or insufficient warm-up |

## 2. Analytical Framework for Comparing Simple vs Complex Workloads

When reporting benchmark findings, always contrast **Simple Operational Workloads (`dashboard.sql`)** against **Complex Analytical & Search Workloads (`complex-*.sql`)** across four axes:

1. **Per-Statement Origin Cost vs Fixed Cache Floor**:
   - PgCache serves cached results from its embedded store at a near-constant protocol cost (~0.35–2.0 ms per statement depending on row count).
   - Origin cost scales directly with tuple scans, join depth (`4–6 tables`), outer join preservation (`LEFT JOIN`), substring matching (`ILIKE '%...%'`), and hash/group aggregations (`FILTER`, `CASE WHEN`, `HAVING`).
   - Consequently, complex workloads exhibit a **much larger speedup factor** (both at 1 client and at 8–32 concurrent clients) than simple primary-key or indexed top-N queries.
2. **Single-Client Latency vs Multi-Client Saturation**:
   - Always separate the **1-client row** (pure query acceleration without queueing) from the **8–32 client rows** (query acceleration + relief of Origin CPU contention).
3. **Write Invalidation Clock Share**:
   - Under mixed read/write workloads (`03-write-sweep.sh` and `04-complex-sweep.sh writes`), evaluate the share of wall-clock time spent on writes:
     $$\text{Write Clock Share} = \frac{w \cdot W}{w \cdot W + (1 - w) \cdot R}$$
   - Because complex reads ($R$) are significantly more expensive on Origin than simple reads while single-row `UPDATE` writes ($W$) cost the same, complex workloads retain massive throughput gains even under 5%–10% write rates alongside CDC invalidations.
4. **Bilingual Documentation Synchronization**:
   - All artifacts, code, scripts, and skills must be in English.
   - Whenever updating `results/README.md`, `results/<tag>/README.md`, or root `README.md`, keep `results/README-pt.md`, `results/<tag>/README-pt.md`, and `README-pt.md` synchronized with identical tables and conclusions.
