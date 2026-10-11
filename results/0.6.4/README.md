# PgCache Benchmark Verification — Tag 0.6.4

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.4** (`pgcache/pgcache:0.6.4`) executed across two complementary environments:
1. **DigitalOcean Kubernetes (DOKS)**: 3-node bare-droplet topology across 1 to 2,000 tenants.
2. **Local Docker Environment**: Single-host baseline across 1 to 1,000 tenants, concurrency scaling, and mixed write workloads.

---

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant tiers (1 to 2,000 tenants on DOKS, 1 to 1,000 tenants on Docker).
- **Key-Space Scaling**: From 1 tenant to 2,000 tenants on DOKS, PgCache maintained 15.5 ms to 21.0 ms request latency, achieving **515 rps** at 2,000 tenants vs 308 rps on origin (+67% gain).
- **Warm-up Passes**: Settled in 2 passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants on DOKS.
- **Throughput Gain**: Delivered **+33% to +90% throughput gain** on DOKS, and **+122% to +161%** on local Docker.
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

| Active Tenants | Origin (Path A) | PgCache 0.6.4 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 27.1 ms · 295 rps | 16.8 ms · 476 rps | +61% | 100.0% | 2 |
| 10 | 27.7 ms · 288 rps | 21.0 ms · 382 rps | +33% | 100.0% | 2 |
| 50 | 29.9 ms · 267 rps | 15.8 ms · 506 rps | +90% | 100.0% | 2 |
| 100 | 25.2 ms · 317 rps | 16.3 ms · 492 rps | +55% | 100.0% | 2 |
| 500 | 26.9 ms · 298 rps | 15.7 ms · 510 rps | +71% | 100.0% | 3 |
| 1,000 | 24.5 ms · 326 rps | 16.8 ms · 476 rps | +46% | 100.0% | 3 |
| 2,000 | 26.0 ms · 308 rps | 15.5 ms · 515 rps | +67% | 100.0% | 4 |

### 3.2 Local Docker Development Environment (1 to 1,000 Tenants)

Evaluating local Docker single-host baseline across 1, 10, 50, 200, 500, and 1,000 active tenants:

| Active Tenants | Origin (Path A) | PgCache 0.6.4 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 34.6 ms · 231 rps | 13.2 ms · 604 rps | +161% | 100.0% | 2 |
| 10 | 33.5 ms · 239 rps | 15.1 ms · 530 rps | +122% | 100.0% | 2 |
| 50 | 34.9 ms · 229 rps | 14.0 ms · 572 rps | +150% | 100.0% | 3 |
| 200 | 33.2 ms · 241 rps | 14.0 ms · 572 rps | +137% | 100.0% | 3 |
| 500 | 33.7 ms · 238 rps | 14.3 ms · 559 rps | +135% | 100.0% | 4 |
| 1,000 | 33.6 ms · 238 rps | 14.5 ms · 551 rps | +132% | 100.0% | 5 |

---

## 4. Sweep 2 — Client Concurrency Sweep (Docker Baseline)

Separating pure read cache speed from origin saturation (concurrency scaling at 1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 10.5 ms · 95 rps | 5.15 ms · 194 rps | +104% | 100.0% | 2 |
| 4 | 18.8 ms · 213 rps | 10.51 ms · 381 rps | +79% | 100.0% | 2 |
| 8 | 38.1 ms · 210 rps | 15.34 ms · 522 rps | +149% | 100.0% | 2 |
| 16 | 61.6 ms · 260 rps | 25.54 ms · 627 rps | +141% | 100.0% | 2 |
| 32 | 104.1 ms · 307 rps | 42.81 ms · 748 rps | +144% | 100.0% | 2 |

---

## 5. Sweep 3 — Write Ratio and Concentration Sweep (Docker Baseline)

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 34.3 ms · 233 rps | 13.86 ms · 577 rps | +148% | 100.0% | 2 |
| 5% | 1 | 32.1 ms · 249 rps | 13.38 ms · 598 rps | +140% | 100.0% | 2 |
| 5% | 10 | 32.3 ms · 248 rps | 13.10 ms · 611 rps | +146% | 100.0% | 2 |
| 5% | 1000 | 32.7 ms · 245 rps | 13.31 ms · 601 rps | +145% | 100.0% | 2 |
| 10% | 1 | 30.1 ms · 265 rps | 12.47 ms · 642 rps | +142% | 100.0% | 2 |
| 10% | 1000 | 29.8 ms · 268 rps | 12.67 ms · 631 rps | +135% | 100.0% | 2 |

---

## 6. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- DigitalOcean DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
- Local Docker TSV: [`results-docker.tsv`](results-docker.tsv)
- Tenants sweep raw log (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Tenants sweep raw log (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt)
- Concurrency sweep raw log (Docker): [`run-clients.txt`](run-clients.txt)
- Write sweep raw log (Docker): [`run-writes.txt`](run-writes.txt)
