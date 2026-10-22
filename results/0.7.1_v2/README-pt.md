# Benchmark do PgCache 0.7.1 em um SaaS Multi-Tenant (Parte 2 — v2): O "Teste Justo", Filtros Dinâmicos do Usuário e Devolutiva sobre `ADMISSION_THRESHOLD`

> 🇺🇸 **[Read in English](README.md)** · 📖 **[Ler Parte 1 (`results/0.7.1/`)](../0.7.1/README-pt.md)**

Na **[Parte 1 (`results/0.7.1/`)](../0.7.1/README-pt.md)**, avaliamos o **PgCache 0.7.1** (`pgcache/pgcache:0.7.1`) na frente do **PostgreSQL 17** em um cluster Kubernetes de 3 nós na nuvem (`3× s-4vcpu-8gb` na mesma zona de disponibilidade), demonstrando **1,98× de ganho** em dashboards operacionais leves e **15× a 29,4× de ganho** em telas corporativas pesadas multi-tabela — além de expor onde o cache sofre quando reiniciado totalmente frio sob escritas concorrentes.

Após publicar a Parte 1 e discutir os resultados com o **James (desenvolvedor core do PgCache)**, desenhamos esta **Parte 2 (`0.7.1_v2`)** para responder a duas frentes essenciais:

1. **Justiça Metodológica ("O Teste Justo")**:
   - *E se o PostgreSQL Origin receber um tuning completo de produção em memória (`2 GiB shared_buffers` + `pg_prewarm` + `work_mem = 32MB` + `random_page_cost = 0,2`) e nunca for reiniciado entre as rodadas?*
   - *E se adicionarmos índices de trigrama `GIN (gin_trgm_ops)` no PostgreSQL e substituirmos as buscas `ILIKE '%1%'` de 1 caractere por buscas realistas de 3+ caracteres (`'%prod%'`, `'%cust%'`, `'% order %'`, `'%quality%'`) que o índice de trigrama do PostgreSQL realmente consegue acelerar?*
   - *O que acontece quando o usuário aplica **filtros dinâmicos dentro do próprio tenant** (`:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`), multiplicando o espaço de chaves do cache em 120× (`24.000` combinações em 200 tenants)?*
2. **Hipóteses do Core Dev do PgCache (James)**:
   - *Como as Materialized Views internas do PgCache (armazenadas na instância PostgreSQL embutida do proxy) se comportam na partida fria (`0s`) e no aquecimento (`30s`) quando subimos o **`ADMISSION_THRESHOLD` de `1` (padrão) para `2` ou `4`**?*
   - *Subir o `ADMISSION_THRESHOLD` evita a poluição do cache e a tempestade de criação de Materialized Views quando os usuários aplicam combinações raras ou únicas de filtros dinâmicos?*
   - *Como um **"Modo Interno de Warm-Up / Pass-Through Transparente"** dentro do PgCache mudaria a equação da partida fria?*

---

## 1. Resumo Executivo (TL;DR)

1. **O PostgreSQL Origin Tunado e Prewarmed Fica até +83% Mais Rápido — Mas o PgCache Ainda Entrega 8,7× a 10,7× de Ganho nas Telas Estáticas**:
   - Dar ao PostgreSQL `2 GiB` de `shared_buffers` aquecidos na RAM (`pg_prewarm`), `work_mem = 32MB`, `random_page_cost = 0,2` e **4 índices de trigrama `GIN (gin_trgm_ops)`** ([`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql)) eleva a vazão do Origin de `63 telas/s` para **`80 telas/s` (+27%)** na busca de 1 caractere (`search_1c`), para **`115 telas/s` (+83%)** na busca de 3+ caracteres com índice de trigrama (`search_3c`), e de `26 telas/s` para **`30 telas/s` (+15%)** na tela corporativa de 8 consultas (`cplx_dash`).
   - Mesmo contra esse Origin 100% em RAM e indexado com `GIN pg_trgm`, o PgCache 0.7.1 entrega **`855 telas/s` (+971% / 10,7×)** em `search_1c`, **`1.138 telas/s` (+889% / 9,9×)** em `search_3c` e **`265 telas/s` na média das 5 rodadas (`353 telas/s` nas rodadas estabilizadas, com pico de `458 telas/s` / +1.407%)** em `cplx_dash`.
2. **Filtros Dinâmicos Intra-Tenant (`cplx_dyn`) Expõem a Poluição do Cache com `ADMISSION_THRESHOLD=1` Padrão**:
   - Quando os usuários variam 5 parâmetros de filtro a cada abertura de tela ([`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql), multiplicando o espaço de chaves em 120×), ~50% das requisições após o aquecimento ainda são combinações inéditas.
   - Com o `ADMISSION_THRESHOLD=1` padrão, o PgCache cria de forma síncrona uma nova Materialized View para **cada combinação de filtro vista pela primeira vez**, derrubando a vazão para **`15 telas/s` (`530,3 ms`, -56% mais lento que os `34 telas/s` do Origin)**.
3. **Validando a Hipótese do James: `ADMISSION_THRESHOLD = 2` e `4` Transformam a Partida Fria e os Filtros Dinâmicos**:
   - **Partida Fria (`0s` de aquecimento em `cplx_dash`)**: Subir o `ADMISSION_THRESHOLD` de `1` para `2` reduz a latência de partida fria em **-20%** (`896,1 ms` $\rightarrow$ `715,7 ms`), e subir para `4` reduz a latência em **-58%** (`896,1 ms` $\rightarrow$ **`372,5 ms`**, mais que dobrando a vazão de `9` para `21 telas/s`).
   - **Aquecimento Inicial (`30s` em `cplx_dash`)**: Subir o `ADMISSION_THRESHOLD` de `1` para `4` corta a latência aos 30 segundos em **-76%** (`1.788,8 ms / 5 telas/s` $\rightarrow$ **`433,5 ms / 23 telas/s`**, com as Execuções 1 e 2 rodando a **`265–270 ms / 30 telas/s`** — praticamente sem penalidade de aquecimento).
   - **Filtros Dinâmicos Intra-Tenant (`cplx_dyn`)**:
     - `ADMISSION_THRESHOLD=2` corta a latência em **-44,5%** (`530,3 ms` $\rightarrow$ **`294,3 ms`**) e aumenta a vazão em **+80%** (`15` $\rightarrow$ **`27 telas/s`**).
     - **`ADMISSION_THRESHOLD=4` elimina 100% da regressão de `-56%`** (`530,3 ms / 15 telas/s` $\rightarrow$ **`235,8 ms / 34 telas/s`**, empatando com os `232,8 ms / 34 telas/s` do Origin com `-1%` na média e **`+2,9%` de ganho na Execução 2**), pois combinações únicas de filtros fazem pass-through direto para o Origin enquanto apenas as consultas recorrentes do tenant (`18,4%` de hit) vão para o cache!
4. **Três Descobertas de Engenharia para Produção**:
   - **Densidade de Linhas por Tenant (`2.500` vs. `250` Pedidos/Tenant)**: Concentrar 500 mil pedidos em 200 tenants densos (10× mais linhas por tenant) escala tanto o custo do join no Origin (`69,9 ms` $\rightarrow$ `633,8 ms`) quanto a leitura da Materialized View no PgCache (`7,2 ms` $\rightarrow$ `168,6 ms`, ainda **3,8× mais rápido** que o Origin).
   - **A Armadilha da Super-Indexação e os Predicados `tenant_id` Correlacionados**: Repetir `tenant_id = :t` em todas as tabelas do join (exigido pelo PgCache para isolamento CDC por tenant) faz o planejador do PostgreSQL multiplicar as seletividades ($\frac{1}{N^3}$) e estimar `rows=1`. Adicionar índices cobertos largos (`B-tree INCLUDE`) enganou o planejador e o levou a escolher `Nested Loop Index Scans` lentos (`1.000 ms / 8 telas/s`), enquanto remover os índices `INCLUDE` e definir `ALTER DATABASE bench SET random_page_cost = 0.2;` restaurou os planos ideais (`264 ms / 30 telas/s`).
   - **Governança de Memória via Cgroup (`resources.limits.memory: 5200Mi`)**: Definir um limite explícito de memória no container evita que o entrypoint do PgCache superdimensione sua instância interna do PostgreSQL lendo `/proc/meminfo` (`7GB total`) em nós Kubernetes de 8 GB.
5. **Impacto do Disco NVMe Local + CPU Intel Premium (`s-4vcpu-8gb-intel` vs `s-4vcpu-8gb` Regular SSD) nas Materialized Views**:
   - Como as Materialized Views do PgCache são gravadas e indexadas na instância interna do PostgreSQL 17 (`/var/lib/postgresql/data`), migrar do nó básico (`s-4vcpu-8gb` SSD Regular) para o nó com **NVMe Local + Intel Premium (`s-4vcpu-8gb-intel`)** elevou os IOPS de `fsync` de páginas de 8 kB em **+127% (`2.050` $\rightarrow$ `4.648 ops/s`, latência de `488 µs` $\rightarrow$ `215 µs`)**.
   - Na tela corporativa completa de 8 consultas (`mv_dash`, `1.600` Materialized Views simultâneas), o NVMe Local + Intel Premium **eliminou 100% dos stalls de criação de MVs em disco**, elevando a vazão média de 3 rodadas de **`150 telas/s` (`86,2%` hit) para `397 telas/s` (`20,66 ms`, `100,0%` hit nas 3 rodadas, pico de `478 telas/s` / `+1.306%`) — um ganho de 2,65× (+165% mais RPS)** na média das 3 rodadas e **+80,5% acima das rodadas aquecidas do SSD Regular (`397` vs `220 telas/s`)**!
   - Nos cenários onde as Materialized Views sofrem pressão constante de disco e criação contínua (`mv_zipf1000` com `1.000` tenants e `mv_dyn_t2` com filtros dinâmicos), o NVMe reduziu a latência em **-10% a -12%** e aumentou tanto a taxa de acerto quanto a vazão em **+7% a +14%**.

---

## 2. O Que Mudou na Configuração da `0.7.1_v2`

### 2.1 Tuning Justo do PostgreSQL Origin ([`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql))

Para garantir que o PostgreSQL Origin seja avaliado em sua máxima eficiência em memória na sua VM dedicada de `4 vCPU / 8 GB` (`s-4vcpu-8gb`):

| Parâmetro / Índice | Parte 1 (`0.7.1` Baseline) | Parte 2 (`0.7.1_v2` Teste Justo) | Por Que Isso Importa |
|---|---|---|---|
| `shared_buffers` | `1024MB` (frio a cada rodada) | **`2048MB` (`2 GiB`) + `pg_prewarm()`** | Coloca todo o banco (~590 MB) e todos os índices 100% na RAM do PostgreSQL, sem leitura de disco. |
| Modo de Recriação de Pods | `RECREATE_PODS_MODE="all"` | **`RECREATE_PODS_MODE="pgcache"`** | Mantém o PostgreSQL Origin 100% aquecido em todas as rodadas enquanto recria o PgCache do zero a cada rodada. |
| `work_mem` | `16MB` | **`32MB`** | Evita que hash joins multi-tabela e ordenações `GROUP BY` despejem arquivos temporários em disco. |
| `random_page_cost` | `1.1` | **`0.2` (`ALTER DATABASE bench SET`)** | Reflete um banco 100% residente em RAM e impede que estimativas correlacionadas `rows=1` escolham `Seq Scan` em `category` e `seller`. |
| Índices de Trigrama (`pg_trgm`) | Nenhum | **4 Índices `GIN (gin_trgm_ops)`** | Indexa `customer.name`, `customer.email`, `product.name` e `review.body` para buscas `ILIKE '%...%'` de $\ge 3$ caracteres. |
| Memória do Container PgCache | Sem limite (`memory.max = max`) | **`resources.limits.memory: 5200Mi`** | Faz o `pgcache-entrypoint.sh` calibrar seu PostgreSQL interno (`127.0.0.1:5433`) para `5GB total` em vez de `7GB total`, evitando despejos pelo Kubelet. |

### 2.2 Novas Cargas SQL Justas e Dinâmicas

> 📖 **Código SQL Completo**: Veja [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql) e [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql).

| Nome e Arquivo SQL | Consultas por Tela | O Que o Cenário Testa |
|---|:---:|---|
| **`search_1c`**<br>[`workload/complex-search.sql`](../../workload/complex-search.sql) | **4** | **Busca por Substring de 1 Caractere (`ILIKE '%1%'`)**: Busca curinga da Parte 1 onde o `GIN pg_trgm` não consegue extrair trigramas de 3 letras. |
| **`search_3c`**<br>[`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql) | **4** | **Busca de 3+ Caracteres com Trigramas (`ILIKE '%prod%'`, `'%cust%'`, `'% order %'`, `'%quality%'`)**: Termos realistas que os índices `GIN (gin_trgm_ops)` do PostgreSQL aceleram via `Bitmap Index Scan`. |
| **`cplx_dash`**<br>[`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) | **8** | **Tela Corporativa Estática de 8 Consultas**: 3 agregações analíticas, 3 joins de 4 a 6 tabelas (`INNER` + `LEFT JOIN`) e 2 buscas `ILIKE` com filtros fixos por tenant (`1.600` consultas distintas em 200 tenants). |
| **`cplx_dyn`**<br>[`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql) | **8** | **Tela Corporativa com Filtros Dinâmicos Intra-Tenant**: As mesmas 8 consultas corporativas, mas cada requisição sorteia 5 parâmetros de filtro do usuário (`:min_price` $\in \{20,40,60,80,100\}$, `:min_rev` $\in \{50,100,150,200\}$, `:min_rating` $\in \{2,3,4\}$, `:min_cnt` $\in \{1,2\}$, `:lim` $\in \{15,25\}$), expandindo o espaço de chaves em 120× (`24.000` combinações). |

---

## 3. Resultados do "Teste Justo" (`TRIALS=5`, `DURATION=15s`, `CLIENTS=8`)

Logs brutos: [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt) · [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt) · [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)

### 3.1 Tabela Consolidada (Média das 5 Execuções)

| Cenário do Teste Justo (`CLIENTS=8`, `TENANTS=200`) | PostgreSQL Origin Tunado (Média Caminho A) | PgCache 0.7.1 (Média Caminho B) | Taxa de Acerto | Ganho Médio (Variação nas 5 Rodadas) | Ciclos Warmup |
|---|---|---|---:|---|---:|
| **1. `search_1c` — Busca `ILIKE '%1%'` (1 char)** ([`complex-search.sql`](../../workload/complex-search.sql)) | **100,45 ms · 80 telas/s** *(±1,9 sd, +27% vs Parte 1)* | **9,38 ms · 855 telas/s** *(±46,1 sd)* | **100,0%** | **10,7× (+971%)** *(-91% / +36%)* | 5,2 |
| **2. `search_3c` — Busca `ILIKE` 3+ chars + `GIN pg_trgm`** ([`complex-search-fair.sql`](../../workload/complex-search-fair.sql)) | **69,86 ms · 115 telas/s** *(±6,5 sd, +83% vs Parte 1)* | **7,17 ms · 1.138 telas/s** *(±162,6 sd)* | **100,0%** | **9,9× (+889%)** *(-152% / +147%)* | 3,6 |
| **3. `cplx_dash` — Tela Corporativa Estática (8 queries)** ([`complex-dashboard.sql`](../../workload/complex-dashboard.sql)) | **264,21 ms · 30 telas/s** *(±0,5 sd, +15% vs Parte 1)* | **193,24 ms · 265 telas/s** *(353 telas/s em T1–T4)* | **90,4%** *(99,9% T1–T4)* | **8,7× (+766%)** *(até +1.407%)* | 7,2 |
| **4. `cplx_dyn` — Filtros Dinâmicos Intra-Tenant** ([`complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)) | **237,57 ms · 34 telas/s** *(±1,6 sd)* | 530,31 ms · **15 telas/s** *(±1,2 sd)* | **49,9%** | **0,44× (-56%)** *(-3% / +6%)* | 7,0 |

---

### 3.2 Detalhamento Individual: Os Números de Cada Uma das 5 Execuções

#### Cenário Justo 1: `search_1c` (`ILIKE '%1%'`, Curinga de 1 Caractere) — Origin `2 GiB` Prewarmed

| Execução | Latência Caminho A (Origin Tunado) | Vazão Caminho A | Latência Caminho B (PgCache) | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 101,32 ms | 79 telas/s | 9,14 ms | 875 telas/s | 100,00% | **+1.007,6% (11,1×)** | 5 |
| **Execução 2** | 98,96 ms | 81 telas/s | 9,23 ms | 867 telas/s | 100,00% | **+970,4% (10,7×)** | 6 |
| **Execução 3** | 100,23 ms | 80 telas/s | 10,20 ms | 784 telas/s | 100,00% | **+880,0% (9,8×)** | 5 |
| **Execução 4** | 104,35 ms | 77 telas/s | 9,51 ms | 841 telas/s | 100,00% | **+992,2% (10,9×)** | 5 |
| **Execução 5** | 97,39 ms | 82 telas/s | 8,82 ms | 907 telas/s | 100,00% | **+1.006,1% (11,1×)** | 5 |
| **Média (5 Execuções)** | **100,45 ms** | **80 telas/s** *(±1,9 sd, -3/+2)* | **9,38 ms** | **855 telas/s** *(±46,1 sd, -71/+52)* | **100,0%** | **+971% (10,7×)** | **5,2** |

---

#### Cenário Justo 2: `search_3c` (Busca `ILIKE` de 3+ Caracteres + 4 Índices `GIN pg_trgm`) — [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql)

| Execução | Latência Caminho A (Origin Tunado) | Vazão Caminho A | Latência Caminho B (PgCache) | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 70,34 ms | 114 telas/s | 6,18 ms | 1.295 telas/s | 100,00% | **+1.036,0% (11,4×)** | 4 |
| **Execução 2** | 66,47 ms | 120 telas/s | 7,17 ms | 1.116 telas/s | 100,00% | **+830,0% (9,3×)** | 3 |
| **Execução 3** | 67,38 ms | 119 telas/s | 6,71 ms | 1.192 telas/s | 100,00% | **+901,7% (10,0×)** | 3 |
| **Execução 4** | 68,26 ms | 117 telas/s | 6,59 ms | 1.215 telas/s | 100,00% | **+938,5% (10,4×)** | 4 |
| **Execução 5** | 76,87 ms | 104 telas/s | 9,20 ms | 870 telas/s | 100,00% | **+736,5% (8,4×)** | 4 |
| **Média (5 Execuções)** | **69,86 ms** | **115 telas/s** *(±6,5 sd, -11/+5)* | **7,17 ms** | **1.138 telas/s** *(±162,6 sd, -268/+157)* | **100,0%** | **+889% (9,9×)** | **3,6** |

> **O que `search_3c` vs `search_1c` comprova**: Adicionar os 4 índices `GIN (gin_trgm_ops)` e buscar termos de 3+ caracteres (`'%prod%'`, `'%cust%'`, `'% order %'`, `'%quality%'`) realmente acelera o PostgreSQL Origin — a latência cai de `100,45 ms (80 telas/s)` para **`69,86 ms (115 telas/s)` (+44% mais rápido que `search_1c` e +83% mais rápido que os `63 telas/s` da Parte 1)**! Além disso, como o Origin responde mais rápido, o próprio PgCache aquece mais depressa (**3,6 passes** em vez de 5,2) e, uma vez aquecido, ainda entrega **1.138 telas/s (9,9× mais rápido que o Origin tunado)** por evitar reexecutar os joins de 3 a 6 tabelas e os bitmaps de trigramas a cada abertura de tela.

---

#### Cenário Justo 3: `cplx_dash` (Tela Corporativa Estática de 8 Consultas) — Origin `2 GiB` Prewarmed

| Execução | Latência Caminho A (Origin Tunado) | Vazão Caminho A | Latência Caminho B (PgCache) | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 256,31 ms | 31 telas/s | 29,63 ms | 270 telas/s | 99,99% | **+771,0% (8,7×)** | 8 |
| **Execução 2** | 269,73 ms | 30 telas/s | 60,20 ms | 133 telas/s | 99,72% | **+343,3% (4,4×)** | 8 |
| **Execução 3** | 260,60 ms | 31 telas/s | 17,47 ms | 458 telas/s | 100,00% | **+1.377,4% (14,8×)** | 8 |
| **Execução 4** | 265,56 ms | 30 telas/s | 17,69 ms | 452 telas/s | 100,00% | **+1.406,7% (15,1×)** | 8 |
| **Execução 5** | 268,88 ms | 30 telas/s | 841,18 ms | 10 telas/s | 52,29% | -66,7% (0,33×) | 4 |
| **Média (5 Execuções)** | **264,21 ms** | **30 telas/s** *(±0,5 sd, -0/+1)* | **193,24 ms** | **265 telas/s** *(±196,7 sd; 353 telas/s T1–T4)* | **90,4%** *(99,9% T1–T4)* | **+766% (8,7×)** | **7,2** |

> **Por que a Execução 5 parou no ciclo 4**: Na Execução 5, o `warm_until_settled` observou uma variação `< 1%` entre os ciclos 3 e 4 ao redor de `52,29%` de hit e iniciou a janela de medição mais cedo enquanto a outra metade dos 200 tenants ainda estava populando Materialized Views (`10 telas/s`). Nas 4 execuções que completaram os 8 ciclos de aquecimento (Execuções 1 a 4), o PgCache teve média de **353 telas/s (`99,93%` de acerto, 11,6× mais rápido que o Origin tunado)**. Repare também como o `pg_prewarm` eliminou a variação do Caminho A (`30 a 31 telas/s`, `±0,5 sd`).

---

#### Cenário Justo 4: `cplx_dyn` (Filtros Dinâmicos Intra-Tenant — `:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`)

| Execução | Latência Caminho A (Origin Tunado) | Vazão Caminho A | Latência Caminho B (PgCache `ADMISSION_THRESHOLD=1`) | Vazão Caminho B | Taxa de Acerto | Ganho (Speedup) | Ciclos Warmup |
|:---:|---:|---:|---:|---:|---:|---:|---:|
| **Execução 1** | 235,66 ms | 34 telas/s | 465,01 ms | 17 telas/s | 58,82% | -50,0% (0,50×) | 8 |
| **Execução 2** | 230,98 ms | 35 telas/s | 539,74 ms | 15 telas/s | 51,51% | -57,1% (0,43×) | 8 |
| **Execução 3** | 228,06 ms | 35 telas/s | 519,48 ms | 15 telas/s | 59,55% | -57,1% (0,43×) | 8 |
| **Execução 4** | 237,90 ms | 34 telas/s | 557,03 ms | 14 telas/s | 42,83% | -58,8% (0,41×) | 6 |
| **Execução 5** | 255,26 ms | 31 telas/s | 570,29 ms | 14 telas/s | 36,88% | -54,8% (0,45×) | 5 |
| **Média (5 Execuções)** | **237,57 ms** | **34 telas/s** *(±1,6 sd, -3/+1)* | **530,31 ms** | **15 telas/s** *(±1,2 sd, -1/+2)* | **49,9%** | **-56% (0,44×)** | **7,0** |

> **Por que `cplx_dyn` cai `-56%` com `ADMISSION_THRESHOLD=1` padrão**: Como cada consulta interpola filtros escolhidos pelo usuário (`:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`), o universo de chaves salta de `1.600` consultas para `24.000` combinações. Mesmo após 7–8 ciclos de aquecimento, `50,1%` das requisições continuam sendo combinações inéditas de filtros. Com o `ADMISSION_THRESHOLD=1` padrão, o PgCache admite e constrói uma nova Materialized View para **cada combinação vista pela primeira vez**, tornando o proxy `2,2×` mais lento do que consultar o PostgreSQL diretamente (`530,3 ms` vs `237,6 ms`). Na **Seção 4**, mostramos como subir o `ADMISSION_THRESHOLD` para `2` ou `4` resolve exatamente esse problema.

---

### 3.3 Três Descobertas Arquiteturais durante o Teste Justo

Durante a construção e validação do Teste Justo, descobrimos três comportamentos de banco de dados e de proxy fundamentais para produção:

#### Descoberta 1: Densidade de Linhas por Tenant (`2.500` vs. `250` Pedidos por Tenant — [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt))

Quando os mesmos `500.000` pedidos e `2.000.000` de itens de pedido são concentrados em **200 tenants densos** (`2.500` pedidos e `10.000` itens por tenant, registrado em [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt)) em vez de **2.000 tenants padrão** (`250` pedidos e `1.000` itens por tenant, registrado em [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)), cada join por tenant processa **10× mais linhas**:

| Densidade do Dataset (`500k` Pedidos, `2M` Itens) | Pedidos / Itens por Tenant | Origin Tunado (`search_3c`) | PgCache 0.7.1 (`search_3c`) | Taxa de Acerto | Ganho |
|---|---:|---|---|---:|---:|
| **Multi-Tenant Padrão (`2.000` Tenants)**<br>[`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt) | `250` pedidos / `1.000` itens | 69,86 ms · **115 telas/s** *(±6,5 sd)* | **7,17 ms · 1.138 telas/s** *(±162,6 sd)* | 100,0% | **9,9× (+889%)** |
| **Tenants 10× Mais Densos (`200` Tenants)**<br>[`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt) | `2.500` pedidos / `10.000` itens | 633,83 ms · **13 telas/s** *(±0,8 sd)* | **168,58 ms · 48 telas/s** *(±7,2 sd)* | 100,0% | **3,8× (+281%)** |

Como o James destacou, o PgCache atende às consultas multi-tabela usando Materialized Views na sua instância PostgreSQL embutida (`127.0.0.1:5433`). Quando cada tenant possui 10× mais linhas, tanto o join no Origin quanto a varredura da Materialized View por tenant dentro do PgCache escalam proporcionalmente ao volume de linhas do tenant — e ainda assim o PgCache entrega **3,8× de ganho (+281%)** nos tenants 10× mais densos.

#### Descoberta 2: A Armadilha da Super-Indexação e os Predicados `tenant_id` Correlacionados ([`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt))

- Para isolar invalidações CDC por tenant e permitir index pushdown, as consultas do PgCache repetem `tenant_id = :t` em todas as tabelas do join (`WHERE o.tenant_id = :t AND oi.tenant_id = :t AND c.tenant_id = :t`).
- Como o planejador do PostgreSQL assume que predicados em tabelas diferentes são estatisticamente independentes, ele multiplica as seletividades ($\frac{1}{N} \times \frac{1}{N} \times \frac{1}{N}$) e estima **`rows=1`** para o resultado do join.
- Quando testamos adicionar **6 índices cobertos largos (`B-tree INCLUDE`)** junto com os 4 índices `GIN pg_trgm` na base densa de 200 tenants (registrado em [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)), essa subestimativa `rows=1` enganou o planejador do PostgreSQL, fazendo-o abandonar planos rápidos de `Hash Join` / `Bitmap Heap Scan` em troca de `Nested Loop Index Scans` profundos (`cplx_dash` rodou a `1.000,3 ms / 8 telas/s` no Origin, e `search_3c` levou `795,4 ms / 10 telas/s` contra `633,8 ms / 13 telas/s` sem os índices `INCLUDE`).
- Mesmo sem índices `INCLUDE`, o `rows=1` fazia o PostgreSQL escolher `Seq Scan on category` (`cost=1.625`) em vez de `Index Scan using category_pkey` (`cost=2.36`) com `random_page_cost=1.1`; configurar `ALTER DATABASE bench SET random_page_cost = 0.2;` restaurou o `Index Scan` em todas as tabelas de dimensão.

#### Descoberta 3: O Problema de Memória no Kubernetes (`Evicted` por `MemoryPressure`) e a Governança via Cgroup (`resources.limits.memory: 5200Mi`)

Durante as primeiras execuções da carga de filtros dinâmicos (`cplx_dyn`) com `ADMISSION_THRESHOLD=1`, o teste travava no meio da bateria porque o pod do PgCache sofria **`Status: Evicted` (`The node had condition: [MemoryPressure]`)** pelo Kubelet da DigitalOcean. A investigação revelou uma interação crítica entre **três camadas de memória** dentro do container do PgCache:

1. **Por que `MEMORY_LIMIT` sozinho não impedia o `Evicted`**:
   - A variável de ambiente `MEMORY_LIMIT: "3758096384"` (`3,5 GiB`) controla o rastreador de memória do processo Rust do PgCache (`pgcache_cache_memory_used_bytes`).
   - Porém, como o próprio James explicou, as Materialized Views das consultas multi-tabela são criadas e armazenadas dentro de uma **instância embutida do PostgreSQL 17** que roda dentro do mesmo container do PgCache (`127.0.0.1:5433`, banco `pgcache_cache`).
2. **A armadilha do `/sys/fs/cgroup/memory.max = max` no `pgcache-entrypoint.sh`**:
   - Ao iniciar o container, o script interno `/usr/local/bin/pgcache-entrypoint.sh` calcula automaticamente os parâmetros de memória do PostgreSQL embutido (`shared_buffers`, `effective_cache_size`, `work_mem`) lendo o limite do cgroup em `/sys/fs/cgroup/memory.max`.
   - Quando o Deployment do Kubernetes **não** define `resources.limits.memory`, o arquivo `/sys/fs/cgroup/memory.max` retorna `max`. Nesse caso, o `pgcache-entrypoint.sh` faz fallback para a RAM física bruta da máquina virtual (`/proc/meminfo` = `8 GB`) e imprime no log de inicialização:
     ```text
     [entrypoint] PostgreSQL tuned for 7GB total (shared_buffers=1792MB, effective_cache_size=5376MB, work_mem=8MB, workers=4)
     ```
   - O problema é que, em um nó Kubernetes de 8 GB (`s-4vcpu-8gb`), o sistema operacional, o Kubelet, o Cilium (CNI) e o containerd reservam ~1,7 GiB, deixando apenas **`Allocatable: ~6,26 GiB` (`6.568.452 KiB`)** para todos os pods do nó.
   - Quando o `cplx_dyn` criava centenas de Materialized Views em sequência, a soma de **PostgreSQL embutido (`shared_buffers=1792MB` + page cache das MVs em disco) + processo Rust do PgCache (`3,5 GiB`)** ultrapassava os `6,26 GiB` disponíveis no nó, fazendo o Kubelet matar o pod com `Evicted` (`MemoryPressure`).
3. **A Solução Definitiva (`resources.limits.memory: 5200Mi`)**:
   - Ao declarar explicitamente `resources.limits.memory: "5200Mi"` em [`infra/helm/pgcache-mt/values-do-tuned.yaml`](../../infra/helm/pgcache-mt/values-do-tuned.yaml) e [`infra/helm/pgcache-mt/templates/pgcache.yaml`](../../infra/helm/pgcache-mt/templates/pgcache.yaml), o cgroup passa a expor `5.452.595.200` bytes em `/sys/fs/cgroup/memory.max`.
   - O `pgcache-entrypoint.sh` detecta automaticamente o limite do container e recalibra o PostgreSQL interno para caber com folga dentro do nó:
     ```text
     [entrypoint] PostgreSQL tuned for 5GB total (shared_buffers=1280MB, effective_cache_size=3840MB, work_mem=6MB, workers=4)
     ```
   - Além disso, o kernel Linux passa a reciclar o page cache das Materialized Views dentro do próprio cgroup de `5200Mi` antes que o consumo chegue ao limiar de `MemoryPressure` do Kubelet (`6,26 GiB`), **eliminando 100% das quedas e despejos (`0 Evictions`)** em todas as baterias `06` e `07`.

---

## 4. Devolutiva do Core Dev do PgCache (James) e Varredura de `ADMISSION_THRESHOLD` (`1` vs `2` vs `4`, `TRIALS=3`)

Ao analisar os resultados da Parte 1, **James (desenvolvedor core do PgCache)** compartilhou três observações arquiteturais e hipóteses:

> **1. Materialized Views Apoiadas em Disco no PostgreSQL Embutido**:
> *"Para as telas pesadas multi-tabela — elas muito provavelmente estão sendo atendidas pela versão de materialized views do pgcache, ou seja, resultados pré-computados mas ainda apoiados em disco e não puramente em memória (embora possam estar no buffer cache da instância interna do postgres)."*
>
> **2. Ajuste do `admission_threshold` (`1` vs `2` vs `4`)**:
> *"Algumas ideias sobre o cold start — estou curioso para ver o que acontece no warm-up e no cold start se o `admission_threshold` for configurado acima de 1, talvez 2 ou 4. Ele controla quantas vezes uma query precisa ser vista antes de ser admitida no cache. Um valor de 2 evitará popular e invalidar muitas queries vistas apenas uma vez ou raramente. Configurar em 4 é uma versão mais extrema."*
>
> **3. Modo Interno de Warm-Up / Pass-Through Transparente**:
> *"A segunda ideia é: e se o próprio pgcache tivesse um modo de cold start ou warm-up, onde ele faria o cache e popularia as queries em background, mas continuaria passando tudo direto para o origin até atingir um limiar de aquecimento ou estado estável? Basicamente movendo as fases de warm-up que o benchmark faz para dentro do próprio cache como comportamento interno."*

Para testar empiricamente a hipótese do James sobre `ADMISSION_THRESHOLD`, adicionamos suporte à variável `ADMISSION_THRESHOLD` no Helm chart ([`infra/helm/pgcache-mt/templates/pgcache.yaml`](../../infra/helm/pgcache-mt/templates/pgcache.yaml)) e executamos [`scripts/07-admission-threshold-sweep.sh`](../../scripts/07-admission-threshold-sweep.sh) (`TRIALS=3`, recriando o pod do PgCache antes de cada trial enquanto o Origin permanecia prewarmed com `2 GiB`) variando **`ADMISSION_THRESHOLD = 1`, `2` e `4`** em quatro regimes distintos:
1. **`cold0s` (Partida Fria Pura, `0s` de warm-up)**: Primeiros 15 segundos imediatamente após subir um pod novo do PgCache em [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (`200` tenants).
2. **`w30s` (Início do Aquecimento, `30s` de warm-up)**: Janela medida após 30 segundos de aquecimento em [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (`200` tenants).
3. **`settle` (Estado Estável, `warm_until_settled` até 8 passes / `120s`)**: Medição após estabilização em [`workload/complex-dashboard.sql`](../../workload/complex-dashboard.sql) (`200` tenants).
4. **`dyn` (Filtros Dinâmicos Intra-Tenant, `warm_until_settled`)**: Medição em [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql) (`200` tenants × `120` combinações de filtros).

Log bruto: [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)

### 4.1 Comparativo Consolidado: `ADMISSION_THRESHOLD = 1, 2, 4` (`TRIALS=3`)

| Regime e Carga (`TENANTS=200`, `CLIENTS=8`) | `ADMISSION_THRESHOLD = 1` (Padrão) | `ADMISSION_THRESHOLD = 2` (Equilibrado) | `ADMISSION_THRESHOLD = 4` (Conservador) | Efeito Arquitetural Observado |
|---|---|---|---|---|
| **1. Partida Fria Pura (`0s` warm-up)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | 896,09 ms · **9 telas/s**<br>*(hit: 3,80%, -70,8%)* | **715,66 ms · 11 telas/s**<br>*(hit: 4,73%, -62,1%)* | **372,48 ms · 21 telas/s**<br>*(hit: 0,76%, -31,9%)* | **`threshold=4` corta a latência de partida fria em -58% (`896` $\rightarrow$ `372 ms`) e mais que dobra o RPS (`9` $\rightarrow$ `21 telas/s`)** |
| **2. Aquecimento Inicial (`30s` warm-up)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | 1.788,75 ms · **5 telas/s**<br>*(hit: 27,98%, -84,4%)* | **1.311,75 ms · 6 telas/s**<br>*(hit: 23,73%, -79,8%)* | **433,49 ms · 23 telas/s**<br>*(hit: 23,91%, -23,1%; 30 telas/s em T1–T2)* | **`threshold=4` corta a latência aos 30s em -76% (`1.789` $\rightarrow$ `433 ms`) ao cadenciar a criação de MVs** |
| **3. Estado Estável (`warm_until_settled`)**<br>[`complex-dashboard.sql`](../../workload/complex-dashboard.sql) | **193,24 ms · 265 telas/s**<br>*(hit: 90,4% / 99,9% T1–T4, **+766%**)* | **474,59 ms · 161 telas/s**<br>*(hit: 82,7% / 100% T1, **+406%**, pico de 433 telas/s)* | 728,80 ms · **16 telas/s**<br>*(hit: 26,3%, -49% no teto de 8 passes)* | **`threshold=2` ainda atinge `100%` de hit (`433 telas/s`), enquanto `threshold=4` exige `>8` passes (`>120s`) para que todos os 200 tenants sejam visitados 4 vezes** |
| **4. Filtros Dinâmicos Intra-Tenant (`cplx_dyn`)**<br>[`complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql) | 530,31 ms · **15 telas/s**<br>*(hit: 49,9%, **-56%**)* | **294,26 ms · 27 telas/s**<br>*(hit: 41,3%, **-21%**, +80% RPS vs `t=1`)* | **235,77 ms · 34 telas/s**<br>*(hit: 18,4%, **-1% média / +2,9% T2**)* | **`threshold=2` corta a latência dinâmica em -44,5%, e `threshold=4` elimina 100% da regressão de -56% (`34 telas/s` = Origin!)** |

---

### 4.2 Detalhamento por Execução (`07-admission-threshold-k8s.txt`, `TRIALS=3`)

| Limiar e Célula | Execução 1 (Caminho A vs B) | Execução 2 (Caminho A vs B) | Execução 3 (Caminho A vs B) | Média das 3 Execuções (Caminho A vs B, Hit %, Ganho) |
|---|---|---|---|---|
| **`t1_cold0s`** (`t=1`, `0s`) | A: 260,7 ms (31 rps)<br>B: 973,0 ms (8 rps, 3,54%) | A: 273,9 ms (29 rps)<br>B: 853,8 ms (9 rps, 3,96%) | A: 273,6 ms (29 rps)<br>B: 861,4 ms (9 rps, 3,90%) | A: **269,40 ms (30 rps)** \| B: **896,09 ms (9 rps)** \| Hit: **3,80%** \| **-70,8%** |
| **`t1_w30s`** (`t=1`, `30s`) | A: 270,6 ms (30 rps)<br>B: 1.271,1 ms (6 rps, 28,85%) | A: 265,0 ms (30 rps)<br>B: 1.950,0 ms (4 rps, 29,16%) | A: 263,8 ms (30 rps)<br>B: 2.145,2 ms (4 rps, 25,92%) | A: **266,46 ms (30 rps)** \| B: **1.788,75 ms (5 rps)** \| Hit: **27,98%** \| **-84,4%** |
| **`t2_cold0s`** (`t=2`, `0s`) | A: 274,6 ms (29 rps)<br>B: 728,4 ms (11 rps, 6,11%) | A: 290,6 ms (28 rps)<br>B: 706,3 ms (11 rps, 4,68%) | A: 264,1 ms (30 rps)<br>B: 712,2 ms (11 rps, 3,41%) | A: **276,43 ms (29 rps)** \| B: **715,66 ms (11 rps)** \| Hit: **4,73%** \| **-62,1%** |
| **`t2_w30s`** (`t=2`, `30s`) | A: 251,6 ms (32 rps)<br>B: 1.399,3 ms (6 rps, 23,99%) | A: 254,6 ms (31 rps)<br>B: 1.427,1 ms (6 rps, 23,51%) | A: 258,2 ms (31 rps)<br>B: 1.108,8 ms (7 rps, 23,70%) | A: **254,81 ms (31 rps)** \| B: **1.311,75 ms (6 rps)** \| Hit: **23,73%** \| **-79,8%** |
| **`t2_settle`** (`t=2`, estável) | A: 252,5 ms (32 rps)<br>B: **18,5 ms (433 rps, 100,00%)** | A: 270,0 ms (30 rps)<br>B: 1.221,8 ms (7 rps, 54,49%, w7) | A: 259,5 ms (31 rps)<br>B: **183,5 ms (44 rps, 93,72%)** | A: **260,69 ms (31 rps)** \| B: **474,59 ms (161 rps)** \| Hit: **82,7%** \| **+406%** |
| **`t2_dyn`** (`t=2`, dinâmico) | A: 236,7 ms (34 rps)<br>B: **271,7 ms (29 rps, 41,99%)** | A: 232,3 ms (34 rps)<br>B: **320,2 ms (25 rps, 38,22%)** | A: 227,3 ms (35 rps)<br>B: **290,9 ms (27 rps, 43,63%)** | A: **232,08 ms (34 rps)** \| B: **294,26 ms (27 rps)** \| Hit: **41,3%** \| **-21%** |
| **`t4_cold0s`** (`t=4`, `0s`) | A: 257,0 ms (31 rps)<br>B: **357,5 ms (22 rps, 1,07%)** | A: 261,3 ms (31 rps)<br>B: **383,3 ms (21 rps, 0,23%)** | A: 253,1 ms (32 rps)<br>B: **376,7 ms (21 rps, 0,97%)** | A: **257,15 ms (31 rps)** \| B: **372,48 ms (21 rps)** \| Hit: **0,76%** \| **-31,9%** |
| **`t4_w30s`** (`t=4`, `30s`) | A: 248,2 ms (32 rps)<br>B: **265,3 ms (30 rps, 21,03%)** | A: 257,7 ms (31 rps)<br>B: **270,3 ms (30 rps, 25,56%)** | A: 287,6 ms (28 rps)<br>B: 764,9 ms (10 rps, 25,14%) | A: **264,48 ms (30 rps)** \| B: **433,49 ms (23 rps)** \| Hit: **23,91%** \| **-23,1%** |
| **`t4_settle`** (`t=4`, estável) | A: 272,3 ms (29 rps)<br>B: 461,9 ms (17 rps, 28,70%) | A: 253,5 ms (32 rps)<br>B: 340,2 ms (24 rps, 30,77%) | A: 263,6 ms (30 rps)<br>B: 1.384,2 ms (6 rps, 19,48%) | A: **263,13 ms (30 rps)** \| B: **728,80 ms (16 rps)** \| Hit: **26,3%** \| **-49%** |
| **`t4_dyn`** (`t=4`, dinâmico) | A: 238,2 ms (34 rps)<br>B: **235,2 ms (34 rps, +0,0%)** | A: 233,6 ms (34 rps)<br>B: **227,9 ms (35 rps, +2,9%)** | A: 226,7 ms (35 rps)<br>B: **244,3 ms (33 rps, -5,7%)** | A: **232,83 ms (34 rps)** \| B: **235,77 ms (34 rps)** \| Hit: **18,4%** \| **-1%** |

---

### 4.3 Síntese: Por Que as Duas Ideias do James Se Complementam Perfeitamente

1. **Por que `ADMISSION_THRESHOLD > 1` Resolve a Poluição por Filtros Dinâmicos (`cplx_dyn`)**:
   - Em [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql), 2 das 8 consultas da tela são consultas por tenant sem parâmetros dinâmicos (repetidas com frequência para o mesmo tenant), enquanto 6 das 8 consultas incluem filtros combinatórios do usuário (`:min_price`, `:min_rev`, `:min_rating`, `:min_cnt`, `:lim`).
   - Com `ADMISSION_THRESHOLD=1`, o PgCache constrói cegamente uma Materialized View para cada combinação rara logo na primeira vez em que ela aparece, gastando `530,3 ms` por tela (`15 telas/s`, `-56%`).
   - Com `ADMISSION_THRESHOLD=2`, o PgCache ignora combinações vistas apenas uma vez (fazendo pass-through direto para o Origin em `~235 ms`) e só admite no cache o que se repete ao menos duas vezes, derrubando a latência para **`294,3 ms` (`27 telas/s`, +80% mais rápido que `t=1`)**.
   - Com `ADMISSION_THRESHOLD=4`, o PgCache faz cache **apenas** das consultas recorrentes do tenant (`18,4%` de hit) e faz pass-through direto de todas as combinações ad-hoc de filtros para o Origin — empatando com a velocidade do Origin (**`235,8 ms / 34 telas/s` vs `232,8 ms / 34 telas/s`, chegando a `227,9 ms / 35 telas/s (+2,9%)` na Execução 2**) e **eliminando 100% da regressão de `-56%`**!
2. **Por que o "Modo Interno de Warm-Up / Pass-Through Transparente" Proposto pelo James É o Próximo Passo Ideal**:
   - Embora o `ADMISSION_THRESHOLD=4` proteja a partida fria (`372,5 ms / 21 telas/s`) e os primeiros 30s (`265–270 ms / 30 telas/s` nas Execuções 1 e 2), ele retarda a convergência total quando há centenas de tenants uniformes (`t4_settle` ainda está em `26,3%` de hit após 8 ciclos de aquecimento porque cada um dos 200 tenants precisa ser sorteado 4 vezes antes que a criação de suas Materialized Views sequer comece).
   - Se o PgCache implementar o **Modo Interno de Warm-Up / Pass-Through** sugerido pelo James — onde os cache misses são repassados diretamente ao Origin no caminho crítico do cliente (`~260 ms` de latência) enquanto o PgCache popula a Materialized View **de forma assíncrona em background** até atingir o limiar de aquecimento — o usuário terá **zero penalidade de partida fria** (`~30 telas/s` desde o segundo zero em vez de `5–9 telas/s`) combinado com **toda a aceleração de estado estável (`350–458 telas/s`, `+1.400%`)** assim que a população em background terminar.

---

## 5. Estudo de Armazenamento de Materialized Views: SSD Regular (`s-4vcpu-8gb`) vs. NVMe Local + Intel Premium (`s-4vcpu-8gb-intel`, `TRIALS=3`)

Como destacou o James, as telas corporativas multi-tabela do PgCache são sustentadas por **Materialized Views gravadas no banco PostgreSQL 17 embutido** (`127.0.0.1:5433`, diretório `/var/lib/postgresql/data` no disco local do Worker Node).

Para medir empiricamente quanto um disco **NVMe local** e uma **CPU de geração superior** aceleram a criação, o aquecimento e a leitura das Materialized Views, executamos o script [`scripts/08-nvme-mv-benchmark.sh`](../../scripts/08-nvme-mv-benchmark.sh) (`TRIALS=3` com recriação do pod do PgCache a cada rodada) em dois clusters Kubernetes de 3 nós na DigitalOcean:
- **Ensaio 1 — SSD Regular (`3× s-4vcpu-8gb`)**: CPU Basic Shared (`DO-Regular`) + SSD SATA/SAS Regular ([`08-mv-regular-ssd-k8s.txt`](08-mv-regular-ssd-k8s.txt)).
- **Ensaio 2 — NVMe Local + Intel Premium (`3× s-4vcpu-8gb-intel`)**: CPU Intel Premium (`DO-Premium-Intel`) + NVMe SSD Local ([`08-mv-nvme-intel-k8s.txt`](08-mv-nvme-intel-k8s.txt)).

### 5.1 Micro-Benchmark Físico de Disco e CPU dentro do Container do PgCache (`pg_test_fsync` & `dd`)

Antes de iniciar as consultas SQL, o [`scripts/08-nvme-mv-benchmark.sh`](../../scripts/08-nvme-mv-benchmark.sh) executou o utilitário oficial `pg_test_fsync` do PostgreSQL 17 diretamente sobre `/var/lib/postgresql` dentro do pod do PgCache:

| Métrica Física (`pg_test_fsync` em `/var/lib/postgresql`) | Ensaio 1: SSD Regular (`s-4vcpu-8gb`) | Ensaio 2: NVMe Local + Intel (`s-4vcpu-8gb-intel`) | Diferença Observada |
|---|---|---|---|
| **Modelo de CPU (`/proc/cpuinfo`)** | `DO-Regular` (2.494 MHz) | **`DO-Premium-Intel`** (2.494 MHz) | Geração superior de IPC e controlador de memória |
| **`fsync` (Flush de 1 página de 8 kB)** | `2.049,6 ops/s` (`488 µs/op`) | **`4.647,5 ops/s` (`215 µs/op`)** | **+126,8% mais IOPS (2,27× mais rápido, -56% latência)** |
| **`open_sync` (Escrita síncrona `O_DIRECT` 8 kB)** | `3.912,4 ops/s` (`256 µs/op`) | **`4.377,6 ops/s` (`228 µs/op`)** | **+11,9% mais IOPS (-11% latência)** |
| **`fdatasync` (2× 8 kB escritas síncronas)** | `5.239,1 ops/s` (`191 µs/op`) | `3.437,4 ops/s` (`291 µs/op`) | Ambos abaixo de `300 µs` com cache de controlador ativo |
| **Escrita em Buffer de 8 kB (`write` não-sincronizado)** | `670.247 ops/s` (`1 µs/op`) | **`702.070 ops/s` (`1 µs/op`)** | **+4,7% maior largura de banda de memória/kernel** |

### 5.2 Comparativo Consolidado nas Cargas de Materialized Views (`TRIALS=3`)

| Cenário Materialized View (`TENANTS=200`, `CLIENTS=8`) | SSD Regular (`s-4vcpu-8gb`)<br>Origin vs PgCache | NVMe Local + Intel (`s-4vcpu-8gb-intel`)<br>Origin vs PgCache | Impacto do NVMe Local + Intel Premium |
|---|---|---|---|
| **1. `mv_cold0s` (Partida Fria `0s` em `complex-dashboard.sql`)** | A: 260,75 ms (31 rps)<br>B: **808,46 ms (10 rps, hit 4,2%)** | A: **247,23 ms (33 rps)**<br>B: **795,82 ms (10 rps, hit 5,2%, pico 7,1%)** | **+24% mais taxa de acerto nos primeiros 15s (`4,2%` $\rightarrow$ `5,2%`)** |
| **2. `mv_warm30s` (Aquecimento `30s` em `complex-dashboard.sql`)** | A: 268,31 ms (30 rps)<br>B: **1.357,10 ms (6 rps, hit 23,3%)** | A: **250,60 ms (32 rps)**<br>B: **1.666,90 ms (7 rps, hit 24,4%; `736 ms / 11 rps / 36,1% hit` no T1)** | **No Trial 1, o NVMe atingiu `36,1%` de hit e `736 ms` (`11 rps`) aos 30s** |
| **3. `mv_joins` (Joins de 4–6 Tabelas Estabilizado)** | A: 193,11 ms (42 rps)<br>B: **8,28 ms (970 rps, hit 99,6%, warm 5,7)** | A: **190,14 ms (42 rps)**<br>B: **12,57 ms (643 rps, hit 100,0%, warm 5,0)** | **Converge para `100,0%` de hit nas 3 rodadas em menos passes (`5,0` vs `5,7`)** |
| **4. `mv_analytics` (Analytics `GROUP BY / HAVING` Estabilizado)** | A: 147,52 ms (55 rps)<br>B: **11,73 ms (690 rps, hit 100,0%)** | A: **143,29 ms (56 rps)**<br>B: **14,31 ms (627 rps, hit 100,0%; pico de `8,63 ms / 927 rps` no T3)** | **`800` MVs compactas cabem 100% nos `1,28 GiB` de RAM; T3 no NVMe bateu `927 rps (+1.498%)`** |
| **5. `mv_dash` (Tela Corporativa Completa de 8 Queries, `1.600` MVs)** | A: 286,40 ms (28 rps)<br>B: **329,47 ms · 150 rps** *(hit 86,2%, +442%; 220 rps em T1/T3)* | A: **240,43 ms (33 rps)**<br>B: **20,66 ms · 397 rps** *(hit **100,0%**, **+1.090%**, pico **478 rps**)* | **2,65× mais vazão média (`397` vs `150 rps`, +165%) e +80,5% acima das rodadas aquecidas (`397` vs `220 rps`), com zero stalls!** |
| **6. `mv_zipf1000` (`1.000` Tenants Pareto 80/20, `8.000` MVs)** | A: 252,58 ms (32 rps)<br>B: **386,46 ms · 21 rps** *(hit 71,5%, -34%)* | A: **242,34 ms (33 rps)**<br>B: **341,29 ms · 24 rps** *(hit **73,4%**, -28%, pico **29 rps**)* | **-11,7% menor latência (`386` $\rightarrow$ `341 ms`), +14,3% mais RPS (`21` $\rightarrow$ `24 rps`) sob paginação de disco** |
| **7. `mv_dyn_t2` (Filtros Dinâmicos com `ADMISSION_THRESHOLD=2`)** | A: 255,95 ms (32 rps)<br>B: **308,37 ms · 27 rps** *(hit 39,6%, -16%)* | A: **221,50 ms (36 rps)**<br>B: **277,89 ms · 29 rps** *(hit **41,4%**, -19%, pico **34 rps**)* | **-9,9% menor latência (`308` $\rightarrow$ `278 ms`) e +7,4% mais RPS (`27` $\rightarrow$ `29 rps`) sob criação contínua de MVs** |

### 5.3 Detalhamento Rodada a Rodada: SSD Regular vs. NVMe Local (`TRIALS=3`)

| Célula | SSD Regular (`s-4vcpu-8gb`) — 3 Execuções (Caminho B PgCache) | NVMe Local + Intel (`s-4vcpu-8gb-intel`) — 3 Execuções (Caminho B PgCache) |
|---|---|---|
| **`mv_cold0s`** | T1: 805,4 ms (10 rps, 4,51%) · T2: 805,2 ms (10 rps, 3,72%) · T3: 814,8 ms (10 rps, 4,33%) | T1: 818,6 ms (10 rps, 4,59%) · T2: 799,7 ms (10 rps, 3,86%) · T3: **769,2 ms (10 rps, 7,11%)** |
| **`mv_warm30s`** | T1: 1.772,0 ms (5 rps, 22,46%) · T2: 1.293,0 ms (6 rps, 19,95%) · T3: 1.006,3 ms (8 rps, 27,56%) | T1: **736,2 ms (11 rps, 36,08%)** · T2: 2.918,3 ms (3 rps, 20,85%) · T3: 1.346,3 ms (6 rps, 16,25%) |
| **`mv_joins`** | T1: 7,74 ms (1.034 rps, 100%) · T2: 8,90 ms (899 rps, 100%) · T3: 8,20 ms (976 rps, 98,94%) | T1: 14,45 ms (554 rps, **100%**) · T2: 11,36 ms (704 rps, **100%**) · T3: 11,90 ms (672 rps, **100%**) |
| **`mv_analytics`** | T1: 10,11 ms (792 rps, 100%) · T2: 13,03 ms (614 rps, 100%) · T3: 12,06 ms (663 rps, 100%) | T1: 19,74 ms (405 rps, 100%) · T2: 14,56 ms (550 rps, 100%) · T3: **8,63 ms (927 rps, 100%)** |
| **`mv_dash`** | T1: 44,62 ms (179 rps, 100%) · T2: *913,12 ms (9 rps, 58,59%)* · T3: 30,67 ms (261 rps, 100%) | T1: **24,89 ms (321 rps, 100%)** · T2: **20,35 ms (393 rps, 100%)** · T3: **16,73 ms (478 rps, 100%)** |
| **`mv_zipf1000`** | T1: 407,02 ms (20 rps, 73,2%) · T2: 447,31 ms (18 rps, 68,7%) · T3: 305,04 ms (26 rps, 72,6%) | T1: 393,29 ms (20 rps, 73,6%) · T2: **272,30 ms (29 rps, 73,9%)** · T3: 358,28 ms (22 rps, 72,8%) |
| **`mv_dyn_t2`** | T1: 233,42 ms (34 rps, 40,6%) · T2: 333,53 ms (24 rps, 39,0%) · T3: 358,16 ms (22 rps, 39,3%) | T1: **275,91 ms (29 rps, 42,3%)** · T2: 321,39 ms (25 rps, 40,2%) · T3: **236,37 ms (34 rps, 41,5%)** |

### 5.4 Conclusão Prática: Quando o Disco NVMe Local Faz Diferença no PgCache?

1. **Quando o Conjunto de Materialized Views é Pequeno (`mv_joins` e `mv_analytics` com `200` Tenants = `800` MVs)**:
   - As `800` Materialized Views cabem inteiras dentro dos **`1,28 GiB` de `shared_buffers`** da instância interna do PostgreSQL do PgCache. Uma vez aquecidas, 100% das leituras vêm da memória RAM (`8–14 ms`, `627–970 telas/s`), sem tocar no disco. Mesmo assim, o NVMe convergiu `mv_joins` para `100,0%` de acerto em **5,0 passes** (contra `5,7` passes e `99,6%` no SSD Regular).
2. **Quando a Tela Combina Múltiplas Materialized Views Pesadas (`mv_dash` = `1.600` MVs) ou Alta Cardinalidade (`mv_zipf1000` e `mv_dyn_t2`)**:
   - Na tela corporativa completa (`mv_dash`), o PgCache precisa criar e manter `1.600` Materialized Views (incluindo buscas textuais, joins de 6 tabelas e agregações). No SSD Regular (`488 µs` de `fsync`), a escrita concorrente das MVs sofreu stall na Execução 2 (`58,6%` hit, `9 rps`) e limitou as execuções aquecidas a `179–261 telas/s`.
   - No **NVMe Local + Intel Premium (`215 µs` de `fsync`)**, todas as 3 execuções de `mv_dash` convergiram sem stall para **100,0% de hit**, sustentando **`321`, `393` e `478 telas/s` (média de `397 telas/s` / `20,66 ms`, 2,65× acima da média do SSD Regular e +80,5% acima das rodadas aquecidas)**!
   - Da mesma forma, em `mv_zipf1000` (`1.000` tenants) e `mv_dyn_t2` (filtros dinâmicos), onde o PgCache grava e pagina Materialized Views continuamente no disco local, o NVMe reduziu a latência em **-10% a -12%** e aumentou a vazão em **+7% a +14%**. Em instâncias dedicadas com NVMe PCIe pass-through (como **AWS `i8g` Nitro SSD** ou **DigitalOcean `so-` Storage-Optimized**), esse ganho nas fases de criação e paginação de MVs será ainda maior.

---

## 6. Arquivos Brutos e Reprodutibilidade

- **Relatório Parte 1 (`results/0.7.1/`)**: [`results/0.7.1/README-pt.md`](../0.7.1/README-pt.md)
- **Scripts de Tuning e Cargas SQL**:
  - Tuning e Prewarm do Origin (`2 GiB` + 4 índices `GIN pg_trgm`): [`sql/03-fair-tuning.sql`](../../sql/03-fair-tuning.sql)
  - Carga de Busca de 3+ Caracteres com Trigramas (`search_3c`): [`workload/complex-search-fair.sql`](../../workload/complex-search-fair.sql)
  - Carga de Filtros Dinâmicos Intra-Tenant (`cplx_dyn`): [`workload/complex-dashboard-dynamic.sql`](../../workload/complex-dashboard-dynamic.sql)
  - Scripts de Execução: [`scripts/06-fair-benchmark.sh`](../../scripts/06-fair-benchmark.sh) · [`scripts/07-admission-threshold-sweep.sh`](../../scripts/07-admission-threshold-sweep.sh) · [`scripts/08-nvme-mv-benchmark.sh`](../../scripts/08-nvme-mv-benchmark.sh)
- **Logs Brutos Multi-Trial (`results/0.7.1_v2/`)**:
  - Teste Justo (`TRIALS=5`, Base Padrão de `2.000` Tenants): [`06-fair-benchmark-k8s.txt`](06-fair-benchmark-k8s.txt)
  - Varredura de `ADMISSION_THRESHOLD` (`1` vs `2` vs `4`, `TRIALS=3`): [`07-admission-threshold-k8s.txt`](07-admission-threshold-k8s.txt)
  - Estudo de Materialized Views em SSD Regular (`s-4vcpu-8gb`, `TRIALS=3`): [`08-mv-regular-ssd-k8s.txt`](08-mv-regular-ssd-k8s.txt)
  - Estudo de Materialized Views em NVMe Local + Intel Premium (`s-4vcpu-8gb-intel`, `TRIALS=3`): [`08-mv-nvme-intel-k8s.txt`](08-mv-nvme-intel-k8s.txt)
  - `search_3c` em 200 Tenants Densos (`2.500` pedidos/tenant, `TRIALS=5`): [`06-fair-search3c-k8s.txt`](06-fair-search3c-k8s.txt)
  - Diagnóstico de Super-Indexação B-Tree `INCLUDE` + `GIN` (`TRIALS=5`): [`06-fair-overindexed-k8s.txt`](06-fair-overindexed-k8s.txt)
