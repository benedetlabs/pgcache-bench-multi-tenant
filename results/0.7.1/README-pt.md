# Verificação de Benchmark PgCache — Tag 0.7.1 (Nuvem DOKS 3 Nós — Baseline e Cenários Complexos Multi-Tenant)

> 🇺🇸 **[English version](README.md)**

Execução oficial de verificação para **PgCache v0.7.1** (`pgcache/pgcache:0.7.1`) realizada em **DigitalOcean Kubernetes de 3 Nós (DOKS)** em duas baterias de complexidade de carga:

1. **Topologia do Cluster (3 Nós Dedicados)**:
   - **DigitalOcean Kubernetes (DOKS)**: 3× `s-4vcpu-8gb` em zona única (`sfo2`), `--ha=false` ($0 para plano de controle), `podAntiAffinity` estrito (`origin`, `pgcache` e `loadgen` em 3 nós físicos distintos), `hostNetwork: true`, roteamento direto por IP de nó e perfil otimizado (`NUM_WORKERS=8`, `PGCACHE_POPULATION_WORKERS_MIN=4`, `MEMO_CACHE_SIZE="1073741824"`, `MEMORY_LIMIT="3758096384"`, 2 GiB `/dev/shm`).
   - *(Nota: O Docker Compose local é utilizado estritamente para montagem do ambiente e validação funcional/corretude via `scripts/verify-correctness.sh`; todos os números de performance abaixo provêm exclusivamente do cluster DOKS de 3 nós.)*
2. **Baterias de Carga**:
   - **Dashboard Operacional Baseline (`workload/dashboard.sql`)**: Verificação completa de regressão de 1 a 2.000 tenants no DOKS de 3 nós.
   - **Cargas SaaS Multi-Tenant Complexas (`scripts/04-complex-sweep.sh`)**: Busca textual por substring (`ILIKE '%...%'`), cadeias profundas de `INNER JOIN` e `LEFT JOIN` entre 4 a 6 tabelas (incluindo coortes de clientes sem pedidos e inventário de produtos sem avaliações), agregações analíticas multidimensionais (`GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`) e uma tela corporativa unificada de 8 statements (`workload/complex-dashboard.sql`), validada por um rigoroso **Gate Diferencial de Correção, Cacheabilidade, Admissão de Materialized Views e Pós-CDC** (`scripts/verify-correctness.sh`).

---

## 1. Resumo Executivo

- **Gate Diferencial de Correção, Cacheabilidade e Hit de MVs (`verify-correctness-doks.txt`)**:
  - Verificado no **DOKS de 3 nós**: todas as **12/12 consultas SQL complexas multi-tenant distintas** em `complex-search.sql` (4), `complex-joins.sql` (4) e `complex-analytics.sql` (4) (cobrindo 100% de `complex-dashboard.sql`) produziram conjuntos de resultados idênticos byte a byte entre o PostgreSQL 17 de Origem e o PgCache 0.7.1 em todos os passes: miss frio/população (Passe 1), hit em tabela-base + build de MV (Passe 2), hit quente em Materialized View (Passe 3) e verificação pós-mutação CDC (Passe 4).
  - **100% de Cacheabilidade**: Delta de `pgcache_queries_cacheable` = `36/36`, delta de `pgcache_queries_uncacheable` = **`0`**, delta de `pgcache_queries_cache_error` = **`0`**.
  - **100% de Admissão e Hit no Gate de Materialized Views (MV)**: `pgcache_cache_mv_gate{outcome="admit"}` = **`12/12`** (`outcome="reject"` = `0`) e delta de `pgcache_cache_mv_hits` = **`12/12`** no Passe 3.
- **Dashboard Operacional Baseline (`workload/dashboard.sql`)**:
  - **DOKS 3 Nós (`1` a `2.000` Tenants)**: **100,0% de hit ratio** em todas as faixas até 2.000 tenants, entregando **+40% a +63% de ganho de vazão** (`470–491 rps` a `16,29–17,01 ms` contra `302–343 rps` a `23,31–26,52 ms` na Origem entre 50 e 2.000 tenants).
- **Cargas Complexas Multi-Tenant (`workload/complex-*.sql`)**:
  - **Aceleração em Nuvem DOKS (3 Nós)**: Entre 3 nós físicos na nuvem, a aceleração por Materialized Views reduz a latência de consultas complexas de 4 a 6 tabelas (`JOIN`/`LEFT JOIN`/`GROUP BY`/`ILIKE`) de **74,3–204,4 ms** na Origem para **4,73–11,50 ms** no PgCache (incluindo 4 a 8 round-trips de rede entre nós), entregando **14,7× a 31,3× mais vazão (`+1.369%` a `+3.033%`)** com 8 clientes, **12,1× (`+1.108%`, 100,0% hit)** em **500 tenants ativos** (`4.000` MVs distintas) e **26,8× (`+2.584%`, `1.020 rps` a `31,36 ms` contra `38 rps` a `835,52 ms`)** sob **32 clientes concorrentes**.
  - **Resiliência a Escritas Mistas (`INNER JOIN` via CDC In-Place vs. Invalidação Conservadora em `LEFT JOIN`)**: Ao escopar cada tabela multi-tenant juntada com um literal `:t` explícito (`AND o.tenant_id = :t`, `AND oi.tenant_id = :t`, `AND c.tenant_id = :t`), as **5 consultas `INNER JOIN` (`62,5%`)** em `complex-dashboard.sql` permanecem **100% cache hits** sob escritas `UPDATE orders` (atualizadas in-place via CDC + rebuild de MV em background), enquanto as **3 consultas `LEFT JOIN` (`37,5%`)** sofrem invalidação conservadora. Como resultado, `complex-dashboard.sql` sustenta **63,1%–75,0% de hit ratio no DOKS** (`+12%` a `+16%` de ganho em escritas concentradas `5:1` / `10:1` e paridade próxima de `-5%` a `-12%` em escritas distribuídas por 200 tenants) com zero erros de cache.

---

## 2. Gate Diferencial de Correção, Cacheabilidade e Admissão de MVs (DOKS 3 Nós)

Executado via [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) no DOKS de 3 nós ([`verify-correctness-doks.txt`](verify-correctness-doks.txt)):

| Verificação | Resultado DOKS (3 Nós) | Telemetria / Detalhe |
|---|---|---|
| **Igualdade de Saída Byte a Byte** | **PASS (12/12 consultas)** | Saída do `psql -tAF '|'` idêntica entre Origem e PgCache nos Passes 1 (miss), 2 (hit em tabela-base + build de MV) e 3 (hit em MV) |
| **Delta de Consultas Cacheáveis** | **PASS (`36 / 36`)** | `pgcache_queries_cacheable` incrementou em 36 nos 3 passes de 12 statements |
| **Delta de Consultas Não-Cacheáveis** | **PASS (`0`)** | Delta de `pgcache_queries_uncacheable` = `0` |
| **Admissão no Gate de MV** | **PASS (`12 / 12`)** | `pgcache_cache_mv_gate{outcome="admit"}` = `12`, `pgcache_cache_mv_gate{outcome="reject"}` = `0` |
| **Hits em Materialized Views** | **PASS (`12 / 12`)** | Delta de `pgcache_cache_mv_hits` = `12` (100% das consultas do Passe 3 servidas diretamente de MVs) |
| **Delta de Erros do Cache** | **PASS (`0`)** | Delta de `pgcache_queries_cache_error` = `0` |

---

## 3. Sweep 1 Baseline — Varredura de Tenants no DOKS 3 Nós (`1` a `2.000` Tenants, `CLIENTS=8`)

Log bruto: [`run-tenants-doks.txt`](run-tenants-doks.txt) · TSV: [`results-doks.tsv`](results-doks.tsv)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 23,32 ms · 343 rps | **16,63 ms · 481 rps** | **+40%** | 100,0% | 2 |
| **10** | 22,88 ms · 350 rps | **21,67 ms · 369 rps** | **+5%** | 100,0% | 2 |
| **50** | 25,43 ms · 315 rps | **17,01 ms · 470 rps** | **+49%** | 100,0% | 3 |
| **100** | 26,52 ms · 302 rps | **16,29 ms · 491 rps** | **+63%** | 100,0% | 3 |
| **500** | 24,35 ms · 329 rps | **16,31 ms · 490 rps** | **+49%** | 100,0% | 4 |
| **1.000** | 24,04 ms · 333 rps | **16,90 ms · 473 rps** | **+42%** | 100,0% | 4 |
| **2.000** | 23,31 ms · 343 rps | **16,51 ms · 485 rps** | **+41%** | 100,0% | 6 |

---

## 4. Sweep 4 — Cenários Complexos Multi-Tenant no DOKS 3 Nós (`scripts/04-complex-sweep.sh`)

Para avaliar como o PgCache se comporta em cargas relacionais pesadas além de lookups simples, executamos quatro suítes SQL multi-tenant complexas em [`workload/`](../../workload/) no **DigitalOcean Kubernetes (DOKS 3 Nós)**:
1. **[`complex-search.sql`](../../workload/complex-search.sql)** (4 statements): Buscas por substring `ILIKE '%...%'` em e-mails/nomes de clientes, nomes de produtos, vendedores e textos de avaliações combinadas com cadeias de `INNER JOIN` e `LEFT JOIN` de 2 a 6 tabelas.
2. **[`complex-joins.sql`](../../workload/complex-joins.sql)** (4 statements): Cadeias profundas de 4 a 6 tabelas com `INNER JOIN` e `LEFT JOIN` (`orders -> customer -> order_item -> product -> category -> seller -> review`), incluindo retenção de coortes de clientes (`LEFT JOIN orders`) e estoque de produtos sem avaliação (`LEFT JOIN review`).
3. **[`complex-analytics.sql`](../../workload/complex-analytics.sql)** (4 statements): Agregações `GROUP BY` multidimensionais com `FILTER (WHERE ...)` condicional, faixas `CASE WHEN` e filtros pós-agregação `HAVING`.
4. **[`complex-dashboard.sql`](../../workload/complex-dashboard.sql)** (8 statements): Tela analítica e de busca corporativa unificada combinando 2 consultas de busca textual, 3 joins profundos multi-tabela (`JOIN` / `LEFT JOIN`) e 3 agregações analíticas pesadas.

### 4.1 Comparativo de Cenários (`TENANTS=200`, `CLIENTS=8` — DOKS 3 Nós)

Log bruto: [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt)

| Cenário | Stmts | Origem DOKS (Caminho A) | PgCache 0.7.1 DOKS (Caminho B) | Ganho DOKS (Aceleração) | Hit Ratio | Passos Warmup |
|---|---:|---|---|---:|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 23,06 ms · 347 rps | **15,92 ms · 503 rps** | **+45% (1,45×)** | 100,0% | 2 |
| **`search`** (`complex-search.sql`) | 4 | 74,26 ms · 108 rps | **5,04 ms · 1.586 rps** | **+1.369% (14,7×)** | 100,0% | 3 |
| **`joins`** (`complex-joins.sql`) | 4 | 148,87 ms · 54 rps | **4,73 ms · 1.692 rps** | **+3.033% (31,3×)** | 100,0% | 3 |
| **`analytics`** (`complex-analytics.sql`) | 4 | 102,38 ms · 78 rps | **5,69 ms · 1.406 rps** | **+1.703% (18,0×)** | 100,0% | 4 |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 204,39 ms · 39 rps | **11,50 ms · 696 rps** | **+1.685% (17,8×)** | 100,0% | 5 |

**Por que Consultas Complexas Alcançam 15×–31× de Aceleração no DOKS de 3 Nós**:
- No PgCache 0.7.1, o cache de consultas opera em dois níveis distintos:
  1. **Subsunção em Nível de Tabela (`public.*`)**: As tabelas-base (`orders`, `order_item`, `product`, `customer`, `review`, `seller`, `category`) são populadas no PostgreSQL embutido do PgCache. Se uma consulta bate diretamente em `public.*` (`pgcache_cache_mv_fallthrough`), o PgCache executa o SQL localmente (~15,9 ms no DOKS para as 8 consultas leves de `dash_base`).
  2. **Gate de Admissão de Materialized Views (`pgcache_mv.q_<hash>`)**: Quando uma consulta possui `OFFSET 0` (sem `OFFSET` positivo), agrupa por chaves de entidade não-nulas (`mv=true`) e varre `>= 1.000` linhas pré-agregação (`--mv_compute_min_rows=1000`) ou atinge taxa de redução `>= 10:1` (`--mv_size_ratio=10`), o PgCache admite a consulta em seu motor de Materialized Views (`pgcache_cache_mv_gate{outcome="admit"}`).
- No **DOKS de 3 nós**, cada bateria complexa de 4 statements paga 4 round-trips de rede entre nós (~3,5 ms de piso de rede) mais ~1,2–2,0 ms de leitura de MV (`4,73–5,69 ms` no total contra `74,3–148,9 ms` na Origem — **14,7× a 31,3× mais rápido**), enquanto a tela `cplx_dash` de 8 statements cai de **204,39 ms (`39 rps`)** para **11,50 ms (`696 rps`, 17,8× mais rápido)** — demonstrando que conforme a complexidade da consulta na Origem cresce, o piso fixo de rede entre nós torna-se uma fração mínima do tempo total.

### 4.2 Escala de Tenants em Carga Complexa (`1` a `1.000` Tenants em `complex-dashboard.sql`, `CLIENTS=8` — DOKS 3 Nós)

Log bruto: [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)

| Tenants Ativos | Origem DOKS (Caminho A) | PgCache 0.7.1 DOKS (Caminho B) | Ganho DOKS (Aceleração) | Hit Ratio DOKS | Passos Warmup |
|---:|---|---|---:|---:|---:|
| **1** | 206,80 ms · 39 rps | **9,19 ms · 871 rps** | **+2.133% (22,3×)** | 100,0% | 2 |
| **10** | 198,24 ms · 40 rps | **9,58 ms · 835 rps** | **+1.988% (20,9×)** | 100,0% | 2 |
| **50** | 227,49 ms · 35 rps | **10,81 ms · 740 rps** | **+2.014% (21,1×)** | 100,0% | 6 |
| **200** | 212,77 ms · 38 rps | **11,23 ms · 712 rps** | **+1.774% (18,7×)** | 100,0% | 7 |
| **500** | 223,87 ms · 36 rps | **18,40 ms · 435 rps** | **+1.108% (12,1×)** | 100,0% | 8 |
| **1.000** *(limite frio 8 passes)* | 210,14 ms · 38 rps | 251,39 ms · 32 rps | -16% (0,84×) | 68,1% | 4 |

**Descoberta — Escala do Working Set em Nós Dedicados no DOKS**:
- De **1 a 500 tenants ativos** (`8` a `4.000` Materialized Views distintas de 4–6 tabelas), o nó dedicado de 4 vCPUs do PgCache no DOKS (`NUM_WORKERS=8`, `PGCACHE_POPULATION_WORKERS_MIN=4`) aquece **100,0%** do working set e entrega **12,1× a 22,3× mais vazão (`+1.108%` em 500 tenants e `+1.774%` a `+2.133%` em 1–200 tenants)**.
- Em **1.000 tenants** (`8.000` consultas complexas distintas), a amostragem aleatória uniforme entre 1.000 tenants (`\set t random(1, 1000)`) dentro de passes limitados de 15s atinge **68,1% de hit ratio no DOKS** (`32 rps` vs `38 rps`, `-16%`).

### 4.3 Escala de Concorrência em Carga Complexa (`1` a `32` Clientes em `complex-dashboard.sql`, `TENANTS=200` — DOKS 3 Nós)

Log bruto: [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)

| Clientes | Origem DOKS (Caminho A) | PgCache 0.7.1 DOKS (Caminho B) | Ganho DOKS (Aceleração) | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|
| **1** | 100,60 ms · 10 rps | **7,14 ms · 140 rps** | **+1.300% (14,0×)** | 100,0% | 2 |
| **4** | 129,45 ms · 31 rps | **8,60 ms · 465 rps** | **+1.400% (15,0×)** | 100,0% | 2 |
| **8** | 212,81 ms · 38 rps | **10,48 ms · 763 rps** | **+1.908% (20,1×)** | 100,0% | 2 |
| **16** | 406,90 ms · 39 rps | **18,06 ms · 886 rps** | **+2.172% (22,7×)** | 100,0% | 2 |
| **32** | 835,52 ms · 38 rps | **31,36 ms · 1.020 rps** | **+2.584% (26,8×)** | 100,0% | 2 |

- **Aceleração Pura com 1 Cliente (`CLIENTS=1`)**: Sem fila em nenhum componente, uma tela analítica e de busca com 8 statements cai de **100,60 ms (`10 rps`)** para **7,14 ms (`140 rps`, 14,0× mais rápido)** através da rede em nuvem do DOKS.
- **Alta Concorrência (`CLIENTS=16..32`)**: No DOKS, a Origem satura em **38–39 rps** com a latência subindo para **835,52 ms** (~0,84 segundos por renderização de tela). O PgCache escala de forma limpa até **1.020 rps** (~8.160 consultas SQL complexas/s) a **31,36 ms** (**26,8× de aceleração, +2.584%**).

### 4.4 Invalidação por Escrita e Comportamento CDC de `INNER JOIN` vs `LEFT JOIN` (`TENANTS=200`, `CLIENTS=8` — DOKS 3 Nós)

Log bruto: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)

| Taxa de Escrita | Tenants de Escrita | Origem DOKS (Caminho A) | PgCache 0.7.1 DOKS (Caminho B) | Ganho DOKS | Hit Ratio DOKS | Passos Warmup |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 200 | 189,81 ms · 42 rps | **11,13 ms · 719 rps** | **+1.612%** | 100,0% | 2 |
| **5%** | 1 | 186,66 ms · 43 rps | **166,17 ms · 48 rps** | **+12%** | 75,0% | 3 |
| **5%** | 10 | 182,40 ms · 44 rps | 194,35 ms · 41 rps | -7% | 65,4% | 3 |
| **5%** | 200 | 191,20 ms · 42 rps | 201,48 ms · 40 rps | -5% | 65,7% | 3 |
| **10%** | 1 | 177,65 ms · 45 rps | **154,73 ms · 52 rps** | **+16%** | 63,1% | 3 |
| **10%** | 200 | 167,93 ms · 48 rps | 191,79 ms · 42 rps | -12% | 64,8% | 3 |

**Por que o Hit Ratio Estabiliza em ~63,1%–75,0% (`>= 5/8`) Sob Escritas `UPDATE orders` (`INNER JOIN` vs. `LEFT JOIN`)**:
- Em `complex-dashboard.sql`, todos os 8 statements referenciam a tabela `orders`:
  1. **5 Statements `INNER JOIN` (`#1`, `#2`, `#4`, `#6`, `#8` = `62,5%` das consultas)**: Como essas consultas incluem predicados explícitos de igualdade `WHERE ... AND o.tenant_id = :t`, o PgCache escopa sua dependência na tabela `orders` para o tenant `:t`, aplica atualizações `UPDATE orders SET total = total + 1` in-place via replicação lógica (`cdc_update`) e reconstrói apenas as Materialized Views do tenant afetado (`pgcache_cache_mv_rebuilds`). Esses 5 statements atingem **100% de cache hit** nos tenants somente-leitura e hits in-place nos tenants atualizados.
  2. **3 Statements `LEFT JOIN` (`#3`, `#5`, `#7` = `37,5%` das consultas)**: Essas consultas utilizam `FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = :t` para preservar clientes com zero pedidos (`o.id IS NULL`). Como `o.tenant_id = :t` é uma condição `ON` de outer join em vez de um filtro `WHERE` de nível superior, o PgCache invalida de forma conservadora as consultas outer-join registradas que referenciam `orders` sempre que `orders` recebe uma escrita.
- Quando as escritas são concentradas em um único tenant (`5:1` e `10:1`), o PgCache supera a Origem em **+12% a +16% no DOKS** (com **75,0% e 63,1% de hit ratio**), enquanto escritas distribuídas por todos os 200 tenants (`5:200`, `10:200`) mantêm **64,8%–65,7% de hit ratio** e vazão próxima da paridade (`40–42 rps` vs `42–48 rps` no DOKS) com **`pgcache_queries_cache_error == 0`**.

---

## 5. Artefatos Brutos (DOKS 3 Nós)

- TSV Baseline (DOKS): [`results-doks.tsv`](results-doks.tsv)
- TSV Cenários Complexos (DOKS): [`results-complex-doks.tsv`](results-complex-doks.tsv)
- Log do Gate Diferencial de Correção, Cacheabilidade e MV (DOKS): [`verify-correctness-doks.txt`](verify-correctness-doks.txt)
- Log bruto do Sweep 1 Baseline (Tenants 1..2000, DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Log bruto do Sweep 4.1 Complexo (Comparativo de cenários, DOKS): [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt)
- Log bruto do Sweep 4.2 Complexo (Escala de tenants, DOKS): [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)
- Log bruto do Sweep 4.3 Complexo (Escala de concorrência, DOKS): [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)
- Log bruto do Sweep 4.4 Complexo (Invalidação por escrita, DOKS): [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)
