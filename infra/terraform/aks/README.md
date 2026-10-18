# Ultra-Low-Cost Azure AKS Terraform Configuration

**[Leia em Português (README-pt.md)](README-pt.md)**

This directory contains the Terraform configuration for provisioning the **lowest-cost possible Azure Kubernetes Service (AKS)** cluster that preserves 100% of the hardware, single-AZ network topology, and Spot node pool specifications used in the `pgcache-bench-multi-tenant` benchmark.

---

## 1. Why Azure Portal Defaults Inflate AKS Costs (and How This Terraform Fixes It)

When creating an AKS cluster through the Azure Portal wizard, Azure enables multiple paid management tiers, observability agents, and networking defaults that often cost **3× to 5× more than the Spot worker VMs themselves** — while also running background `DaemonSet` agents on worker nodes that steal CPU cycles and introduce p99 latency noise.

| Component / Setting | Azure Portal Default (High Cost) | This Terraform Configuration (`infra/terraform/aks/`) | Cost & Benchmark Impact |
|---|---|---|---|
| **Control Plane Tier (`sku_tier`)** | `Standard` (**$0.10/hr = ~$73/mo**) | **`Free` ($0.00/hr)** | **Saves $73/mo.** Identical Kubernetes API server without paying for the uptime SLA fee. |
| **Container Insights / Log Analytics (`oms_agent`)** | Enabled (~$2.76/GB ingested + log retention) | **Disabled (block omitted)** | **Saves $10–$50+/run.** Prevents `ama-logs` DaemonSet from scraping stdout/stderr during high-RPS `pgbench` sweeps. |
| **Azure Managed Prometheus (`monitor_metrics`)** | Enabled (per-sample ingestion billing) | **Disabled (block omitted)** | **$0 cost.** Benchmark metrics are scraped directly from PgCache `:9090/metrics` via the lightweight `metrics-reader` pod (`alpine:3.20`). |
| **Azure Managed Grafana** | Often linked in Portal (~$0.09/hr per active user/instance) | **Disabled** | **$0 cost.** No external Grafana workspace created. |
| **Microsoft Defender for Containers** | Enabled (~$7/vCore/month) | **Disabled (block omitted)** | **Saves ~$180/mo (on 26 vCores)** and eliminates eBPF security sensor CPU overhead during benchmark runs. |
| **Azure Policy & Cost Analysis** | Enabled | **`azure_policy_enabled = false`, `cost_analysis_enabled = false`** | Eliminates Gatekeeper webhook latency and background cost agent pods. |
| **Storage CSI Drivers** | Disk + Files + Blob + Snapshot Controller | **Only `disk_driver_enabled = true`** | Keeps `managed-csi` for PostgreSQL PVCs while disabling unused File/Blob/Snapshot CSI pods. |
| **Outbound Networking** | Managed NAT Gateway (**~$0.045/hr = ~$33/mo** + per-GB fee) | **`loadBalancer` (`managed_outbound_ip_count = 1`)** | **Saves ~$33/mo.** Uses a single standard outbound IP with `azure` CNI Overlay (`network_plugin_mode = "overlay"`). |
| **Availability Zones (`zones`)** | Zones `1, 2, 3` (**$0.01/GB** cross-AZ transfer + ~500 µs RTT) | **Single Zone (`zones = ["1"]`)** | **$0.00/GB cross-AZ transfer** and **~160 µs inter-node RTT** (required by `README.md` Section 7.1). |
| **Default `system` Node Pool** | 2–3× On-Demand `Standard_D2s_v5` / `D4s_v5` | **1× `Standard_B2als_v2`** (`only_critical_addons_enabled = true`) | **~$0.018–$0.032/hr.** Azure forbids Spot on the default `System` pool, so we isolate `kube-system` + `metrics-reader` onto 1 tiny burstable node. |
| **Benchmark `benchspot` Pool** | On-Demand or Multi-AZ | **3× Spot VMs (`priority = "Spot"`, `eviction_policy = "Delete"`)** | **~80–88% Spot discount** (~$0.038–$0.055/hr per `Standard_D8as_v5` node, or ~$0.025/hr per `Standard_E4s_v5`). |
| **Node OS Disks (`os_disk_size_gb`)** | 128 GiB Premium SSD per node (~$19.71/mo × 4 = **~$79/mo**) | **`30 GiB` OS disk** (or `Ephemeral` $0 disk on `d`-series SKUs) | **Cuts OS disk cost by 76%–100%.** |

### Total Estimated Hourly Cost While Running

| Resource | Configuration | Estimated Hourly Cost (`eastus2`) |
|---|---|---:|
| **AKS Control Plane** | `sku_tier = "Free"` | **$0.000 / hr** |
| **Observability (Prometheus / Grafana / OMS)** | Explicitly disabled | **$0.000 / hr** |
| **1× System Node (`system`)** | `Standard_B2als_v2` (2 vCPU, 4 GiB RAM) | **~$0.019 / hr** |
| **3× Spot Benchmark Nodes (`benchspot`)** | `3 × Standard_D8as_v5` Spot (8 vCPU, 32 GiB RAM each) | **~$0.115 – $0.165 / hr total** |
| **Alternative 4-vCPU Spot Pool** | `3 × Standard_E4s_v5` Spot (4 vCPU, 32 GiB RAM each) | **~$0.075 – $0.105 / hr total** |
| **Cross-AZ Data Transfer** | Single Availability Zone (`zones = ["1"]`) | **$0.000 / hr** |
| **Total Cluster Runtime Cost** | **Full 4-node cluster (1 System + 3 Spot)** | **~$0.10 – $0.19 / hr** |

---

## 2. Node Pool Architecture & Pod Scheduling

Azure AKS enforces a hard API rule: the `default_node_pool` must have `mode = "System"` and **cannot use `priority = "Spot"`**.

To achieve the lowest possible cost while guaranteeing strict hardware isolation for the benchmark:

1. **`system` Default Node Pool (1× `Standard_B2als_v2`, On-Demand)**:
   - Configured with `only_critical_addons_enabled = true`, which automatically taints the node with `CriticalAddonsOnly=true:NoSchedule`.
   - Hosts `kube-system` control-plane agents (`coredns`, `konnectivity-agent`, `csi-azuredisk-controller`) plus the idle `metrics-reader` pod (`alpine:3.20`, `50m` CPU / `64Mi` RAM).
   - **Zero benchmark pods (`origin`, `pgcache`, `loadgen`) can ever schedule on this node.**
2. **`benchspot` User Node Pool (3× Spot VMs, Single AZ)**:
   - Configured with `mode = "User"`, `priority = "Spot"`, `eviction_policy = "Delete"`, `spot_max_price = -1`, and `zones = ["1"]`.
   - Azure automatically attaches label `kubernetes.azure.com/scalesetpriority=spot` and taint `kubernetes.azure.com/scalesetpriority=spot:NoSchedule`.
   - Both [`infra/helm/pgcache-mt/values-aks-tuned.yaml`](../../helm/pgcache-mt/values-aks-tuned.yaml) and [`infra/helm/pgcache-mt/values-aks.yaml`](../../helm/pgcache-mt/values-aks.yaml) configure `nodeSelector` and `tolerations` for `kubernetes.azure.com/scalesetpriority: spot` alongside `podAntiAffinity` (`lab/role`), placing:
     - **Spot Node 1**: `origin-0` (`postgres:17`, `shared_buffers=1GB`, `wal_level=logical`)
     - **Spot Node 2**: `pgcache` (`pgcache/pgcache:0.7.1`, `NUM_WORKERS=8`, `MEMO_CACHE_SIZE=1GiB`)
     - **Spot Node 3**: `loadgen` (`postgres:17` / `pgbench`)

---

## 3. Quickstart

### Option A: Turnkey Helper Script (`scripts/aks-cluster.sh`)

```bash
# 1. Authenticate with Azure CLI
az login

# 2. Provision the AKS cluster + 3-node Spot pool (default: Standard_D8as_v5 in eastus2 zone 1)
./scripts/aks-cluster.sh create

# Or use 4-vCPU / 32-GiB Spot nodes if your subscription has a 12-20 Spot vCPU quota limit:
# ./scripts/aks-cluster.sh create Standard_E4s_v5 eastus2 1

# 3. Deploy the tuned AKS Helm profile (PgCache 0.7.1 + direct node IP routing)
./scripts/aks-cluster.sh deploy 0.7.1

# 4. Seed the database and run the correctness & benchmark sweeps
./scripts/00-setup.sh
./scripts/verify-correctness.sh
./scripts/01-tenant-sweep.sh
./scripts/02-concurrency-sweep.sh
./scripts/03-write-sweep.sh
./scripts/04-complex-sweep.sh

# 5. Tear down everything immediately after collecting results ($0 residual billing)
./scripts/aks-cluster.sh destroy
```

### Option B: Direct Terraform Commands

```bash
cd infra/terraform/aks

# Optional: copy and customize variables
cp terraform.tfvars.example terraform.tfvars

# Initialize and preview plan
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
terraform init
terraform plan

# Apply configuration
terraform apply

# Configure kubectl
$(terraform output -raw get_credentials_command)

# Deploy benchmark from repo root
cd ../../..
./scripts/helm-deploy.sh --aks-tuned 0.7.1

# Destroy when finished
cd infra/terraform/aks
terraform destroy
```

---

## 4. Choosing `benchmark_vm_size` & `os_disk_type`

| VM SKU | vCPUs | RAM | Spot Quota Used (3 Nodes) | Local Temp Disk | Recommended `os_disk_type` | Helm Profile |
|---|---:|---:|---:|---|---|---|
| **`Standard_D8as_v5`** *(Default — matches `README.md` §7.1)* | 8 | 32 GiB | 24 vCPUs | No | `"Managed"` (`30 GiB`) | `--aks-tuned` or `--aks` |
| **`Standard_E4s_v5`** *(Same 32 GiB RAM, half the vCPU quota)* | 4 | 32 GiB | 12 vCPUs | No | `"Managed"` (`30 GiB`) | `--aks-tuned` |
| **`Standard_D4as_v5`** *(Ultra-budget 4 vCPU Spot)* | 4 | 16 GiB | 12 vCPUs | No | `"Managed"` (`30 GiB`) | `--aks-tuned` |
| **`Standard_D8ads_v5`** *(8 vCPU + local NVMe temp disk)* | 8 | 32 GiB | 24 vCPUs | Yes (300 GiB NVMe) | `"Ephemeral"` (**$0 disk**) | `--aks-tuned` or `--aks` |
| **`Standard_E4ds_v5`** *(4 vCPU + local NVMe temp disk)* | 4 | 32 GiB | 12 vCPUs | Yes (150 GiB NVMe) | `"Ephemeral"` (**$0 disk**) | `--aks-tuned` |

> **Important Note on Azure v5 VMs and Ephemeral OS Disks**: In Azure's v5 generation, VM SKUs **without** `d` in the name (`Standard_D8as_v5`, `Standard_E4s_v5`, `Standard_D4as_v5`) do not include a local temporary disk or OS cache. Attempting to set `os_disk_type = "Ephemeral"` on a non-`d` v5 SKU will be rejected by the Azure API with `EphemeralOSDiskNotSupportedForVMSize`. Therefore, `os_disk_type` defaults to `"Managed"` with the minimum `os_disk_size_gb = 30` so `Standard_D8as_v5` works out of the box, and can be switched to `"Ephemeral"` whenever you select a `d`-series SKU (`Standard_D8ads_v5` / `Standard_E4ds_v5`).
