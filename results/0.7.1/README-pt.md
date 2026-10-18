# Verificação de Benchmark PgCache — Tag 0.7.1 (Baseline e Cenários Complexos Multi-Tenant)

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.7.1** (`pgcache/pgcache:0.7.1-arm64` / `pgcache/pgcache:0.7.1`) cobrindo duas baterias de benchmark:
1. **Dashboard Operacional Baseline (`workload/dashboard.sql`)**: Verificação completa de regressão de 1 a 1.000 tenants, 1 a 32 clientes concorrentes e cargas mistas com 0%–10% de escritas (`scripts/01`–`03`).
2. **Cargas SaaS Multi-Tenant Complexas (`scripts/04-complex-sweep.sh`)**: Busca textual por substring (`ILIKE '%...%'`), cadeias profundas de `INNER JOIN` e `LEFT JOIN` entre 4 a 6 tabelas (incluindo coortes de clientes sem pedidos e inventário de produtos sem avaliações), agregações analíticas multidimensionais (`GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`) e uma tela corporativa unificada de 8 statements (`workload/complex-dashboard.sql`), validada por um rigoroso **Gate Diferencial de Correção, Cacheabilidade e Admissão de Materialized Views** (`scripts/verify-correctness.sh`).

---

## 1. Resumo Executivo

- **Gate Diferencial de Correção, Cacheabilidade e Hit de MVs (`verify-correctness.txt`)**:
  - Todas as **12/12 consultas SQL complexas multi-tenant distintas** em `complex-search.sql` (4), `complex-joins.sql` (4) e `complex-analytics.sql` (4) (cobrindo 100% de `complex-dashboard.sql`) produziram conjuntos de resultados idênticos byte a byte entre o PostgreSQL 17 de Origem e o PgCache 0.7.1 nos três passes: miss frio/população (Passe 1), hit em tabela-base + build de MV (Passe 2) e hit quente em Materialized View (Passe 3).
  - **100% de Cacheabilidade**: Delta de `pgcache_queries_cacheable` = `36/36`, delta de `pgcache_queries_uncacheable` = **`0`**, delta de `pgcache_queries_cache_error` = **`0`**.
  - **100% de Admissão e Hit no Gate de Materialized Views (MV)**: `pgcache_cache_mv_gate{outcome="admit"}` = **`12/12`** (`outcome="reject"` = `0`) e delta de `pgcache_cache_mv_hits` = **`12/12`** no Passe 3.
- **Dashboard Operacional Baseline (`workload/dashboard.sql`)**:
  - **Hit Ratio**: **100,0%** de 1 a 500 tenants e **99,9%** em 1.000 tenants.
  - **Ganho de Vazão**: **+116% a +139%** na escala de tenants (`450–514 rps` vs `196–222 rps` na Origem), **+93% a +138%** na escala de concorrência (`1..32` clientes) e **+40% a +110%** sob taxas de escrita de 5%–10%.
- **Cargas Complexas Multi-Tenant (`workload/complex-*.sql`)**:
  - **Aceleração em Leitura**: Uma vez admitidas no motor de Materialized Views do PgCache (`pgcache_mv.q_<hash>`), consultas pesadas de 4 a 6 tabelas com `JOIN`/`LEFT JOIN`/`GROUP BY`/`ILIKE` caem de **88,7–209,6 ms** na Origem para **1,25–2,86 ms** no PgCache (~0,31–0,38 ms por statement), entregando **58,0× a 97,4× mais vazão (`+5.703%` a `+9.636%`)** com 8 clientes e até **94,0× (`+9.300%`, `3.478 rps` vs `37 rps`)** sob 32 clientes concorrentes.
  - **Resiliência a Escritas Mistas (`INNER JOIN` via CDC In-Place vs. Invalidação Conservadora em `LEFT JOIN`)**: Ao escopar cada tabela multi-tenant juntada com um literal `:t` explícito (`AND o.tenant_id = :t`, `AND oi.tenant_id = :t`, `AND c.tenant_id = :t`), as **5 consultas `INNER JOIN` (`62,5%`)** em `complex-dashboard.sql` permanecem **100% cache hits** sob escritas `UPDATE orders` (atualizadas in-place via CDC + rebuild de MV em background), enquanto as **3 consultas `LEFT JOIN` (`37,5%`)** (onde `o.tenant_id = :t` reside na cláusula `ON` do outer join) sofrem invalidação conservadora. Como resultado, `complex-dashboard.sql` sustenta **62,5%–67,6% de hit ratio** e **+8% a +30% de ganho de vazão** sob taxas de escrita de 5%–10% (`5:1`, `5:10`, `10:1`, `10:200`) com zero erros de cache.

---

## 2. Gate Diferencial de Correção, Cacheabilidade e Admissão de MVs

Executado via [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) (log bruto: [`verify-correctness.txt`](verify-correctness.txt)):

| Verificação | Resultado | Telemetria / Detalhe |
|---|---|---|
| **Igualdade de Saída Byte a Byte** | **PASS (12/12 consultas)** | Saída do `psql -tAF '|'` idêntica entre Origem e PgCache nos Passes 1 (miss), 2 (hit em tabela-base + build de MV) e 3 (hit em MV) |
| **Delta de Consultas Cacheáveis** | **PASS (`36 / 36`)** | `pgcache_queries_cacheable` incrementou em 36 nos 3 passes de 12 statements |
| **Delta de Consultas Não-Cacheáveis** | **PASS (`0`)** | Delta de `pgcache_queries_uncacheable` = `0` |
| **Admissão no Gate de MV** | **PASS (`12 / 12`)** | `pgcache_cache_mv_gate{outcome="admit"}` = `12`, `pgcache_cache_mv_gate{outcome="reject"}` = `0` |
| **Hits em Materialized Views** | **PASS (`12 / 12`)** | Delta de `pgcache_cache_mv_hits` = `12` (100% das consultas do Passe 3 servidas diretamente de MVs) |
| **Delta de Erros do Cache** | **PASS (`0`)** | Delta de `pgcache_queries_cache_error` = `0` |

---

## 3. Varreduras Baseline 1–3 (`workload/dashboard.sql`)

### 3.1 Sweep 1 — Varredura de Tenants (1 a 1.000 Tenants, `CLIENTS=8`)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 37,08 ms · 216 rps | **15,56 ms · 514 rps** | **+138%** | 100,0% | 2 |
| **10** | 36,11 ms · 222 rps | **16,13 ms · 496 rps** | **+123%** | 100,0% | 2 |
| **50** | 37,21 ms · 215 rps | **17,22 ms · 465 rps** | **+116%** | 100,0% | 3 |
| **200** | 40,11 ms · 199 rps | **16,86 ms · 475 rps** | **+139%** | 100,0% | 3 |
| **500** | 40,48 ms · 198 rps | **17,78 ms · 450 rps** | **+127%** | 100,0% | 4 |
| **1.000** | 40,87 ms · 196 rps | **17,73 ms · 451 rps** | **+130%** | 99,9% | 5 |

### 3.2 Sweep 2 — Concorrência de Clientes (`TENANTS=1.000`)

| Clientes | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 13,26 ms · 75 rps | **6,89 ms · 145 rps** | **+93%** | 100,0% | 2 |
| **4** | 21,82 ms · 183 rps | **9,82 ms · 408 rps** | **+123%** | 100,0% | 2 |
| **8** | 38,67 ms · 207 rps | **16,75 ms · 478 rps** | **+131%** | 100,0% | 2 |
| **16** | 67,48 ms · 237 rps | **30,76 ms · 520 rps** | **+119%** | 100,0% | 2 |
| **32** | 128,51 ms · 249 rps | **53,93 ms · 593 rps** | **+138%** | 100,0% | 2 |

### 3.3 Sweep 3 — Taxa de Escritas e Concentração (`TENANTS=1.000`, `CLIENTS=8`)

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 1.000 | 40,60 ms · 197 rps | **16,83 ms · 475 rps** | **+141%** | 100,0% | 2 |
| **5%** | 1 | 36,80 ms · 217 rps | **17,55 ms · 456 rps** | **+110%** | 100,0% | 2 |
| **5%** | 10 | 37,12 ms · 215 rps | **20,91 ms · 383 rps** | **+78%** | 100,0% | 2 |
| **5%** | 1.000 | 38,89 ms · 206 rps | **23,23 ms · 344 rps** | **+67%** | 100,0% | 2 |
| **10%** | 1 | 35,99 ms · 222 rps | **18,59 ms · 430 rps** | **+94%** | 100,0% | 2 |
| **10%** | 1.000 | 36,41 ms · 220 rps | **25,98 ms · 308 rps** | **+40%** | 100,0% | 2 |

---

## 4. Sweep 4 — Cenários Complexos Multi-Tenant (`scripts/04-complex-sweep.sh`)

Para avaliar como o PgCache se comporta em cargas relacionais pesadas além de lookups simples, projetamos quatro suítes SQL multi-tenant complexas em [`workload/`](../../workload/):
1. **[`complex-search.sql`](../../workload/complex-search.sql)** (4 statements): Buscas por substring `ILIKE '%...%'` em e-mails/nomes de clientes, nomes de produtos, vendedores e textos de avaliações combinadas com cadeias de `INNER JOIN` e `LEFT JOIN` de 2 a 6 tabelas.
2. **[`complex-joins.sql`](../../workload/complex-joins.sql)** (4 statements): Cadeias profundas de 4 a 6 tabelas com `INNER JOIN` e `LEFT JOIN` (`orders -> customer -> order_item -> product -> category -> seller -> review`), incluindo retenção de coortes de clientes (`LEFT JOIN orders`) e estoque de produtos sem avaliação (`LEFT JOIN review`).
3. **[`complex-analytics.sql`](../../workload/complex-analytics.sql)** (4 statements): Agregações `GROUP BY` multidimensionais com `FILTER (WHERE ...)` condicional, faixas `CASE WHEN` e filtros pós-agregação `HAVING`.
4. **[`complex-dashboard.sql`](../../workload/complex-dashboard.sql)** (8 statements): Tela analítica e de busca corporativa unificada combinando 2 consultas de busca textual, 3 joins profundos multi-tabela (`JOIN` / `LEFT JOIN`) e 3 agregações analíticas pesadas.

### 4.1 Comparativo de Cenários (`TENANTS=200`, `CLIENTS=8`)

Log bruto: [`run-complex-scenarios.txt`](run-complex-scenarios.txt)

| Cenário | Statements | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---|---:|---|---|---:|---:|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 37,61 ms · 213 rps | **16,05 ms · 498 rps** | **+134%** | **2,3×** | 100,0% | 3 |
| **`search`** (`complex-search.sql`) | 4 | 88,67 ms · 90 rps | **1,53 ms · 5.223 rps** | **+5.703%** | **58,0×** | 100,0% | 4 |
| **`joins`** (`complex-joins.sql`) | 4 | 121,46 ms · 66 rps | **1,25 ms · 6.426 rps** | **+9.636%** | **97,4×** | 100,0% | 5 |
| **`analytics`** (`complex-analytics.sql`) | 4 | 92,31 ms · 87 rps | **1,39 ms · 5.737 rps** | **+6.494%** | **65,9×** | 100,0% | 5 |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 209,62 ms · 38 rps | **2,86 ms · 2.798 rps** | **+7.263%** | **73,6×** | 100,0% | 6 |

**Por que Consultas Complexas Alcançam 58×–97× de Aceleração (Cache em Dois Estágios e Gate de Admissão de MVs)**:
- No PgCache 0.7.1, o cache de consultas opera em dois níveis distintos:
  1. **Subsunção em Nível de Tabela (`public.*`)**: As tabelas-base (`orders`, `order_item`, `product`, `customer`, `review`, `seller`, `category`) são populadas no PostgreSQL embutido do PgCache. Se uma consulta bate diretamente em `public.*` (`pgcache_cache_mv_fallthrough`), o PgCache ainda executa o join/agregação localmente (~16 ms para as 8 consultas leves de `dash_base`).
  2. **Gate de Admissão de Materialized Views (`pgcache_mv.q_<hash>`)**: Quando uma consulta possui `OFFSET 0` (sem `OFFSET` positivo), agrupa por chaves de entidade não-nulas (`mv=true`) e varre `>= 1.000` linhas pré-agregação (`--mv_compute_min_rows=1000`) ou atinge taxa de redução `>= 10:1` (`--mv_size_ratio=10`), o PgCache admite a consulta em seu motor de Materialized Views (`pgcache_cache_mv_gate{outcome="admit"}`).
- Como todas as 8 consultas em `complex-dashboard.sql` (e todas as 12 consultas em `complex-search`, `complex-joins` e `complex-analytics`) satisfazem o gate de MV, o PgCache pré-materializa a visão de 10 a 20 linhas em `pgcache_mv.q_<hash>` e responde às consultas subsequentes via `pgcache_cache_mv_hits` em **~0,31–0,38 ms por statement** (`1,25–1,53 ms` para 4 statements; `2,86 ms` para 8 statements), contra **88,7–209,6 ms** na Origem.

### 4.2 Escala de Tenants em Carga Complexa (`1` a `1.000` Tenants em `complex-dashboard.sql`, `CLIENTS=8`)

Log bruto: [`run-complex-tenants.txt`](run-complex-tenants.txt)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|---:|
| **1** | 208,31 ms · 38 rps | **2,28 ms · 3.511 rps** | **+9.139%** | **92,4×** | 100,0% | 2 |
| **10** | 168,59 ms · 47 rps | **2,24 ms · 3.579 rps** | **+7.515%** | **76,1×** | 100,0% | 2 |
| **50** | 184,07 ms · 43 rps | **2,27 ms · 3.532 rps** | **+8.114%** | **82,1×** | 100,0% | 3 |
| **200** | 206,95 ms · 39 rps | **2,90 ms · 2.763 rps** | **+6.985%** | **70,8×** | 100,0% | 8 |
| **500** | 212,27 ms · 38 rps | **67,55 ms · 118 rps** | **+211%** | **3,1×** | 97,4% | 8 |
| **1.000** *(limite frio 8 passes)* | 226,02 ms · 35 rps | 517,86 ms · 15 rps | -57% | 0,43× | 62,7% | 5 |

**Descoberta — Escala do Working Set de Tenants e Taxa de População no Cold-Start em 500–1.000 Tenants**:
- De **1 a 200 tenants** (`8` a `1.600` Materialized Views distintas de 4–6 tabelas), o PgCache aquece 100,0% do working set e entrega **+6.985% a +9.139% de ganho de vazão (`70,8× a 92,4×` de aceleração, `2.763–3.579 rps` vs `38–47 rps` na Origem)**.
- Em **500 tenants** (`4.000` consultas complexas distintas), o PgCache atinge **97,4% de hit ratio** dentro de 8 passes de aquecimento e supera a Origem em **+211% (`3,1×` de aceleração, `118 rps` vs `38 rps`, `67,55 ms` vs `212,27 ms`)**.
- Em **1.000 tenants** (`8.000` consultas complexas distintas), a amostragem aleatória uniforme entre 1.000 tenants (`\set t random(1, 1000)`) combinada ao custo de população fria por tenant (~100–250 ms por tenant frio via `SELECT DISTINCT` + build de MV) aquece **62,7%** das consultas dentro da janela limitada de passes de 15s, deixando 37,3% de misses frios em andamento durante o passe medido.

### 4.3 Escala de Concorrência em Carga Complexa (`1` a `32` Clientes em `complex-dashboard.sql`, `TENANTS=200`)

Log bruto: [`run-complex-clients.txt`](run-complex-clients.txt)

| Clientes | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|---:|
| **1** | 84,83 ms · 12 rps | **1,73 ms · 578 rps** | **+4.717%** | **48,2×** | 100,0% | 2 |
| **4** | 92,22 ms · 43 rps | **2,26 ms · 1.770 rps** | **+4.016%** | **41,2×** | 100,0% | 2 |
| **8** | 194,69 ms · 41 rps | **2,66 ms · 3.003 rps** | **+7.224%** | **73,2×** | 100,0% | 2 |
| **16** | 400,89 ms · 40 rps | **4,60 ms · 3.475 rps** | **+8.588%** | **86,9×** | 100,0% | 2 |
| **32** | 862,44 ms · 37 rps | **9,20 ms · 3.478 rps** | **+9.300%** | **94,0×** | 100,0% | 2 |

- **Aceleração Pura com 1 Cliente (`CLIENTS=1`)**: Sem fila em nenhum componente, uma tela analítica e de busca com 8 statements cai de **84,83 ms (`12 rps`)** na Origem para **1,73 ms (`578 rps`)** no PgCache — uma aceleração pura de cache de **48,2× (`+4.717%`)**.
- **Alta Concorrência (`CLIENTS=16..32`)**: A Origem satura em **37–40 rps** com a latência subindo para **862,44 ms** (~0,86 segundos por renderização de tela), enquanto o PgCache sustenta **3.475–3.478 rps** (~27.800 consultas SQL/s) a **4,60–9,20 ms** por tela (**86,9× a 94,0× de aceleração**).

### 4.4 Invalidação por Escrita e Comportamento CDC de `INNER JOIN` vs `LEFT JOIN` (`TENANTS=200`, `CLIENTS=8`)

Log bruto: [`run-complex-writes.txt`](run-complex-writes.txt)

| Taxa de Escrita | Tenants de Escrita | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Hit Ratio | Passos Warmup |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 200 | 196,12 ms · 41 rps | **2,62 ms · 3.059 rps** | **+7.361%** | 100,0% | 2 |
| **5%** | 1 | 191,28 ms · 42 rps | **166,86 ms · 48 rps** | **+14%** | 67,6% | 2 |
| **5%** | 10 | 216,04 ms · 37 rps | **167,12 ms · 48 rps** | **+30%** | 63,3% | 2 |
| **5%** | 200 | 210,42 ms · 38 rps | 220,45 ms · 36 rps | -5% | 64,0% | 3 |
| **10%** | 1 | 206,33 ms · 39 rps | **163,51 ms · 49 rps** | **+26%** | 63,1% | 2 |
| **10%** | 200 | 213,03 ms · 38 rps | **195,50 ms · 41 rps** | **+8%** | 62,5% | 3 |

**Por que o Hit Ratio Estabiliza em ~62,5% (`5/8`) Sob Escritas `UPDATE orders` (`INNER JOIN` vs. `LEFT JOIN`)**:
- Em `complex-dashboard.sql`, todos os 8 statements referenciam a tabela `orders`:
  1. **5 Statements `INNER JOIN` (`#1`, `#2`, `#4`, `#6`, `#8` = `62,5%` das consultas)**: Como essas consultas incluem predicados explícitos de igualdade `WHERE ... AND o.tenant_id = :t`, o PgCache escopa sua dependência na tabela `orders` para o tenant `:t`, aplica atualizações `UPDATE orders SET total = total + 1` in-place via replicação lógica (`cdc_update`) e reconstrói apenas as Materialized Views do tenant afetado (`pgcache_cache_mv_rebuilds`, mediana de `48 ms`). Esses 5 statements atingem **100% de cache hit** nos tenants somente-leitura e hits in-place nos tenants atualizados.
  2. **3 Statements `LEFT JOIN` (`#3`, `#5`, `#7` = `37,5%` das consultas)**: Essas consultas utilizam `FROM customer c LEFT JOIN orders o ON o.customer_id = c.id AND o.tenant_id = :t` para preservar clientes com zero pedidos (`o.id IS NULL`). Como `o.tenant_id = :t` é uma condição `ON` de outer join em vez de um filtro `WHERE` de nível superior, o PgCache invalida de forma conservadora as consultas outer-join registradas que referenciam `orders` sempre que `orders` recebe uma escrita.
- Como resultado, exatamente **5 dos 8 statements (`62,5%`)** permanecem em cache quente (`62,5%–67,6%` de hit ratio observado) enquanto os 3 statements de outer join são repopulados, permitindo que o PgCache mantenha **+8% a +30% mais vazão** (`41–49 rps` vs `37–42 rps` na Origem) sob taxas de escrita de 5%–10% (`5:1`, `5:10`, `10:1`, `10:200`) e paridade (`-5%`, `36 rps` vs `38 rps`) em `5:200`, com **`pgcache_queries_cache_error == 0`**.

---

## 5. Artefatos Brutos

- TSV legível por máquina (Baseline): [`results.tsv`](results.tsv) / [`results-docker.tsv`](results-docker.tsv)
- TSV legível por máquina (Cenários Complexos): [`results-complex.tsv`](results-complex.tsv)
- Log do Gate Diferencial de Correção, Cacheabilidade e MV: [`verify-correctness.txt`](verify-correctness.txt)
- Log bruto do Sweep 1 Baseline (Tenants): [`run-tenants.txt`](run-tenants.txt)
- Log bruto do Sweep 2 Baseline (Concorrência): [`run-clients.txt`](run-clients.txt)
- Log bruto do Sweep 3 Baseline (Escritas): [`run-writes.txt`](run-writes.txt)
- Log bruto do Sweep 4.1 Complexo (Comparativo de cenários): [`run-complex-scenarios.txt`](run-complex-scenarios.txt)
- Log bruto do Sweep 4.2 Complexo (Escala de tenants): [`run-complex-tenants.txt`](run-complex-tenants.txt)
- Log bruto do Sweep 4.3 Complexo (Escala de concorrência): [`run-complex-clients.txt`](run-complex-clients.txt)
- Log bruto do Sweep 4.4 Complexo (Invalidação por escrita): [`run-complex-writes.txt`](run-complex-writes.txt)
