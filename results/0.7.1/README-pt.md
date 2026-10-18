# Verificação de Benchmark PgCache — Tag 0.7.1 (Baseline e Cenários Complexos Multi-Tenant)

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.7.1** (`pgcache/pgcache:0.7.1-arm64` / `pgcache/pgcache:0.7.1`) cobrindo duas baterias de benchmark:
1. **Dashboard Operacional Baseline (`workload/dashboard.sql`)**: Verificação completa de regressão de 1 a 1.000 tenants, 1 a 32 clientes concorrentes e cargas mistas com 0%–10% de escritas (`scripts/01`–`03`).
2. **Cargas SaaS Multi-Tenant Complexas (`scripts/04-complex-sweep.sh`)**: Busca textual por substring (`ILIKE '%...%'`), cadeias profundas de `INNER JOIN` e `LEFT JOIN` entre 4 a 6 tabelas (incluindo coortes de clientes sem pedidos e inventário de produtos sem avaliações), agregações analíticas multidimensionais (`GROUP BY`, `FILTER (WHERE ...)`, `CASE WHEN`, `HAVING`) e uma tela corporativa unificada de 8 statements (`workload/complex-dashboard.sql`), validada por um rigoroso **Gate Diferencial de Correção, Cacheabilidade e Admissão de Materialized Views** (`scripts/verify-correctness.sh`).

---

## 1. Resumo Executivo

- **Gate Diferencial de Correção e 100% de Cacheabilidade (`verify-correctness.txt`)**:
  - Todas as **8/8 consultas SQL complexas multi-tenant** em `workload/complex-dashboard.sql` produziram conjuntos de resultados idênticos byte a byte entre o PostgreSQL 17 de Origem e o PgCache 0.7.1 tanto na execução fria (Passe 1) quanto na execução aquecida (Passe 2).
  - **100% de Cacheabilidade**: Delta de `pgcache_queries_cacheable` = `16/16`, delta de `pgcache_queries_uncacheable` = **`0`**, delta de `pgcache_queries_error` = **`0`**.
  - **100% de Admissão no Gate de Materialized Views (MV)**: `pgcache_cache_mv_gate{result="admitted"}` = **`8/8`** (`rejected = 0`).
- **Dashboard Operacional Baseline (`workload/dashboard.sql`)**:
  - **Hit Ratio**: **100,0%** de 1 a 500 tenants e **99,9%** em 1.000 tenants.
  - **Ganho de Vazão**: **+116% a +139%** na escala de tenants (`450–514 rps` vs `196–222 rps` na Origem), **+93% a +138%** na escala de concorrência (`1..32` clientes) e **+40% a +110%** sob taxas de escrita de 5%–10%.
- **Cargas Complexas Multi-Tenant (`workload/complex-*.sql`)**:
  - **Aceleração em Leitura**: Uma vez admitidas no motor de Materialized Views do PgCache (`pgcache_mv.q_<hash>`), consultas pesadas de 4 a 6 tabelas com `JOIN`/`LEFT JOIN`/`GROUP BY`/`ILIKE` caem de **95,8–217,4 ms** na Origem para **1,31–2,73 ms** no PgCache (~0,33 ms por statement), entregando **72,8× a 96,8× mais vazão (`+7.183%` a `+9.575%`)** com 8 clientes e até **108,0× (`+10.697%`, `3.260 rps` vs `33 rps`)** sob 16–32 clientes concorrentes.
  - **Trade-off de Invalidação de Escrita em MVs Multi-Tabela**: Enquanto consultas operacionais simples (`dashboard.sql`) sustentam ganhos de **+40% a +110%** sob tráfego de 5%–10% de `UPDATE orders`, MVs analíticas complexas de 6 tabelas que fazem join com `orders` sofrem invalidação completa e custo de reconstrução (`pgcache_cache_mv_rebuilds`, ~50–100 ms por rebuild de view de 6 tabelas) sob escritas contínuas na tabela-fato central `orders`.

---

## 2. Gate Diferencial de Correção, Cacheabilidade e Admissão de MVs

Executado via [`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh) (log bruto: [`verify-correctness.txt`](verify-correctness.txt)):

| Verificação | Resultado | Telemetria / Detalhe |
|---|---|---|
| **Igualdade de Saída Byte a Byte** | **PASS (8/8 consultas)** | Saída do `psql -X -A -t` idêntica entre Origem e PgCache nos Passes 1 e 2 |
| **Delta de Consultas Cacheáveis** | **PASS (`16 / 16`)** | `pgcache_queries_cacheable` incrementou em 16 nos 2 passes de 8 statements |
| **Delta de Consultas Não-Cacheáveis** | **PASS (`0`)** | Delta de `pgcache_queries_uncacheable` = `0` (expressões pré-computadas via `\set`) |
| **Admissão no Gate de MV** | **PASS (`8 / 8`)** | `pgcache_cache_mv_gate{result="admitted"}` = `8`, `rejected` = `0` |
| **Delta de Erros do Cache** | **PASS (`0`)** | Delta de `pgcache_queries_error` = `0` |

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
1. **[`complex-search.sql`](../../workload/complex-search.sql)** (4 statements): Buscas por substring `ILIKE '%...%'` em e-mails/nomes de clientes, nomes de produtos, vendedores e textos de avaliações combinadas com cadeias de `INNER JOIN` e `LEFT JOIN` de 2 a 4 tabelas.
2. **[`complex-joins.sql`](../../workload/complex-joins.sql)** (4 statements): Cadeias profundas de 4 a 6 tabelas com `INNER JOIN` e `LEFT JOIN` (`orders -> customer -> order_item -> product -> category -> seller -> review`), incluindo retenção de coortes de clientes (`LEFT JOIN orders`) e estoque de produtos sem avaliação (`LEFT JOIN review`).
3. **[`complex-analytics.sql`](../../workload/complex-analytics.sql)** (4 statements): Agregações `GROUP BY` multidimensionais com `FILTER (WHERE ...)` condicional, faixas `CASE WHEN` e filtros pós-agregação `HAVING`.
4. **[`complex-dashboard.sql`](../../workload/complex-dashboard.sql)** (8 statements): Tela analítica e de busca corporativa unificada combinando 2 consultas de busca textual, 3 joins profundos multi-tabela (`JOIN` / `LEFT JOIN`) e 3 agregações analíticas pesadas.

### 4.1 Comparativo de Cenários (`TENANTS=200`, `CLIENTS=8`)

Log bruto: [`run-complex-scenarios.txt`](run-complex-scenarios.txt)

| Cenário | Statements | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---|---:|---|---|---:|---:|---:|---:|
| **`dash_base`** (`dashboard.sql`) | 8 | 40,57 ms · 197 rps | **17,11 ms · 468 rps** | **+138%** | **2,4×** | 100,0% | 3 |
| **`search`** (`complex-search.sql`) | 4 | 98,50 ms · 81 rps | **1,34 ms · 5.982 rps** | **+7.285%** | **73,9×** | 100,0% | 4 |
| **`joins`** (`complex-joins.sql`) | 4 | 131,70 ms · 61 rps | **1,36 ms · 5.902 rps** | **+9.575%** | **96,8×** | 100,0% | 5 |
| **`analytics`** (`complex-analytics.sql`) | 4 | 95,76 ms · 84 rps | **1,31 ms · 6.118 rps** | **+7.183%** | **72,8×** | 100,0% | 4 |
| **`cplx_dash`** (`complex-dashboard.sql`) | 8 | 217,38 ms · 37 rps | **2,73 ms · 2.928 rps** | **+7.814%** | **79,1×** | 100,0% | 6 |

**Por que Consultas Complexas Alcançam 73×–97× de Aceleração (Cache em Dois Estágios e Gate de Admissão de MVs)**:
- No PgCache 0.7.1, o cache de consultas opera em dois níveis distintos:
  1. **Subsunção em Nível de Tabela (`public.*`)**: As tabelas-base (`orders`, `order_item`, `product`, `customer`, `review`, `seller`, `category`) são populadas no PostgreSQL embutido do PgCache. Se uma consulta bate diretamente em `public.*` (`pgcache_cache_mv_fallthrough`), o PgCache ainda executa o join/agregação localmente (~15–17 ms para as 8 consultas leves de `dash_base`).
  2. **Gate de Admissão de Materialized Views (`pgcache_mv.q_<hash>`)**: Quando uma consulta possui `OFFSET 0` (sem `OFFSET` positivo), agrupa por chaves de entidade não-nulas (`mv=true`) e varre `>= 1.000` linhas pré-agregação (`--mv_compute_min_rows=1000`) ou atinge taxa de redução `>= 10:1` (`--mv_size_ratio=10`), o PgCache admite a consulta em seu motor de Materialized Views (`pgcache_cache_mv_gate{result="admitted"}`).
- Como todas as 8 consultas em `complex-dashboard.sql` (e todas as 12 consultas em `complex-search`, `complex-joins` e `complex-analytics`) satisfazem o gate de MV, o PgCache pré-materializa a visão de 10 a 20 linhas em `pgcache_mv.q_<hash>` e responde às consultas subsequentes em **~0,33 ms por statement** (`1,31–1,36 ms` para 4 statements; `2,73 ms` para 8 statements), contra **95,8–217,4 ms** na Origem.

### 4.2 Escala de Tenants em Carga Complexa (`1` a `1.000` Tenants em `complex-dashboard.sql`, `CLIENTS=8`)

Log bruto: [`run-complex-tenants.txt`](run-complex-tenants.txt)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|---:|
| **1** | 249,31 ms · 32 rps | **2,67 ms · 2.996 rps** | **+9.262%** | **93,6×** | 100,0% | 2 |
| **10** | 252,09 ms · 32 rps | **2,54 ms · 3.144 rps** | **+9.725%** | **98,3×** | 100,0% | 2 |
| **50** | 268,10 ms · 30 rps | **2,58 ms · 3.097 rps** | **+10.223%** | **103,2×** | 100,0% | 3 |
| **200** *(incremental)* | 274,31 ms · 29 rps | **56,03 ms · 143 rps** | **+393%** | **4,9×** | 97,9% | 6 |
| **200** *(estabilizado)* | 217,38 ms · 37 rps | **2,73 ms · 2.928 rps** | **+7.814%** | **79,1×** | 100,0% | 6 |
| **500** *(limite frio 90s)* | 291,64 ms · 27 rps | 1.304,31 ms · 6 rps | -78% | 0,22× | 35,2% | 6 |
| **1.000** *(limite frio 90s)* | 294,97 ms · 27 rps | 1.131,32 ms · 7 rps | -74% | 0,26× | 17,5% | 6 |

**Descoberta — Limite de Taxa de Registro no Cold-Start (`pgcache_cache_reg_gate_rate`) em 500–1.000 Tenants**:
- De **1 a 200 tenants**, o PgCache aquece todo o working set de Materialized Views complexas e entrega **+7.814% a +10.223% de ganho de vazão** (`2.928–3.144 rps` vs `29–37 rps` na Origem). Mesmo quando 2,1% das consultas ainda estão concluindo a construção de MVs em background (`97,9%` de hit em 200 tenants), o PgCache é **4,9× mais rápido (`+393%`)** que a Origem.
- Em **500 e 1.000 tenants**, cada tenant introduz ~32 assinaturas distintas de consultas complexas (`16.000` a `32.000` Materialized Views pesadas de 6 tabelas). A inspeção da telemetria revelou que o PgCache aplica um limitador interno de taxa de registro no cold-start (`pgcache_cache_reg_gate_rate`) que restringe novos registros a **~8–20 consultas/s** para que os workers de `CREATE MATERIALIZED VIEW` não sobrecarreguem a origem ou o PostgreSQL embutido. Dentro da janela de aquecimento de 6 passes (90s), cerca de ~175 tenants (~35,2% de 500 tenants, ~17,5% de 1.000 tenants) são registrados, enquanto as consultas não registradas aguardam no gate de registro.

### 4.3 Escala de Concorrência em Carga Complexa (`1` a `32` Clientes em `complex-dashboard.sql`, `TENANTS=200`)

Log bruto: [`run-complex-clients.txt`](run-complex-clients.txt)

| Clientes | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|---:|
| **1** | 86,03 ms · 12 rps | **1,90 ms · 528 rps** | **+4.300%** | **44,0×** | 100,0% | 3 |
| **4** | 140,95 ms · 28 rps | **2,38 ms · 1.679 rps** | **+5.896%** | **60,0×** | 100,0% | 2 |
| **8** | 286,37 ms · 28 rps | **2,84 ms · 2.814 rps** | **+9.950%** | **100,5×** | 100,0% | 2 |
| **16** | 525,68 ms · 30 rps | **4,94 ms · 3.239 rps** | **+10.697%** | **108,0×** | 100,0% | 2 |
| **32** | 983,51 ms · 33 rps | **9,82 ms · 3.260 rps** | **+9.779%** | **98,8×** | 100,0% | 2 |

- **Aceleração Pura com 1 Cliente (`CLIENTS=1`)**: Sem fila em nenhum componente, uma tela analítica e de busca com 8 statements cai de **86,03 ms (`12 rps`)** na Origem para **1,90 ms (`528 rps`)** no PgCache — uma aceleração pura de cache de **44,0× (`+4.300%`)**.
- **Alta Concorrência (`CLIENTS=16..32`)**: A Origem satura em **28–33 rps** com a latência subindo para **983,5 ms** (~1 segundo por renderização de tela), enquanto o PgCache sustenta **3.239–3.260 rps** (~26.000 consultas SQL/s) a **4,94–9,82 ms** por tela (**98,8× a 108,0× de aceleração**).

### 4.4 Invalidação por Escrita e Custo de Rebuild de MVs (`TENANTS=200`, `CLIENTS=8`)

Log bruto: [`run-complex-writes.txt`](run-complex-writes.txt)

| Taxa de Escrita | Tenants de Escrita | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Hit Ratio | Passos Warmup |
|---:|---:|---|---|---:|---:|---:|
| **0%** | 200 | 292,04 ms · 27 rps | **2,89 ms · 2.771 rps** | **+10.163%** | 100,0% | 2 |
| **5%** | 1 | 283,13 ms · 28 rps | 901,73 ms · 9 rps | -68% | 65,8% | 2 |
| **5%** | 10 | 540,68 ms · 15 rps | 6.487,62 ms · 1 rps | -93% | 61,2% | 3 |
| **5%** | 200 | 279,00 ms · 29 rps | 1.380,21 ms · 6 rps | -79% | 34,4% | 6 |
| **10%** | 1 | 1.010,47 ms · 8 rps | **600,83 ms · 13 rps** | **+62%** | 62,1% | 3 |
| **10%** | 200 | 244,39 ms · 33 rps | 822,49 ms · 10 rps | -70% | 27,2% | 3 |

**Por que a Invalidação por Escrita se Comporta de Forma Diferente em MVs Complexas de 6 Tabelas vs. Consultas Simples**:
- Na carga operacional baseline (`dashboard.sql`, Seção 3.3), as consultas rodam sobre as tabelas-base em `public.*` com lookups leves de 1 a 2 tabelas. Quando `write.sql` executa `UPDATE orders SET total = total + 1`, o PgCache aplica a atualização da linha via replicação lógica / CDC e mantém **100,0% de hit ratio** com **+40% a +110% de ganho de vazão**.
- Em `complex-dashboard.sql`, **7 dos 8 statements fazem join da tabela `orders` entre 4 a 6 tabelas** (`orders`, `order_item`, `product`, `category`, `seller`, `customer`, `review`) e dependem de Materialized Views pré-computadas (`pgcache_mv.q_<hash>`) para alcançar sua aceleração de 100×.
- Quando `UPDATE orders` passa pelo PgCache em proporções de 5%–10% das transações, o PgCache invalida (`pgcache_cache_invalidations`) as Materialized Views que dependem de `orders` e dispara **reconstruções de Materialized Views de 6 tabelas em background (`pgcache_cache_mv_rebuilds`)** dentro de sua instância PostgreSQL embutida. Como cada rebuild de MV de 6 tabelas varre e junta milhares de linhas (~50–100 ms de trabalho de CPU por rebuild), escritas contínuas na tabela-fato central `orders` saturam os workers do PostgreSQL embutido com manutenção de MVs, reduzindo o hit ratio efetivo para `27,2%–65,8%`.
- Apenas quando as escritas estão concentradas em um único tenant quente (`10:1`) enquanto a própria Origem sofre forte contenção (`1.010,5 ms` / `8 rps`) o PgCache permanece à frente (**`+62%`**, `600,8 ms` / `13 rps`) ao servir os outros 199 tenants somente-leitura a partir do cache.

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
