# pgcache-multi-tenant

**A reproducible benchmark that measures what a read cache is worth in front of
a multi-tenant SaaS database — and a complete write-up of what it measured.**

Everything needed to run it is here: the schema, the workload, the environment,
the drivers, and the numbers we got. Section 2 is a four-command quick start;
the rest is the reasoning, including the parts we got wrong.

> 🇧🇷 **[Versão em português](README-pt.md)**

---

## Table of contents

1. [What this is](#1-what-this-is)
2. [Quick start](#2-quick-start)
3. [The question](#3-the-question)
4. [Background: the one fact that decides everything](#4-background-the-one-fact-that-decides-everything)
5. [Why multi-tenant, and what we expected](#5-why-multi-tenant-and-what-we-expected)
6. [The trick: a pgbench script is a request](#6-the-trick-a-pgbench-script-is-a-request)
7. [**The environment, exactly**](#7-the-environment-exactly)
   - [7.7 The DigitalOcean low-cost setup (DOKS)](#77-the-digitalocean-low-cost-kubernetes-setup-doks)
8. [Step 1 — the schema](#8-step-1--the-schema)
9. [Step 2 — denormalising the tenant](#9-step-2--denormalising-the-tenant)
10. [Step 3 — the request](#10-step-3--the-request)
11. [Step 4 — the measurement protocol](#11-step-4--the-measurement-protocol)
12. [Sweep 1 — does the tenant count break the cache?](#12-sweep-1--does-the-tenant-count-break-the-cache)
   - [12.1 Multi-tenant scaling up to 2,000 tenants on DigitalOcean (DOKS)](#121-multi-tenant-scaling-up-to-2000-tenants-on-digitalocean-doks)
   - [12.2 Tuned network & engine profile (Baseline vs Tuned)](#122-side-by-side-baseline-vs-tuned-network--engine-profile)
13. [Sweep 2 — separating caching from saturation](#13-sweep-2--separating-caching-from-saturation)
14. [Sweep 3 — writes](#14-sweep-3--writes)
15. [Why the query shape decides everything](#15-why-the-query-shape-decides-everything)
   - [15.1 Sweep 4 — complex multi-tenant SaaS scenarios (PgCache 0.7.1)](#151-sweep-4--complex-multi-tenant-saas-scenarios-pgcache-071)
   - [15.2 Sweep 5 — 1h30m endurance & Origin resource offload (DOKS + Grafana Cloud)](#152-sweep-5--1h30m-endurance--origin-resource-offload-doks--grafana-cloud)
16. [What this does not prove](#16-what-this-does-not-prove)
17. [Appendix: every file](#17-appendix-every-file)

---

## 1. What this is

Two things in one repository.

**A tool.** A benchmark that models both a lightweight multi-tenant SaaS
dashboard (`workload/dashboard.sql`) and complex enterprise SaaS screens —
substring text search (`ILIKE '%...%'`), deep 4-to-6 table `INNER JOIN` and
`LEFT JOIN` chains, and multi-dimensional analytical aggregations (`GROUP BY`,
`FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`) — against PostgreSQL, with and
without a read cache in front, across tenant count, concurrency, and write ratio.

**A write-up.** The full account of running it — why each decision was made the
way it was, what the numbers came out as, and the mistakes made along the way.
Written for someone who has never seen it before; nothing assumes prior context.

**The result, in one line:** the cache answered an eight-statement SaaS dashboard
between **6.4× and 12.6× faster** than the uncached database (and **14× to 31×
faster on 3-node DOKS** on complex 4-to-6 table Materialized View workloads in
PgCache `0.7.1`), with a **100% hit ratio** across settled read workloads.

Section 16 is where that number should stop being pushed. Whereas the original
campaign published without a differential correctness check, [`scripts/verify-correctness.sh`](scripts/verify-correctness.sh)
now enforces byte-for-byte output identity (`Origin == PgCache`), `pgcache_queries_uncacheable == 0`,
Materialized View gate admission & hit verification, and Post-CDC live mutation equality across all baseline and complex queries (`results/0.7.1/verify-correctness-doks.txt`).

The cache under test is [PgCache](https://www.pgcache.com). Nothing here is
affiliated with it — this is an independent measurement, including the parts
that are unflattering.

---

## 2. Quick start

You need a Kubernetes cluster with **three schedulable nodes** (the reason is in
section 7 and it is not negotiable), and `kubectl`.

```bash
# 1. Stand up the three components plus a metrics reader.
kubectl apply -f infra/k8s/

# 2. Wait for them, and confirm they landed on three DIFFERENT nodes.
kubectl -n pgcache-mt rollout status deploy/loadgen --timeout=10m
kubectl -n pgcache-mt rollout status deploy/pgcache --timeout=10m
kubectl -n pgcache-mt get pods -o wide

# 3. Schema, seed, tenant denormalisation, workload. About a minute.
./scripts/00-setup.sh
# Or scale dataset volume:
# SCALE=5 ./scripts/00-setup.sh      # ~2.3 GB (2.5M orders, 10M items)
# SCALE=10 ./scripts/00-setup.sh     # ~4.6 GB (5.0M orders, 20M items)

# 4. Run the differential correctness, cacheability & MV admission gate.
./scripts/verify-correctness.sh

# 5. The baseline sweeps (01-03) and complex multi-tenant sweeps (04).
./scripts/01-tenant-sweep.sh      | tee data/run-tenants.txt
./scripts/02-concurrency-sweep.sh | tee data/run-clients.txt
./scripts/03-write-sweep.sh       | tee data/run-writes.txt
./scripts/04-complex-sweep.sh all | tee data/run-complex.txt
```

Before believing any output, check two things:

```bash
# Three distinct nodes, ideally one availability zone.
kubectl -n pgcache-mt get pods -o wide
kubectl get nodes -L topology.kubernetes.io/zone

# No preemption inside a measurement window. On spot instances an eviction
# mid-window invalidates that cell -- discard it and run it again.
kubectl -n pgcache-mt get events --sort-by=.lastTimestamp \
  | grep -iE 'preempt|evict|NodeNotReady'
```

There is also a laptop setup at [`infra/docker-compose.yml`](infra/docker-compose.yml).
It reproduces the *shape* of the results but not the magnitudes — section 7.6
explains why, and it matters more than it sounds.

### Helm deployment

You can deploy to Kubernetes or Docker Desktop using the Helm chart in [`infra/helm/pgcache-mt`](infra/helm/pgcache-mt/) or the [`scripts/helm-deploy.sh`](scripts/helm-deploy.sh) helper:

```bash
# Production 3-node Kubernetes cluster:
helm install pgcache-mt infra/helm/pgcache-mt \
  --namespace pgcache-mt --create-namespace \
  --set image.pgcache.tag="0.7.1"

# ARM64 production clusters (e.g. AWS Graviton):
helm install pgcache-mt infra/helm/pgcache-mt \
  --namespace pgcache-mt --create-namespace \
  --set image.pgcache.tag="0.7.1-arm64"

# Local Docker Kubernetes (Docker Desktop / kind / k3d):
./scripts/helm-deploy.sh --docker 0.7.1-arm64
# Or manually with Helm:
helm install pgcache-mt infra/helm/pgcache-mt \
  -f infra/helm/pgcache-mt/values-docker.yaml \
  --namespace pgcache-mt --create-namespace \
  --set image.pgcache.tag="0.7.1-arm64"

# DigitalOcean low-cost 3-node cluster (~$0.21/hr total, free control plane via --ha=false):
./scripts/do-cluster.sh create
./scripts/do-cluster.sh deploy 0.7.1
# When finished, destroy the cluster and all volumes:
./scripts/do-cluster.sh destroy
```

### Multi-version results & multi-trial tag verification

Official benchmark verification results structured by release tag (`0.6.3`, `0.6.4`, `0.7.0`, and `0.7.1`) are available under [`results/`](results/) with dedicated English and Portuguese reports.

To run an official multi-trial campaign (default: 5 trials with full pod recreation `origin + pgcache + loadgen` between trials) on a 3-node Kubernetes cluster:

```bash
./scripts/run-tag-verification.sh 0.7.1 30 5
```

To assemble the environment locally in Docker and run only the functional & differential correctness gate (no performance results are recorded from Docker):

```bash
./scripts/run-tag-verification.sh --smoke-docker 0.7.1
```

---

## 3. The question

**PgCache** is a read cache that sits between an application and PostgreSQL. It
speaks the PostgreSQL wire protocol, so the application does not know it is
there — you point the connection string at the cache instead of the database and
change nothing else.

What makes it interesting is *coherence*. Most caches go stale and rely on a
TTL: you accept serving data that is up to N seconds old. PgCache instead
follows the origin database's replication log and invalidates affected entries
when the underlying rows change. In principle that is a cache's speed without a
cache's classic problem.

The question this benchmark answers:

> Does putting a read cache in front of a database actually make a multi-tenant
> application faster — and under what conditions does it stop being worth it?

Both halves matter. A benchmark that only produces the first half is marketing.

---

## 4. Background: the one fact that decides everything

Here is the thing about PgCache that sounds like an implementation detail and
turns out to drive every result in this document:

> **A cache hit is not a memory read. It is a full SQL round trip.**

The PgCache image embeds its own PostgreSQL instance, and that is where cached
entries live. When the cache "hits", what happens is a complete query against
that local database — parse, execute, ship the rows back. Cheaper than going to
the origin, but not free, and nowhere near the nanoseconds of a Redis `GET`.

This gives PgCache a **floor**: a minimum cost per query it cannot go below. And
it produces a rule that is easy to state and easy to forget:

> If the origin database already answers faster than that floor, no amount of
> configuration will help. The cache becomes pure overhead.

We learned this the expensive way on an earlier subject in the same lab — an
authorisation service whose database served each query in **39.5–42.2
microseconds**, against PgCache's **41.9–47.0**. About 5 µs of overhead per
query, which is genuinely good behaviour for a network proxy, but the wrong
**sign**. Multiplied across the 104–171 queries that service issued per request,
those 5 µs became a visible penalty.

Why was the origin so fast? Its entire dataset fit in memory, running at a
**99.93% buffer hit rate**. We had built a read cache in front of a database
already serving entirely from RAM.

Hold that thought for section 7.2, where you will see us do it again on purpose.

### The two paths

The benchmark compares two identical stacks that differ in exactly one thing:

- **Path A — the baseline.** The client talks straight to PostgreSQL.
- **Path B — PgCache.** The client talks to PgCache, which talks to PostgreSQL.

Same binary, same data, same machine class, same network. **The connection host
and port is the only difference.** Anything else that differs makes the
comparison meaningless, and section 7 is largely about defending that sentence.

---

## 5. Why multi-tenant, and what we expected

Three application shapes were candidates: an e-commerce catalogue, a
multi-tenant SaaS, and a content site. We ran multi-tenant first **on purpose,
because we expected it to be the worst one.**

In a multi-tenant SaaS every query is scoped to a customer organisation:

```sql
SELECT ... FROM orders WHERE tenant_id = 47 ...
```

Under the simple query protocol — which is what PgCache needs, and section 7.5
explains why — the literal is written into the SQL text before it is sent. So
`tenant_id = 47` and `tenant_id = 48` are two *different query strings*, and
therefore two different cache entries.

With 200 active tenants, every statement multiplies into 200 distinct entries.
Add pagination and filters and it multiplies again. The hypothesis was that this
**explosion of the query space** would drive the hit ratio into the ground.

If the cache survived the hardest case, the easier ones would need no defending.

**The hypothesis was wrong**, and section 12 shows by how much. Worth stating up
front: this benchmark was designed to find a limit and did not find it, which is
a different and less comfortable thing than one designed to find a win.

---

## 6. The trick: a pgbench script is a request

The tool is **pgbench**, which ships with PostgreSQL.

pgbench has an obvious-looking weakness: it is built to hammer a database with
single statements. Real applications do not do that — they issue eight, or
twenty, or a hundred statements to render one screen. That property is called
**query amplification**, and it is the single biggest factor in whether a cache
helps, because whatever the cache does per query gets multiplied by it.

The trick that makes this benchmark possible:

> **A pgbench `-f` script is one transaction, and pgbench reports its latency as
> one number.**

So a script containing eight statements is a **request** containing eight
statements, and what pgbench measures is per-request latency — the unit a user
experiences, and the unit an adoption decision is made in.

Amplification stops being a property of some application you have to go find,
and becomes a parameter you write down.

---

## 7. The environment, exactly

Every setting here is part of the measurement. Changing one changes what the
numbers mean, so each carries its reason.

Manifests: [`infra/k8s/`](infra/k8s/).

### 7.1 Machines

| role | what it runs | requests | node used for the published numbers |
|---|---|---|---|
| `origin` | `postgres:17` | 6 CPU / 20 GiB | Standard_D8as_v5 — 8 vCPU, 32 GiB |
| `pgcache` | `pgcache/pgcache:latest` | 6 CPU / 24 GiB | same |
| `loadgen` | `postgres:17` (pgbench) | 6 CPU / 8 GiB | same |
| `metrics-reader` | `alpine:3.20` | 50m / 64 MiB | system pool, idle |

**Three separate nodes, enforced by `podAntiAffinity`.** This is the single most
important infrastructure decision and it is not tidiness.

Path B runs *both* the origin and PgCache. Path A runs only the origin. If they
shared a node, path B would have less CPU available for the origin than path A
had — **at exactly the concurrency where the comparison is decided**. The result
would be an artifact of co-location rather than a property of the cache.

**Requests only. No CPU limits.** A CPU limit in Kubernetes becomes a CFS quota
enforced over 100 ms windows: a pod that exceeds it is frozen until the window
turns. That freeze appears as a p99 spike **indistinguishable from a cache
miss** — precisely the signal being read. With one pod per node, isolation comes
from the node and no quota is needed.

**Memory limits carry a specific trap.** If you add `resources.limits.memory` to
the PgCache pod, you must also set `MEMORY_LIMIT` below it. PgCache defaults to
80% of the RAM it *detects*, and inside a cgroup it tends to detect the node's
full 32 GiB — so it will try to use ~25 GB inside a 4 GiB limit and be
OOM-killed.

**Availability zones were verified, not assumed.** All three nodes landed in one
zone. A cross-zone split adds tens of microseconds to one path and could explain
a result of this size on its own:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

**Spot instances are fine, with one rule.** These ran on spot nodes. An eviction
*inside* a measurement window invalidates that cell — check for it after every
sweep and re-run any affected repetition.

**Ultra-low-cost Azure AKS Terraform setup (`infra/terraform/aks/`).** Creating
an AKS cluster through the Azure Portal enables the `Standard` control plane
tier ($0.10/hr = ~$73/mo), Container Insights / Log Analytics, Managed
Prometheus, Managed Grafana, Defender, and Multi-AZ node pools by default. To
reproduce the exact 3-node single-AZ Spot topology (`Standard_D8as_v5` or
`Standard_E4s_v5`) with a **$0.00/hr Free control plane** and **zero observability
or security add-on billing (~$0.10–$0.19/hr total)**, use
[`infra/terraform/aks/`](infra/terraform/aks/README.md) and
[`scripts/aks-cluster.sh`](scripts/aks-cluster.sh).

### 7.2 PostgreSQL — every flag, and why

```
postgres
  -c wal_level=logical
  -c max_wal_senders=10
  -c max_replication_slots=10
  -c shared_preload_libraries=pg_stat_statements
  -c pg_stat_statements.track=all
  -c shared_buffers=1GB
  -c max_connections=500
  -c work_mem=32MB
  -c maintenance_work_mem=512MB
  -c random_page_cost=1.1
  -c track_io_timing=on
```

| flag | why it is there |
|---|---|
| `wal_level=logical` | **Mandatory.** PgCache follows the replication stream to know what to invalidate. Without logical decoding there is no change feed and no coherence. |
| `max_wal_senders`, `max_replication_slots` | Headroom for the cache's replication slot plus anything else attached. |
| `pg_stat_statements` | Lets you inspect what the workload *actually* issued, per statement. Assumptions about generated SQL are usually wrong. |
| **`shared_buffers=1GB`** | **The most consequential setting here.** See below. |
| `max_connections=500` | The concurrency sweep reaches 32 clients per path, each holding a connection. Headroom, not tuning. |
| `work_mem=32MB` | Enough that the dashboard's `GROUP BY` and `ORDER BY` sort in memory. A workload spilling to disk would measure temp files. |
| `random_page_cost=1.1` | SSD-backed storage. The 4.0 default assumes spinning disks and pushes the planner toward sequential scans it should not choose. |
| `track_io_timing=on` | Makes "is the origin serving from memory?" a measurement rather than an assumption. |

**About `shared_buffers=1GB`.** The dataset is ~463 MB, so it fits entirely. The
origin never touches disk.

That is deliberate, and it is the **hardest** case for the cache: it cannot win
by avoiding disk I/O — the easy story — and has to win on work saved or not at
all. It is also the exact condition that made the earlier subject in section 4
unwinnable. Any result here is conservative on that axis.

### 7.3 PgCache — every variable, and one that will ruin your run

```yaml
UPSTREAM_URL:       postgres://bench:benchpass@origin...:5432/bench
LISTEN_PORT:        "6432"
METRICS_PORT:       "9090"
NUM_WORKERS:        "4"
ALLOWED_TABLES:     "product,category,seller,customer,orders,order_item,review"
PGCACHE_TELEMETRY:  "off"
```

**`ALLOWED_TABLES` is the setting that silently ruins a run.** PgCache caches
only the tables listed. Get it wrong and every query is a miss, the cache looks
useless, and **nothing errors anywhere**.

We lost a full ten-cell probe to exactly this. The list was passed with
`helm --set`, which splits unescaped commas into separate assignments, so the
whole value was discarded. Every query shape reported a **0.0% hit ratio** —
including a plain primary-key lookup, which should be trivially cacheable — and
the cache was working perfectly. It had simply been given no tables.

Whatever tool you deploy with, **verify the value arrived**:

```bash
kubectl -n pgcache-mt exec deploy/pgcache -- printenv ALLOWED_TABLES
```

`PGCACHE_TELEMETRY: off` because anonymous telemetry is uncontrolled network
traffic inside a measurement window.

**Three settings are deliberately left unset**, so the benchmark measures the
product's defaults rather than our tuning: `PINNED_TABLES` (pre-load tables and
keep them updated in place instead of invalidating), `ADMISSION_THRESHOLD` (how
many occurrences before an entry is admitted), and `MEMORY_LIMIT`. Turning them
on is a legitimate follow-up experiment, but it is a *different* experiment and
must be labelled as one.

### 7.4 The network path

The Services are **headless** (`clusterIP: None`) and the pods use
**`hostNetwork: true`**. Under hostNetwork the pod IP *is* the node IP, so DNS
resolves straight to the node and the connection skips kube-proxy, NAT and the
overlay.

At roughly 1,000 requests per second with eight statements each, the per-packet
cost of an overlay is a measurable fraction of the result. Including it would
mean measuring Kubernetes rather than the cache.

**If your cluster forbids hostNetwork** — Pod Security admission often does —
remove `clusterIP: None` from both Services and the `hostNetwork`/`dnsPolicy`
lines from the pod specs. Everything still works. Both paths pay the overlay cost
equally, so the *comparison* stays fair; the absolute latencies will simply be
higher than the ones published here.

### 7.5 Why pgbench, and not the four alternatives

The deciding factor in every case was **how the tool talks to PostgreSQL**,
checked by reading each one's source rather than its documentation.

PgCache needs the **simple query protocol**: values interpolated into the SQL
text rather than sent separately as bound parameters. pgbench does this **by
default** — `-M simple` is its default mode and nothing has to be forced.

That sounds minor and is not. In an earlier campaign against a real application,
simple protocol had to be forced *on the cached path only*. So path B was not
"path A plus a cache" — it was "path A with prepared statements disabled, plus a
cache", and the two effects could not be separated. **Nine cells of that
campaign's conclusion had to be retracted.** With pgbench there is no such
confound to make, because both paths run the tool's own default.

The others each had a blocking problem:

- **BenchBase** — the most attractive on paper, with real Wikipedia and Twitter
  workloads — calls `setAutoCommit(false)` in its `Worker` **constructor**, once
  for the connection's whole lifetime. Every read in every workload therefore
  runs inside an explicit `BEGIN…COMMIT`, and **PgCache passes through
  everything inside a transaction**. Not a flag, not tunable.
- **HammerDB** runs its TPC-C transactions as server-side PostgreSQL functions.
  The client sends one opaque call; the cache never sees the statements.
- **YCSB** duplicates what pgbench already does, in a worse protocol.
- **sysbench** is viable but needs two non-default flags, one of which
  (`--db-ps-mode=disable`) makes the *origin* slower and would flatter the cache
  for the wrong reason.

### 7.6 Running it on a laptop

[`infra/docker-compose.yml`](infra/docker-compose.yml) brings up the same three
components locally. The *shape* of the results reproduces; the *magnitudes* do
not.

On Kubernetes the three components sit on three machines and every query crosses
a real network hop. In Docker they share one host and one kernel: the hop is
nearly free and the three compete for the same CPUs. We measured the difference
directly on an earlier campaign — the same query cost **77 µs on a laptop and
167 µs across nodes on the cluster**.

Use Docker to develop the workload and confirm the effect exists. Use a cluster
to produce numbers.

### 7.7 The DigitalOcean Low-Cost Kubernetes Setup (DOKS)

To validate the benchmark on real cloud infrastructure without enterprise cloud costs, we automated deployment onto DigitalOcean Kubernetes (`scripts/do-cluster.sh` and `infra/helm/pgcache-mt/values-do-lowcost.yaml`):

```bash
# 1. Stand up a 3-node cluster in single-AZ sfo3 with $0 control plane:
./scripts/do-cluster.sh create pgcache-bench s-4vcpu-8gb sfo3

# 2. Deploy PgCache release via Helm:
./scripts/do-cluster.sh deploy 0.7.1
```

| Component | DOKS Configuration | Rationale / Invariant |
|---|---|---|
| **Cluster Nodes** | 3x `s-4vcpu-8gb` (4 vCPU, 8 GB RAM) | ~$0.071/hr per node (~$0.21/hr total). |
| **High Availability** | `--ha=false` | Disables redundant control plane to keep control plane fee at $0. |
| **Region / Topology** | `sfo3` / `sfo2` (single-AZ) | Strictly colocates all three worker nodes in one availability zone to avoid cross-AZ latency jitter. |
| **Storage Class** | `do-block-storage` | Native block storage via DigitalOcean CSI (`dobs.csi.digitalocean.com`). |
| **Storage Volumes** | 25 GiB (`origin`), 15 GiB (`loadgen`) | Sized for multi-tenant database scaling with `do-block-storage`. |
| **Pod Anti-Affinity** | `podAntiAffinity` (required) | Enforces 1 node each for `origin`, `pgcache`, and `loadgen` to eliminate CPU competition. |
| **Networking** | `hostNetwork: true` | Direct host IP routing bypassing overlay encapsulation. |
| **CPU Limits Policy** | `resources.limits.cpu` unset | Never set hard CPU limits: prevents Linux CFS throttling jitter that introduces artificial p99 latency spikes. |
| **Pod Resource Requests** | `origin`: 2500m / 5Gi, `pgcache`: 2500m / 5Gi, `loadgen`: 2500m / 2Gi | Guarantees resource reservation while leaving headroom for node OS and daemonsets. |
| **Memory & `/dev/shm` Sizing** | `MEMORY_LIMIT="3758096384"`, `MEMO_CACHE_SIZE="1073741824"`, 2 GiB `/dev/shm` | Caps PgCache at 3.5 GiB raw integer bytes on 8 GB nodes and provides a 2 GiB memory-backed `/dev/shm` for PostgreSQL 17 DSA and MV builds. |
| **Metrics Port** | `METRICS_PORT=9091` | Prevents host port conflict with DigitalOcean's managed Cilium agent (which binds host port 9090). |
| **Origin Settings** | `shared_buffers=512MB` | Preserves in-memory evaluation for the 500k-orders baseline on 8 GB worker nodes. |

---

## 8. Step 1 — the schema

**File: [`sql/01-schema.sql`](sql/01-schema.sql)**

Seven tables shaped like an application, not like a benchmark.

| table | rows | size | role |
|---|---:|---:|---|
| `order_item` | 2,000,000 | 184 MB | line items — the big fact table |
| `orders` | 500,000 | 48 MB | the tenant-scoped centre of the workload |
| `review` | 300,000 | 41 MB | present so not every join hits the same tables |
| `product` | 200,000 | 22 MB | joined from `order_item` |
| `customer` | 100,000 | 9.6 MB | carries the native `tenant_id` |
| `seller` | 500 | 96 kB | small reference |
| `category` | 50 | 32 kB | small reference |
| **total** | | **463 MB** | |

### The cardinalities are not arbitrary

Each ratio controls a specific property of the workload:

- **100,000 customers over 200 tenants** = 500 customers per tenant.
- **500,000 orders over 100,000 customers** = 5 orders each, so **2,500 orders
  per tenant**. This is the number that matters most: it is what the dashboard's
  aggregates run over, and therefore it sets how much work the origin does per
  request. Too few and the query is trivial; too many and it stops looking like
  a dashboard.
- **2,000,000 line items over 500,000 orders** = 4 per order, giving roughly
  10,000 line items per tenant for the join-and-aggregate statement.

Seeding uses `generate_series` and runs entirely inside the server — well under
a minute, no external loader.

One deliberate detail:

```sql
INSERT INTO order_item
SELECT g, 1 + (g % 500000), 1 + (g * 7 % 200000), ...
```

The `g * 7 % 200000` scatters products across orders. A naive `g % 200000` would
correlate line-item id with product id, making the join artificially local and
cheaper than it should be.

### Every foreign key is populated

No NULLs in any FK column. Not cosmetic: with an all-NULL foreign key, planners
and ORMs alike can skip a join entirely, and the workload would quietly stop
exercising what it was written to exercise.

### The indexes are the ones an ORM would create

One on every foreign key, plus the columns the workload filters on. Nothing
hand-tuned.

That cuts both ways, which is the point. A schema indexed *better* than a real
application would make the origin look artificially good; indexed *worse* it
would hand the cache an easy win. "What the ORM would have done" is the only
defensible default.

---

## 9. Step 2 — denormalising the tenant

**File: [`sql/02-tenant.sql`](sql/02-tenant.sql)**

After step 1, only `customer` carries `tenant_id`. Finding an order's tenant
means joining back through `customer`; for a line item, joining twice.

Real multi-tenant applications do not do that. They **copy `tenant_id` onto
every table**, precisely so every query can filter on it directly with one index
and no join.

```sql
ALTER TABLE orders     ADD COLUMN IF NOT EXISTS tenant_id int;
ALTER TABLE order_item ADD COLUMN IF NOT EXISTS tenant_id int;

UPDATE orders SET tenant_id = 1 + ((customer_id - 1) % 200) WHERE tenant_id IS NULL;
UPDATE order_item oi SET tenant_id = o.tenant_id
  FROM orders o WHERE o.id = oi.order_id AND oi.tenant_id IS NULL;
```

This is not only realism — **it protects the experiment**. If the tenant filter
required a join, every measurement would include that join's cost, and the
question being asked (does tenant count explode the query space?) would be
confounded by it.

Takes about 45 seconds: one `UPDATE` over 500,000 rows and one over 2,000,000.

### The composite indexes, and a fairness decision

```sql
CREATE INDEX orders_tenant_created ON orders(tenant_id, created_at DESC);
CREATE INDEX orders_tenant_status  ON orders(tenant_id, status);
CREATE INDEX oitem_tenant_product  ON order_item(tenant_id, product_id);
```

The first earns its keep. The dashboard's recent-orders query is "this tenant's
orders, newest first, first 20". With a plain index on `tenant_id` the database
finds the tenant's 2,500 rows and then **sorts them**. With
`(tenant_id, created_at DESC)` the index is already in the required order, so
the planner walks it and stops after 20 rows.

**This decision favours path A.** Without these indexes the origin would be
slower and the cache would look better. Adding them is the kind of accidental
advantage a benchmark has to refuse — you index for the origin's benefit,
because the origin is what you are claiming to beat.

Verify:

```sql
SELECT count(DISTINCT tenant_id) AS tenants,
       count(*) / count(DISTINCT tenant_id) AS orders_per_tenant FROM orders;
--  tenants | orders_per_tenant
--      200 |              2500
```

---

## 10. Step 3 — the request

**File: [`workload/dashboard.sql`](workload/dashboard.sql)**

Eight statements, all scoped to one tenant: summary cards, a list of recent
orders, a top-products panel, a page of line items.

### The variables

```
\set t    random(1, :tenants)     -- which tenant
\set off  random(0, 9)            -- which page (10 pages)
\set st   random(1, 4)            -- which status filter (4 values)
```

`:tenants` is the sweep's independent variable. `:off` and `:st` are the
variability a real application has *beyond* the tenant — a user pages through
results and filters by status, and under simple protocol each combination is a
different SQL string and therefore a different cache entry.

Without them the query space would be 200 entries per statement and the test
would be trivially easy. With them it is 200 × 10 × 4 across eight statements —
thousands of distinct entries. **That was the point: give the query-space
explosion a real chance to happen.**

### Statement by statement

**1 — Order counts by status.** `GROUP BY` over the tenant's 2,500 orders.

```sql
SELECT status, count(*) FROM orders WHERE tenant_id = :t GROUP BY status;
```

**2 — Revenue and order count.** Two aggregates over the same rows.

**3 — Customer count.** A different table through a different index, so the
request is not satisfied entirely out of one relation's cached pages.

**4 — The recent-orders page.** What the composite index exists for. `OFFSET`
makes each page a distinct entry.

```sql
SELECT id, status, total, created_at FROM orders WHERE tenant_id = :t
 ORDER BY created_at DESC LIMIT 20 OFFSET :off * 20;
```

**5 — A filtered count.** The badge next to a status tab. `COUNT(*)` is the
classic cache target: **expensive to compute, tiny to store.**

**6 — Recent orders with the customer name.** A two-table join — what an ORM
emits when a list view shows a field from a related record.

**7 — Top products.** The most expensive statement: a join across ~10,000 line
items, a `GROUP BY`, and a sort on the aggregate. No index serves this by
walking; the origin has to do the work.

```sql
SELECT p.name, sum(oi.qty)
  FROM order_item oi JOIN product p ON p.id = oi.product_id
 WHERE oi.tenant_id = :t GROUP BY p.name ORDER BY 2 DESC LIMIT 10;
```

**8 — A page of line items with product names.** Join plus pagination combined.

### There is no BEGIN, and that is load-bearing

pgbench runs with `-M simple` and the script contains no transaction, so every
statement is its own implicit transaction.

This is not style. **PgCache passes through everything inside `BEGIN…COMMIT`** —
a script wrapped in a transaction would measure precisely nothing. It is the
same property that disqualified BenchBase in section 7.5, and it is worth
checking in any real application before assuming a cache can help it.

### What it costs before any caching

Single client, no concurrency, straight to the origin:

```
latency average = 39.511 ms
tps = 25.31
```

**Roughly 40 milliseconds per request.** Not a toy query — this is what a real
dashboard costs, and three orders of magnitude more expensive than the 0.19 ms
point selects most database benchmarks use.

---

## 11. Step 4 — the measurement protocol

The measurements are only as good as the protocol around them.

### Warm-up: the mistake made three times

**File: [`scripts/lib.sh`](scripts/lib.sh), function `warm_until_settled`**

A cache starts cold. Measure it too early and you measure the warm-up, not the
cache. Obvious — and it has produced a wrong published result three separate
times in this lab.

- **The retracted campaign.** Adaptive warm-up code existed that runs until the
  hit ratio stabilises, and the flag enabling it was never passed. All 52 runs
  recorded 45 seconds of warm-up while the hit ratio was still climbing at two
  and a half minutes. **Nine cells were retracted.**
- **A query-shape probe**, weeks later. One 15-second pass made a plain
  primary-key lookup appear to reach a **19.5%** hit ratio and lose by 42%. With
  adequate warm-up the identical cell reaches **100%** and wins by 38%. The
  ranking nearly published was measuring warm-up speed, not cacheability.

So this benchmark does not use a fixed warm-up. It repeats 30-second passes,
measures each one's hit ratio, and stops when two consecutive passes differ by
less than one percentage point:

```bash
warm_until_settled() {
  local prev=0 cur
  for p in 1 2 3 4 5; do
    read -r h0 m0 <<<"$(scrape)"
    run "$host" "$port" "$DURATION" "$@" >/dev/null
    read -r h1 m1 <<<"$(scrape)"
    cur=$(awk -v h=$((h1-h0)) -v m=$((m1-m0)) 'BEGIN{printf "%.4f", (h+m)?h/(h+m):0}')
    if awk -v c="$cur" -v q="$prev" 'BEGIN{exit !(c-q < 0.01 && c-q > -0.01)}'; then
      echo "$p"; return 0
    fi
    prev="$cur"
  done
  echo 5
}
```

The number of passes is reported in every result table, so a reader can see it
rather than trust it.

> **A fixed warm-up pass is a guess wearing the costume of a protocol.**

### Reading the metrics

PgCache exposes Prometheus metrics. The two that matter:

```
pgcache_queries_cache_hit    <cumulative count>
pgcache_queries_cache_miss   <cumulative count>
```

They are **cumulative** since process start, so every measurement takes a
*delta* around the window rather than reading them absolutely.

The scrape does not come from the load generator: the `postgres:17` image ships
neither `curl` nor `wget`, and installing one at pod startup is the fragility
that killed an earlier campaign with `exit 127` halfway through. That is why
[`infra/k8s/04-metrics-reader.yaml`](infra/k8s/04-metrics-reader.yaml) exists —
a tiny Alpine pod whose only job is to be exec'd into for the scrape.

One more lesson from an earlier run: a single 10-second scrape timed out under
load and recorded `ratio=0.0000` on three cells. Scraped by hand afterwards, the
same cache was at **99.25%**. A latency without its hit ratio is
uninterpretable, so a failed scrape must **stop** the cell rather than record a
zero that reads like a cache failure.

### Repeatability, measured rather than assumed

Three cells share the same nominal configuration — 8 clients, 200 tenants, no
writes — and were measured independently as part of three different sweeps:

| measured in | origin | PgCache |
|---|---:|---:|
| tenant sweep | 83.265 ms | 7.085 ms |
| concurrency sweep | 83.052 ms | 7.088 ms |
| write sweep | 83.177 ms | 7.100 ms |

**A spread of 0.3% on the origin and 0.2% through the cache.** That is the
yardstick for judging every small difference below — and it is what makes the
argument in section 14 about write concentration something other than an
assertion.

---

## 12. Sweep 1 — does the tenant count break the cache?

**Script: [`scripts/01-tenant-sweep.sh`](scripts/01-tenant-sweep.sh)**

The hypothesis: every query carrying `WHERE tenant_id` multiplies the query space
by the tenant count, so the hit ratio should fall as tenants rise.

Concurrency held at 8 clients so tenant count is the only variable.

| active tenants | origin | PgCache | gain | hit ratio | warm passes |
|---:|---|---|---:|---:|---:|
| 1 | 79.2 ms · 101 rps | 6.96 ms · 1,149 rps | +1038% | 100% | 2 |
| 10 | 81.2 ms · 99 rps | 7.00 ms · 1,143 rps | +1055% | 100% | 2 |
| 50 | 82.5 ms · 97 rps | 7.07 ms · 1,131 rps | +1066% | 100% | 2 |
| 200 | 83.3 ms · 96 rps | 7.09 ms · 1,129 rps | +1076% | 100% | 3 |

### How to read this

Look at the hit-ratio column first. **It does not move.** From one tenant to two
hundred, the cache answers every query from its own store.

Then PgCache's latency: 6.96 ms to 7.09 ms — a **1.8%** rise across a 200×
increase in tenant count.

The gain moves 38 percentage points, from +1038% to +1076%, which on a base of a
thousand is under 4% relatively. Note the direction: it moves **upward**, because
the origin slows slightly faster than the cache does.

The only visible cost of 200 tenants is the last column: warming took three
passes instead of two.

### The hypothesis was wrong

Two hundred tenants × ten offsets × four status values across eight statements is
a query space in the thousands. It was enough to need one extra warm-up pass and
nothing else.

**The query space of a SaaS with this shape is large, but not large on the scale
that would matter to this cache.**

That is an uncomfortable outcome to report. The scenario was chosen to expose a
limit and did not. Section 16 says how far the finding can honestly be pushed —
200 tenants is not 20,000.

### 12.1 Multi-Tenant Scaling up to 2,000 Tenants on DigitalOcean (DOKS)

To test whether extreme multi-tenancy causes key-space explosion or cache eviction, we executed the tenant sweep across **1, 10, 50, 100, 500, 1,000, and 2,000 active tenants** on our 3-node DigitalOcean Kubernetes cluster (`s-4vcpu-8gb`, `sfo3`/`sfo2` single-AZ) across four consecutive PgCache releases (**0.6.3**, **0.6.4**, **0.7.0**, and **0.7.1**):

| Active Tenants | Origin (Path A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio | Warm Passes |
|---|---|---|---|---|---|---|---|
| **1** | 23.3–27.5 ms (291–343 rps) | **17.6 ms** (455 rps, +56%) | **16.8 ms** (476 rps, +61%) | **15.6 ms** (513 rps, +50%) | **16.6 ms** (481 rps, +40%) | **100.0%** | 2 |
| **10** | 22.9–27.7 ms (288–350 rps) | **17.8 ms** (451 rps, +52%) | **21.0 ms** (382 rps, +33%) | **22.9 ms** (349 rps, +4%) | **21.7 ms** (369 rps, +5%) | **100.0%** | 2 |
| **50** | 25.4–29.9 ms (267–315 rps) | **17.5 ms** (456 rps, +66%) | **15.8 ms** (506 rps, +90%) | **17.3 ms** (462 rps, +64%) | **17.0 ms** (470 rps, +49%) | **100.0%** | 2–3 |
| **100** | 25.2–30.3 ms (264–317 rps) | **19.4 ms** (412 rps, +56%) | **16.3 ms** (492 rps, +55%) | **17.2 ms** (465 rps, +51%) | **16.3 ms** (491 rps, +63%) | **100.0%** | 2–3 |
| **500** | 24.4–32.2 ms (248–329 rps) | **16.7 ms** (478 rps, +93%) | **15.7 ms** (510 rps, +71%) | **18.7 ms** (428 rps, +38%) | **16.3 ms** (490 rps, +49%) | **100.0%** | 3–4 |
| **1,000** | 24.0–26.2 ms (305–333 rps) | **17.5 ms** (458 rps, +50%) | **16.8 ms** (476 rps, +46%) | **17.2 ms** (466 rps, +52%) | **16.9 ms** (473 rps, +42%) | **100.0%** | 3–4 |
| **2,000** | 23.3–26.0 ms (308–343 rps) | **18.3 ms** (438 rps, +40%) | **15.5 ms** (515 rps, +67%) | **18.8 ms** (425 rps, +38%) | **16.5 ms** (485 rps, +41%) | **100.0%** | 4–6 |

**Key observations from the 2,000-tenant run**:
- **The hit ratio held at 100.0% in every cell** across all versions. Even with 2,000 active tenants and 200,000 potential query variations, the cache accommodated the working set without evicting active keys.
- **Warm-up scaling was strictly sublinear**: 1–100 tenants settled in 2–3 passes, 500–1,000 tenants in 3–4 passes, and 2,000 tenants in 4–6 passes.
- **Throughput gain remained positive throughout**: PgCache delivered between **+38% and +93% higher throughput** than the uncached database on standard low-cost cloud droplets.

For detailed breakdowns by version, see the [`results/`](results/) directory.

### 12.2 Side-by-Side: Baseline vs Tuned Network & Engine Profile

To maximize PgCache throughput and eliminate network and concurrency bottlenecks, we implemented a **Tuned Profile**:
- **Linux Network Stack Tuning**: Privileged `tune-net-stack` initContainer configuring `tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_max_syn_backlog=65535`, `tcp_tw_reuse=1`, and VirtIO RPS packet steering across all vCPUs (`rps_cpus=f`).
- **PgCache Sizing**: `NUM_WORKERS=8` (matching droplet vCPU concurrency), `MEMO_CACHE_SIZE=1073741824` (1 GiB raw integer bytes), and `PGCACHE_POPULATION_WORKERS_MIN=4`.
- **Direct Node IP Routing**: Bypassed CoreDNS latency through direct `/etc/hosts` mappings and direct pod IP addressing.

| Active Tenants | Baseline Origin | Baseline PgCache | Baseline Gain | Tuned Origin | Tuned PgCache | Tuned Gain | Hit Ratio | Warm Passes |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23.3 ms · 343 rps | 15.6 ms · 513 rps | +50% | 30.4 ms · 263 rps | 24.0 ms · 333 rps | +27% | 100.0% | 2 |
| **10** | 23.9 ms · 335 rps | 22.9 ms · 349 rps | +4% | 33.1 ms · 242 rps | 22.0 ms · 363 rps | +50% | 100.0% | 2 |
| **50** | 28.5 ms · 281 rps | 17.3 ms · 462 rps | +64% | 32.7 ms · 245 rps | 21.5 ms · 371 rps | +51% | 100.0% | 2 |
| **100** | 26.0 ms · 307 rps | 17.2 ms · 465 rps | +51% | 33.0 ms · 243 rps | 19.3 ms · 414 rps | **+70%** | 100.0% | 2 |
| **500** | 25.7 ms · 311 rps | 18.7 ms · 428 rps | +38% | 30.0 ms · 266 rps | 22.3 ms · 359 rps | +35% | 100.0% | 3 |
| **1,000** | 26.0 ms · 307 rps | 17.2 ms · 466 rps | +52% | 33.2 ms · 241 rps | 19.7 ms · 405 rps | **+68%** | 100.0% | 3 |
| **2,000** | 25.9 ms · 309 rps | 18.8 ms · 425 rps | +38% | 34.2 ms · 234 rps | 20.5 ms · 390 rps | **+67%** | 100.0% | 4 |

**Tuned Profile Takeaway**:
Under large tenant counts (2,000 tenants), throughput gain increased from **+38% (baseline)** to **+67% (tuned)**, while sustaining an unbroken **100.0% cache hit ratio**. Full artifacts and raw logs are located in [`results/tuned/`](results/tuned/README.md).

---

## 13. Sweep 2 — separating caching from saturation

**Script: [`scripts/02-concurrency-sweep.sh`](scripts/02-concurrency-sweep.sh)**

A large number at high concurrency is **two effects added together**, and only
one of them follows a reader home.

| clients | origin | PgCache | gain |
|---:|---|---|---:|
| 1 | 32.2 ms · 31 rps | 5.07 ms · 197 rps | **+535%** |
| 4 | 53.5 ms · 75 rps | 5.63 ms · 711 rps | +848% |
| 8 | 83.1 ms · 96 rps | 7.09 ms · 1,129 rps | +1076% |
| 16 | 148.7 ms · 108 rps | 11.80 ms · 1,356 rps | +1156% |
| 32 | 290.6 ms · 110 rps | 23.35 ms · 1,370 rps | +1145% |

### The first row is caching, alone

With one client there is **no queueing anywhere** — not at the origin, not at the
proxy. Nothing waits for anything. And PgCache still answers in 5.07 ms against
32.2 ms.

**That is 6.4× faster, with no help from concurrency at all.**

This is the number that transfers. A reader whose database is not under pressure
should expect something of this shape, not the bottom row.

### The rest is the origin falling over

Read the origin column top to bottom: 31 to 110 requests per second, then it
stops. From 16 clients to 32 it gains **two** requests per second while latency
nearly doubles, 148.7 to 290.6 ms.

Textbook saturation: past the knee, additional concurrency buys queueing rather
than throughput.

PgCache over the same step goes 1,356 to 1,370 rps, latency 11.8 to 23.4 ms. It
is approaching its own limit but has not turned over.

A dashboard at **290 ms** is one a user experiences as broken. The same dashboard
through the cache answers in **23 ms**.

### Why the two effects must be reported separately

Quote only the bottom row — "12× faster!" — and you are describing a database
that is already failing. That is a real and common situation, but it is a
different claim from "the cache makes requests faster", and conflating them is
how benchmarks mislead.

Both are true. They answer different questions:

- *"Will this make my dashboard faster?"* → **6.4×**, the single-client row.
- *"Will this save me when my database is at its limit?"* → **12×**, the bottom
  row.

---

## 14. Sweep 3 — writes

**Script: [`scripts/03-write-sweep.sh`](scripts/03-write-sweep.sh)**
**Workload: [`workload/write.sql`](workload/write.sql)**

An earlier campaign in this lab had produced an apparently devastating result,
and this sweep exists to find out whether it generalised.

### What the earlier campaign found

That campaign mixed reads and writes over a single-table point-select workload:

| writes | origin | PgCache | gain |
|---:|---:|---:|---:|
| 0% | 36,376 tps | 49,690 tps | **+37%** |
| 10% | 12,573 tps | 12,308 tps | **−2%** |

At a perfectly ordinary OLTP write ratio, the advantage was **gone**.

### The hypothesis tested here

In that campaign, reads and writes hit **the same 1,000 keys** — the worst
possible case for invalidation. Real applications write to a small subset and
read from a much larger one.

So `write.sql` takes a second variable:

```
\set t random(1, :wtenants)
```

Reads draw tenants from `1..200`; writes draw from `1..:wtenants`. Setting
`wtenants=1` concentrates every write on one tenant while reads span all 200.

If concentration were the explanation, `wtenants=1` should look much better.

### The results

| writes | write tenants | origin | PgCache | gain | hit ratio |
|---:|---:|---|---|---:|---:|
| 0% | — | 83.2 ms · 96 rps | 7.10 ms · 1,127 rps | +1074% | 100% |
| 5% | 1 | 79.0 ms · 101 rps | 7.20 ms · 1,111 rps | +1000% | 100% |
| 5% | 10 | 79.9 ms · 100 rps | 7.30 ms · 1,096 rps | +996% | 100% |
| 5% | 200 | 79.8 ms · 100 rps | 7.50 ms · 1,067 rps | +967% | 100% |
| 10% | 1 | 78.5 ms · 102 rps | 7.42 ms · 1,079 rps | +958% | 100% |
| 10% | 200 | 77.9 ms · 103 rps | 7.55 ms · 1,060 rps | **+929%** | 100% |

**At 10% writes the gain is still +929%**, where the earlier campaign gave −2%.

### The concentration hypothesis was also wrong

Compare the two 10% rows: concentrated on one tenant, **+958%**; spread over all
200, **+929%**.

Twenty-nine percentage points on a gain of about 950 — and section 11 measured
this benchmark's run-to-run spread at around 0.3%. The difference is real but
tiny. **Concentration is not what decided the earlier campaign.**

### What actually decides it: the share of the clock

The real variable is the **ratio of read cost to write cost**, and the arithmetic
fits on one line.

In the earlier campaign a read cost **0.191 ms** and a write **4.879 ms** —
about 25× more. With 10% of transactions writing:

```
        0.10 × 4.879
──────────────────────────────  =  0.488 / 0.660  ≈  74%
0.10 × 4.879 + 0.90 × 0.191
```

**Three quarters of the clock was writes.** And writes pass through both paths
*identically* — the cache neither accelerates nor delays them. So it could only
compete for the remaining quarter, and no amount of read acceleration could show
up in the total.

The clearest evidence this was never a caching effect: the **uncached** path also
collapsed, 36,376 tps to 12,573, when one transaction in ten became a write. The
bottleneck had stopped being the read for *both* paths at once.

Here the ratio is inverted. A read is an eight-statement dashboard costing the
origin ~79 ms; a write is a single indexed `UPDATE`. At the same 10% ratio the
writes take a negligible share of the clock.

> **The rule is not "what fraction of transactions write". It is "what fraction
> of the time do the writes consume".** The two only coincide when reads are
> cheap.

The corrected test: measure your read and write costs separately, compute
`w·W / (w·W + (1−w)·R)`, and if it is above roughly half, the cache cannot reach
the part of the request that matters — whatever its hit ratio.

---

## 15. Why the query shape decides everything

A probe run just before this benchmark measured ten query shapes in isolation,
each against both paths:

| shape | origin | PgCache | gain |
|---|---:|---:|---:|
| primary-key lookup | 0.228 ms | 0.165 ms | +38% |
| `COUNT(*)` with `WHERE` | 0.241 ms | 0.162 ms | +48% |
| `ORDER BY … LIMIT` | 0.258 ms | 0.174 ms | +48% |
| `GROUP BY` + aggregate | 0.259 ms | 0.168 ms | +54% |
| `IN (10 ids)` | 0.261 ms | 0.182 ms | +44% |
| `LEFT JOIN` | 0.292 ms | 0.173 ms | +69% |
| two-table join | 0.330 ms | 0.171 ms | +92% |
| correlated `EXISTS` | 0.392 ms | 0.176 ms | +123% |
| three-table join | 0.431 ms | 0.179 ms | +141% |
| FK listing + `LIMIT` | 0.429 ms | 0.163 ms | +163% |

Read PgCache's column top to bottom: **0.162 to 0.182 ms**. A 12% spread between
the cheapest query in the set and the most expensive.

Now the origin's: **0.228 to 0.431 ms**. An 89% spread.

> **PgCache charges a nearly fixed price per answer. The origin charges for the
> work. The gain is, almost exactly, how much work the query costs the origin.**

Everything else follows from that one sentence.

- A multi-tenant dashboard — eight statements, aggregations, joins over a
  tenant's thousands of rows — costs the origin 32 to 83 ms and costs the cache
  the same as anything else. Hence an order of magnitude.
- The authorisation service from section 4 was the exact inverse: ~40 µs per
  query on the origin, no work to save, only proxy overhead multiplied by
  amplification.

It also explains why so many database benchmarks find caches unimpressive. They
run primary-key lookups, which are the **bottom row** of that table. **The
cheapest query is a cache's worst case.**

### 15.1 Sweep 4 — Complex Multi-Tenant SaaS Scenarios (PgCache 0.7.1)

**Script: [`scripts/04-complex-sweep.sh`](scripts/04-complex-sweep.sh)**  
**Workloads: [`complex-search.sql`](workload/complex-search.sql), [`complex-joins.sql`](workload/complex-joins.sql), [`complex-analytics.sql`](workload/complex-analytics.sql), [`complex-dashboard.sql`](workload/complex-dashboard.sql)**  
**Report: [`results/0.7.1/README.md`](results/0.7.1/README.md)**

To test the corollary of that rule — what happens when a multi-tenant SaaS
executes genuinely heavy relational screens — we expanded the benchmark with four
complex workload suites evaluated on **PgCache `0.7.1`** on **3-Node DigitalOcean Kubernetes (DOKS)**:

1. **Substring Text Search (`complex-search.sql`)**: 4 statements combining `ILIKE '%...%'` searches across customer emails/names, product names, seller names, and review bodies with 2-to-4 table `INNER JOIN` and `LEFT JOIN` chains.
2. **Deep Multi-Table Joins (`complex-joins.sql`)**: 4 statements traversing 4-to-6 table `INNER JOIN` and `LEFT JOIN` chains (`orders -> customer -> order_item -> product -> category -> seller -> review`), preserving zero-order customer cohorts (`LEFT JOIN orders`) and unreviewed product inventory (`LEFT JOIN review`).
3. **Multi-Dimensional Analytics (`complex-analytics.sql`)**: 4 statements running multi-column `GROUP BY`, conditional `FILTER (WHERE ...)`, `CASE WHEN` fulfillment and price-tier buckets, and `HAVING` rollups.
4. **Unified Complex Screen (`complex-dashboard.sql`)**: 8-statement enterprise analytics & search screen combining 2 search queries, 3 deep multi-table `JOIN` / `LEFT JOIN` queries, and 3 heavy analytical rollups.

#### Workload Complexity Comparison (`TENANTS=200`, `CLIENTS=8` — 3-Node DOKS)

| Scenario | Statements | DOKS Origin (Path A) | DOKS PgCache 0.7.1 (Path B) | DOKS Gain (Speedup) | Hit Ratio | Warm Passes |
|---|---:|---|---|---:|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 23.06 ms · 347 rps | **15.92 ms · 503 rps** | **+45% (1.45×)** | 100.0% | 2 |
| **`search`** (`complex-search.sql`) | 4 | 74.26 ms · 108 rps | **5.04 ms · 1,586 rps** | **+1,369% (14.7×)** | 100.0% | 3 |
| **`joins`** (`complex-joins.sql`) | 4 | 148.87 ms · 54 rps | **4.73 ms · 1,692 rps** | **+3,033% (31.3×)** | 100.0% | 3 |
| **`analytics`** (`complex-analytics.sql`) | 4 | 102.38 ms · 78 rps | **5.69 ms · 1,406 rps** | **+1,703% (18.0×)** | 100.0% | 4 |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 204.39 ms · 39 rps | **11.50 ms · 696 rps** | **+1,685% (17.8×)** | 100.0% | 5 |

#### Concurrency Scaling on `complex-dashboard.sql` (`TENANTS=200` — 3-Node DOKS)

| Clients | DOKS Origin (Path A) | DOKS PgCache 0.7.1 (Path B) | DOKS Gain (Speedup) | Hit Ratio | Warm Passes |
|---:|---|---|---:|---:|---:|
| **1** | 100.60 ms · 10 rps | **7.14 ms · 140 rps** | **+1,300% (14.0×)** | 100.0% | 2 |
| **4** | 129.45 ms · 31 rps | **8.60 ms · 465 rps** | **+1,400% (15.0×)** | 100.0% | 2 |
| **8** | 212.81 ms · 38 rps | **10.48 ms · 763 rps** | **+1,908% (20.1×)** | 100.0% | 2 |
| **16** | 406.90 ms · 39 rps | **18.06 ms · 886 rps** | **+2,172% (22.7×)** | 100.0% | 2 |
| **32** | 835.52 ms · 38 rps | **31.36 ms · 1,020 rps** | **+2,584% (26.8×)** | 100.0% | 2 |

#### Two Architectural Findings from the Complex Sweeps

1. **Two-Stage Caching in PgCache `0.7.1` (Table Subsumption vs. Materialized View Admission Gate)**:
   - On `dashboard.sql` (`dash_base`), queries execute against populated base tables (`public.*`) inside PgCache's embedded PostgreSQL instance (`15.92 ms` vs `23.06 ms` on DOKS, **1.45× faster**).
   - On `complex-*.sql`, queries pass PgCache's **Materialized View Admission Gate** (`pgcache_cache_mv_gate{outcome="admit"} == 12/12`: `OFFSET 0`, non-nullable entity `GROUP BY` keys, and pre-aggregation rows `>= 1,000` or reduction ratio `>= 10:1`). PgCache pre-computes each 4-to-6 table `JOIN`/`GROUP BY`/`ILIKE` result into `pgcache_mv.q_<hash>` and serves subsequent hits via `pgcache_cache_mv_hits` in **~1.18–1.44 ms per statement across physical nodes on DOKS** (`11.50 ms` for 8 statements vs `204.39 ms` on Origin — **17.8× faster** at 8 clients, **26.8× faster** at 32 clients, and **31.3× faster** on `complex-joins.sql`).
2. **Where Complex Materialized Views Hit Their Limits (Cold-Start Working-Set Scaling & `INNER JOIN` vs `LEFT JOIN` Write Invalidation)**:
   - **Cold-Start Working-Set Scaling**: On 3-node DOKS, PgCache warms **100.0% of the working set from 1 to 500 tenants (`4,000` complex queries)** (`+2,133%` at 1 tenant, `+1,774%` at 200 tenants, and `+1,108%` at 500 tenants). At 1,000 tenants (`8,000` complex queries), uniform random sampling across 1,000 tenants combined with per-tenant cold population cost warms `68.1%` on DOKS within the bounded 8-pass (15s) warm-up window.
   - **`INNER JOIN` In-Place CDC vs. `LEFT JOIN` Outer Invalidation Under Writes**: When `UPDATE orders` runs at 5%–10% write ratios, the **5 `INNER JOIN` queries (`62.5%`)** in `complex-dashboard.sql` (which include explicit `WHERE ... AND o.tenant_id = :t` predicates) apply non-key updates in-place via CDC (`cdc_update`) and background MV rebuilds (`pgcache_cache_mv_rebuilds`), remaining **100% cache hits**. By contrast, the **3 `LEFT JOIN` queries (`37.5%`)** (where `o.tenant_id = :t` resides in the outer-join `ON` clause to preserve zero-order customers) undergo conservative invalidation on `orders` writes, settling the overall hit ratio at **63.1%–75.0% on DOKS**. See [`results/0.7.1/README.md`](results/0.7.1/README.md) for the complete breakdown.

### 15.2 Sweep 5 — 1h30m endurance & Origin resource offload (DOKS + Grafana Cloud)

**Driver: [`scripts/05-endurance-90m.sh`](scripts/05-endurance-90m.sh)** ·
**Telemetry Stack: [`scripts/deploy-monitoring.sh`](scripts/deploy-monitoring.sh)** ·
**Grafana Cloud Dashboard: [`https://pgcachebench.grafana.net/`](https://pgcachebench.grafana.net/)** ([`infra/grafana/pgcache-endurance-dashboard.json`](infra/grafana/pgcache-endurance-dashboard.json)) ·
**Runbook & Methodology: [`results/endurance-90m/README.md`](results/endurance-90m/README.md)**

To measure continuous hardware resource offloading on the Origin PostgreSQL server (CPU utilization by mode, memory working set, `do-block-storage` Disk Read/Write IOPS and MB/s, active backend connections, tuple scan rates, and logical replication WAL lag) over a sustained 90-minute horizon, Sweep 5 scales the dataset to **`SCALE=20` (~10 GB: 10M orders, 40M line items, 2M customers across 1,000 tenants — 20× larger than Origin's `shared_buffers=512MB`)** and runs six consecutive phases:

| Phase ID | Duration | Block & Target | Workload Mix | Telemetry Objective |
| :---: | :---: | :--- | :--- | :--- |
| **Phase 1** | **30 min** (`1800s`) | **Block 1 — Origin Direct (`Path A`)** | `100% Read` (`complex-dashboard.sql`) | Baseline Origin CPU saturation, Disk Read IOPS/MBs, active backends, and tuple scans |
| **Phase 2** | *Dynamic* (`warm_until_settled`) | **Block 1 — PgCache Warm-up** | `100% Read` (`complex-dashboard.sql`) | Base-table population and Materialized View construction until hit rate settles (`< 1%`) |
| **Phase 3** | **30 min** (`1800s`) | **Block 1 — PgCache Proxy (`Path B`)** | `100% Read` (`complex-dashboard.sql`) | **Origin Offload**: Origin CPU, Disk Read IOPS, and active backends drop to near zero while TPS surges |
| **Phase 4** | **15 min** (`900s`) | **Block 2 — Origin Direct (`Path A`)** | `95% Read` + `5% Write` (`write.sql`) | Origin under combined analytical reads and transactional `UPDATE`s + WAL flushes |
| **Phase 5** | *Dynamic* (`warm_until_settled`) | **Block 2 — PgCache CDC Warm-up** | `95% Read` + `5% Write` (`write.sql`) | Stabilizes logical replication CDC invalidation loop under active writes |
| **Phase 6** | **15 min** (`900s`) | **Block 2 — PgCache Proxy (`Path B`)** | `95% Read` + `5% Write` (`write.sql`) | Origin processes only the 5% write stream and WAL CDC replication while PgCache serves reads |

All telemetry is streamed every 5–10 seconds to **[https://pgcachebench.grafana.net/](https://pgcachebench.grafana.net/)** with `grafana-alloy`, `postgres-exporter`, and `pgbench-exporter` pinned to the `loadgen` node (`bench_role=loadgen`) for zero observer CPU interference on `origin` and `pgcache`.

#### Measured 1h30m Endurance Results (`SCALE=20`, `54.5M` Rows / `5.86 GB`, `ACTIVE_TENANTS=100`, `CLIENTS=8`)

| Block / Scenario | Duration | Path A (Origin) Avg Latency | Path A TPS | Path B (PgCache) Avg Latency | Path B TPS | Steady-State Final 10m TPS | Cache Hit % | Overall TPS Gain | Total Txns (`A` vs `B`) |
| :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **Block 1: 100% Read** (`read_1800s`) | **30m + 30m** | `16,865.88 ms` | `0.47` | **`11,091.45 ms`** | **`0.72`** | **`1.60–1.90 TPS`** | `47.1%` | **`+51.8%`** (up to **`4.0×`**) | `856` vs **`1,304`** |
| **Block 2: 95% Read / 5% Write** (`rw_5pct_900s`) | **15m + 15m** | `16,462.09 ms` | `0.48` | **`11,970.92 ms`** | **`0.66`** | **`1.80–2.10 TPS`** | `62.1%` | **`+37.1%`** (up to **`4.3×`**) | `444` vs **`610`** |

- **Origin Write Acceleration (`2.21×` Faster Writes)**: In Block 2, offloading complex analytical reads to PgCache relieved Origin CPU and block-storage I/O contention, cutting transactional `UPDATE` (`write.sql@5`) average latency in half from **`226.96 ms` on Origin Direct** down to **`102.89 ms` via PgCache** (`-54.7%` latency).
- **Zero Evictions & 100% Stability (`pgcache_cache_evictions = 0`, `pgcache_queries_uncacheable = 0`)**: Across the entire 90-minute soak (`16,401` queries), PgCache operated at `3.39 GiB / 3.50 GiB` (`96.7%` of `MEMORY_LIMIT`) with its high-watermark admission controller cleanly pinning `607 / 800` complex tenant Materialized Views in RAM without a single eviction or restart. See [`results/endurance-90m/README.md`](results/endurance-90m/README.md) for the full telemetry breakdown.

---

## 16. What this does not prove

Five limits worth keeping in view.

### The correctness gate: originally missing, now enforced in `0.7.1`

Other campaigns in this lab blocked publication of any performance number until
they had compared, query by query, the origin's answer against the cache's.
**The original campaign published without that.**

Those gates always passed — thousands of comparisons across three subjects, zero
divergences, including a test that sampled reads *while* writes were in flight
and found 1,931 conclusive comparisons with none divergent.

To close that gap for both simple and complex multi-tenant query shapes (4-to-6
table `INNER JOIN` and `LEFT JOIN` chains, `ILIKE '%...%'` substring search,
`GROUP BY` with `FILTER`/`CASE`/`HAVING`, and `ORDER BY` limits), we added
[`scripts/verify-correctness.sh`](scripts/verify-correctness.sh) and ran it
against PgCache `0.7.1` on both 3-node DOKS ([`results/0.7.1/verify-correctness-doks.txt`](results/0.7.1/verify-correctness-doks.txt)) and Local Docker ([`results/0.7.1/verify-correctness.txt`](results/0.7.1/verify-correctness.txt)):
- **12/12 complex queries** returned byte-for-byte identical rows between Origin and PgCache across Pass 1 (miss), Pass 2 (base-table hit + MV build), and Pass 3 (warm MV hit).
- **`pgcache_queries_uncacheable` delta = `0`** (`36/36` cacheable), **`pgcache_cache_mv_gate{outcome="admit"}` = `12/12` (`reject = 0`)**, and **`pgcache_cache_mv_hits` delta = `12/12`**.

### Mean latency only

pgbench reports the mean natively; percentiles need per-transaction logging,
which this run did not collect. For a latency claim the mean is the weakest
statistic available, because a cache's damage lives in the tail — a miss costs
several times a hit.

Two rules worth carrying if you add percentiles: filter them to the read script
when writes are in the mix (otherwise you are describing WAL flush), and
**refuse** to report below a few hundred samples. That second rule was learned
the honest way — a slow cell produced a "p99" of 296 ms against a **mean of
794 ms**, arithmetically impossible, and the tell that four samples is not a
measurement.

### One data size, and it fits in memory

463 MB against 1 GB of `shared_buffers`. As section 7.2 explained, that is the
hardest case for the cache and the result is conservative on that axis — and
Section 15.2 (`scripts/05-endurance-90m.sh`) extends this to a **~10 GB (`SCALE=20`)**
dataset against `512 MB` of `shared_buffers` over a 1h30m endurance run.

### Two hundred tenants is not twenty thousand

The curve was flat from 1 to 200 (and up to 2,000 on DOKS for `dashboard.sql`).
Nothing guarantees it stays flat at 20,000, where the query space is an order of
magnitude larger — and as section 15.1 showed, complex multi-table Materialized
Views require longer warm-up windows once active tenants reach 1,000 (`8,000` distinct complex queries).
**The flatness of the baseline curve is not a licence to extrapolate.**

### There is no application-level cache in the comparison

This measures a cache against an *uncached* database. Many real applications
already cache in their own process or in Redis, and such a cache **eliminates**
the query rather than accelerating it — a different and often stronger thing.

This benchmark cannot make that comparison, because there is no application
here. It measures the product's envelope under application-shaped load. **It is
not an adoption verdict.**

---

## 17. Appendix: every file

```
pgcache-multi-tenant/
├── README.md                        this document
├── README-pt.md                     Portuguese version
├── AGENTS.md                        repository guidelines & 3-agent skill team
├── .env.grafana.example             template for Grafana Cloud remote_write credentials
├── .agents/
│   └── skills/
│       ├── pgcache-benchmark/       Benchmark Coordinator skill
│       ├── pgcache-complex-scenarios/ Complex SQL & correctness gate skill
│       └── pgcache-metrics-analyst/ Telemetry & Amdahl's Law analyst skill
├── infra/
│   ├── grafana/
│   │   └── pgcache-endurance-dashboard.json Ready-to-import Grafana Cloud dashboard
│   ├── monitoring/
│   │   └── grafana-cloud-monitoring.yaml    node-exporter, postgres-exporter, pgbench-exporter & Alloy
│   ├── terraform/
│   │   └── aks/                     Ultra-low-cost Azure AKS + 3-node Spot Terraform
│   ├── k8s/
│   │   ├── 00-namespace-and-secret.yaml
│   │   ├── 01-origin.yaml           PostgreSQL, every flag explained
│   │   ├── 02-pgcache.yaml          the cache, every variable explained
│   │   ├── 03-loadgen.yaml          pgbench + results volume
│   │   └── 04-metrics-reader.yaml   the pod that can scrape metrics
│   ├── helm/
│   │   └── pgcache-mt/              Helm chart for Kubernetes deployment
│   └── docker-compose.yml           laptop setup (shape, not magnitudes)
├── sql/
│   ├── 01-schema.sql                7 tables, seed, ORM-style indexes
│   └── 02-tenant.sql                tenant_id denormalisation + indexes
├── workload/
│   ├── dashboard.sql                the 8-statement operational request
│   ├── write.sql                    the write, with :wtenants
│   ├── complex-search.sql           4-statement ILIKE '%...%' + JOIN search workload
│   ├── complex-joins.sql            4-statement 4-to-6 table JOIN & LEFT JOIN workload
│   ├── complex-analytics.sql        4-statement GROUP BY / FILTER / CASE / HAVING workload
│   └── complex-dashboard.sql        unified 8-statement complex analytics & search screen
├── scripts/
│   ├── lib.sh                       scrape, run, warm_until_settled, reset_pgcache, cell
│   ├── 00-setup.sh                  apply schema, copy workload into the pod
│   ├── 01-tenant-sweep.sh
│   ├── 02-concurrency-sweep.sh
│   ├── 03-write-sweep.sh
│   ├── 04-complex-sweep.sh          complex scenario, tenant, client & write sweeps
│   ├── 05-endurance-90m.sh          1h30m endurance & resource offload campaign (30+30m read, 15+15m R/W)
│   ├── deploy-monitoring.sh         deploys Grafana Cloud telemetry stack to Kubernetes
│   ├── verify-correctness.sh        differential correctness, cacheability & MV gate
│   ├── aks-cluster.sh               turnkey Azure AKS Spot Terraform helper
│   ├── do-cluster.sh                turnkey DigitalOcean DOKS helper
│   └── run-tag-verification.sh      automated tag verification runner
├── data/
│   └── results.tsv                  all 15 cells, machine-readable
└── results/                         multi-version results by tag
    ├── README.md                    cross-version comparison (English)
    ├── README-pt.md                 cross-version comparison (Portuguese)
    ├── 0.6.3/                       results for PgCache 0.6.3
    ├── 0.6.4/                       results for PgCache 0.6.4
    ├── 0.7.0/                       results for PgCache 0.7.0
    ├── 0.7.1/                       results & complex scenarios for PgCache 0.7.1
    ├── endurance-90m/               1h30m endurance & Origin resource offload runbook
    └── tuned/                       tuned network & engine profile results
```

### A note on the scripts

The campaign as it actually ran was driven by ad-hoc bash typed at a prompt, and
the SQL lived in `/tmp` inside a pod. The scripts here are cleaned-up equivalents
that perform the same measurements with the same parameters in the same order —
not a verbatim transcript.

That gap is worth recording on its own. A benchmark whose artifacts exist only
inside a running pod is not reproducible, and nobody notices until the pod is
gone. This repository exists partly to close it.
