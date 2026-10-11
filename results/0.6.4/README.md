# PgCache Benchmark Verification — Tag 0.6.4

> 🇧🇷 **[Versão em português](README-pt.md)**

Verification run for **PgCache v0.6.4** (`pgcache/pgcache:0.6.4`) executed on DigitalOcean Kubernetes (DOKS) across 1, 10, 50, 100, 500, 1,000, and 2,000 tenants following the benchmark protocol.

## 1. Summary

- **Hit Ratio**: **100.0%** across all tenant tiers (1 to 2,000 tenants).
- **Key-Space Scaling**: From 1 tenant to 2,000 tenants, PgCache maintained 15.5 ms to 20.9 ms request latency, achieving **515 rps** at 2,000 tenants vs 308 rps on origin (+67% gain).
- **Warm-up Passes**: Settled in 2 passes (60s) for 1–100 tenants, 3 passes (90s) for 500–1,000 tenants, and 4 passes (120s) for 2,000 tenants.
- **Throughput Gain**: Consistently delivered **+33% to +90% throughput gain** across all tenant counts.
- **Environment**: 3-node DigitalOcean Kubernetes cluster (`s-4vcpu-8gb`, sfo3 region) with strict `podAntiAffinity` and `hostNetwork: true`.

---

## 2. Infrastructure & Environment Details

| Component | Specification |
|---|---|
| **Cloud Provider** | DigitalOcean Kubernetes (DOKS) |
| **Region / Topology** | `sfo3` (single-AZ, all 3 nodes colocated) |
| **Cluster Nodes** | 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM each) |
| **Control Plane** | `--ha=false` ($0 control plane cost) |
| **Node OS / Runtime** | Debian GNU/Linux 13 (trixie), kernel 6.12.96, containerd 2.3.3 |
| **Storage Class** | `do-block-storage` (`dobs.csi.digitalocean.com`) |
| **Pod Distribution** | Strict `podAntiAffinity` (1 node each for `origin`, `pgcache`, `loadgen`) |
| **Networking** | `hostNetwork: true` (direct node IP routing, bypassing overlay NAT) |
| **Origin Pod** | PostgreSQL 17 (`postgres:17`), requests: 2500m CPU / 5Gi RAM, `shared_buffers=512MB` |
| **PgCache Pod** | PgCache 0.6.4 (`pgcache/pgcache:0.6.4`), requests: 2500m CPU / 5Gi RAM, `workers=4`, `metricsPort=9091` |
| **Loadgen Pod** | PostgreSQL 17 (`postgres:17` com pgbench), requests: 2500m CPU / 2Gi RAM |
| **Metrics Reader Pod** | Alpine 3.20 (`alpine:3.20`), requests: 50m CPU / 64Mi RAM |
| **Dataset Size** | 500k orders, 2M items (~594 MB total), 2,000 tenants (250 orders/tenant) |

---

## 3. Sweep 1 — Tenant Count Sweep (DigitalOcean DOKS)

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

---

## 4. Sweep 2 — Client Concurrency Sweep (Baseline)

Separating pure read cache speed from origin saturation (concurrency scaling at 1,000 tenants):

| Clients | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| 1 | 10.9 ms · 92 rps | 5.15 ms · 194 rps | +111% | 100.0% | 2 |
| 4 | 19.8 ms · 202 rps | 8.88 ms · 451 rps | +123% | 100.0% | 2 |
| 8 | 38.1 ms · 210 rps | 15.34 ms · 522 rps | +149% | 100.0% | 2 |
| 16 | 58.3 ms · 275 rps | 24.96 ms · 641 rps | +133% | 100.0% | 2 |
| 32 | 104.2 ms · 307 rps | 42.81 ms · 748 rps | +144% | 100.0% | 2 |

---

## 5. Sweep 3 — Write Ratio and Concentration Sweep (Baseline)

Testing cache invalidation resilience with mixed reads and writes (8 clients, 1,000 tenants):

| Writes | Write Tenants | Origin (Path A) | PgCache (Path B) | Gain | Hit Ratio | Warm Passes |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 36.0 ms · 222 rps | 15.12 ms · 529 rps | +138% | 100.0% | 2 |
| 5% | 1 | 32.7 ms · 244 rps | 13.63 ms · 587 rps | +141% | 100.0% | 2 |
| 5% | 10 | 32.3 ms · 247 rps | 13.75 ms · 582 rps | +136% | 100.0% | 2 |
| 5% | 1000 | 32.7 ms · 245 rps | 13.39 ms · 598 rps | +144% | 100.0% | 2 |
| 10% | 1 | 32.1 ms · 249 rps | 12.72 ms · 629 rps | +153% | 100.0% | 2 |
| 10% | 1000 | 30.6 ms · 261 rps | 12.67 ms · 631 rps | +142% | 100.0% | 2 |

---

## 6. Raw Artifacts

- Machine-readable data: [`results.tsv`](results.tsv)
- Tenants sweep raw log (DOKS): [`run-tenants.txt`](run-tenants.txt)
- Concurrency sweep raw log: [`run-clients.txt`](run-clients.txt)
- Write sweep raw log: [`run-writes.txt`](run-writes.txt)
