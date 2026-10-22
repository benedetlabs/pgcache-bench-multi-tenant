# Benchmark do PgCache 0.7.1 em um SaaS Multi-Tenant: O Que Realmente Acontece em um Cluster de 3 Nós na Nuvem

> 🇺🇸 **[Read in English](README.md)** · 🚀 **[Ler Parte 2 (`results/0.7.1_v2/`): O "Teste Justo" (Origin `2 GiB` Prewarmed + `GIN pg_trgm`), Filtros Dinâmicos do Usuário e Estudo de `ADMISSION_THRESHOLD` (`1` vs `2` vs `4`)](../0.7.1_v2/README-pt.md)**

Colocar um proxy de cache de leitura na frente do PostgreSQL realmente deixa um sistema SaaS multi-tenant mais rápido — e em quais situações ele encontra seus limites?

Este artigo apresenta os resultados práticos de testar o **PgCache 0.7.1** (`pgcache/pgcache:0.7.1`) na frente do **PostgreSQL 17**. Toda a suíte foi desenhada para rodar em um **cluster Kubernetes de 3 nós em qualquer provedor de nuvem** (AWS EKS, Azure AKS, Google GKE ou DigitalOcean DOKS), posicionando o banco de dados, o cache e o gerador de carga em **três máquinas virtuais separadas** para que cada consulta pague a latência real de rede e tenha CPU e RAM isoladas. Para esta rodada de testes, executamos o cluster na DigitalOcean (`3× s-4vcpu-8gb` em uma mesma zona de disponibilidade).

---

## 1. O Que Está Sendo Testado: O Banco de Dados e as Consultas SQL

> 📖 **Catálogo Completo de Modelagem e SQL**: Para ver o diagrama Entidade-Relacionamento, os índices e o código SQL completo de cada consulta, acesse o guia **[`workload/README-pt.md`](../../workload/README-pt.md)**.

Modelamos um banco de dados de e-commerce SaaS multi-tenant criado pelos scripts [`sql/01-schema.sql`](../../sql/01-schema.sql) e [`sql/02-tenant.sql`](../../sql/02-tenant.sql), composto por **7 tabelas relacionais** (`customer`, `orders`, `order_item`, `product`, `category`, `seller` e `review`) populadas com **500.000 pedidos, 2.000.000 de itens de pedido, 300.000 avaliações, 200.000 produtos e 100.000 clientes**, distribuídos em até **2.000 empresas clientes (tenants)**.

Em vez de testar consultas isoladas, cada requisição do `pgbench` simula um usuário abrindo uma **tela completa do SaaS**, executando de **4 a 8 consultas SQL em sequência**:

| Arquivo SQL da Carga | Consultas por Tela | O Que a Tela Simula |
|---|:---:|---|
| **[`workload/dashboard.sql`](../../workload/dashboard.sql)** | **8** | **Dashboard Operacional Leve**: Contadores rápidos por índice (`GROUP BY status`), receita total, total de clientes, paginação de pedidos recentes e listagens simples com `INNER JOIN` de 2 tabelas. |
| **[`workload/complex-search.sql`](../../workload/complex-search.sql)** | **4** | **Busca Textual por Substring (`ILIKE '%...%'`)**: Buscas com curinga inicial em nomes/e-mails de clientes, nomes de produtos, vendedores e textos de avaliações, cruzando de 3 a 6 tabelas. |
| **[`workload/complex-joins.sql`](../../workload/complex-joins.sql)** | **4** | **Joins Profundos de 4 a 6 Tabelas (`JOIN` e `LEFT JOIN`)**: Cruzamentos longos (`orders → customer → order_item → product → category → seller → review`), incluindo `LEFT JOIN` para listar clientes sem pedidos e produtos sem avaliações. |
| **[`workload/complex-analytics.sql`](../../workload/complex-analytics.sql)** | **4** | **Analytics Multidimensional**: Relatórios analíticos com `GROUP BY`, `FILTER (WHERE ...)`, faixas de ticket `CASE WHEN` e filtros `HAVING` sobre 4 a 6 tabelas. |
| **[`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql)** | **8** | **Tela Corporativa Completa (Tráfego Uniforme)**: Combina 3 relatórios analíticos, 3 joins profundos de até 6 tabelas e 2 buscas textuais `ILIKE` em uma única tela pesada de 8 consultas, sorteando os tenants de forma uniforme (`1..N`). |
| **[`workload/complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)** | **8** | **Tela Corporativa Completa (Tráfego Pareto 80/20)**: As mesmas 8 consultas pesadas acima, mas sorteando os tenants segundo uma distribuição **Zipfian (`s = 1.07`)**, onde ~20% dos tenants concentram ~80% dos acessos. |
| **[`workload/write.sql`](../../workload/write.sql)** | **2** | **Escritas Transacionais ao Vivo (`UPDATE` + `INSERT`)**: Atualiza o valor de um pedido existente (`UPDATE orders`) e insere um novo item de pedido (`INSERT INTO order_item`), acionando a replicação lógica (CDC) no PgCache. |

### Os Dois Caminhos Comparados
- **Caminho A (PostgreSQL Direto)**: O gerador de carga conecta diretamente na VM do PostgreSQL 17.
- **Caminho B (PgCache 0.7.1)**: O gerador de carga conecta na VM do PgCache, que responde às leituras em memória e acompanha o log de replicação lógica (CDC) do PostgreSQL para manter os dados atualizados.

---

## 2. Resumo Executivo (TL;DR)

1. **100% de Respostas Idênticas (`verify-correctness.sh`)**: Antes de medir velocidade, validamos que todas as **8 consultas do dashboard básico** e todas as **12 consultas complexas** devolvem exatamente as mesmas linhas (byte a byte) no PostgreSQL e no PgCache — tanto em leituras estáticas quanto imediatamente após escritas `UPDATE` e `INSERT` ao vivo.
2. **Consultas Simples vs. Consultas Pesadas (1,98× vs. 29,4× mais rápido)**:
   - No **dashboard operacional leve** ([`dashboard.sql`](../../workload/dashboard.sql)), o PostgreSQL já responde às 8 consultas indexadas em **57,8 ms**, então o PgCache quase **dobra a capacidade (+98%, subindo de 146 para 273 telas/s)**.
   - Nas **telas corporativas pesadas** ([`complex-search.sql`](../../workload/complex-search.sql), [`complex-joins.sql`](../../workload/complex-joins.sql), [`complex-analytics.sql`](../../workload/complex-analytics.sql)), o PostgreSQL leva de **130 a 308 ms** varrendo e juntando tabelas. O PgCache pré-computa essas visões em memória (Materialized Views) e responde a tela inteira em **6,9 a 23,4 ms** — entregando **15× a 29,4× mais vazão (+1.400% a +2.839%)**.
3. **Por que a Regra 80/20 do Mundo Real Faz Diferença em 2.000 Tenants**:
   - Quando 2.000 tenants acessam o sistema seguindo a **regra de Pareto 80/20** ([`complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)), os 20% de clientes mais ativos aquecem rápido (**64,1% de acerto**) e mantêm o PgCache à frente do PostgreSQL mesmo partindo do zero.
4. **Onde o Cache Sofre (Partida Fria com Escritas Simultâneas)**:
   - Quando aquecido primeiro, o PgCache lida bem com 5% a 10% de tráfego de escrita (**63% a 75% de acerto**).
   - Porém, se você reiniciar o cache **totalmente frio** enquanto bombardeia o banco simultaneamente com `UPDATE orders` e `INSERT INTO order_item` ([`write.sql`](../../workload/write.sql)), as invalidações de replicação brigam com o carregamento inicial do cache e derrubam a vazão (**-85%**). Sempre aqueça o cache com leituras antes de virar a chave de cargas mistas intensas.
5. **Continuação na Parte 2 ([`results/0.7.1_v2/`](../0.7.1_v2/README-pt.md))**:
   - Veja a **[Parte 2 (`0.7.1_v2`)](../0.7.1_v2/README-pt.md)** para o estudo complementar com **PostgreSQL Origin tunado (`2 GiB` prewarmed + índices `GIN pg_trgm`)**, **busca textual de 3+ caracteres (`search_3c`)**, **filtros dinâmicos intra-tenant (`cplx_dyn`)** e a varredura experimental de **`ADMISSION_THRESHOLD = 1` vs `2` vs `4`** a partir da devolutiva do James (core dev do PgCache).

---

## 3. Bateria Multi-Trial: Tabela Consolidada e Números de Cada Uma das 5 Execuções (`TRIALS=5`)

Em ambientes de nuvem, rodar um benchmark apenas uma vez pode enganar — basta uma variação de rede ou de aquecimento para distorcer o número. Para eliminar anomalias pontuais, executamos cada cenário **5 vezes independentes (`TRIALS=5`, `DURATION=15s`, `CLIENTS=8`)**.

Antes de **cada uma das 5 execuções**, nossa automação (`reset_all_pods` em [`scripts/lib.sh`](../../scripts/lib.sh)) limpou os registros inseridos e **recriou do zero os pods do PostgreSQL, do PgCache e do gerador de carga**, aquecendo o cache dinamicamente (`warm_until_settled`) antes de medir o Caminho B.

Logs brutos: [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt) · [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt) · [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)

### 3.1 Tabela Consolidada (Média das 5 Execuções)

| Cenário e Arquivo SQL (`CLIENTS=8`) | PostgreSQL Direto (Média Caminho A) | PgCache 0.7.1 (Média Caminho B) | Taxa de Acerto | Ganho Médio (Variação Mín/Máx nas 5 Rodadas) |
|---|---|---|---:|---|
| **1. Dashboard Operacional Leve** ([`dashboard.sql`](../../workload/dashboard.sql), 200 tenants) | 57,8 ms · **146 telas/s** *(±40,5 sd)* | **29,4 ms · 273 telas/s** *(±16,3 sd)* | **100,0%** | **1,98× (+98%)** *(-68% / +69%)* |
| **2. Busca Textual por Substring** ([`complex-search.sql`](../../workload/complex-search.sql), 200 tenants) | 129,6 ms · **63 telas/s** *(±9,2 sd)* | **6,9 ms · 1.170 telas/s** *(±126,1 sd)* | **100,0%** | **18,8× (+1.778%)** *(-266% / +243%)* |
| **3. Joins Profundos (4 a 6 Tabelas)** ([`complex-joins.sql`](../../workload/complex-joins.sql), 200 tenants) | 238,9 ms · **34 telas/s** *(±2,8 sd)* | **8,2 ms · 991 telas/s** *(±160,6 sd)* | **100,0%** | **29,4× (+2.839%)** *(-666% / +443%)* |
| **4. Analytics Multidimensional** ([`complex-analytics.sql`](../../workload/complex-analytics.sql), 200 tenants) | 175,3 ms · **46 telas/s** *(±4,1 sd)* | **9,0 ms · 905 telas/s** *(±122,1 sd)* | **100,0%** | **19,8× (+1.883%)** *(-395% / +267%)* |
| **5. Tela Corporativa — Uniforme** ([`complex-dashboard.sql`](../../workload/complex-dashboard.sql), 200 tenants) | 307,5 ms · **26 telas/s** *(±1,2 sd)* | **23,4 ms · 389 telas/s** *(±132,6 sd)* | **100,0%** | **15,0× (+1.400%)** *(-766% / +684%)* |
| **6. Tela Corporativa — Pareto 80/20** ([`complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql), 200 tenants) | 339,2 ms · **24 telas/s** *(±4,1 sd)* | **76,0 ms · 267 telas/s** *(±191,3 sd)* | **97,5%** | **11,5× (+1.051%)** *(-1.016% / +917%)* |
| **7. Tela Corporativa — Pareto 80/20** ([`complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql), 2.000 tenants) | 373,1 ms · **22 telas/s** *(±1,9 sd)* | **351,2 ms · 24 telas/s** *(±5,4 sd)* | **64,1%** | **1,09× (+9%)** *(-26% / +30%)* |
| **8. Partida Fria + 5% Escritas (`UPDATE`+`INSERT`)** ([`complex-dashboard.sql`](../../workload/complex-dashboard.sql) + [`write.sql`](../../workload/write.sql)) | 327,9 ms · **25 telas/s** *(±2,7 sd)* | 2.995,5 ms · **3 telas/s** *(±2,6 sd)* | **32,4%** | **0,15× (-85%)** *(-8% / +23%)* |

---

### 3.2 Detalhamento Individual: Os Números de Cada Uma das 5 Execuções

Abaixo estão os números exatos medidos em cada uma das 5 rodadas (`Execução 1` a `Execução 5`), com recriação completa dos pods entre uma e outra.

#### Cenário 1: Dashboard Operacional Leve — [`workload/dashboard.sql`](../../workload/dashboard.sql) (8 consultas, 200 tenants)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 38,91 ms | 206 telas/s | 29,94 ms | 267 telas/s | 100,00% | **+29,6% (1,30×)** | 6 |
| **Execução 2** | 72,54 ms | 110 telas/s | 27,18 ms | 294 telas/s | 100,00% | **+167,3% (2,67×)** | 5 |
| **Execução 3** | 69,15 ms | 116 telas/s | 29,14 ms | 275 telas/s | 99,99% | **+137,1% (2,37×)** | 5 |
| **Execução 4** | 47,41 ms | 169 telas/s | 28,58 ms | 280 telas/s | 100,00% | **+65,7% (1,66×)** | 6 |
| **Execução 5** | 61,18 ms | 131 telas/s | 31,98 ms | 250 telas/s | 99,99% | **+90,8% (1,91×)** | 5 |
| **Média (5 Execuções)** | **57,84 ms** | **146 telas/s** *(±40,5 sd, -36/+60)* | **29,36 ms** | **273 telas/s** *(±16,3 sd, -23/+21)* | **100,0%** | **+98% (1,98×)** | **5,4** |

> **O que as 5 execuções revelam**: Repare como o PostgreSQL Direto (Caminho A) oscila entre `110 telas/s` e `206 telas/s` (`±40,5 sd`) logo após o pod reiniciar (enquanto seu buffer pool e disco aquecem), enquanto o PgCache (Caminho B) mantém uma estabilidade impressionante nas 5 rodadas (`250 a 294 telas/s`, `±16,3 sd`).

---

#### Cenário 2: Busca Textual por Substring (`ILIKE '%...%'`) — [`workload/complex-search.sql`](../../workload/complex-search.sql) (4 consultas, 200 tenants)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 107,94 ms | 74 telas/s | 6,61 ms | 1.210 telas/s | 100,00% | **+1.535,1% (16,4×)** | 5 |
| **Execução 2** | 120,00 ms | 67 telas/s | 6,03 ms | 1.327 telas/s | 100,00% | **+1.880,6% (19,8×)** | 5 |
| **Execução 3** | 161,05 ms | 50 telas/s | 7,84 ms | 1.020 telas/s | 100,00% | **+1.940,0% (20,4×)** | 6 |
| **Execução 4** | 121,72 ms | 66 telas/s | 7,52 ms | 1.064 telas/s | 100,00% | **+1.512,1% (16,1×)** | 5 |
| **Execução 5** | 137,43 ms | 58 telas/s | 6,50 ms | 1.230 telas/s | 100,00% | **+2.020,7% (21,2×)** | 5 |
| **Média (5 Execuções)** | **129,63 ms** | **63 telas/s** *(±9,2 sd, -13/+11)* | **6,90 ms** | **1.170 telas/s** *(±126,1 sd, -150/+157)* | **100,0%** | **+1.778% (18,8×)** | **5,2** |

---

#### Cenário 3: Joins Profundos de 4 a 6 Tabelas (`JOIN` e `LEFT JOIN`) — [`workload/complex-joins.sql`](../../workload/complex-joins.sql) (4 consultas, 200 tenants)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 214,54 ms | 37 telas/s | 9,51 ms | 841 telas/s | 100,00% | **+2.173,0% (22,7×)** | 6 |
| **Execução 2** | 242,98 ms | 33 telas/s | 7,17 ms | 1.116 telas/s | 100,00% | **+3.281,8% (33,8×)** | 7 |
| **Execução 3** | 268,60 ms | 30 telas/s | 9,74 ms | 821 telas/s | 100,00% | **+2.636,7% (27,4×)** | 7 |
| **Execução 4** | 245,73 ms | 33 telas/s | 8,02 ms | 997 telas/s | 100,00% | **+2.921,2% (30,2×)** | 6 |
| **Execução 5** | 222,48 ms | 36 telas/s | 6,78 ms | 1.181 telas/s | 100,00% | **+3.180,6% (32,8×)** | 6 |
| **Média (5 Execuções)** | **238,86 ms** | **34 telas/s** *(±2,8 sd, -4/+3)* | **8,24 ms** | **991 telas/s** *(±160,6 sd, -170/+190)* | **100,0%** | **+2.839% (29,4×)** | **6,4** |

---

#### Cenário 4: Analytics Multidimensional (`GROUP BY / FILTER / HAVING`) — [`workload/complex-analytics.sql`](../../workload/complex-analytics.sql) (4 consultas, 200 tenants)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 172,20 ms | 46 telas/s | 7,73 ms | 1.035 telas/s | 100,00% | **+2.150,0% (22,5×)** | 7 |
| **Execução 2** | 175,57 ms | 46 telas/s | 7,84 ms | 1.020 telas/s | 100,00% | **+2.117,4% (22,2×)** | 6 |
| **Execução 3** | 159,02 ms | 50 telas/s | 10,07 ms | 794 telas/s | 100,00% | **+1.488,0% (15,9×)** | 8 |
| **Execução 4** | 203,17 ms | 39 telas/s | 10,33 ms | 774 telas/s | 100,00% | **+1.884,6% (19,8×)** | 6 |
| **Execução 5** | 166,40 ms | 48 telas/s | 8,89 ms | 900 telas/s | 100,00% | **+1.775,0% (18,8×)** | 7 |
| **Média (5 Execuções)** | **175,27 ms** | **46 telas/s** *(±4,1 sd, -7/+4)* | **8,97 ms** | **905 telas/s** *(±122,1 sd, -131/+130)* | **100,0%** | **+1.883% (19,8×)** | **6,8** |

---

#### Cenário 5: Tela Corporativa Completa (Sorteio Uniforme) — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (8 consultas, 200 tenants)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 319,77 ms | 25 telas/s | 20,59 ms | 389 telas/s | 100,00% | **+1.456,0% (15,6×)** | 8 |
| **Execução 2** | 316,40 ms | 25 telas/s | 14,66 ms | 546 telas/s | 100,00% | **+2.084,0% (21,8×)** | 7 |
| **Execução 3** | 303,35 ms | 26 telas/s | 41,86 ms | 191 telas/s | 99,96% | **+634,6% (7,3×)** | 8 |
| **Execução 4** | 284,58 ms | 28 telas/s | 17,26 ms | 463 telas/s | 100,00% | **+1.553,6% (16,5×)** | 8 |
| **Execução 5** | 313,51 ms | 26 telas/s | 22,39 ms | 357 telas/s | 100,00% | **+1.273,1% (13,7×)** | 8 |
| **Média (5 Execuções)** | **307,52 ms** | **26 telas/s** *(±1,2 sd, -1/+2)* | **23,35 ms** | **389 telas/s** *(±132,6 sd, -198/+157)* | **100,0%** | **+1.400% (15,0×)** | **7,8** |

> **Por que olhar a Execução 3 é tão interessante**: Na Execução 3, a taxa de acerto ficou em `99,96%` em vez de `100,00%`. Como um único cache miss em uma consulta de 6 tabelas leva ~40 ms para ser populado na hora, esses míseros `0,04%` de misses puxaram a média da Execução 3 para `41,86 ms (191 telas/s)` contra `14,66–22,39 ms (357–546 telas/s)` nas outras 4 execuções. Mostrar as 5 execuções abertas permite enxergar tanto a velocidade típica (~400 a 546 telas/s) quanto o impacto de qualquer fração de cache miss.

---

#### Cenário 6: Tela Corporativa com Tráfego Pareto 80/20 (`200` Tenants) — [`workload/complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 266,60 ms | 30 telas/s | 48,32 ms | 166 telas/s | 99,28% | **+453,3% (5,5×)** | 8 |
| **Execução 2** | 313,86 ms | 25 telas/s | 16,95 ms | 472 telas/s | 100,00% | **+1.788,0% (18,9×)** | 8 |
| **Execução 3** | 412,61 ms | 19 telas/s | 37,92 ms | 211 telas/s | 99,73% | **+1.010,5% (11,1×)** | 8 |
| **Execução 4** | 347,18 ms | 23 telas/s | 259,23 ms | 31 telas/s | 88,27% | **+34,8% (1,3×)** | 5 |
| **Execução 5** | 355,99 ms | 22 telas/s | 17,59 ms | 455 telas/s | 100,00% | **+1.968,2% (20,7×)** | 8 |
| **Média (5 Execuções)** | **339,25 ms** | **24 telas/s** *(±4,1 sd, -5/+6)* | **76,00 ms** | **267 telas/s** *(±191,3 sd, -236/+205)* | **97,5%** | **+1.051% (11,5×)** | **7,4** |

> **Por que a Execução 4 parou de aquecer no ciclo 5**: Como a distribuição 80/20 repete bastante os mesmos 20% de tenants mais quentes, dois ciclos seguidos de aquecimento tiveram variação `< 1%` perto de `88%` de hit ratio, fazendo o algoritmo `warm_until_settled` iniciar a medição mais cedo enquanto os tenants menos frequentes ainda estavam carregando (`31 telas/s`). Nas 4 rodadas que completaram os 8 ciclos (Execuções 1, 2, 3 e 5), a vazão bateu **166 a 472 telas/s (5,5× a 20,7× mais rápido)**.

---

#### Cenário 7: Tela Corporativa com Tráfego Pareto 80/20 (`2.000` Tenants) — [`workload/complex-dashboard-zipfian.sql`](../../workload/complex-dashboard-zipfian.sql)

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 354,03 ms | 23 telas/s | 253,83 ms | 32 telas/s | 70,02% | **+39,1% (1,39×)** | 7 |
| **Execução 2** | 374,73 ms | 21 telas/s | 310,03 ms | 26 telas/s | 68,46% | **+23,8% (1,24×)** | 8 |
| **Execução 3** | 383,77 ms | 21 telas/s | 400,58 ms | 20 telas/s | 62,19% | -4,8% (0,95×) | 5 |
| **Execução 4** | 413,70 ms | 19 telas/s | 392,73 ms | 20 telas/s | 61,13% | **+5,3% (1,05×)** | 5 |
| **Execução 5** | 339,23 ms | 24 telas/s | 398,85 ms | 20 telas/s | 58,75% | -16,7% (0,83×) | 4 |
| **Média (5 Execuções)** | **373,09 ms** | **22 telas/s** *(±1,9 sd, -3/+2)* | **351,21 ms** | **24 telas/s** *(±5,4 sd, -4/+8)* | **64,1%** | **+9% (1,09×)** | **5,8** |

---

#### Cenário 8: Partida Fria com 5% de Escritas `UPDATE` + `INSERT` — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) @ 95% + [`workload/write.sql`](../../workload/write.sql) @ 5%

| Execução | Latência Caminho A | Vazão Caminho A | Latência Caminho B | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 322,66 ms | 25 telas/s | 2.851,12 ms | 3 telas/s | 32,95% | -88,0% (0,12×) | 3 |
| **Execução 2** | 378,34 ms | 21 telas/s | 979,29 ms | 8 telas/s | 36,52% | -61,9% (0,38×) | 3 |
| **Execução 3** | 285,19 ms | 28 telas/s | 3.263,27 ms | 2 telas/s | 29,37% | -92,9% (0,07×) | 3 |
| **Execução 4** | 346,50 ms | 23 telas/s | 3.367,50 ms | 2 telas/s | 27,43% | -91,3% (0,09×) | 3 |
| **Execução 5** | 306,65 ms | 26 telas/s | 4.516,17 ms | 2 telas/s | 35,59% | -92,3% (0,08×) | 3 |
| **Média (5 Execuções)** | **327,87 ms** | **25 telas/s** *(±2,7 sd, -4/+3)* | **2.995,47 ms** | **3 telas/s** *(±2,6 sd, -1/+5)* | **32,4%** | **-85% (0,15×)** | **3,0** |

---

## 4. Varreduras de Escala: Tenants, Usuários Simultâneos e Escritas com Cache Aquecido

Além da bateria de 5 execuções acima, realizamos varreduras variando um eixo por vez no cluster de 3 nós.

### 4.1 Escalando de 1 até 2.000 Tenants no Dashboard Leve ([`workload/dashboard.sql`](../../workload/dashboard.sql))

Log bruto: [`run-tenants-doks.txt`](run-tenants-doks.txt) · TSV: [`results-doks.tsv`](results-doks.tsv)

| Tenants Ativos | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 23,3 ms · 343 telas/s | **16,6 ms · 481 telas/s** | **+40%** | 100,0% | 2 |
| **10** | 22,9 ms · 350 telas/s | **21,7 ms · 369 telas/s** | **+5%** | 100,0% | 2 |
| **50** | 25,4 ms · 315 telas/s | **17,0 ms · 470 telas/s** | **+49%** | 100,0% | 3 |
| **100** | 26,5 ms · 302 telas/s | **16,3 ms · 491 telas/s** | **+63%** | 100,0% | 3 |
| **500** | 24,4 ms · 329 telas/s | **16,3 ms · 490 telas/s** | **+49%** | 100,0% | 4 |
| **1.000** | 24,0 ms · 333 telas/s | **16,9 ms · 473 telas/s** | **+42%** | 100,0% | 4 |
| **2.000** | 23,3 ms · 343 telas/s | **16,5 ms · 485 telas/s** | **+41%** | 100,0% | 6 |

---

### 4.2 Escalando Tenants na Tela Corporativa Pesada (`1` a `1.000` Tenants Uniformes — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql))

Log bruto: [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)

| Tenants Ativos (Uniforme) | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 206,8 ms · 39 telas/s | **9,2 ms · 871 telas/s** | **22,3× (+2.133%)** | 100,0% | 2 |
| **10** | 198,2 ms · 40 telas/s | **9,6 ms · 835 telas/s** | **20,9× (+1.988%)** | 100,0% | 2 |
| **50** | 227,5 ms · 35 telas/s | **10,8 ms · 740 telas/s** | **21,1× (+2.014%)** | 100,0% | 6 |
| **200** | 212,8 ms · 38 telas/s | **11,2 ms · 712 telas/s** | **18,7× (+1.774%)** | 100,0% | 7 |
| **500** | 223,9 ms · 36 telas/s | **18,4 ms · 435 telas/s** | **12,1× (+1.108%)** | 100,0% | 8 |
| **1.000** *(teto de 8 passes)* | 210,1 ms · 38 telas/s | 251,4 ms · 32 telas/s | 0,84× (-16%) | 68,1% | 4 |

---

### 4.3 Escalando Usuários Simultâneos (`1` a `32` Clientes — [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql))

Log bruto: [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)

| Clientes Simultâneos | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Taxa de Acerto |
|---:|---|---|---:|---:|
| **1** | 100,6 ms · 10 telas/s | **7,1 ms · 140 telas/s** | **14,0× (+1.300%)** | 100,0% |
| **4** | 129,5 ms · 31 telas/s | **8,6 ms · 465 telas/s** | **15,0× (+1.400%)** | 100,0% |
| **8** | 212,8 ms · 38 telas/s | **10,5 ms · 763 telas/s** | **20,1× (+1.908%)** | 100,0% |
| **16** | 406,9 ms · 39 telas/s | **18,1 ms · 886 telas/s** | **22,7× (+2.172%)** | 100,0% |
| **32** | 835,5 ms · 38 telas/s | **31,4 ms · 1.020 telas/s** | **26,8× (+2.584%)** | 100,0% |

---

### 4.4 Cache Aquecido sob Escritas ao Vivo ([`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) + `UPDATE orders`)

Ao contrário do Cenário 8 da Seção 3 (que partiu de um pod 100% frio), este teste **aquece primeiro os 200 tenants no cache** e depois introduz 5% ou 10% de escritas ao vivo:
- **5 das 8 consultas (`62,5%`) usam `INNER JOIN`** com `WHERE o.tenant_id = :t`, permitindo que o PgCache atualize os dados do tenant diretamente em memória via CDC e continue respondendo com **100% de acerto no cache**.
- **3 das 8 consultas (`37,5%`) usam `LEFT JOIN`** (onde `o.tenant_id = :t` fica na cláusula `ON` do outer join para preservar clientes sem pedidos), que o PgCache invalida de forma conservadora sempre que a tabela `orders` muda.

Log bruto: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)

| Proporção de Escrita | Tenants Recebendo Escrita | PostgreSQL Direto (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho / Perda | Taxa de Acerto |
|---:|---:|---|---|---:|---:|
| **0% (Só Leitura)** | — | 189,8 ms · 42 telas/s | **11,1 ms · 719 telas/s** | **+1.612% (17,1×)** | 100,0% |
| **5% Escrita** | 1 tenant quente | 186,7 ms · 43 telas/s | **166,2 ms · 48 telas/s** | **+12%** | 75,0% |
| **5% Escrita** | 10 tenants | 182,4 ms · 44 telas/s | 194,4 ms · 41 telas/s | -7% | 65,4% |
| **5% Escrita** | Todos os 200 tenants | 191,2 ms · 42 telas/s | 201,5 ms · 40 telas/s | -5% | 65,7% |
| **10% Escrita** | 1 tenant quente | 177,7 ms · 45 telas/s | **154,7 ms · 52 telas/s** | **+16%** | 63,1% |
| **10% Escrita** | Todos os 200 tenants | 167,9 ms · 48 telas/s | 191,8 ms · 42 telas/s | -12% | 64,8% |

---

## 5. Verificação de Corretude em 3 Estágios ([`scripts/verify-correctness.sh`](../../scripts/verify-correctness.sh))

Log completo da verificação: [`verify-correctness-doks.txt`](verify-correctness-doks.txt)

| Estágio | O Que é Verificado | Resultado |
|---|---|---|
| **Estágio 1: Consultas Básicas (8/8)** | Roda todas as 8 consultas de [`workload/dashboard.sql`](../../workload/dashboard.sql) no PostgreSQL e no PgCache e compara cada linha byte a byte. | **APROVADO (8/8 idênticas, 100% cacheáveis)** |
| **Estágio 2: Consultas Complexas Estáticas (12/12)** | Roda todas as 12 consultas complexas de [`complex-search.sql`](../../workload/complex-search.sql), [`complex-joins.sql`](../../workload/complex-joins.sql) e [`complex-analytics.sql`](../../workload/complex-analytics.sql) em 3 passagens. | **APROVADO (12/12 idênticas, 100% hit em MV)** |
| **Estágio 3: Mutação CDC ao Vivo (`UPDATE` + `INSERT`)** | Executa `UPDATE orders`, `UPDATE order_item` e `INSERT INTO order_item` ao vivo no PostgreSQL, aguarda a replicação CDC e confere novamente as 12 consultas complexas no PgCache. | **APROVADO (12/12 idênticas após escritas)** |

---

## 6. Arquivos Brutos e Logs do Benchmark

- **Estudo Complementar Parte 2 (`results/0.7.1_v2/`)**: [`results/0.7.1_v2/README-pt.md`](../0.7.1_v2/README-pt.md)
- **Documentação da Modelagem e das Consultas SQL**: [`workload/README-pt.md`](../../workload/README-pt.md)
- **Logs da Bateria Multi-Trial (`TRIALS=5`, com Recriação Completa dos Pods)**:
  - Cenários Complexos (`TRIALS=5`): [`04-complex-scenarios-k8s.txt`](04-complex-scenarios-k8s.txt)
  - Distribuição Pareto/Zipfian 80/20 (`TRIALS=5`): [`04-complex-zipfian-k8s.txt`](04-complex-zipfian-k8s.txt)
  - Escrita Concorrente `UPDATE + INSERT` em Partida Fria (`TRIALS=5`): [`04-complex-writes-k8s.txt`](04-complex-writes-k8s.txt)
- **Logs de Varredura e Corretude**:
  - Saída do Gate de Corretude: [`verify-correctness-doks.txt`](verify-correctness-doks.txt)
  - Varredura de Tenants Baseline (`1..2000`): [`run-tenants-doks.txt`](run-tenants-doks.txt) · [`results-doks.tsv`](results-doks.tsv)
  - Comparativo de Cenários Complexos: [`run-complex-scenarios-doks.txt`](run-complex-scenarios-doks.txt) · [`results-complex-doks.tsv`](results-complex-doks.tsv)
  - Escala de Tenants Complexos (`1..1000`): [`run-complex-tenants-doks.txt`](run-complex-tenants-doks.txt)
  - Escala de Concorrência (`1..32` clientes): [`run-complex-clients-doks.txt`](run-complex-clients-doks.txt)
  - Escritas com Cache Aquecido: [`run-complex-writes-doks.txt`](run-complex-writes-doks.txt)
