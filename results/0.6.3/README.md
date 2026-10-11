# PgCache Benchmark Verification — Tag 0.6.3

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.3** (`pgcache/pgcache:0.6.3`) executed across two complementary environments:
1. **DigitalOcean Kubernetes (DOKS)**: 3-node bare-droplet topology across 1 to 2,000 tenants.
2. **Local Docker Environment**: Single-host baseline across 1 to 1,000 tenants, concurrency scaling, and mixed write workloads.

---

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant tiers (1 to 2,000 tenants on DOKS, 1 to 1,000 tenants on Docker).
- **Key-Space Scaling**: From 1 tenant to 2,000 tenants on DOKS, PgCache maintained consistent response times (~16.7 ms to 19.4 ms) vs ~25.6 ms to 32.2 ms on origin.
- **Warm-up Passes**: Settled in 2 passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants on DOKS.
- **Throughput Gain**: Delivered **+40% to +93% throughput gain** on DOKS, and **+140% to +153%** on local Docker.
- **Environment Parity**: Retains both production cloud and local development benchmark data.

---

## 2. Infrastructure & Environment Details

| Component | DigitalOcean Kubernetes (DOKS) | Local Docker Development |
|---|---|---|
| **Topology** | 3 separate physical nodes (`sfo3` single-AZ) | Single-host container runtime |
| **Compute Nodes** | 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM) | Shared host cores / memory |
| **Control Plane** | `--ha=false` ($0 control plane fee) | Local Docker daemon |
| **Node OS / Kernel** | Debian 13 (trixie), kernel 6.12.96 | Host kernel |
| **Storage Class** | `do-block-storage` CSI (25 GiB origin, 15 GiB loadgen) | Local bind-mount volumes |
| **Pod / Node Isolation** | Strict `podAntiAffinity` (1 node each: origin, pgcache, loadgen) | Shared host CFS scheduler |
| **Networking** | `hostNetwork: true` (direct host IP routing) | Docker bridge network |
| **CPU Limits** | Unset (avoids CFS quota throttling jitter) | Unset |
| **Origin Settings** | PostgreSQL 17, `shared_buffers=512MB` | PostgreSQL 17, `shared_buffers=1GB` |
| **PgCache Settings** | `workers=4`, `metricsPort=9091` | `workers=4`, `metricsPort=9090` |
| **Dataset Sizing** | 500k orders, 2M items (~594 MB), 2,000 tenants | 500k orders, 2M items (~463 MB), 1,000 tenants |

---

## 3. Sweep 1 — Tenant Count Sweep

### 3.1 DigitalOcean Kubernetes (DOKS — 1 to 2,000 Tenants)

Evaluating query space expansion across 1, 10, 50, 100, 500, 1,000, and 2,000 active tenants (concurrency fixed at 8 clients, 30s duration, dynamic warmup):

| Active Tenants | Origin (Path A) | PgCache 0.6.3 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 27.5 ms · 291 rps | 17.6 ms · 455 rps | +56% | 100.0% | 2 |
| 10 | 27.0 ms · 296 rps | 17.8 ms · 451 rps | +52% | 100.0% | 2 |
| 50 | 29.2 ms · 274 rps | 17.5 ms · 456 rps | +66% | 100.0% | 2 |
| 100 | 30.3 ms · 264 rps | 19.4 ms · 412 rps | +56% | 100.0% | 2 |
| 500 | 32.2 ms · 248 rps | 16.7 ms · 478 rps | +93% | 100.0% | 3 |
| 1,000 | 26.2 ms · 305 rps | 17.5 ms · 458 rps | +50% | 100.0% | 3 |
| 2,000 | 25.6 ms · 313 rps | 18.3 ms · 438 rps | +40% | 100.0% | 4 |

### 3.2 Local Docker Development Environment (1 to 1,000 Tenants)

Evaluating local Docker single-host baseline across 1, 10, 50, 200, 500, and 1,000 active tenants:

| Active Tenants | Origin (Path A) | PgCache 0.6.3 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 33.9 ms · 236 rps | 13.4 ms · 596 rps | +153% | 100.0% | 2 |
| 10 | 32.6 ms · 246 rps | 13.6 ms · 590 rps | +140% | 100.0% | 2 |
| 50 | 33.7 ms · 237 rps | 13.8 ms · 578 rps | +144% | 100.0% | 3 |
| 200 | 34.6 ms · 231 rps | 14.0 ms · 570 rps | +147% | 100.0% | 3 |
| 500 | 34.6 ms · 231 rps | 14.2 ms · 563 rps | +144% | 100.0% | 4 |
| 1,000 | 34.7 ms · 230 rps | 14.3 ms · 559 rps | +143% | 100.0% | 5 |

---

## 4. Sweep 2 — Client Concurrency Sweep (Docker Baseline)

Separating pure read cache speed from origin saturation (concurrency scaling at 1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 11.2 ms · 89 rps | 5.53 ms · 181 rps | +103% | 100.0% | 2 |
| 4 | 19.2 ms · 208 rps | 8.79 ms · 455 rps | +119% | 100.0% | 2 |
| 8 | 35.4 ms · 226 rps | 14.62 ms · 547 rps | +142% | 100.0% | 2 |
| 16 | 60.3 ms · 265 rps | 25.18 ms · 635 rps | +140% | 100.0% | 2 |
| 32 | 107.2 ms · 299 rps | 45.02 ms · 711 rps | +138% | 100.0% | 2 |

---

## 5. Sweep 3 — Write Ratio and Concentration Sweep (Docker Baseline)

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35.1 ms · 228 rps | 14.52 ms · 551 rps | +142% | 100.0% | 2 |
| 5% | 1 | 33.5 ms · 239 rps | 13.92 ms · 575 rps | +141% | 100.0% | 2 |
| 5% | 10 | 33.3 ms · 240 rps | 14.03 ms · 570 rps | +138% | 100.0% | 2 |
| 5% | 1000 | 33.2 ms · 241 rps | 13.93 ms · 574 rps | +138% | 100.0% | 2 |
| 10% | 1 | 31.4 ms · 254 rps | 13.28 ms · 603 rps | +137% | 100.0% | 2 |
| 10% | 1000 | 31.9 ms · 251 rps | 13.27 ms · 603 rps | +140% | 100.0% | 2 |

---

## 6. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- DigitalOcean DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
- Local Docker TSV: [`results-docker.tsv`](results-docker.tsv)
- Tenants sweep raw log (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Tenants sweep raw log (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt)
- Concurrency sweep raw log (Docker): [`run-clients.txt`](run-clients.txt)
- Write sweep raw log (Docker): [`run-writes.txt`](run-writes.txt)
