# PgCache Benchmark Verification — Tag 0.6.3

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.3** (`pgcache/pgcache:0.6.3`) executed on DigitalOcean Kubernetes (DOKS) across 1, 10, 50, 100, 500, 1,000, and 2,000 tenants following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant tiers (1 to 2,000 tenants).
- **Key-Space Scaling**: From 1 tenant to 2,000 tenants, PgCache maintained consistent response times (~16.7 ms to 19.4 ms) vs ~25.6 ms to 32.2 ms on origin.
- **Warm-up Passes**: Settled in 2 passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants.
- **Throughput Gain**: Delivered **+40% to +93% throughput gain** (+56% at 100 tenants, +93% at 500 tenants, +40% at 2,000 tenants).
- **Environment**: 3-node DigitalOcean Kubernetes cluster (`s-4vcpu-8gb`, sfo3 region) with strict `podAntiAffinity` and `hostNetwork: true`.

---

## 2. Infrastructure & Environment Details

| Component | Specification |
|---|---|
| **Cloud Provider** | DigitalOcean Kubernetes (DOKS) |
| **Region / Topology** | `sfo3` (single-AZ, all 3 nodes colocated) |
| **Cluster Nodes** | 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM) |
| **Control Plane** | `--ha=false` ($0 control plane cost) |
| **Node OS / Runtime** | Debian GNU/Linux 13 (trixie), kernel 6.12.96, containerd 2.3.3 |
| **Storage Class** | `do-block-storage` (`dobs.csi.digitalocean.com`), 25 GiB (origin) and 15 GiB (loadgen) |
| **Pod Distribution** | Strict `podAntiAffinity` (1 node each for `origin`, `pgcache`, `loadgen`) |
| **Networking** | `hostNetwork: true` (direct node IP routing, bypassing overlay NAT) |
| **CPU Limits Policy** | Zero hard CPU limits (`resources.limits.cpu` unset) to eliminate CFS throttling jitter |
| **Origin Pod** | PostgreSQL 17 (`postgres:17`), requests: 2500m CPU / 5Gi RAM, `shared_buffers=512MB` |
| **PgCache Pod** | PgCache 0.6.3 (`pgcache/pgcache:0.6.3`), requests: 2500m CPU / 5Gi RAM, `workers=4`, `metricsPort=9091` |
| **Loadgen Pod** | PostgreSQL 17 (`postgres:17` with pgbench), requests: 2500m CPU / 2Gi RAM |
| **Metrics Reader Pod** | Alpine 3.20 (`alpine:3.20`), requests: 50m CPU / 64Mi RAM |
| **Dataset Size** | 500k orders, 2M items (~594 MB total), 2,000 tenants (250 orders/tenant) |

---

## 3. Sweep 1 — Tenant Count Sweep (DigitalOcean DOKS)

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

---

## 4. Sweep 2 — Client Concurrency Sweep (Baseline)

Separating pure read cache speed from origin saturation (concurrency scaling at 1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 11.2 ms · 89 rps | 5.53 ms · 181 rps | +103% | 100.0% | 2 |
| 4 | 19.2 ms · 208 rps | 8.79 ms · 455 rps | +119% | 100.0% | 2 |
| 8 | 35.4 ms · 226 rps | 14.62 ms · 547 rps | +142% | 100.0% | 2 |
| 16 | 60.3 ms · 265 rps | 25.18 ms · 635 rps | +140% | 100.0% | 2 |
| 32 | 107.2 ms · 299 rps | 45.02 ms · 711 rps | +138% | 100.0% | 2 |

---

## 5. Sweep 3 — Write Ratio and Concentration Sweep (Baseline)

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
- Tenants sweep raw log (DOKS): [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
