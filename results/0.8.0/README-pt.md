# Benchmark do PgCache 0.8.0 em um SaaS Multi-Tenant: Subsumption em Outer Joins, Invalidação Seletiva por Coluna e Curva de `pgcache_cache_subsumptions` (`0.8.0` vs. `0.7.1`)

> 🇺🇸 **[Read in English](README.md)** · 📖 **[Ler Parte 1 (`0.7.1`)](../0.7.1/README-pt.md)** · 📖 **[Ler Parte 2 (`0.7.1_v2`)](../0.7.1_v2/README-pt.md)**

Este relatório documenta a avaliação completa do **PgCache `0.8.0` (`pgcache/pgcache:0.8.0`)** em comparação direta com o **`0.7.1` / `0.7.1_v2`** no cluster Kubernetes de 3 nós na DigitalOcean (`3× s-4vcpu-8gb` na mesma zona `nyc1`, `TRIALS=3` com recriação completa do pod do PgCache entre rodadas).

Além de repetir todas as baterias oficiais (`01` a `04`, `06`, `07` e `verify-correctness.sh`), incluímos a bateria especial **[`10-subsumption-curve.sh`](../../scripts/10-subsumption-curve.sh)** sugerida pelo **James (core dev do PgCache)** para medir, janela a janela (`8 × 15s = 120s`), a evolução da métrica **`pgcache_cache_subsumptions`** durante o warm-up comparando o `0.8.0` contra o `0.7.1`.

---

## 1. O Que Mudou no PgCache 0.8.0 e Por Que Isso Impacta Nossos Testes?

Segundo o [Changelog Oficial do PgCache 0.8.0](https://www.pgcache.com/docs/changelog/), quatro mudanças arquiteturais atingem diretamente gargalos que havíamos identificado na `0.7.1` e na `0.7.1_v2`:

1. **Invalidação Seletiva por Coluna em `UPDATE` (*Skip redundant cache invalidations when UPDATE does not modify any column referenced by a cached query*)**:
   - Na `0.7.1`, qualquer `UPDATE` em `orders` invalidava todas as consultas cacheadas do tenant que tocavam `orders`, mesmo que a coluna alterada não fizesse parte do `SELECT`/`WHERE`/`GROUP BY` da consulta.
   - Na `0.8.0`, o rastreador CDC analisa quais colunas foram realmente modificadas pela tupla WAL antes de disparar invalidações.
2. **Subsumption de Consultas de Tabela Única sobre Views de `LEFT JOIN` (*Subsumption for single-table queries against outer join views*)**:
   - Consultas de tabela única cuja tabela é o lado preservado (*preserved relation*) de uma Materialized View com `LEFT JOIN` agora podem ser **subsumidas** diretamente por essa view, evitando idas desnecessárias ao Origin.
3. **Subsumption com Predicados `LIKE / ILIKE` e `IS NULL / IS NOT NULL` (*Extended subsumption predicate support*)**:
   - O motor de subsumption agora avalia padrões `LIKE` / `ILIKE` e predicados `IS NULL` / `IS NOT NULL` ao decidir se uma nova consulta pode ser respondida a partir de uma entrada já cacheada.
4. **Remoção de Locks Exclusivos no Caminho Quente do Proxy (*Reduced lock contention on the hot path*)**:
   - O registro de tabelas no *cache writer* trocou `RwLock` por `DashMap` concorrente, e a resolução do clock de invalidação por tabela nas leituras foi movida para fora do lock exclusivo do cache — reduzindo drasticamente a contenção entre o worker de população/subsumption e as conexões de leitura.

---

## 2. Resumo Executivo (TL;DR): `0.8.0` vs. `0.7.1_v2`

| Eixo Avaliado (Cluster 3 Nós DOKS `3× s-4vcpu-8gb`, `TRIALS=3`) | PgCache `0.7.1` / `0.7.1_v2` | PgCache `0.8.0` | Evolução (`0.8.0` vs. `0.7.1_v2`) |
|---|---|---|---|
| **Gate de Corretude + Invalidações Pós-CDC** ([`verify-correctness-doks.txt`](verify-correctness-doks.txt)) | `32/32 PASS` · **`12` invalidações** | `32/32 PASS` · **`3` invalidações** | **-75% invalidações CDC redundantes** |
| **Dashboard Operacional em `1.000` Tenants** ([`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt)) | 332,93 ms · `24 rps` (`62,5%` hit) | **149,08 ms · `55 rps` (`88,1%` hit)** | **2,29× mais rápido (+25,6 pp de hit)** |
| **Dashboard Operacional em `2.000` Tenants** ([`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt)) | 882,23 ms · `9 rps` (`20,6%` hit) | **196,26 ms · `42 rps` (`49,2%` hit)** | **4,67× mais rápido (+28,6 pp de hit)** |
| **Concorrência `c=1` (`200` Tenants)** ([`02-concurrency-sweep-k8s.txt`](02-concurrency-sweep-k8s.txt)) | 63,36 ms · `16 rps` (`62,3%` hit, `-64%`) | **14,81 ms · `68 rps` (`99,9%` hit, `+34%`)** | **4,25× mais rápido (virou de `-64%` para `+34%`)** |
| **Escritas CDC `5%` em `200` Tenants (`5:200`)** ([`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt)) | 102,49 ms · `82 rps` (`82,3%` hit) | **64,43 ms · `125 rps` (`95,9%` hit)** | **+52,4% mais RPS (`4,3×` menos misses CDC)** |
| **Escritas CDC `10%` em `200` Tenants (`10:200`)** ([`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt)) | 121,67 ms · `69 rps` (`78,1%` hit) | **89,86 ms · `90 rps` (`92,7%` hit)** | **+30,4% mais RPS (`3,0×` menos misses CDC)** |
| **Joins de 4–6 Tabelas (`joins`)** ([`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)) | 25,68 ms · `330 rps` (`98,8%` hit) | **10,85 ms · `773 rps` (`100,0%` hit, `+2.710%`)** | **2,34× mais rápido (`100%` hit)** |
| **Tela Corporativa Completa (`cplx_dash`)** ([`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)) | 89,85 ms · `128 rps` (`97,9%` hit) | **24,62 ms · `338 rps` (`100,0%` hit, `+1.410%`)** | **2,64× mais rápido (`100%` hit)** |
| **Pareto 80/20 em `1.000` Tenants (`z_tenants=1000`)** ([`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)) | 463,82 ms · `18 rps` (`71,0%` hit, `-49%`) | **265,90 ms · `33 rps` (`79,1%` hit, `+53%`)** | **1,83× mais rápido (virou de `-49%` para `+53%`)** |
| **Pareto 80/20 em `2.000` Tenants (`z_tenants=2000`)** ([`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)) | 996,55 ms · `8 rps` (`49,9%` hit, `-77%`) | **338,95 ms · `25 rps` (`71,5%` hit, `+27%`)** | **3,13× mais rápido (virou de `-77%` para `+27%`)** |
| **Escritas Pesadas a Frio (`5:10` Complex Writes)** ([`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)) | 2.995,5 ms · `3 rps` (`32,4%` hit, `-85%`) | **809,01 ms · `10 rps` (`42,4%` hit, `-54%`)** | **3,33× mais rápido (`3,70×` menor latência)** |
| **Teste Justo: `search_3c` (`GIN pg_trgm` + `2 GiB`)** ([`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)) | 9,23 ms · `914 rps` (`100,0%` hit, `3,4` warm) | **6,07 ms · `1.319 rps` (`100,0%` hit, `3,0` warm)** | **+44,3% mais rápido (`+1.143%` sobre Origin)** |
| **Teste Justo: `cplx_dash` (`2 GiB` Prewarmed)** ([`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)) | 67,16 ms · `128 rps` (`97,9%` hit) | **16,55 ms · `487 rps` (`100,0%` hit, `+1.728%`)** | **3,80× mais rápido (`0` stalls de warm-up)** |
| **`ADMISSION_THRESHOLD=2` Estabilizado (`t2_settle`)** ([`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)) | 75,34 ms · `117 rps` (`98,3%` hit) | **23,03 ms · `369 rps` (`100,0%` hit, `+1.084%`)** | **3,15× mais rápido** |
| **`ADMISSION_THRESHOLD=4` Filtros Dinâmicos (`t4_dyn`)** ([`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)) | 504,14 ms · `16 rps` (`-52%` na v2_3t) | **231,46 ms · `35 rps` (`18,3%` hit, `+8%` vs Origin)** | **2,19× mais rápido (bate o Origin em `+8%`!)** |

---

## 3. Estudo Especial para o James: Curva de `pgcache_cache_subsumptions` no Warm-Up (`0.8.0` vs. `0.7.1`)

Log bruto completo: **[`10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt`](10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt)** · Script: **[`scripts/10-subsumption-curve.sh`](../../scripts/10-subsumption-curve.sh)**

O James sugeriu monitorar a métrica `pgcache.cache.subsumptions` (exposta no Prometheus como `pgcache_cache_subsumptions` ao lado do contador de verificações `pgcache_cache_writer_register_subsumption_check_seconds_count`) durante a rampa de aquecimento, comparando `0.8.0` contra `0.7.1`.

Para obter uma curva limpa de alta resolução, recriamos o pod do PgCache do zero (`cold start`) antes de cada cenário e executamos **8 janelas consecutivas de 15 segundos (`0–120s` de aquecimento contínuo, `CLIENTS=8`)** nos mesmos 3 nós DOKS para **`0.8.0`** e **`0.7.1`**, cobrindo 4 cenários:
1. **`dashboard_200t`**: Dashboard operacional (`workload/dashboard.sql`, 11 consultas/tenant = `2.200` consultas únicas em `200` tenants).
2. **`dashboard_1000t`**: Dashboard operacional em alta cardinalidade (`11.000` consultas únicas em `1.000` tenants).
3. **`outer_join_plus_base_200t`**: Carga mista (`50%` [`workload/complex-joins.sql`](../../workload/complex-joins.sql) com `LEFT JOIN` sobre `customer` e `product` + `50%` [`workload/dashboard.sql`](../../workload/dashboard.sql) com consultas de tabela única sobre as relações preservadas), desenhada especificamente para exercitar a nova feature *"Subsumption for single-table queries against outer join views"* da `0.8.0`.
4. **`cplx_dyn_200t`**: Tela corporativa com filtros dinâmicos intra-tenant ([`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)).

### 3.1 Cenário 1: `dashboard_200t` (`200` Tenants, `2.200` Consultas Únicas) — `0.8.0` vs. `0.7.1`

Dentro do `dashboard.sql`, 4 das 11 consultas por tenant (`4 × 200 = 800` consultas no total) filtram subconjuntos de tabelas já cobertas por consultas mais amplas do mesmo tenant e, portanto, são candidatas diretas a **subsumption** durante o registro no cache:

| Janela de Warm-Up | `0.7.1` RPS (Latência) | `0.8.0` RPS (Latência) | `0.7.1` Hit % | `0.8.0` Hit % | `0.7.1` `subsumptions` ($\Delta$) | `0.8.0` `subsumptions` ($\Delta$) | `0.7.1` Checks | `0.8.0` Checks |
|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **`0–15s`** | 23 rps (340,8 ms) | 19 rps (412,1 ms) | 16,10% | 16,00% | **42** (+42) | **21** (+21) | 821 | 600 |
| **`15–30s`** | 31 rps (261,9 ms) | **61 rps (132,1 ms)** | 66,59% | **77,52%** | **294** (+252) | **577 (+556)** | 1.581 | **1.990** |
| **`30–45s`** | 97 rps (82,9 ms) | **235 rps (34,0 ms)** | 95,87% | **99,44%** | **679** (+385) | **781 (+204)** | 2.125 | **2.198** |
| **`45–60s`** | 215 rps (37,2 ms) | **263 rps (30,5 ms)** | 99,72% | **99,93%** | **752** (+73) | **783 (+2)** | 2.198 | **2.200** |
| **`60–75s`** | 210 rps (38,1 ms) | **259 rps (30,9 ms)** | 99,93% | **99,98%** | **754** (+2) | **783 (+0)** | 2.200 | 2.200 |
| **`75–90s`** | 247 rps (32,4 ms) | **271 rps (29,5 ms)** | 99,99% | **99,99%** | **754** (+0) | **783 (+0)** | 2.200 | 2.200 |
| **`90–105s`** | 262 rps (30,5 ms) | **301 rps (26,6 ms)** | 100,00% | **100,00%** | **754** (+0) | **783 (+0)** | 2.200 | 2.200 |
| **`105–120s`** | 261 rps (30,7 ms) | **296 rps (27,0 ms)** | 100,00% | **100,00%** | **754** (+0) | **783 (+0)** | 2.200 | 2.200 |

**O que a curva de `dashboard_200t` revela:**
- Na janela crítica de **`15–30s`**, o `0.8.0` realiza **`+556` subsumptions em 15 segundos** (acumulando **`577` subsumptions**, contra apenas **`294`** no `0.7.1` — **quase 2× mais subsumptions no mesmo intervalo!**) e já salta para **`61 rps` (`77,52%` hit)** contra `31 rps` (`66,59%` hit) no `0.7.1`.
- Na janela de **`30–45s`**, o `0.8.0` já concluiu praticamente todas as subsumptions possíveis (**`781` de `783`**) e entrega **`235 rps` (`99,44%` hit, `34,0 ms`)**, enquanto o `0.7.1` ainda está em `679` subsumptions e roda a `97 rps` (`82,9 ms`) — o `0.8.0` é **2,42× mais rápido aos 45 segundos de aquecimento**!
- No total estacionário, ambos registram exatamente `2.200` `Sub_Checks` (`11 queries × 200 tenants`), mas o `0.8.0` subsume **`783` consultas** contra **`754`** no `0.7.1` (**`+29` subsumptions extras**) e estabiliza em **`296–301 rps` (+15% acima do `0.7.1`)**.

---

### 3.2 Cenário 2: `dashboard_1000t` (`1.000` Tenants, `11.000` Consultas Únicas) — `0.8.0` vs. `0.7.1`

| Janela de Warm-Up | `0.7.1` RPS | `0.8.0` RPS | `0.7.1` Hit % | `0.8.0` Hit % | `0.7.1` `subsumptions` ($\Delta$) | `0.8.0` `subsumptions` ($\Delta$) | `0.7.1` Checks | `0.8.0` Checks |
|:---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **`0–15s`** | 35 rps | 31 rps | 2,99% | **4,42%** | **7** (+7) | **7** (+7) | 816 | **827** |
| **`15–30s`** | 38 rps | **45 rps** | 12,28% | **14,22%** | **58** (+51) | **53** (+46) | 1.648 | **1.709** |
| **`30–45s`** | 37 rps | 36 rps | 21,75% | **28,94%** | **123** (+65) | **293 (+240)** | 2.304 | **3.385** |
| **`45–60s`** | 34 rps | **36 rps** | 30,03% | **39,84%** | **233** (+110) | **467 (+174)** | 3.076 | **4.155** |
| **`60–75s`** | 40 rps | **46 rps** | 36,59% | **48,73%** | **361** (+128) | **596 (+129)** | 3.783 | **4.703** |
| **`75–90s`** | 41 rps | 37 rps | 46,40% | **53,46%** | **503** (+142) | **794 (+198)** | 4.396 | **5.392** |
| **`90–105s`** | 45 rps | 36 rps | 54,12% | **58,10%** | **712** (+209) | **943 (+149)** | 5.115 | **5.895** |
| **`105–120s`** | 41 rps | 40 rps | 61,14% | **70,31%** | **930** (+218) | **1.180 (+237)** | 5.800 | **6.415** |

**O que a curva de `dashboard_1000t` revela:**
- Com `1.000` tenants simultâneos, a remoção de contenção de lock (`DashMap` + leitura do clock fora do lock exclusivo) permite que o *cache writer* do `0.8.0` registre e cheque **`6.415` consultas em 120s** (contra `5.800` no `0.7.1`) e complete **`1.180` subsumptions** contra **`930`** no `0.7.1` (**`+250` subsumptions / `+26,9%`**).
- Aos `45s`, o `0.8.0` já realizou **2,38× mais subsumptions (`293` vs `123`)**, e ao final de 120s atinge **`70,31%` de hit ratio** contra `61,14%` no `0.7.1` (**`+9,17 pp` de vantagem**). É exatamente por isso que, na varredura `01-tenant-sweep.sh`, a vazão em `1.000` tenants mais que dobrou (`55 rps` vs `24 rps`) e em `2.000` tenants subiu **4,67× (`42 rps` vs `9 rps`)**!

---

### 3.3 Cenário 3: `outer_join_plus_base_200t` (`LEFT JOIN` + Tabela Única Preservada) — `0.8.0` vs. `0.7.1`

Quando combinamos `complex-joins.sql` (`LEFT JOIN` preservando `customer` e `product`, além de `IS NULL / IS NOT NULL`) com `dashboard.sql` (`SELECT` de tabela única em `customer`, `product` e `orders` para os mesmos `200` tenants):

| Janela de Warm-Up | `0.7.1` `subsumptions` ($\Delta$) | `0.8.0` `subsumptions` ($\Delta$) | Vantagem de Subsumptions da `0.8.0` na Rampa |
|:---:|---:|---:|---|
| **`0–15s`** | 2 (+2) | **3 (+3)** | `+50%` |
| **`15–30s`** | 12 (+10) | **29 (+26)** | **`2,42×` mais subsumptions acumuladas no início do warm-up** |
| **`30–45s`** | 58 (+46) | **86 (+57)** | **`+48,3%` mais subsumptions acumuladas aos 45s** |
| **`45–60s`** | 140 (+82) | **188 (+102)** | **`+34,3%` mais subsumptions acumuladas aos 60s** |
| **`60–75s`** | 298 (+158) | **294 (+106)** | Empate técnico na metade da rampa |
| **`105–120s` (Final)** | **886** (de 3.000 checks) | **887** (de 2.851 checks) | **`+104` subsumptions extras sobre `dashboard_200t` (`887` vs `783`), com maior taxa por check (`31,1%` vs `29,5%`)** |

**Por que o total salta de `783` (em `dashboard_200t`) para `887` (em `outer_join_plus_base_200t`):**
- O `dashboard.sql` sozinho produz no máximo `783` subsumptions em 200 tenants. Quando rodamos `complex-joins.sql` + `dashboard.sql` juntos, surgem **`+104` subsumptions adicionais (`887` no total)** vindas do cruzamento entre as views multi-tabela e as consultas por tenant, sendo que nos primeiros 60 segundos a `0.8.0` acumula subsumptions até **2,42× mais rápido** (`29` vs `12` aos 30s; `188` vs `140` aos 60s).

---

### 3.4 Cenário 4: `cplx_dyn_200t` (Filtros Dinâmicos Intra-Tenant em Consultas Multi-Tabela)

Em `cplx_dyn_200t` ([`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)), tanto `0.8.0` (`2.695` `Sub_Checks`) quanto `0.7.1` (`3.261` `Sub_Checks`) registram **`0` `pgcache_cache_subsumptions`** ao longo dos 120s.
- **Explicação Arquitetural Importante**: Todas as 8 consultas de `complex-dashboard-dynamic.sql` são joins multi-tabela (3 a 6 tabelas) e agregações `GROUP BY / HAVING` atendidas pelo motor de **Materialized Views (MVs)**. O verificador de subsumption (`subsumption_check`) é invocado a cada registro (`2.695` a `3.261` vezes), mas como consultas multi-tabela com `GROUP BY / HAVING` e `LIMIT` distintos geram MVs independentes em vez de subsumir entradas de tabela base no cache de memória, `subsumptions` permanece `0`.

---

## 4. Resultados Detalhados de Todas as Varreduras (`01` a `07`) na `0.8.0`

### 4.1 Varredura 1: Escala de Tenants (`1` a `2.000` Tenants — [`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt))

| Tenants (`CLIENTS=8`) | Origin Caminho A (`0.8.0`) | PgCache `0.7.1_v2` (Caminho B) | PgCache `0.8.0` (Caminho B) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---:|---|---|---|---:|---:|---|
| **`1`** | 31,85 ms · 252 rps | 11,57 ms · 692 rps | **9,20 ms · 883 rps** *(±129,8 sd)* | 100,0% → **100,0%** | **+249% (3,50×)** | **+27,6% mais rápido** |
| **`10`** | 29,43 ms · 275 rps | 17,47 ms · 458 rps | **14,42 ms · 573 rps** *(±130,1 sd)* | 100,0% → **100,0%** | **+109% (2,08×)** | **+25,1% mais rápido** |
| **`50`** | 31,06 ms · 259 rps | 16,80 ms · 476 rps | **15,04 ms · 533 rps** *(±32,4 sd)* | 100,0% → **100,0%** | **+107% (2,06×)** | **+12,0% mais rápido** |
| **`100`** | 34,51 ms · 233 rps | 19,21 ms · 416 rps | **21,91 ms · 367 rps** *(±28,1 sd)* | 100,0% → **100,0%** | **+59% (1,58×)** | Warm-up caiu de `5,7` para **`3,3` passes** |
| **`500`** | 39,82 ms · 208 rps | 65,98 ms · 121 rps | **52,96 ms · 153 rps** *(±20,1 sd)* | 99,6% → **99,9%** | -22% (0,74×) | **+26,4% mais rápido** |
| **`1.000`** | 39,58 ms · 205 rps | 332,93 ms · 24 rps | **149,08 ms · 55 rps** *(±9,5 sd)* | 62,5% → **88,1%** | -73% (0,27×) | **2,29× mais rápido (+25,6 pp hit)** |
| **`2.000`** | 38,42 ms · 208 rps | 882,23 ms · 9 rps | **196,26 ms · 42 rps** *(±10,1 sd)* | 20,6% → **49,2%** | -80% (0,20×) | **4,67× mais rápido (+28,6 pp hit)** |

---

### 4.2 Varredura 2: Escala de Concorrência (`1` a `32` Clientes em `200` Tenants — [`02-concurrency-sweep-k8s.txt`](02-concurrency-sweep-k8s.txt))

| Clientes (`TENANTS=200`) | Origin Caminho A (`0.8.0`) | PgCache `0.7.1_v2` (Caminho B) | PgCache `0.8.0` (Caminho B) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---:|---|---|---|---:|---:|---|
| **`1`** | 19,83 ms · 51 rps | 63,36 ms · 16 rps (`8,0` warm) | **14,81 ms · 68 rps** (`6,0` warm) | 62,3% → **99,9%** | **+34% (1,33×)** | **4,25× mais rápido (virou de `-64%` para `+34%`)** |
| **`4`** | 18,90 ms · 212 rps | 20,73 ms · 193 rps (`8,0` warm) | **23,47 ms · 173 rps** (`5,0` warm) | 100,0% → **100,0%** | -18% | Warm-up caiu de `8,0` para **`5,0` passes** |
| **`8`** | 32,52 ms · 246 rps | 25,99 ms · 308 rps (`8,0` warm) | **29,36 ms · 272 rps** (`4,7` warm) | 100,0% → **100,0%** | **+11%** | Warm-up caiu de `8,0` para **`4,7` passes** |
| **`16`** | 66,93 ms · 239 rps | 37,59 ms · 426 rps (`6,0` warm) | **43,65 ms · 371 rps** (`4,0` warm) | 100,0% → **100,0%** | **+55% (1,55×)** | Warm-up caiu de `6,0` para **`4,0` passes** |
| **`32`** | 115,27 ms · 280 rps | 73,84 ms · 433 rps (`6,3` warm) | **78,95 ms · 408 rps** (`4,3` warm) | 100,0% → **100,0%** | **+47% (1,46×)** | Warm-up caiu de `6,3` para **`4,3` passes** |

---

### 4.3 Varredura 3: Proporção de Escritas CDC no Dashboard Operacional ([`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt))

| `% Escrita : Tenants Alvo` | Origin Caminho A (`0.8.0`) | PgCache `0.7.1_v2` (Caminho B) | PgCache `0.8.0` (Caminho B) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`0:200` (0% writes)** | 32,93 ms · 243 rps | 29,74 ms · 269 rps | **26,77 ms · 300 rps** | 100,0% → **100,0%** | **+23%** | **+11,5% mais rápido (`+9%` → `+23%`)** |
| **`5:1` (5% writes, 1 tenant)** | 31,75 ms · 252 rps | 29,77 ms · 269 rps | **26,87 ms · 299 rps** | 99,3% → **99,9%** | **+18%** | **+11,2% mais rápido (`7×` menos misses CDC)** |
| **`5:10` (5% writes, 10 tenants)** | 28,84 ms · 278 rps | 44,69 ms · 179 rps | **40,22 ms · 201 rps** | 96,2% → **99,2%** | -27% | **+12,3% mais rápido (`4,8×` menos misses CDC)** |
| **`5:200` (5% writes, 200 tenants)** | 27,09 ms · 298 rps | 102,49 ms · 82 rps | **64,43 ms · 125 rps** | 82,3% → **95,9%** | -58% | **+52,4% mais rápido (`4,3×` menos misses CDC)** |
| **`10:1` (10% writes, 1 tenant)** | 29,57 ms · 271 rps | 33,47 ms · 239 rps | **31,61 ms · 254 rps** | 99,4% → **99,9%** | -6% | **+6,3% mais rápido (`6×` menos misses CDC)** |
| **`10:200` (10% writes, 200 tenants)** | 43,99 ms · 182 rps | 121,67 ms · 69 rps | **89,86 ms · 90 rps** | 78,1% → **92,7%** | -51% | **+30,4% mais rápido (`3,0×` menos misses CDC)** |

---

### 4.4 Varredura 4: Cenários Complexos Multi-Tabela, Pareto 80/20 e Escritas Pesadas ([`04-complex-sweep-k8s.txt`](04-complex-sweep-k8s.txt))

#### 4.4.1 Cenários Complexos (`200` Tenants, `CLIENTS=8` — [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt))

| Cenário (`200` Tenants) | Origin Caminho A (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`dash_base`** (`dashboard.sql`) | 49,97 ms · 160 rps | 26,65 ms · 300 rps | **28,53 ms · 282 rps** (`5,0` warm) | 100,0% → **100,0%** | **+76% (1,76×)** | Warm-up caiu de `6,7` para **`5,0` passes** |
| **`search`** (`complex-search.sql`) | 129,00 ms · 62 rps | 14,00 ms · 572 rps | **9,91 ms · 812 rps** (`4,7` warm) | 100,0% → **100,0%** | **+1.219% (13,1×)** | **+42,0% mais rápido (`7,3` → `4,7` warm)** |
| **`joins`** (`complex-joins.sql`) | 289,78 ms · 28 rps | 25,68 ms · 330 rps | **10,85 ms · 773 rps** (`5,0` warm) | 98,8% → **100,0%** | **+2.710% (28,1×)** | **2,34× mais rápido (`8,0` → `5,0` warm)** |
| **`analytics`** (`complex-analytics.sql`) | 206,10 ms · 39 rps | 18,50 ms · 433 rps | **12,41 ms · 655 rps** (`5,7` warm) | 98,4% → **100,0%** | **+1.583% (16,8×)** | **+51,3% mais rápido (`8,0` → `5,7` warm)** |
| **`cplx_dash`** (`complex-dashboard.sql`) | 360,62 ms · 23 rps | 89,85 ms · 128 rps | **24,62 ms · 338 rps** (`7,7` warm) | 97,9% → **100,0%** | **+1.410% (15,1×)** | **2,64× mais rápido (`100%` hit)** |
| **`cplx_zipf`** (`complex-dashboard-zipfian.sql`) | 396,29 ms · 20 rps | 89,85 ms · 128 rps | **20,64 ms · 393 rps** (`7,7` warm) | 97,9% → **100,0%** | **+1.863% (19,6×)** | **3,07× mais rápido (`100%` hit)** |

#### 4.4.2 Escala de Tenants com Pareto 80/20 (`100` a `2.000` Tenants — [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt))

| Tenants Pareto 80/20 (`z_tenants`) | Origin Caminho A (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---:|---|---|---|---:|---:|---|
| **`100` Tenants** | 384,00 ms · 21 rps | 52,85 ms · 151 rps | **16,00 ms · 510 rps** (`5,7` warm) | 99,1% → **100,0%** | **+2.357% (24,3×)** | **3,38× mais rápido** |
| **`200` Tenants** | 377,05 ms · 21 rps | 62,48 ms · 128 rps | **16,54 ms · 487 rps** (`7,3` warm) | 99,1% → **100,0%** | **+2.233% (23,2×)** | **3,80× mais rápido** |
| **`500` Tenants** | 357,45 ms · 23 rps | 216,14 ms · 37 rps | **145,62 ms · 56 rps** (`8,0` warm) | 85,1% → **93,2%** | **+150% (2,50×)** | **+51,4% mais rápido (+8,1 pp hit)** |
| **`1.000` Tenants** | 381,24 ms · 21 rps | 463,82 ms · 18 rps (`-49%`) | **265,90 ms · 33 rps** (`6,0` warm) | 71,0% → **79,1%** | **+53% (1,53×)** | **1,83× mais rápido (virou de `-49%` para `+53%`)** |
| **`2.000` Tenants** | 408,88 ms · 20 rps | 996,55 ms · 8 rps (`-77%`) | **338,95 ms · 25 rps** (`6,3` warm) | 49,9% → **71,5%** | **+27% (1,27×)** | **3,13× mais rápido (virou de `-77%` para `+27%`)** |

#### 4.4.2-B Varredura 11: 5 Execuções Consecutivas sem Reset entre Execuções (`100` a `2.000` Tenants — [`11-complex-zipfian-progressive-k8s.txt`](11-complex-zipfian-progressive-k8s.txt))

Na bateria `04-complex-zipfian-k8s.txt` acima, cada trial recriava o pod do PgCache (`reset_pgcache`) e limitava o aquecimento a `8 × 15s = 120s`, interrompendo a população de Materialized Views antes que os tenants da cauda longa (a partir de `500` tenants) terminassem de aquecer.

Para medir a evolução real do cache ao longo do tempo e sua capacidade aquecida, o script **[`scripts/11-complex-zipfian-progressive.sh`](../../scripts/11-complex-zipfian-progressive.sh)** reseta o PgCache **apenas uma vez** no início de cada ponto (`T`) e mede **5 execuções consecutivas de `60s` (`Exec 1/5` a `Exec 5/5` = `300s` contínuos) sem pre-warm separado e sem resetar o PgCache entre elas**, além do modo **`prewarmed`** (onde todos os tenants `1..T` recebem um passe sequencial inicial antes das 5 execuções):

| Tenants (`z_tenants`) | Origin (`A_rps`) | `Exec 1/5` (`0–60s` Frio) | `Exec 2/5` (`60–120s`) | `Exec 3/5` (`120–180s`) | `Exec 4/5` (`180–240s`) | **`Exec 5/5` (`240–300s` Aquecido)** | **`Exec 5/5` (Com Pre-Warm)** | Queries Registradas (`Exec 5`) | Memória Usada (`Exec 5`) |
|---:|---:|---|---|---|---|---|---|---:|---:|
| **`100`** | 35–41 rps | 17 rps (`79,1%`) | 8 rps (`99,6%`) | 118 rps (`99,9%`) | **820 rps (`20,0×`)** | **756 rps (`18,4×`, `100%` hit)** | **794 rps (`22,7×`, `100%` hit)** | **`800 / 800` (100%)** | `652–668 MiB` |
| **`200`** | 36–38 rps | 31 rps (`77,4%`) | 277 rps (`99,1%`) | 734 rps (`100%`) | **746 rps (`20,7×`)** | **698 rps (`19,4×`, `100%` hit)** | **777 rps (`20,4×`, `100%` hit)** | **`1.600 / 1.600` (100%)** | `908–911 MiB` |
| **`500`** | 38–39 rps | 28 rps (`63,7%`) | 56 rps (`83,1%`) | 79 rps (`92,7%`) | 171 rps (`98,3%`) | **604 rps (`15,9×`, `99,99%` hit)** | **678 rps (`17,4×`, `100%` hit)** | **`4.000 / 4.000` (100%)** | `1.349–1.400 MiB` |
| **`1.000`** | 37–38 rps | 26 rps (`56,4%`) | 42 rps (`72,8%`) | 51 rps (`81,8%`) | 56 rps (`86,3%`) | **64 rps (`1,7×`, `90,6%` hit)** | **65 rps (`1,7×`, `92,9%` hit)** | `6.136–7.053 / 8.000` (88%) | `1.591–1.801 MiB` |
| **`2.000`** | 36–38 rps | 26 rps (`51,2%`) | 42 rps (`67,8%`) | 47 rps (`73,3%`) | 50 rps (`78,0%`) | **50 rps (`1,4×`, `81,4%` hit)** | **42 rps (`1,1×`, `84,7%` hit)** | `6.196–9.149 / 16.000` (57%) | `1.666–2.240 MiB` |

**O que as 5 execuções consecutivas provam:**
1. **Em `500` tenants, a queda para `56 rps` era 100% falta de aquecimento da cauda longa**:
   - Na `Exec 2/5` (`120s`, mesmo tempo do teste anterior), `500` tenants está exatamente em **`56 rps`** (`2.562 / 4.000` MVs registradas, `83,1%` hit).
   - Mantendo o cache vivo até a `Exec 5/5` (`300s`), ele atinge **`4.000 / 4.000` Materialized Views registradas (`99,99%–100%` hit)** e a vazão dispara mais de **10×**, subindo de `56 rps` para **`604 rps` (`15,9×`)** no modo progressivo e **`678 rps` (`17,4×`)** no modo pre-warmed!
2. **Taxa física constante de construção de Materialized Views (`~1.210 MVs/minuto` ou `~20,2 MVs/s`)**:
   - A coluna `Queries_Reg` revela que o worker de população do PgCache constrói Materialized Views complexas (4 a 6 tabelas) a uma taxa constante de **`~1.210 MVs por minuto`** em um nó de 4 vCPUs (`Exec 1`: `~1.350` MVs $\rightarrow$ `Exec 2`: `~2.560` $\rightarrow$ `Exec 3`: `~3.780` $\rightarrow$ `Exec 4`: `~5.000` $\rightarrow$ `Exec 5`: `~6.180`).
   - Por isso, `500` tenants (`4.000` MVs) completa 100% da população na 4ª/5ª execução (`~3,3 minutos`), `1.000` tenants (`8.000` MVs) já dobra a vazão para **`64–65 rps` (`90,6%–92,9%` hit)** na 5ª execução (precisando de `~6,6 minutos` para atingir `8.000/8.000`), e `2.000` tenants (`16.000` MVs) dobra para **`50 rps` (`81,4%–84,7%` hit)** usando apenas `2,24 GiB` dos `3,5 GiB` de RAM (`0` evictions).

#### 4.4.3 Escritas Concorrentes na Tela Corporativa (`MAX_WARM_PASSES=3` com Reset Frio — [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt))

| `% Escrita : Tenants Alvo` | Origin Caminho A (`0.8.0`) | PgCache `0.7.1` (Parte 1) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1` |
|---|---|---|---|---:|---:|---|
| **`0:200` (Somente Leitura)** | 342,50 ms · 24 rps | 23,4 ms · 389 rps | **19,18 ms · 419 rps** | 100,0% → **100,0%** | **+1.703% (18,0×)** | **+7,7% mais rápido** |
| **`5:1` (5% writes, 1 tenant)** | 345,34 ms · 23 rps | 21,9 ms · 365 rps *(sem reset)* | **891,91 ms · 9 rps** *(com reset)* | **48,1%** | -61% | Reset frio por trial (`3` passes) |
| **`5:10` (5% writes, 10 tenants)** | 367,47 ms · 22 rps | 2.995,5 ms · 3 rps (`-85%`) | **809,01 ms · 10 rps** | 32,4% → **42,4%** | -54% | **3,33× mais RPS (`3,70×` menor latência)** |
| **`5:200` (5% writes, 200 tenants)** | 391,69 ms · 21 rps | — | **761,62 ms · 10 rps** | **44,1%** | -50% | Estável em `10–11 rps` |
| **`10:1` (10% writes, 1 tenant)** | 319,85 ms · 25 rps | — | **704,13 ms · 12 rps** | **45,6%** | -51% | Até `17 rps` (`49,96%` hit) no Trial 1 |
| **`10:200` (10% writes, 200 tenants)** | 329,39 ms · 25 rps | — | **762,32 ms · 11 rps** | **35,6%** | -56% | Estável em `10–11 rps` |

---

### 4.5 Varredura 6: O "Teste Justo" (`2 GiB shared_buffers` + `pg_prewarm` + `GIN pg_trgm` — [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt))

| Cenário do Teste Justo (`TENANTS=200`, `CLIENTS=8`) | Origin Tunado (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`search_1c` (`ILIKE '%1%'`)** | 109,38 ms · 73 rps | 12,42 ms · 644 rps (`8,0` warm) | **9,17 ms · 874 rps** (`4,0` warm) | 100,0% → **100,0%** | **+1.095% (12,0×)** | **+35,7% mais rápido (metade do warm-up)** |
| **`search_3c` (`ILIKE` 3+ chars + `GIN`)** | 75,32 ms · 107 rps | 8,75 ms · 914 rps (`3,4` warm) | **6,07 ms · 1.319 rps** (`3,0` warm) | 100,0% → **100,0%** | **+1.143% (12,4×)** | **+44,3% mais rápido (`1.375 rps` pico)** |
| **`cplx_dash` (Tela Corporativa 8 queries)** | 302,52 ms · 27 rps | 67,16 ms · 128 rps (`97,9%` hit) | **16,55 ms · 487 rps** (`7,3` warm) | 97,9% → **100,0%** | **+1.728% (18,3×)** | **3,80× mais rápido (`100%` hit nos 3 trials)** |
| **`cplx_dyn` (Filtros Dinâmicos, `t=1`)** | 268,48 ms · 30 rps | 898,55 ms · 9 rps (`29,8%` hit) | **422,20 ms · 20 rps** (`8,0` warm) | 29,8% → **66,1%** | -33% (0,67×) | **2,22× mais rápido (+36,3 pp hit)** |

---

### 4.6 Varredura 7: Estudo de `ADMISSION_THRESHOLD` (`1` vs `2` vs `4` — [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt))

| Célula e Limiar (`TENANTS=200`, `CLIENTS=8`) | Origin Tunado (`0.8.0`) | PgCache `0.7.1_v2` (3-Trial) | PgCache `0.8.0` (3-Trial) | Hit Ratio (`0.7.1_v2` → `0.8.0`) | Ganho `0.8.0` vs Origin | Evolução `0.8.0` vs `0.7.1_v2` |
|---|---|---|---|---:|---:|---|
| **`t1_cold0s` (`threshold=1`, 0s warm)** | 255,32 ms · 31 rps | 1.796,26 ms · 4 rps (`-87,1%`) | **842,92 ms · 9 rps** | 3,30% → **4,54%** | -70,2% | **2,25× mais rápido (`-53%` latência)** |
| **`t1_w30s` (`threshold=1`, 30s warm)** | 276,80 ms · 29 rps | 1.547,88 ms · 5 rps (`-83,9%`) | **976,53 ms · 8 rps** | 17,90% → **29,04%** | -72,4% | **+60% mais rápido (+11,1 pp hit)** |
| **`t2_cold0s` (`threshold=2`, 0s warm)** | 278,19 ms · 29 rps | 739,14 ms · 11 rps (`-64,9%`) | **707,69 ms · 11 rps** | 2,71% → **4,26%** | -60,9% | **+58% mais rápido que `t1_cold0s`** |
| **`t2_w30s` (`threshold=2`, 30s warm)** | 272,24 ms · 30 rps | 1.158,39 ms · 7 rps (`-77,4%`) | **605,63 ms · 13 rps** | 15,89% → **29,44%** | -56,2% | **1,86× mais rápido (+13,6 pp hit)** |
| **`t2_settle` (`threshold=2`, settled)** | 259,55 ms · 31 rps | 75,34 ms · 117 rps (`98,3%` hit) | **23,03 ms · 369 rps** (`8,0` warm) | 98,3% → **100,0%** | **+1.084% (11,8×)** | **3,15× mais rápido (`446 rps` pico)** |
| **`t2_dyn` (`threshold=2`, dinâmico)** | 212,43 ms · 38 rps | 638,94 ms · 13 rps (`33,2%` hit) | **249,12 ms · 32 rps** (`8,0` warm) | 33,2% → **47,5%** | -13% (`+8,8%` T3) | **2,46× mais rápido (superou Origin no T3!)** |
| **`t4_cold0s` (`threshold=4`, 0s warm)** | 245,38 ms · 33 rps | 742,20 ms · 11 rps (`-66,2%`) | **402,73 ms · 20 rps** | 1,22% → **2,68%** | -38,8% | **1,82× mais rápido (`-52%` vs `t1_cold0s`)** |
| **`t4_w30s` (`threshold=4`, 30s warm)** | 283,80 ms · 28 rps | 568,58 ms · 14 rps (`-57,9%`) | **313,59 ms · 27 rps** | 13,45% → **22,08%** | **-4,8% (`+13,8%` T2)** | **1,93× mais rápido (empata com Origin aos 30s!)** |
| **`t4_settle` (`threshold=4`, settled)** | 240,75 ms · 33 rps | 591,29 ms · 14 rps (`14,1%` hit) | **258,50 ms · 31 rps** (`6,0` warm) | 14,1% → **30,1%** | **-6% (`-2,9%` T2)** | **2,21× mais rápido (+16,0 pp hit)** |
| **`t4_dyn` (`threshold=4`, dinâmico)** | 247,03 ms · 33 rps | 504,14 ms · 16 rps (`-52%`) | **231,46 ms · 35 rps** (`5,0` warm) | 9,5% → **18,3%** | **+8% (`+12,1%` T2)** | **2,19× mais rápido (supera o Origin em `+8%`!)** |

---

## 5. Índice de Artefatos desta Pasta (`results/0.8.0/`)

- [`verify-correctness-doks.txt`](verify-correctness-doks.txt): Gate diferencial byte a byte (`8/8` baseline, `12/12` complexas estáticas, `12/12` pós-CDC ao vivo, `0` uncacheable, `3` invalidações seletivas).
- [`01-tenant-sweep-k8s.txt`](01-tenant-sweep-k8s.txt): Varredura de `1` a `2.000` tenants (`TRIALS=3`).
- [`02-concurrency-sweep-k8s.txt`](02-concurrency-sweep-k8s.txt): Varredura de `1` a `32` clientes simultâneos (`TRIALS=3`).
- [`03-write-sweep-k8s.txt`](03-write-sweep-k8s.txt): Varredura de proporção de escrita CDC no dashboard operacional (`TRIALS=3`).
- [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt): Baterias corporativas de 4 a 6 tabelas (`dash_base`, `search`, `joins`, `analytics`, `cplx_dash`, `cplx_zipf`, `TRIALS=3`).
- [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt): Escala Pareto 80/20 de `100` a `2.000` tenants (`TRIALS=3`).
- [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt): Escritas concorrentes na tela corporativa com reset frio (`TRIALS=3`).
- [`04-complex-sweep-k8s.txt`](04-complex-sweep-k8s.txt): Log consolidado da bateria `04`.
- [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt): O "Teste Justo" contra Origin `2 GiB` Prewarmed + `GIN pg_trgm` (`TRIALS=3`).
- [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt): Varredura `ADMISSION_THRESHOLD` (`1`, `2`, `4`) em `0s`, `30s`, `settled` e `cplx_dyn` (`TRIALS=3`).
- [`10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt`](10-subsumption-warmup-0.8.0-vs-0.7.1-k8s.txt): Curva comparativa de 120s (`8 × 15s`) de `pgcache_cache_subsumptions` entre `0.8.0` e `0.7.1`.
- [`11-complex-zipfian-progressive-k8s.txt`](11-complex-zipfian-progressive-k8s.txt): Varredura de 5 execuções consecutivas (`60s` cada, sem resetar o PgCache entre execuções) de `100` a `2.000` tenants em `complex-dashboard-zipfian.sql` (modos `progressive` e `prewarmed`).
