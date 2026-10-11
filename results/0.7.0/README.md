# PgCache Benchmark Verification — Tag 0.7.0

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.7.0** (`pgcache/pgcache:0.7.0`) executed across two complementary environments:
1. **DigitalOcean Kubernetes (DOKS)**: 3-node bare-droplet topology across 1 to 2,000 tenants.
2. **Local Docker Environment**: Single-host baseline across 1 to 1,000 tenants, concurrency scaling, and mixed write workloads.

---

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant tiers on DOKS (1 to 2,000 tenants), and **100.0%** up to 500 tenants / **99.7%** at 1,000 tenants on local Docker.
- **Key-Space Scaling**: PgCache maintained robust request latencies (~15.6 ms to 18.8 ms across most cells) with up to **513 rps** (15.6 ms vs 23.3 ms, +50% gain) on DOKS.
- **Warm-up Passes**: Settled in 2 passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants on DOKS.
- **Throughput Gain**: Maintained **+38% to +64% throughput gain** under multi-tenant expansion up to 2,000 tenants on DOKS, and **+115% to +229%** on local Docker.
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

| Active Tenants | Origin (Path A) | PgCache 0.7.0 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 23.3 ms · 343 rps | 15.6 ms · 513 rps | +50% | 100.0% | 2 |
| 10 | 23.9 ms · 335 rps | 22.9 ms · 349 rps | +4% | 100.0% | 2 |
| 50 | 28.5 ms · 281 rps | 17.3 ms · 462 rps | +64% | 100.0% | 2 |
| 100 | 26.0 ms · 307 rps | 17.2 ms · 465 rps | +51% | 100.0% | 2 |
| 500 | 25.7 ms · 311 rps | 18.7 ms · 428 rps | +38% | 100.0% | 3 |
| 1,000 | 26.0 ms · 307 rps | 17.2 ms · 466 rps | +52% | 100.0% | 3 |
| 2,000 | 25.9 ms · 309 rps | 18.8 ms · 425 rps | +38% | 100.0% | 4 |

### 3.2 Local Docker Development Environment (1 to 1,000 Tenants)

Evaluating local Docker single-host baseline across 1, 10, 50, 200, 500, and 1,000 active tenants:

| Active Tenants | Origin (Path A) | PgCache 0.7.0 (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 46.1 ms · 174 rps | 14.0 ms · 572 rps | +229% | 100.0% | 3 |
| 10 | 33.5 ms · 239 rps | 14.1 ms · 567 rps | +137% | 100.0% | 2 |
| 50 | 32.5 ms · 246 rps | 15.1 ms · 529 rps | +115% | 100.0% | 3 |
| 200 | 37.0 ms · 216 rps | 15.4 ms · 521 rps | +141% | 100.0% | 3 |
| 500 | 36.5 ms · 219 rps | 16.1 ms · 496 rps | +126% | 100.0% | 4 |
| 1,000 | 36.0 ms · 222 rps | 15.7 ms · 510 rps | +130% | 99.7% | 5 |

---

## 4. Sweep 2 — Client Concurrency Sweep (Docker Baseline)

Separating pure read cache speed from origin saturation (concurrency scaling at 1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 11.5 ms · 87 rps | 5.55 ms · 180 rps | +107% | 100.0% | 2 |
| 4 | 19.5 ms · 205 rps | 9.10 ms · 439 rps | +114% | 100.0% | 2 |
| 8 | 36.5 ms · 219 rps | 14.90 ms · 537 rps | +145% | 100.0% | 2 |
| 16 | 58.9 ms · 272 rps | 25.97 ms · 616 rps | +126% | 100.0% | 2 |
| 32 | 107.8 ms · 297 rps | 51.09 ms · 626 rps | +111% | 100.0% | 2 |

---

## 5. Sweep 3 — Write Ratio and Concentration Sweep (Docker Baseline)

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35.6 ms · 225 rps | 14.91 ms · 537 rps | +139% | 100.0% | 2 |
| 5% | 1 | 32.5 ms · 246 rps | 19.60 ms · 408 rps | +66% | 100.0% | 2 |
| 5% | 10 | 31.6 ms · 253 rps | 19.43 ms · 412 rps | +63% | 100.0% | 2 |
| 5% | 1000 | 31.8 ms · 252 rps | 20.96 ms · 382 rps | +52% | 100.0% | 2 |
| 10% | 1 | 32.1 ms · 249 rps | 18.97 ms · 422 rps | +69% | 100.0% | 2 |
| 10% | 1000 | 31.2 ms · 257 rps | 25.14 ms · 318 rps | +24% | 100.0% | 2 |

---

## 6. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- DigitalOcean DOKS TSV: [`results-doks.tsv`](results-doks.tsv)
- Local Docker TSV: [`results-docker.tsv`](results-docker.tsv)
- Tenants sweep raw log (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Tenants sweep raw log (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt)
- Concurrency sweep raw log (Docker): [`run-clients.txt`](run-clients.txt)
- Write sweep raw log (Docker): [`run-writes.txt`](run-writes.txt)
