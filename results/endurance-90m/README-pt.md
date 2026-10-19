# Sweep 5: Campanha de Longa Duração (1h30m) e Alívio de Recursos na Origem (DOKS + Grafana Cloud)

> 🇺🇸 **[English version](README.md)**

---

## 1. Objetivo e Hipótese

Enquanto os Sweeps 1 a 4 (`01-tenant-sweep.sh` a `04-complex-sweep.sh`) avaliam a vazão (RPS) e a latência média em janelas curtas de 30 segundos sobre um banco que cabe em memória (`SCALE=1`, ~463 MB), o **Sweep 5 (`scripts/05-endurance-90m.sh`)** responde à pergunta de infraestrutura operacional para sistemas SaaS multi-tenant em produção:

> **O que acontece com o consumo de recursos físicos do servidor PostgreSQL de Origem (CPU, Memória RAM, IOPS e Throughput de Disco, Conexões Ativas e Tuplas Varridas) ao longo de um teste contínuo de 1h30m quando o tráfego migra da Origem Direta (Path A) para o PgCache Proxy (Path B) em um banco ~20× maior que o `shared_buffers`?**

Para testar isso com rigor, sem atalhos de cache em RAM na Origem:
- **Escala do Banco de Dados (`SCALE=20`, ~10 GB)**:
  - `10.000.000` de pedidos (`orders`)
  - `40.000.000` de itens de pedido (`order_item`)
  - `2.000.000` de clientes (`customer`) distribuídos em **`1.000` tenants distintos**
  - `1.000.000` de produtos (`product`) e `1.500.000` de avaliações (`review`)
- **Proporção Memória vs Disco na Origem**:
  - O PostgreSQL de origem roda com `shared_buffers = 512MB` em um nó dedicado `s-4vcpu-8gb` conectado a um volume de bloco CSI de `80Gi` (`do-block-storage`). Como o banco de ~10 GB é ~20× maior que o `shared_buffers`, consultas complexas sem cache forçam leituras reais de disco e alto uso de CPU com `JOIN`s e agregações na Origem.
- **Conjunto Ativo de Tenants (`ACTIVE_TENANTS=100`)**:
  - O benchmark exercita `100` tenants ativos (`-D tenants=100`) executando a tela analítica e de busca de 8 statements (`workload/complex-dashboard.sql`). O conjunto ativo de dados e as Materialized Views cabem com folga dentro do `MEMORY_LIMIT` de `3.5 GiB` (`3758096384` bytes) do PgCache, operando com zero evictions.

---

## 2. Stack de Observabilidade em Tempo Real e Link do Grafana Cloud

- **Stack no Grafana Cloud**: **[https://pgcachebench.grafana.net/](https://pgcachebench.grafana.net/)**
- **JSON do Dashboard para Importação**: [`infra/grafana/pgcache-endurance-dashboard.json`](../../infra/grafana/pgcache-endurance-dashboard.json) (UID: `pgcache-endurance-90m`)
- **Manifesto de Telemetria Kubernetes**: [`infra/monitoring/grafana-cloud-monitoring.yaml`](../../infra/monitoring/grafana-cloud-monitoring.yaml)
- **Script de Deploy da Telemetria**: [`scripts/deploy-monitoring.sh`](../../scripts/deploy-monitoring.sh)

### Topologia de Telemetria com Zero Interferência

Para garantir que os coletores de monitoramento não roubem CPU dos nós `origin` ou `pgcache` durante o benchmark:

| Papel do Nó (`bench_role`) | Droplet DOKS (`nyc1`) | Pod do Benchmark | Agentes de Telemetria no Nó |
| :--- | :--- | :--- | :--- |
| **`origin`** | Nó 1 (`10.116.0.3`, `s-4vcpu-8gb`) | `origin-0` (PostgreSQL 17, `:5432`) | Apenas `node-exporter` (`:9100`) + Kubelet `cAdvisor` |
| **`pgcache`** | Nó 2 (`10.116.0.4`, `s-4vcpu-8gb`) | `pgcache` (`0.7.1`, `:6432` / `:9091`) | `node-exporter` (`:9100`) + Kubelet `cAdvisor` + endpoint nativo `:9091/metrics` |
| **`loadgen`** | Nó 3 (`10.116.0.5`, `s-4vcpu-8gb`) | `loadgen` (`pgbench -P 10`) | `node-exporter` + **`postgres-exporter` (`:9187`)** + **`pgbench-exporter` (`:9105`)** + **`grafana-alloy`** |

Todo o trabalho de coleta central, relabeling e envio `prometheus.remote_write` (`grafana-alloy`, `postgres-exporter` e `pgbench-exporter`) fica fixado via `nodeAffinity` no **nó `loadgen`**, garantindo **0% de overhead de CPU do observador** nos nós `origin` e `pgcache`.

---

## 3. Métricas Coletadas nas 4 Camadas

1. **Camada de Aplicação Cliente (`pgbench-exporter` `:9105/metrics`, a cada 5–10s)**:
   - `pgbench_phase_id`: Fase ativa do benchmark (`1` a `6`, `0` quando ocioso)
   - `pgbench_target_is_pgcache`: `0` quando apontado para a Origem (`:5432`), `1` quando apontado para o PgCache (`:6432`)
   - `pgbench_live_tps`: Transações por segundo ao vivo reportadas pelo `pgbench -P 10`
   - `pgbench_live_latency_ms` e `pgbench_live_latency_stddev_ms`: Latência média e desvio padrão em tempo real (ms)
2. **Camada de Recursos de Hardware e SO (`node-exporter` `:9100` e `cAdvisor`, rotulados por `bench_role`)**:
   - **CPU**: `node_cpu_seconds_total` detalhado por modo (`user`, `system`, `iowait`, `softirq`, `idle`) para `bench_role="origin"`, `bench_role="pgcache"` e `bench_role="loadgen"`
   - **Memória**: `node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes` e `container_memory_working_set_bytes`
   - **Disco I/O (`do-block-storage`)**: `node_disk_reads_completed_total` (IOPS de leitura), `node_disk_writes_completed_total` (IOPS de escrita), `node_disk_read_bytes_total` (MB/s de leitura), `node_disk_written_bytes_total` (MB/s de escrita)
   - **Rede**: `node_network_receive_bytes_total` e `node_network_transmit_bytes_total`
3. **Camada Interna do PostgreSQL de Origem (`postgres-exporter` `:9187/metrics`)**:
   - `pg_activity_states_connections` e `pg_stat_database_numbackends`: Conexões ativas vs ociosas na Origem
   - `pg_stat_database_tup_returned` e `pg_stat_database_tup_fetched`: Linhas varridas e buscadas por segundo na Origem
   - `pg_stat_database_blks_read` vs `pg_stat_database_blks_hit`: Leituras físicas de bloco de disco/SO vs hits no `shared_buffers` por segundo
   - `pg_stat_database_xact_commit`, `tup_updated`, `tup_inserted`: Taxa de commits e mutações por segundo
   - `pg_replication_slot_lag_flush_lag_bytes`: Atraso (lag) em bytes do slot de replicação lógica (CDC)
4. **Camada do PgCache Proxy e Engine de MVs (`pgcache` `:9091/metrics`)**:
   - `pgcache_queries_cache_hit`, `pgcache_queries_cache_miss`, `pgcache_queries_uncacheable`
   - `pgcache_cache_mv_hits`, `pgcache_cache_mv_fallthrough`, `pgcache_cache_mv_rebuilds`, `pgcache_cache_mv_gate`
   - `pgcache_cache_memory_used_bytes` vs `pgcache_cache_memory_budget_bytes` (`3.5 GiB`)
   - `pgcache_cache_invalidations` e `pgcache_cache_evictions`

---

## 4. Linha do Tempo da Execução de 1h30m (90 Minutos)

A campanha ([`scripts/05-endurance-90m.sh`](../../scripts/05-endurance-90m.sh)) executa dois blocos comparativos consecutivos totalizando **90 minutos de carga medida** mais as transições dinâmicas de aquecimento:

| ID da Fase | Duração | Bloco e Alvo | Mix de Carga | O que é Medido |
| :---: | :---: | :--- | :--- | :--- |
| **Seed** | ~8–12m | **Setup do Banco (`00-setup.sh`)** | `SCALE=20`, `TENANTS=1000` | Popula 10M pedidos e 40M itens (~10 GB) e cria os índices compostos por tenant na Origem |
| **Fase 1** | **30 min** (`1800s`) | **Bloco 1 — Origem Direto (`Path A`)** | `100% Leitura` (`complex-dashboard.sql`) | Saturação de CPU da Origem, IOPS/MBs de leitura de disco, conexões ativas e varredura de tuplas |
| **Fase 2** | *Dinâmico* (`warm_until_settled`) | **Bloco 1 — Warm-up PgCache** | `100% Leitura` (`complex-dashboard.sql`) | População das tabelas-base e construção das Materialized Views até o hit ratio estabilizar (`< 1%`) |
| **Fase 3** | **30 min** (`1800s`) | **Bloco 1 — PgCache Proxy (`Path B`)** | `100% Leitura` (`complex-dashboard.sql`) | **Alívio na Origem**: CPU, leitura de disco e conexões ativas na Origem caem a quase zero enquanto o TPS sobe |
| **Fase 4** | **15 min** (`900s`) | **Bloco 2 — Origem Direto (`Path A`)** | `95% Leitura` + `5% Escrita` (`write.sql`) | Origem sob leituras analíticas pesadas combinadas com `UPDATE`s contínuos e flush de WAL |
| **Fase 5** | *Dinâmico* (`warm_until_settled`) | **Bloco 2 — Warm-up CDC PgCache** | `95% Leitura` + `5% Escrita` (`write.sql`) | Estabiliza o ciclo de invalidação por replicação lógica (CDC) sob escrita ativa |
| **Fase 6** | **15 min** (`900s`) | **Bloco 2 — PgCache Proxy (`Path B`)** | `95% Leitura` + `5% Escrita` (`write.sql`) | Origem processa apenas os 5% de escrita e o stream de CDC enquanto o PgCache responde às leituras |

---

## 5. Como Reproduzir

```bash
# 1. Criar o cluster Kubernetes de 3 nós na DigitalOcean (~US$ 0,21/h total)
./scripts/do-cluster.sh create pgcache-bench s-4vcpu-8gb nyc1

# 2. Fazer deploy do Origin (PVC de 80Gi), PgCache 0.7.1 e Loadgen (perfil tuned)
./scripts/do-cluster.sh deploy 0.7.1

# 3. Configurar .env.grafana (a partir do .env.grafana.example) e subir a telemetria para o Grafana Cloud
cp .env.grafana.example .env.grafana
# (Edite .env.grafana com a sua chave GCLOUD_RW_API_KEY)
./scripts/deploy-monitoring.sh

# 4. Importar infra/grafana/pgcache-endurance-dashboard.json em:
#    https://pgcachebench.grafana.net/dashboard/import

# 5. Executar a campanha de longa duração de 1h30m (90 minutos)
./scripts/05-endurance-90m.sh

# 6. Ao finalizar, destruir o cluster e os volumes de bloco (custo residual US$ 0)
./scripts/do-cluster.sh destroy pgcache-bench
```
