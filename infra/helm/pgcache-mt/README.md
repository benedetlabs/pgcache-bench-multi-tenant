# PgCache Multi-Tenant Benchmark Helm Chart

Helm chart for deploying the multi-tenant benchmark architecture for PostgreSQL and PgCache on Kubernetes.

## Architecture

The chart deploys:
1. **origin**: PostgreSQL 17 StatefulSet (`lab/role: origin`), with logical replication enabled (`wal_level=logical`), 1 GB shared buffers, and PVC storage.
2. **pgcache**: PgCache Deployment (`lab/role: pgcache`), with embedded PostgreSQL cache, upstream connection to `origin`, and Prometheus metrics on port 9090.
3. **loadgen**: `postgres:17` Deployment (`lab/role: loadgen`) containing `pgbench` and persistent storage for benchmarks.
4. **metrics-reader**: Lightweight Alpine pod used to scrape Prometheus metrics over HTTP from PgCache.
5. **lab-db**: Secret containing the PostgreSQL credentials.

Anti-affinity enforces that `origin`, `pgcache`, and `loadgen` land on **three distinct physical nodes**.

---

## Installation

### 1. Production Benchmark (3-node Kubernetes cluster)

```bash
helm install pgcache-mt infra/helm/pgcache-mt \
  --namespace pgcache-mt \
  --create-namespace \
  --set image.pgcache.tag="0.7.0"
```

For ARM64 nodes (e.g. AWS Graviton):

```bash
helm install pgcache-mt infra/helm/pgcache-mt \
  --namespace pgcache-mt \
  --create-namespace \
  --set image.pgcache.tag="0.7.0-arm64"
```

### 2. Local / Single-Node Kubernetes (Docker Desktop, kind, k3d, minikube)

On single-node clusters, anti-affinity must be disabled and resources sized appropriately so all pods can schedule on a local Docker daemon (e.g. 4 CPUs / 8 GB RAM):

```bash
helm install pgcache-mt infra/helm/pgcache-mt \
  -f infra/helm/pgcache-mt/values-docker.yaml \
  --namespace pgcache-mt \
  --create-namespace \
  --set image.pgcache.tag="0.7.0-arm64"
```

---

## Important Parameters

| Parameter | Description | Default |
|---|---|---|
| `image.pgcache.tag` | PgCache image tag (e.g. `0.6.3`, `0.6.4`, `0.7.0`, `0.7.0-arm64`) | `0.7.0` |
| `image.pgcache.repository` | PgCache image repository | `pgcache/pgcache` |
| `pgcache.allowedTables` | Tables cached by PgCache (handles list or string safely) | `[product, category, seller, customer, orders, order_item, review]` |
| `affinity.enabled` | Enforce 1 pod per node via anti-affinity | `true` |
| `hostNetwork.enabled` | Bypass kube-proxy and network overlay latency | `true` |
| `origin.sharedBuffers` | Sized so dataset fits entirely in memory | `1GB` |

### Note on `ALLOWED_TABLES`

In earlier campaigns, passing comma-separated strings via `helm --set` resulted in Helm splitting values at commas, discarding the list and silently failing all cache queries with 0% hit ratio.
This chart's `_helpers.tpl` safely converts YAML list definitions into a quoted comma-separated string:

```yaml
pgcache:
  allowedTables:
    - product
    - category
    - seller
    - customer
    - orders
    - order_item
    - review
```
