# Resultados da Verificação Multi-Versão do PgCache (Kubernetes 3 Nós / DOKS)

> 🇺🇸 **[English version](README.md)**

Este diretório contém as execuções oficiais de verificação de benchmark comparando versões do **PgCache** em **DigitalOcean Kubernetes de 3 Nós (DOKS)** e dois níveis de complexidade de carga:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)
- [**PgCache 0.7.1 (Baseline + Cenários Complexos Multi-Tenant)**](0.7.1/README-pt.md)
- [**Sweep 5: Endurance de 1h30m e Alívio de Recursos na Origem (`SCALE=20`)**](endurance-90m/README-pt.md)
- [**Perfil Otimizado / Tuned (v0.7.0)**](tuned/README-pt.md)

> **Política de Ambiente**: Todos os resultados oficiais de performance são coletados **exclusivamente em clusters Kubernetes de 3 nós (DOKS)** com `podAntiAffinity` estrito (`origin`, `pgcache` e `loadgen` em três nós físicos separados). O Docker Compose local (`infra/docker-compose.yml`) é utilizado estritamente para montagem do ambiente e testes funcionais/corretude diferencial (`scripts/verify-correctness.sh`).

---

## 1. DigitalOcean Kubernetes (DOKS 3 Nós — 1 a 2.000 Tenants)

Executado em um cluster com topologia de produção: 3 nós dedicados (`s-4vcpu-8gb`, single-AZ), `--ha=false`, `podAntiAffinity` estrito (1 nó exclusivo para cada: `origin`, `pgcache`, `loadgen`) e `hostNetwork: true`.

### 1.1 Varredura Multi-Versão Baseline (1 a 2.000 Tenants)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio (Todos) | Passos de Aquecimento |
|---|---|---|---|---|---|---|---|
| **1 Tenant** | 23,3–27,5 ms (291–343 rps) | **17,6 ms** (455 rps, +56%) | **16,8 ms** (476 rps, +61%) | **15,6 ms** (513 rps, +50%) | **16,6 ms** (481 rps, +40%) | **100,0%** | 2 |
| **10 Tenants** | 22,9–27,7 ms (288–350 rps) | **17,8 ms** (451 rps, +52%) | **21,0 ms** (382 rps, +33%) | **22,9 ms** (349 rps, +4%) | **21,7 ms** (369 rps, +5%) | **100,0%** | 2 |
| **50 Tenants** | 25,4–29,9 ms (267–315 rps) | **17,5 ms** (456 rps, +66%) | **15,8 ms** (506 rps, +90%) | **17,3 ms** (462 rps, +64%) | **17,0 ms** (470 rps, +49%) | **100,0%** | 2–3 |
| **100 Tenants** | 25,2–30,3 ms (264–317 rps) | **19,4 ms** (412 rps, +56%) | **16,3 ms** (492 rps, +55%) | **17,2 ms** (465 rps, +51%) | **16,3 ms** (491 rps, +63%) | **100,0%** | 2–3 |
| **500 Tenants** | 24,4–32,2 ms (248–329 rps) | **16,7 ms** (478 rps, +93%) | **15,7 ms** (510 rps, +71%) | **18,7 ms** (428 rps, +38%) | **16,3 ms** (490 rps, +49%) | **100,0%** | 3–4 |
| **1.000 Tenants** | 24,0–26,2 ms (305–333 rps) | **17,5 ms** (458 rps, +50%) | **16,8 ms** (476 rps, +46%) | **17,2 ms** (466 rps, +52%) | **16,9 ms** (473 rps, +42%) | **100,0%** | 3–4 |
| **2.000 Tenants** | 23,3–26,0 ms (308–343 rps) | **18,3 ms** (438 rps, +40%) | **15,5 ms** (515 rps, +67%) | **18,8 ms** (425 rps, +38%) | **16,5 ms** (485 rps, +41%) | **100,0%** | 4–6 |

### 1.2 Comparativo Lado a Lado: Baseline vs Perfil Otimizado (PgCache 0.7.0)

Comparando a configuração padrão do DOKS com o perfil otimizado (`tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_tw_reuse=1`, VirtIO RPS `rps_cpus=f`, roteamento direto por IP de nó via `/etc/hosts`, `NUM_WORKERS=8` e `MEMO_CACHE_SIZE=1073741824`):

| Inquilinos Ativos | Origem Baseline | PgCache Baseline | Ganho Baseline | Origem Otimizada | PgCache Otimizado | Ganho Otimizado | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23,3 ms · 343 rps | 15,6 ms · 513 rps | +50% | 30,4 ms · 263 rps | 24,0 ms · 333 rps | +27% | 100,0% | 2 |
| **10** | 23,9 ms · 335 rps | 22,9 ms · 349 rps | +4% | 33,1 ms · 242 rps | 22,0 ms · 363 rps | +50% | 100,0% | 2 |
| **50** | 28,5 ms · 281 rps | 17,3 ms · 462 rps | +64% | 32,7 ms · 245 rps | 21,5 ms · 371 rps | +51% | 100,0% | 2 |
| **100** | 26,0 ms · 307 rps | 17,2 ms · 465 rps | +51% | 33,0 ms · 243 rps | 19,3 ms · 414 rps | **+70%** | 100,0% | 2 |
| **500** | 25,7 ms · 311 rps | 18,7 ms · 428 rps | +38% | 30,0 ms · 266 rps | 22,3 ms · 359 rps | +35% | 100,0% | 3 |
| **1.000** | 26,0 ms · 307 rps | 17,2 ms · 466 rps | +52% | 33,2 ms · 241 rps | 19,7 ms · 405 rps | **+68%** | 100,0% | 3 |
| **2.000** | 25,9 ms · 309 rps | 18,8 ms · 425 rps | +38% | 34,2 ms · 234 rps | 20,5 ms · 390 rps | **+67%** | 100,0% | 4 |

---

## 2. Cenários Complexos Multi-Tenant no DOKS 3 Nós (PgCache 0.7.1 — Aceleração via Materialized Views)

No **PgCache 0.7.1**, expandimos o benchmark além de consultas operacionais leves (`workload/dashboard.sql`) para quatro **cargas corporativas SaaS complexas** (`scripts/04-complex-sweep.sh`) em **DigitalOcean Kubernetes de 3 Nós (DOKS)**, e aplicamos um rigoroso **Gate Diferencial de Correção, Cacheabilidade, Admissão de MVs e Pós-CDC** (`scripts/verify-correctness.sh`):
- **12/12 consultas complexas** verificadas byte a byte idênticas entre Origem e PgCache nos 3 passes estáticos (`verify-correctness-doks.txt`, `TENANTS=2000`) e após mutações CDC ao vivo.
- **100% de cacheabilidade** (`pgcache_queries_uncacheable == 0`), **100% de admissão no Gate de Materialized Views** (`pgcache_cache_mv_gate{outcome="admit"} == 12/12`, `reject == 0`) e **100% de hit em MVs no Passe 3** (delta de `pgcache_cache_mv_hits == 12/12`).

### 2.1 Comparativo por Complexidade de Carga (`TENANTS=200`, `CLIENTS=8` — DOKS 3 Nós)

| Cenário | Carga SQL | Origem DOKS (Caminho A) | PgCache 0.7.1 DOKS (Caminho B) | Ganho DOKS (Aceleração) | Hit Ratio | Passos Warmup |
|---|---|---|---|---:|---:|---:|
| **`dash_base`** | [`dashboard.sql`](../workload/dashboard.sql) (8 consultas operacionais simples) | 23,06 ms · 347 rps | **15,92 ms · 503 rps** | **+45% (1,45×)** | 100,0% | 2 |
| **`search`** | [`complex-search.sql`](../workload/complex-search.sql) (4 buscas `ILIKE '%...%'` + `JOIN`/`LEFT JOIN`) | 74,26 ms · 108 rps | **5,04 ms · 1.586 rps** | **+1.369% (14,7×)** | 100,0% | 3 |
| **`joins`** | [`complex-joins.sql`](../workload/complex-joins.sql) (4 cadeias de 4 a 6 tabelas com `JOIN` e `LEFT JOIN`) | 148,87 ms · 54 rps | **4,73 ms · 1.692 rps** | **+3.033% (31,3×)** | 100,0% | 3 |
| **`analytics`** | [`complex-analytics.sql`](../workload/complex-analytics.sql) (4 agregações `GROUP BY` + `FILTER` + `CASE` + `HAVING`) | 102,38 ms · 78 rps | **5,69 ms · 1.406 rps** | **+1.703% (18,0×)** | 100,0% | 4 |
| **`cplx_dash`** | [`complex-dashboard.sql`](../workload/complex-dashboard.sql) (Tela unificada com 8 statements corporativos) | 204,39 ms · 39 rps | **11,50 ms · 696 rps** | **+1.685% (17,8×)** | 100,0% | 5 |

### 2.2 Escala de Concorrência em `complex-dashboard.sql` (`TENANTS=200` — DOKS 3 Nós)

| Clientes | Origem DOKS (Caminho A) | PgCache 0.7.1 DOKS (Caminho B) | Ganho DOKS (Aceleração) | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|
| **1** | 100,60 ms · 10 rps | **7,14 ms · 140 rps** | **+1.300% (14,0×)** | 100,0% | 2 |
| **4** | 129,45 ms · 31 rps | **8,60 ms · 465 rps** | **+1.400% (15,0×)** | 100,0% | 2 |
| **8** | 212,81 ms · 38 rps | **10,48 ms · 763 rps** | **+1.908% (20,1×)** | 100,0% | 2 |
| **16** | 406,90 ms · 39 rps | **18,06 ms · 886 rps** | **+2.172% (22,7×)** | 100,0% | 2 |
| **32** | 835,52 ms · 38 rps | **31,36 ms · 1.020 rps** | **+2.584% (26,8×)** | 100,0% | 2 |

Para a análise completa de escala de tenants no DOKS de 3 nós (`100,0%` de hit ratio de 1 a 500 tenants com `+2.133%` em 1 tenant, `+1.774%` em 200 tenants e `+1.108%` em 500 tenants) e resiliência a escritas mistas (`63,1%–75,0%` de hit ratio no DOKS sob 5%–10% de escritas), consulte [`results/0.7.1/README-pt.md`](0.7.1/README-pt.md).

---

## 3. Insights Arquiteturais: Piso de Rede e Lei de Amdahl em Clusters de 3 Nós

1. **O Multiplicador de Rede de 8 Consultas Sequenciais e a Lei de Amdahl**:
   - Cada requisição (`dashboard.sql` e `complex-dashboard.sql`) é composta por **8 consultas SQL sequenciais** executadas sob o protocolo de consulta simples (`-M simple`), sem blocos `BEGIN...COMMIT`.
   - No **DigitalOcean (DOKS em 3 nós físicos distintos)**, a latência de rede entre VMs gira em torno de **~0,6 a 0,8 ms por RTT**. Para 8 consultas sequenciais, isso introduz um **piso irredutível de rede de $8 \times 0,7\text{ ms} \approx 5,6\text{ ms}$** por transação, pago tanto pelo Caminho A (Origem) quanto pelo Caminho B (PgCache).
   - Quando a carga é leve (`dashboard.sql`, `23,06 ms` na Origem), o piso de rede de `5,6 ms` representa ~24% do tempo total da requisição, limitando a aceleração relativa a **1,45×–1,93× (`+45%` a `+93%`)**.
   - Quando a carga passa para telas analíticas multi-tabela (`complex-dashboard.sql`, `204,39 ms` na Origem), o piso de rede de `5,6 ms` cai para `< 3%` do tempo de execução da Origem, e a aceleração no DOKS de 3 nós salta para **17,8× (`+1.685%`)** com 8 clientes e **26,8× (`+2.584%`)** com 32 clientes (**31,3× / `+3.033%`** em `complex-joins.sql`).
2. **Por que o Docker Local não faz parte dos Resultados de Benchmark**:
   - No Docker de host único (`infra/docker-compose.yml`), `origin`, `pgcache` e `loadgen` compartilham os mesmos núcleos de CPU da máquina host e comunicam-se via loopback (`~50 µs` RTT), violando o isolamento físico de nós e inflando artificialmente as taxas de aceleração. Por isso, o Docker local é restrito exclusivamente à montagem de ambiente e validação funcional/corretude (`scripts/verify-correctness.sh`).

---

## 4. Estrutura de Diretórios por Tag

- [`0.6.3/`](0.6.3/README-pt.md): Resultados e logs da tag `0.6.3`.
- [`0.6.4/`](0.6.4/README-pt.md): Resultados e logs da tag `0.6.4`.
- [`0.7.0/`](0.7.0/README-pt.md): Resultados e logs da tag `0.7.0`.
- [`0.7.1/`](0.7.1/README-pt.md): Resultados oficiais em DOKS 3 nós (`results-doks.tsv`, `results-complex-doks.tsv`), gate diferencial de correção (`verify-correctness-doks.txt`) e logs dos cenários complexos da tag `0.7.1`.
- [`endurance-90m/`](endurance-90m/README-pt.md): Runbook e telemetria DOKS + Grafana Cloud do teste de endurance de 1h30m e alívio de recursos na Origem (`SCALE=20`).
- [`tuned/`](tuned/README-pt.md): Resultados e logs do Perfil Otimizado / Tuned (`0.7.0` com ajustes de rede e engine no DOKS).
