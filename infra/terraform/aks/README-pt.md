# Configuração Terraform de Ultra-Baixo Custo para Azure AKS

**[Read in English (README.md)](README.md)**

Este diretório contém a configuração Terraform para provisionar um cluster **Azure Kubernetes Service (AKS) com o menor custo possível**, mantendo 100% das especificações de hardware, topologia em zona única (Single-AZ) e node pool Spot exigidas pelo benchmark `pgcache-bench-multi-tenant`.

---

## 1. Por Que o Padrão do Portal da Azure Encarece o AKS (e Como Este Terraform Resolve)

Ao criar um cluster AKS pelo assistente do Portal da Azure, a plataforma ativa por padrão camadas pagas de gerenciamento, agentes de observabilidade e recursos de rede que frequentemente custam **de 3× a 5× mais do que as próprias VMs Spot de trabalho** — além de injetarem `DaemonSets` que consomem CPU nos nós e adicionam ruído de latência p99 ao benchmark.

| Componente / Configuração | Padrão do Portal da Azure (Custo Elevado) | Esta Configuração Terraform (`infra/terraform/aks/`) | Impacto no Custo e no Benchmark |
|---|---|---|---|
| **Camada do Control Plane (`sku_tier`)** | `Standard` (**US$ 0,10/h = ~US$ 73/mês**) | **`Free` (US$ 0,00/h)** | **Economiza US$ 73/mês.** Mesmo API Server do Kubernetes sem a cobrança pela taxa de SLA do control plane. |
| **Container Insights / Log Analytics (`oms_agent`)** | Ativado (~US$ 2,76/GB ingerido + retenção) | **Desativado (bloco omitido)** | **Economiza US$ 10–50+/execução.** Evita que o DaemonSet `ama-logs` colete logs durante baterias intensas do `pgbench`. |
| **Azure Managed Prometheus (`monitor_metrics`)** | Ativado (cobrança por amostra de métrica) | **Desativado (bloco omitido)** | **Custo US$ 0.** As métricas do PgCache (`:9090/metrics`) já são lidas diretamente pelo pod leve `metrics-reader` (`alpine:3.20`). |
| **Azure Managed Grafana** | Frequentemente vinculado no Portal (~US$ 0,09/h) | **Desativado** | **Custo US$ 0.** Nenhuma instância de Grafana é criada. |
| **Microsoft Defender for Containers** | Ativado (~US$ 7/vCore/mês) | **Desativado (bloco omitido)** | **Economiza ~US$ 180/mês (em 26 vCores)** e elimina o overhead de CPU do sensor eBPF durante as medições. |
| **Azure Policy & Cost Analysis** | Ativados | **`azure_policy_enabled = false`, `cost_analysis_enabled = false`** | Elimina latência de webhooks do Gatekeeper e pods de análise de custo em background. |
| **Drivers CSI de Armazenamento** | Disk + Files + Blob + Snapshot Controller | **Apenas `disk_driver_enabled = true`** | Mantém o `managed-csi` para os PVCs do PostgreSQL e desativa os drivers extras de File, Blob e Snapshot. |
| **Rede de Saída (Outbound)** | Managed NAT Gateway (**~US$ 0,045/h = ~US$ 33/mês** + taxa/GB) | **`loadBalancer` (`managed_outbound_ip_count = 1`)** | **Economiza ~US$ 33/mês.** Usa um único IP de saída padrão com Azure CNI Overlay (`network_plugin_mode = "overlay"`). |
| **Zonas de Disponibilidade (`zones`)** | Zonas `1, 2, 3` (**US$ 0,01/GB** tráfego entre zonas + ~500 µs RTT) | **Zona Única (`zones = ["1"]`)** | **US$ 0,00/GB de tráfego entre zonas** e **~160 µs de RTT entre nós** (exigido pelo `README-pt.md` Seção 7.1). |
| **Node Pool `system` Padrão** | 2–3× VMs On-Demand `Standard_D2s_v5` / `D4s_v5` | **1× `Standard_B2als_v2`** (`only_critical_addons_enabled = true`) | **~US$ 0,018–0,032/h.** Como a Azure proíbe Spot no pool `System` obrigatório, isolamos o `kube-system` + `metrics-reader` em 1 nó mínimo. |
| **Node Pool `benchspot` de Benchmark** | On-Demand ou Multi-AZ | **3× VMs Spot (`priority = "Spot"`, `eviction_policy = "Delete"`)** | **~80–88% de desconto Spot** (~US$ 0,038–0,055/h por nó `Standard_D8as_v5`, ou ~US$ 0,025/h por `Standard_E4s_v5`). |
| **Discos de SO (`os_disk_size_gb`)** | 128 GiB Premium SSD por nó (~US$ 19,71/mês × 4 = **~US$ 79/mês**) | **`30 GiB` OS disk** (ou disco `Ephemeral` a US$ 0 em SKUs série `d`) | **Reduz o custo de disco de SO em 76%–100%.** |

### Custo Horário Total Estimado Durante o Teste

| Recurso | Configuração | Custo Horário Estimado (`eastus2`) |
|---|---|---:|
| **Control Plane do AKS** | `sku_tier = "Free"` | **US$ 0,000 / h** |
| **Observabilidade (Prometheus / Grafana / OMS)** | Explicitamente desativados | **US$ 0,000 / h** |
| **1× Nó de Sistema (`system`)** | `Standard_B2als_v2` (2 vCPU, 4 GiB RAM) | **~US$ 0,019 / h** |
| **3× Nós Spot de Benchmark (`benchspot`)** | `3 × Standard_D8as_v5` Spot (8 vCPU, 32 GiB RAM cada) | **~US$ 0,115 – 0,165 / h total** |
| **Alternativa Pool Spot 4-vCPU** | `3 × Standard_E4s_v5` Spot (4 vCPU, 32 GiB RAM cada) | **~US$ 0,075 – 0,105 / h total** |
| **Tráfego Entre Zonas (Cross-AZ)** | Zona de Disponibilidade Única (`zones = ["1"]`) | **US$ 0,000 / h** |
| **Custo Total do Cluster em Execução** | **Cluster completo de 4 nós (1 System + 3 Spot)** | **~US$ 0,10 – 0,19 / h** |

---

## 2. Arquitetura dos Node Pools e Agendamento dos Pods

A API do Azure AKS possui uma restrição obrigatória: o `default_node_pool` precisa ter `mode = "System"` e **não aceita `priority = "Spot"`**.

Para obter o menor custo possível garantindo isolamento estrito de hardware para o benchmark:

1. **Node Pool Padrão `system` (1× `Standard_B2als_v2`, On-Demand)**:
   - Configurado com `only_critical_addons_enabled = true`, que aplica automaticamente o taint `CriticalAddonsOnly=true:NoSchedule`.
   - Hospeda apenas os agentes do `kube-system` (`coredns`, `konnectivity-agent`, `csi-azuredisk-controller`) e o pod ocioso `metrics-reader` (`alpine:3.20`, `50m` CPU / `64Mi` RAM).
   - **Nenhum pod do benchmark (`origin`, `pgcache`, `loadgen`) é agendado neste nó.**
2. **Node Pool de Usuário `benchspot` (3× VMs Spot, Zona Única)**:
   - Configurado com `mode = "User"`, `priority = "Spot"`, `eviction_policy = "Delete"`, `spot_max_price = -1` e `zones = ["1"]`.
   - A Azure adiciona automaticamente o label `kubernetes.azure.com/scalesetpriority=spot` e o taint `kubernetes.azure.com/scalesetpriority=spot:NoSchedule`.
   - Os perfis [`infra/helm/pgcache-mt/values-aks-tuned.yaml`](../../helm/pgcache-mt/values-aks-tuned.yaml) e [`infra/helm/pgcache-mt/values-aks.yaml`](../../helm/pgcache-mt/values-aks.yaml) configuram `nodeSelector` e `tolerations` para `kubernetes.azure.com/scalesetpriority: spot` junto com `podAntiAffinity` (`lab/role`), distribuindo:
     - **Nó Spot 1**: `origin-0` (`postgres:17`, `shared_buffers=1GB`, `wal_level=logical`)
     - **Nó Spot 2**: `pgcache` (`pgcache/pgcache:0.7.1`, `NUM_WORKERS=8`, `MEMO_CACHE_SIZE=1GiB`)
     - **Nó Spot 3**: `loadgen` (`postgres:17` / `pgbench`)

---

## 3. Guia Rápido de Uso

### Opção A: Script Automatizado (`scripts/aks-cluster.sh`)

```bash
# 1. Autenticar no Azure CLI
az login

# 2. Provisionar o cluster AKS + pool Spot de 3 nós (padrão: Standard_D8as_v5 em eastus2 zona 1)
./scripts/aks-cluster.sh create

# Ou usando nós Spot de 4 vCPU / 32 GiB caso sua assinatura tenha limite de cota Spot de 12-20 vCPUs:
# ./scripts/aks-cluster.sh create Standard_E4s_v5 eastus2 1

# 3. Implantar o chart Helm otimizado para AKS (PgCache 0.7.1 + roteamento direto por IP do nó)
./scripts/aks-cluster.sh deploy 0.7.1

# 4. Popular o banco e executar o gate de corretude e as baterias de benchmark
./scripts/00-setup.sh
./scripts/verify-correctness.sh
./scripts/01-tenant-sweep.sh
./scripts/02-concurrency-sweep.sh
./scripts/03-write-sweep.sh
./scripts/04-complex-sweep.sh

# 5. Destruir toda a infraestrutura imediatamente após coletar os resultados (US$ 0 de custo residual)
./scripts/aks-cluster.sh destroy
```

### Opção B: Comandos Terraform Diretos

```bash
cd infra/terraform/aks

# Opcional: copiar e personalizar variáveis
cp terraform.tfvars.example terraform.tfvars

# Inicializar e visualizar o plano
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
terraform init
terraform plan

# Criar o cluster
terraform apply

# Configurar o kubectl
$(terraform output -raw get_credentials_command)

# Implantar o benchmark a partir da raiz do repositório
cd ../../..
./scripts/helm-deploy.sh --aks-tuned 0.7.1

# Destruir ao finalizar
cd infra/terraform/aks
terraform destroy
```

---

## 4. Escolhendo `benchmark_vm_size` e `os_disk_type`

| SKU da VM | vCPUs | RAM | Cota Spot Usada (3 Nós) | Disco Temp Local | `os_disk_type` Recomendado | Perfil Helm |
|---|---:|---:|---:|---|---|---|
| **`Standard_D8as_v5`** *(Padrão — igual ao `README-pt.md` §7.1)* | 8 | 32 GiB | 24 vCPUs | Não | `"Managed"` (`30 GiB`) | `--aks-tuned` ou `--aks` |
| **`Standard_E4s_v5`** *(Mesmos 32 GiB de RAM, metade da cota de vCPU)* | 4 | 32 GiB | 12 vCPUs | Não | `"Managed"` (`30 GiB`) | `--aks-tuned` |
| **`Standard_D4as_v5`** *(Ultra-econômico 4 vCPU Spot)* | 4 | 16 GiB | 12 vCPUs | Não | `"Managed"` (`30 GiB`) | `--aks-tuned` |
| **`Standard_D8ads_v5`** *(8 vCPU + disco NVMe local)* | 8 | 32 GiB | 24 vCPUs | Sim (300 GiB NVMe) | `"Ephemeral"` (**US$ 0 disco**) | `--aks-tuned` ou `--aks` |
| **`Standard_E4ds_v5`** *(4 vCPU + disco NVMe local)* | 4 | 32 GiB | 12 vCPUs | Sim (150 GiB NVMe) | `"Ephemeral"` (**US$ 0 disco**) | `--aks-tuned` |

> **Nota Importante sobre VMs Azure v5 e Discos de SO Efêmeros (`Ephemeral`)**: Na geração v5 da Azure, SKUs **sem** a letra `d` no nome (`Standard_D8as_v5`, `Standard_E4s_v5`, `Standard_D4as_v5`) não possuem disco temporário local nem cache de SO. Definir `os_disk_type = "Ephemeral"` em uma SKU v5 sem `d` faz a API da Azure rejeitar a criação com `EphemeralOSDiskNotSupportedForVMSize`. Por isso, `os_disk_type` usa `"Managed"` com o tamanho mínimo de `30 GiB` por padrão para funcionar imediatamente com `Standard_D8as_v5`, podendo ser alterado para `"Ephemeral"` ao escolher uma SKU da série `d` (`Standard_D8ads_v5` / `Standard_E4ds_v5`).
