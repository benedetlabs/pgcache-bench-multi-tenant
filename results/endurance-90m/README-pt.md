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

## 5. Resultados Medidos (DOKS 3 Nós `s-4vcpu-8gb`, PgCache `0.7.1`, `SCALE=20`)

- **Janela de Execução**: `2026-10-19 01:02:02 UTC` → `2026-10-19 03:20:00 UTC`
- **Tabela Resumo Bruta**: [`results/endurance-90m/run-endurance-90m.txt`](run-endurance-90m.txt)
- **Snapshot Final de Telemetria**: [`results/endurance-90m/final-metrics-snapshot.txt`](final-metrics-snapshot.txt)

### 5.1 Tamanho do Banco e Distribuição de Linhas (`SCALE=20`, `TENANTS=1000`)

| Tabela | Total de Linhas | Tamanho em Disco (Heap + Índices) | Observações |
| :--- | ---: | ---: | :--- |
| `order_item` | `40.000.048` | `4.165 MB` | 40.000 itens de pedido por tenant |
| `orders` | `9.999.858` | `1.174 MB` | ~10.000 pedidos por tenant (`min=9.690`, `max=10.382`) |
| `review` | `1.500.000` | `215 MB` | Tabela compartilhada de catálogo |
| `customer` | `2.000.000` | `187 MB` | 2.000 clientes por tenant |
| `product` | `1.000.000` | `108 MB` | Tabela compartilhada de catálogo |
| `seller` / `tenant` | `21.000` | `8 MB` | Tabelas de referência |
| **TOTAL** | **`54.520.906`** | **`5.857 MB` (`~5,86 GB`)** | **`11,4×` maior que o `shared_buffers = 512MB` da Origem** |

### 5.2 Comparativo Ponta a Ponta de 90 Minutos (`complex-dashboard.sql`, `ACTIVE_TENANTS=100`, `CLIENTS=8`)

Cada transação do `complex-dashboard.sql` executa **8 statements SQL complexos** (2 buscas textuais por substring `ILIKE`, 3 `INNER/LEFT JOIN`s profundos de 4 a 5 tabelas e 3 agregações analíticas multidimensionais com `GROUP BY / FILTER / CASE / HAVING`).

| Bloco / Cenário | Duração | Latência Média Path A (Origem) | TPS Path A (Stmts/s) | Latência Média Path B (PgCache) | TPS Path B (Stmts/s) | TPS Final Estabilizado 10m (Lat) | Cache Hit % | Ganho Geral de TPS | Total de Txns (`A` vs `B`) |
| :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| **Bloco 1: 100% Leitura** (`read_1800s`) | **30m + 30m** | `16.865,88 ms` | `0,47` (`3,79/s`) | **`11.091,45 ms`** | **`0,72` (`5,75/s`)** | **`1,60–1,90 TPS`** (`4.225–5.600 ms`) | `47,1%` | **`+51,8%`** (até **`4,0×`**) | `856` vs **`1.304`** (`+52,3%`) |
| **Bloco 2: 95% Leitura / 5% Escrita** (`rw_5pct_900s`) | **15m + 15m** | `16.462,09 ms` | `0,48` (`3,67/s`) | **`11.970,92 ms`** | **`0,66` (`5,07/s`)** | **`1,80–2,10 TPS`** (`2.654–4.780 ms`) | `62,1%` | **`+37,1%`** (até **`4,3×`**) | `444` vs **`610`** (`+37,4%`) |

### 5.3 Abertura por Script no Bloco 2: Como o Alívio de Leitura Acelera a Escrita na Origem em `2,21×`

No Bloco 2 (`95%` `complex-dashboard.sql` + `5%` `write.sql`), o `pgbench` reporta estatísticas separadas para o script de leitura complexa e para o script de escrita transacional (`UPDATE`):

| Componente de Carga no Bloco 2 (`900s`) | Path A (Origem Direto) | Path B (PgCache Proxy) | Ganho Relativo |
| :--- | ---: | ---: | :--- |
| **Leitura Complexa (`complex-dashboard.sql@95`)** | `17.471,93 ms` (`0,455 TPS` / `418` txns) | **`12.584,78 ms`** (`0,630 TPS` / `580` txns) | **`+38,4%` mais telas de leitura concluídas** |
| **Escrita Transacional (`write.sql@5`)** | `226,96 ms` (`0,028 TPS` / `26` escritas) | **`102,89 ms`** (`0,033 TPS` / `30` escritas) | **Escritas `2,21×` mais rápidas (`-54,7%` de latência)** |

> [!TIP]
> **Por que as escritas ficam `2,21×` mais rápidas passando pelo PgCache**: Quando os clientes batem direto na Origem (Path A), os comandos `UPDATE orders` disputam as 4 vCPUs e o I/O de disco da Origem com 8 sessões pesadas de leitura analítica concorrente, elevando a latência de um simples `UPDATE` de linha única para **`226,96 ms`**. Quando as leituras são absorvidas pelas Materialized Views em memória do PgCache (Path B), a contenção de CPU e disco na Origem despenca, reduzindo a latência do `UPDATE` pela metade para **`102,89 ms`** mesmo incluindo o salto de rede do proxy e a invalidação via CDC.

---

## 6. Telemetria Interna e Descobertas Arquiteturais

Extraído de [`results/endurance-90m/final-metrics-snapshot.txt`](final-metrics-snapshot.txt):

| Métrica Prometheus | Valor Final | Significado Arquitetural |
| :--- | ---: | :--- |
| `pgcache_queries_total` / `pgcache_queries_cacheable` | `16.401` / `16.368` | `16.368` consultas complexas de leitura + `33` comandos `UPDATE` de escrita |
| `pgcache_queries_uncacheable` | **`0`** | **100% de cacheabilidade** em todos os 8 statements do `complex-dashboard.sql` |
| `pgcache_cache_mv_gate{outcome="reject"}` | **`0`** | **0% de rejeição no MV Gate** (`673` Materialized Views admitidas) |
| `pgcache_cache_mv_hits` | **`5.924`** | Joins, buscas e agregações servidos diretamente das MVs em sub-milissegundos |
| `pgcache_cache_evictions` | **`0`** | Zero thrashing de cache ou evictions ao longo dos 90 minutos |
| `pgcache_cache_restarts_total` / `pgcache_connections_errors` | **`0` / `0`** | 100% de estabilidade do proxy e zero transações falhas sob carga pesada contínua |
| `pgcache_cdc_events_processed` / `pgcache_cdc_flush_staleness_seconds` | `178` / **`8,1 µs`** | Ciclo de aplicação de replicação lógica (CDC) praticamente instantâneo |
| `pgcache_cache_memory_used_bytes` / `pgcache_cache_memory_budget_bytes` | `3,39 GiB` / `3,50 GiB` | **96,7% de uso do orçamento de memória** (`3,5 GiB`) sem nenhum OOM kill |

### Controle de Admissão por High-Watermark de Memória em `SCALE=20` (Orçamento de `3,5 GiB`)

Em `SCALE=20` (`54,5M` linhas), as tabelas compartilhadas de catálogo (`product` com `1.000.000` de linhas e `review` com `1.500.000` linhas) somadas aos `100` tenants ativos (`1.000.000` de pedidos e `4.000.000` de itens) formam um working set expressivo no armazenamento embutido do PgCache (`pgcache_cache_disk_used_bytes = 16,79 GiB`).

- Durante as Fases 3 e 6, conforme `pgcache_cache_memory_used_bytes` subiu de `2,93 GiB` (`83,8%` do `MEMORY_LIMIT`) até `3,39 GiB` (`96,7%` do `MEMORY_LIMIT`), o **controlador de admissão por high-watermark de memória** do PgCache (`pgcache_cache_registration_throttled_total = 348`) cadenciou o registro de novas Materialized Views (`pgcache_cache_queries_registered = 607 / 800` combinações distintas de query por tenant).
- Em vez de estourar a RAM do host ou entrar em thrashing de evictions (`pgcache_cache_evictions = 0`), o PgCache manteve fixadas em memória ~76% das Materialized Views dos tenants ativos (respondendo aos hits em sub-milissegundos e elevando o TPS do cluster para **`1,8–2,1 TPS`** nos minutos finais), enquanto encaminhou de forma limpa as consultas ainda não residentes (`pgcache_cache_coalesce_deadline_forward_total = 5.586`).
- **Recomendação de Dimensionamento para Produção**: Em um nó `4 vCPU / 8 GB` (`MEMORY_LIMIT = 3,5 GiB`), o PgCache comporta confortavelmente ~75 tenants do dashboard enterprise de 8 queries em `SCALE=20`. Escalar o nó do PgCache para `16 GB RAM` (`MEMORY_LIMIT = 10 GiB`) permite manter 100% dos `100+` tenants ativos simultaneamente residentes em RAM para atingir ~100% de hit ratio contínuo.

---

## 7. Como Reproduzir

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

