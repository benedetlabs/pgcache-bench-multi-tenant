# Resultados do Benchmark PgCache: De Dashboards Simples a Telas Analíticas de 6 Tabelas

> 🇺🇸 **[Read in English](README.md)**

Esta pasta reúne os resultados práticos de colocar o **PgCache** na frente do **PostgreSQL 17** ao longo de várias versões (`0.6.3`, `0.6.4`, `0.7.0`, `0.7.1`, `0.7.1_v2` e `0.8.0`) e em dois perfis bem diferentes de aplicações SaaS multi-tenant.

> **Topologia Cloud de 3 Nós (Qualquer Provedor)**: Todos os benchmarks deste repositório rodam em um **cluster Kubernetes de 3 nós na nuvem**, onde o **PostgreSQL (`origin`)**, o **PgCache (`pgcache`)** e o **gerador de carga (`loadgen`)** ficam em três máquinas virtuais dedicadas e separadas. Essa mesma bateria pode ser executada em **qualquer provedor de nuvem** (AWS EKS, Azure AKS, GCP GKE, DigitalOcean DOKS, etc.); os números publicados abaixo foram coletados na **DigitalOcean (`3× s-4vcpu-8gb`)**.

### Entendendo as Consultas SQL do Teste
Antes de olhar os números, consulte o [**Guia de Workloads e Consultas SQL (`workload/README-pt.md`)**](../workload/README-pt.md) para entender o banco de 7 tabelas ([`sql/01-schema.sql`](../sql/01-schema.sql), [`sql/02-tenant.sql`](../sql/02-tenant.sql)) e todos os 7 arquivos `.sql` testados:
- **Dashboard Simples e Escritas**: [`workload/dashboard.sql`](../workload/dashboard.sql) (8 consultas rápidas por índice) e [`workload/write.sql`](../workload/write.sql) (escritas `UPDATE + INSERT` ao vivo com invalidação CDC).
- **Telas Corporativas Complexas**: [`workload/complex-search.sql`](../workload/complex-search.sql) (busca textual `ILIKE '%...%'`), [`workload/complex-joins.sql`](../workload/complex-joins.sql) (`INNER` e `LEFT JOIN` de 4 a 6 tabelas), [`workload/complex-analytics.sql`](../workload/complex-analytics.sql) (`GROUP BY / HAVING`), [`workload/complex-dashboard.sql`](../workload/complex-dashboard.sql) (tela completa de 8 consultas) e [`workload/complex-dashboard-zipfian.sql`](../workload/complex-dashboard-zipfian.sql) (tráfego Pareto 80/20).

### Navegação Rápida
- [**PgCache 0.8.0 — Subsumption em Outer Joins, Invalidação Seletiva por Coluna e Curva de `pgcache_cache_subsumptions` (`0.8.0` vs. `0.7.1`)**](0.8.0/README-pt.md) *(Versão mais recente — `2026-04-22`)*
- [**PgCache 0.7.1_v2 (Parte 2) — O "Teste Justo", Filtros Dinâmicos, `ADMISSION_THRESHOLD` e SSD vs. NVMe Local**](0.7.1_v2/README-pt.md) *(Origem Otimizada com `GIN pg_trgm` + `2 GiB` Prewarmed, Filtros Dinâmicos Intra-Tenant e Estudo de Disco em 5 GB)*
- [**PgCache 0.7.1 (Parte 1) — Bateria de 5 Rodadas (`TRIALS=5`) e Cenários Corporativos Complexos**](0.7.1/README-pt.md) *(Ponto de partida recomendado)*
- [**Teste de Resistência de 1h30m e Alívio do Banco Principal (`SCALE=20`, ~10 GB)**](endurance-90m/README-pt.md)
- [**Comparativo de Ajuste Fino de Rede e Engine (`0.7.0` Tuned)**](tuned/README-pt.md)
- Versões Anteriores: [**0.6.3**](0.6.3/README-pt.md) · [**0.6.4**](0.6.4/README-pt.md) · [**0.7.0**](0.7.0/README-pt.md)

---

## 1. Visão Geral: Quando um Cache de Leitura Realmente Compensa?

Se você for olhar apenas uma tabela neste repositório, olhe esta.

Rodamos cada cenário **5 vezes independentes (`TRIALS=5`)** no nosso cluster de 3 nós na nuvem, destruindo e recriando os pods do PostgreSQL, do PgCache e do cliente antes de cada rodada para eliminar qualquer fator sorte:

| Tipo de Carga (200 Tenants, 8 Clientes Simultâneos) | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Taxa de Acerto (Hit) | Ganho Médio (Faixa nas 5 Rodadas) |
|---|---|---|---:|---|
| **Dashboard Operacional Leve** (`dashboard.sql`, 8 consultas simples) | 57,8 ms · **146 telas/s** *(±40,5 sd)* | **29,4 ms · 273 telas/s** *(±16,3 sd)* | **100,0%** | **1,98× mais rápido (+98%)** *(-68% / +69%)* |
| **Busca Textual por Substring** (`complex-search.sql`, 4 `ILIKE '%...%'` + joins) | 129,6 ms · **63 telas/s** *(±9,2 sd)* | **6,9 ms · 1.170 telas/s** *(±126,1 sd)* | **100,0%** | **18,8× mais rápido (+1.778%)** *(-266% / +243%)* |
| **Joins Profundos de 4 a 6 Tabelas** (`complex-joins.sql`, `INNER` e `LEFT JOIN`) | 238,9 ms · **34 telas/s** *(±2,8 sd)* | **8,2 ms · 991 telas/s** *(±160,6 sd)* | **100,0%** | **29,4× mais rápido (+2.839%)** *(-666% / +443%)* |
| **Analytics Multidimensional** (`complex-analytics.sql`, `GROUP BY / HAVING`) | 175,3 ms · **46 telas/s** *(±4,1 sd)* | **9,0 ms · 905 telas/s** *(±122,1 sd)* | **100,0%** | **19,8× mais rápido (+1.883%)** *(-395% / +267%)* |
| **Tela Corporativa Completa (Uniforme)** (`complex-dashboard.sql`, 8 consultas pesadas) | 307,5 ms · **26 telas/s** *(±1,2 sd)* | **23,4 ms · 389 telas/s** *(±132,6 sd)* | **100,0%** | **15,0× mais rápido (+1.400%)** *(-766% / +684%)* |
| **Tela Corporativa (Pareto 80/20, 200 Tenants)** (`complex-dashboard-zipfian.sql`) | 339,2 ms · **24 telas/s** *(±4,1 sd)* | **76,0 ms · 267 telas/s** *(±191,3 sd)* | **97,5%** | **11,5× mais rápido (+1.051%)** *(-1.016% / +917%)* |
| **Tela Corporativa (Pareto 80/20, 2.000 Tenants)** (`complex-dashboard-zipfian.sql`) | 373,1 ms · **22 telas/s** *(±1,9 sd)* | **351,2 ms · 24 telas/s** *(±5,4 sd)* | **64,1%** | **1,09× mais rápido (+9%)** *(-26% / +30%)* |

### Por Que o Ganho Salta de ~2× para ~29×?

Por dois motivos simples — **a física da rede** e **o esforço que o PostgreSQL precisa fazer**:
1. **O Pedágio da Rede**: Em um cluster real na nuvem, cada consulta SQL leva ~0,7 ms só para ir e voltar de uma VM para outra. Como uma tela faz 8 consultas em sequência, **~5,6 ms são gastos apenas viajando pela rede**, seja falando com o PostgreSQL ou com o PgCache.
2. **Quando a Consulta é Leve (`dashboard.sql`)**: O PostgreSQL já responde às 8 consultas simples em ~23 a 58 ms. Como a viagem pela rede já representa uma boa fatia desse tempo, o PgCache praticamente **dobra a vazão (+45% a +98%)**.
3. **Quando a Consulta é Pesada (`complex-*.sql`)**: Quando a tela faz buscas por texto (`ILIKE '%...%'`), cruza 6 tabelas ou agrupa milhares de pedidos (`GROUP BY`), o PostgreSQL leva **130 a 308 ms** por tela. O PgCache deixa esses resultados pré-calculados em memória (Materialized Views) e continua respondendo em **7 a 23 ms** — transformando uma tela lenta de 300 ms em uma resposta instantânea de 20 ms (**15× a 29× mais rápido**).

---

## 2. Evolução Entre Versões (`0.6.3` → `0.7.1`)

No dashboard operacional leve (`workload/dashboard.sql`), acompanhamos a evolução do PgCache da versão `0.6.3` até a `0.7.1` variando de **1 até 2.000 tenants** no cluster DOKS de 3 nós. Em todas as versões e faixas de clientes, após aquecido, o PgCache manteve **100,0% de acerto no cache**:

| Tenants Ativos | PostgreSQL Direto (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Taxa de Acerto |
|---|---|---|---|---|---|---:|
| **1 Tenant** | 23,3–27,5 ms (291–343 telas/s) | **17,6 ms** (455 telas/s, +56%) | **16,8 ms** (476 telas/s, +61%) | **15,6 ms** (513 telas/s, +50%) | **16,6 ms** (481 telas/s, +40%) | **100,0%** |
| **10 Tenants** | 22,9–27,7 ms (288–350 telas/s) | **17,8 ms** (451 telas/s, +52%) | **21,0 ms** (382 telas/s, +33%) | **22,9 ms** (349 telas/s, +4%) | **21,7 ms** (369 telas/s, +5%) | **100,0%** |
| **50 Tenants** | 25,4–29,9 ms (267–315 telas/s) | **17,5 ms** (456 telas/s, +66%) | **15,8 ms** (506 telas/s, +90%) | **17,3 ms** (462 telas/s, +64%) | **17,0 ms** (470 telas/s, +49%) | **100,0%** |
| **100 Tenants** | 25,2–30,3 ms (264–317 telas/s) | **19,4 ms** (412 telas/s, +56%) | **16,3 ms** (492 telas/s, +55%) | **17,2 ms** (465 telas/s, +51%) | **16,3 ms** (491 telas/s, +63%) | **100,0%** |
| **500 Tenants** | 24,4–32,2 ms (248–329 telas/s) | **16,7 ms** (478 telas/s, +93%) | **15,7 ms** (510 telas/s, +71%) | **18,7 ms** (428 telas/s, +38%) | **16,3 ms** (490 telas/s, +49%) | **100,0%** |
| **1.000 Tenants** | 24,0–26,2 ms (305–333 telas/s) | **17,5 ms** (458 telas/s, +50%) | **16,8 ms** (476 telas/s, +46%) | **17,2 ms** (466 telas/s, +52%) | **16,9 ms** (473 telas/s, +42%) | **100,0%** |
| **2.000 Tenants** | 23,3–26,0 ms (308–343 telas/s) | **18,3 ms** (438 telas/s, +40%) | **15,5 ms** (515 telas/s, +67%) | **18,8 ms** (425 telas/s, +38%) | **16,5 ms** (485 telas/s, +41%) | **100,0%** |

---

## 3. O Que Acontece Quando os Acessos Simultâneos Crescem? (`1` a `32` Usuários)

Quando aumentamos os usuários simultâneos na tela corporativa pesada (`complex-dashboard.sql`), o PostgreSQL bate no teto de CPU em **38–39 telas/s** e o tempo de espera do usuário explode para **835 ms**. O PgCache escala até **1.020 telas/s (26,8× mais rápido)** mantendo o tempo de resposta em **31 ms**:

| Usuários Simultâneos | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto |
|---:|---|---|---:|---:|
| **1 Usuário** | 100,6 ms · 10 telas/s | **7,1 ms · 140 telas/s** | **14,0× (+1.300%)** | 100,0% |
| **4 Usuários** | 129,5 ms · 31 telas/s | **8,6 ms · 465 telas/s** | **15,0× (+1.400%)** | 100,0% |
| **8 Usuários** | 212,8 ms · 38 telas/s | **10,5 ms · 763 telas/s** | **20,1× (+1.908%)** | 100,0% |
| **16 Usuários** | 406,9 ms · 39 telas/s | **18,1 ms · 886 telas/s** | **22,7× (+2.172%)** | 100,0% |
| **32 Usuários** | 835,5 ms · 38 telas/s | **31,4 ms · 1.020 telas/s** | **26,8× (+2.584%)** | 100,0% |

---

## 4. Guia das Pastas

- [`0.8.0/`](0.8.0/README-pt.md): **PgCache 0.8.0 (`2026-04-22`)** — Avaliação completa em 3 nós DOKS (`TRIALS=3`) demonstrando `-75%` de invalidações CDC redundantes (`12 → 3`), `+52,4%` de vazão sob escrita contínua (`5:200`), ganho líquido positivo em `1.000` e `2.000` tenants Pareto 80/20 (`+53%` e `+27%`), vitória de `+8%` sobre o Origin em filtros dinâmicos (`t4_dyn`), e a curva comparativa de 120s de **`pgcache_cache_subsumptions` (`0.8.0` vs. `0.7.1`)**.
- [`0.7.1/`](0.7.1/README-pt.md): Relatório completo e logs da versão **PgCache 0.7.1 (Parte 1)** (bateria de 5 rodadas com recriação de pods, cenários complexos, escala Pareto 80/20 e testes de escrita ao vivo).
- [`0.7.1_v2/`](0.7.1_v2/README-pt.md): **PgCache 0.7.1_v2 (Parte 2)** — O "Teste Justo" contra um PostgreSQL de Origem totalmente otimizado (`GIN pg_trgm` + `2 GiB shared_buffers` prewarmed), filtros dinâmicos intra-tenant (`complex-dashboard-dynamic.sql`), investigação de `ADMISSION_THRESHOLD` (`1` vs `2` vs `4`) e estudo de pressão de disco em 5 GB (`SCALE=10`, SSD Padrão vs NVMe Local).
- [`endurance-90m/`](endurance-90m/README-pt.md): **Teste de Resistência de 1h30m e Alívio do Banco Principal** em um banco de ~10 GB (`54,5M` linhas), mostrando como tirar o peso das leituras do PostgreSQL reduz a latência de escrita pela metade (`227 ms → 103 ms`).
- [`tuned/`](tuned/README-pt.md): Comparativo entre a configuração padrão e o ajuste fino de rede Linux (`tcp_tw_reuse`, VirtIO RPS, roteamento direto por IP).
- [`0.6.3/`](0.6.3/README-pt.md), [`0.6.4/`](0.6.4/README-pt.md), [`0.7.0/`](0.7.0/README-pt.md): Rodadas históricas do baseline.
