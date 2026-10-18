# Resultados da Verificação Multi-Versão do PgCache

> 🇺🇸 **[English version](README.md)**

Este diretório contém os resultados das execuções de benchmark comparando versões do **PgCache** em dois ambientes distintos e dois níveis de complexidade de carga:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)
- [**PgCache 0.7.1 (Baseline + Cenários Complexos Multi-Tenant)**](0.7.1/README-pt.md)
- [**Perfil Otimizado / Tuned (v0.7.0)**](tuned/README-pt.md)

Ambos os ambientes seguem rigorosamente o protocolo do benchmark (protocolo de consulta simples `-M simple`, sem transações explícitas `BEGIN...COMMIT`, aquecimento dinâmico estabilizado `< 1%` e `pgcache_queries_uncacheable == 0`).

---

## 1. DigitalOcean Kubernetes (DOKS 3 Nós — 1 a 2.000 Tenants)

Executado em um cluster de produção de baixo custo: 3 nós dedicados (`s-4vcpu-8gb`, `sfo3` single-AZ), `--ha=false`, `podAntiAffinity` estrito (1 nó exclusivo para cada: origin, pgcache, loadgen) e `hostNetwork: true`.

### 1.1 Varredura Multi-Versão Baseline (1 a 2.000 Tenants)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | Hit Ratio (Todos) | Passos de Aquecimento |
|---|---|---|---|---|---|---|
| **1 Tenant** | 23,3–27,5 ms (291–343 rps) | **17,6 ms** (455 rps, +56%) | **16,8 ms** (476 rps, +61%) | **15,6 ms** (513 rps, +50%) | **100,0%** | 2 |
| **10 Tenants** | 23,9–27,7 ms (288–335 rps) | **17,8 ms** (451 rps, +52%) | **21,0 ms** (382 rps, +33%) | **22,9 ms** (349 rps, +4%) | **100,0%** | 2 |
| **50 Tenants** | 28,5–29,9 ms (267–281 rps) | **17,5 ms** (456 rps, +66%) | **15,8 ms** (506 rps, +90%) | **17,3 ms** (462 rps, +64%) | **100,0%** | 2 |
| **100 Tenants** | 25,2–30,3 ms (264–317 rps) | **19,4 ms** (412 rps, +56%) | **16,3 ms** (492 rps, +55%) | **17,2 ms** (465 rps, +51%) | **100,0%** | 2 |
| **500 Tenants** | 25,7–32,2 ms (248–311 rps) | **16,7 ms** (478 rps, +93%) | **15,7 ms** (510 rps, +71%) | **18,7 ms** (428 rps, +38%) | **100,0%** | 3 |
| **1.000 Tenants** | 24,5–26,2 ms (305–326 rps) | **17,5 ms** (458 rps, +50%) | **16,8 ms** (476 rps, +46%) | **17,2 ms** (466 rps, +52%) | **100,0%** | 3 |
| **2.000 Tenants** | 25,6–26,0 ms (308–313 rps) | **18,3 ms** (438 rps, +40%) | **15,5 ms** (515 rps, +67%) | **18,8 ms** (425 rps, +38%) | **100,0%** | 4 |

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

## 2. Ambiente Local Docker (Linha de Base — 1 a 1.000 Tenants)

Executado em ambiente Docker local em máquina de desenvolvimento com rede de host único e núcleos compartilhados:

### Comparativo nos Eixos de Carga (`workload/dashboard.sql`)

| Métrica / Cenário | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 |
|---|---|---|---|---|---|
| **Hit Ratio (Todas as Células)** | N/A | **100,0%** | **100,0%** | **100,0%** (1..500t) / **99,7%** (1.000t) | **100,0%** (1..500t) / **99,9%** (1.000t) |
| **Latência com 1 Cliente** | 10,5–13,3 ms | **5,53 ms** (2,0× mais rápido) | **5,15 ms** (2,1× mais rápido) | **5,55 ms** (2,1× mais rápido) | **6,89 ms** (1,9× mais rápido) |
| **Latência com 8 Clientes (Leitura)** | 35,4–40,1 ms | **14,62 ms** (+142%) | **15,34 ms** (+149%) | **14,90 ms** (+145%) | **16,75 ms** (+131%) |
| **Vazão Máxima (32 clientes)** | 249–307 rps | **711 rps** (+138%) | **748 rps** (+144%) | **626 rps** (+111%) | **593 rps** (+138%) |
| **Resiliência a Escritas (5% w, 1 wt)** | 217–249 rps | **575 rps** (+141%) | **598 rps** (+140%) | **408 rps** (+66%) | **456 rps** (+110%) |
| **Resiliência a Escritas (10% w, 1000 wt)** | 220–268 rps | **603 rps** (+140%) | **631 rps** (+135%) | **318 rps** (+24%) | **308 rps** (+40%) |

### Varredura de Tenants (Linha de Base Docker)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | PgCache 0.7.1 | Hit Ratio | Passos de Aquecimento |
|---|---|---|---|---|---|---|---|
| **1 Tenant** | 33,9–46,1 ms (174–236 rps) | **13,4 ms** (596 rps, +153%) | **13,2 ms** (604 rps, +161%) | **14,0 ms** (572 rps, +229%) | **15,6 ms** (514 rps, +138%) | **100,0%** | 2–3 |
| **10 Tenants** | 32,6–36,1 ms (222–246 rps) | **13,6 ms** (590 rps, +140%) | **15,1 ms** (530 rps, +122%) | **14,1 ms** (567 rps, +137%) | **16,1 ms** (496 rps, +123%) | **100,0%** | 2 |
| **50 Tenants** | 32,5–37,2 ms (215–246 rps) | **13,8 ms** (578 rps, +144%) | **14,0 ms** (572 rps, +150%) | **15,1 ms** (529 rps, +115%) | **17,2 ms** (465 rps, +116%) | **100,0%** | 3 |
| **200 Tenants** | 33,2–40,1 ms (199–241 rps) | **14,0 ms** (570 rps, +147%) | **14,0 ms** (572 rps, +137%) | **15,4 ms** (521 rps, +141%) | **16,9 ms** (475 rps, +139%) | **100,0%** | 3 |
| **500 Tenants** | 33,7–40,5 ms (198–238 rps) | **14,2 ms** (563 rps, +144%) | **14,3 ms** (559 rps, +135%) | **16,1 ms** (496 rps, +126%) | **17,8 ms** (450 rps, +127%) | **100,0%** | 4 |
| **1.000 Tenants** | 33,6–40,9 ms (196–238 rps) | **14,3 ms** (559 rps, +143%) | **14,5 ms** (551 rps, +132%) | **15,7 ms** (510 rps, +130%) | **17,7 ms** (451 rps, +130%) | **99,7%–100,0%** | 5 |

---

## 3. Cenários Complexos Multi-Tenant (PgCache 0.7.1 — Aceleração via Materialized Views)

No **PgCache 0.7.1**, expandimos o benchmark além de consultas operacionais leves (`workload/dashboard.sql`) para quatro **cargas corporativas SaaS complexas** (`scripts/04-complex-sweep.sh`) e aplicamos um rigoroso **Gate Diferencial de Correção, Cacheabilidade e Admissão de MVs** (`scripts/verify-correctness.sh`):
- **12/12 consultas complexas** verificadas byte a byte idênticas entre Origem e PgCache em 3 passes (`verify-correctness.txt`).
- **100% de cacheabilidade** (`pgcache_queries_uncacheable == 0`), **100% de admissão no Gate de Materialized Views** (`pgcache_cache_mv_gate{outcome="admit"} == 12/12`, `reject == 0`) e **100% de hit em MVs no Passe 3** (delta de `pgcache_cache_mv_hits == 12/12`).

### 3.1 Comparativo por Complexidade de Carga (`TENANTS=200`, `CLIENTS=8`)

| Cenário | Carga SQL | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---|---|---|---|---:|---:|---:|---:|
| **`dash_base`** | [`dashboard.sql`](../workload/dashboard.sql) (8 consultas operacionais simples) | 37,61 ms · 213 rps | **16,05 ms · 498 rps** | **+134%** | **2,3×** | 100,0% | 3 |
| **`search`** | [`complex-search.sql`](../workload/complex-search.sql) (4 buscas textuais `ILIKE '%...%'` + `JOIN`/`LEFT JOIN`) | 88,67 ms · 90 rps | **1,53 ms · 5.223 rps** | **+5.703%** | **58,0×** | 100,0% | 4 |
| **`joins`** | [`complex-joins.sql`](../workload/complex-joins.sql) (4 cadeias profundas de 4 a 6 tabelas com `JOIN` e `LEFT JOIN`) | 121,46 ms · 66 rps | **1,25 ms · 6.426 rps** | **+9.636%** | **97,4×** | 100,0% | 5 |
| **`analytics`** | [`complex-analytics.sql`](../workload/complex-analytics.sql) (4 agregações `GROUP BY` + `FILTER` + `CASE` + `HAVING`) | 92,31 ms · 87 rps | **1,39 ms · 5.737 rps** | **+6.494%** | **65,9×** | 100,0% | 5 |
| **`cplx_dash`** | [`complex-dashboard.sql`](../workload/complex-dashboard.sql) (Tela unificada com 8 statements analíticos e de busca) | 209,62 ms · 38 rps | **2,86 ms · 2.798 rps** | **+7.263%** | **73,6×** | 100,0% | 6 |

### 3.2 Escala de Concorrência em `complex-dashboard.sql` (`TENANTS=200`)

| Clientes | Origem (Caminho A) | PgCache 0.7.1 (Caminho B) | Ganho | Aceleração | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---:|---:|---:|
| **1** | 84,83 ms · 12 rps | **1,73 ms · 578 rps** | **+4.717%** | **48,2×** | 100,0% | 2 |
| **4** | 92,22 ms · 43 rps | **2,26 ms · 1.770 rps** | **+4.016%** | **41,2×** | 100,0% | 2 |
| **8** | 194,69 ms · 41 rps | **2,66 ms · 3.003 rps** | **+7.224%** | **73,2×** | 100,0% | 2 |
| **16** | 400,89 ms · 40 rps | **4,60 ms · 3.475 rps** | **+8.588%** | **86,9×** | 100,0% | 2 |
| **32** | 862,44 ms · 37 rps | **9,20 ms · 3.478 rps** | **+9.300%** | **94,0×** | 100,0% | 2 |

Para a análise completa de escala de tenants (`+6.985%` em 200 tenants, `+211%` em 500 tenants) e resiliência a escritas mistas (`+8%` a `+30%` sob 5%–10% de escritas), consulte [`results/0.7.1/README-pt.md`](0.7.1/README-pt.md).

---

## 4. Visão Comparativa de Ambientes: DOKS vs Docker

### 4.1 Por que o Ganho de Vazão foi Maior no Docker (+140% a +160%) do que no DOKS (+40% a +93%)

Uma dúvida frequente ao comparar os números do Docker local com os do Kubernetes em nuvem (DOKS) é a diferença no percentual de aceleração relativa:

$$\text{Ganho relativo no Docker: } \mathbf{+140\%\text{ a }+161\%} \quad \text{vs} \quad \text{Ganho relativo no DOKS: } \mathbf{+40\%\text{ a }+93\%}$$

Essa divergência decorre de quatro fatores estruturais, de hardware e de arquitetura:

1. **O Multiplicador de Rede de 8 Consultas Sequenciais e a Lei de Amdahl**:
   - A requisição sob teste (`dashboard.sql`) é composta por **8 consultas SQL sequenciais** executadas sob o protocolo de consulta simples (`-M simple`), sem blocos de transação `BEGIN...COMMIT`.
   - Cada instrução exige seu próprio round-trip de rede (Envio de Query → Resposta / `ReadyForQuery`). Logo, cada transação realiza **8 idas e vindas de rede consecutivas**.
   - No **Docker local**, todos os contêineres se comunicam por loopback/bridge dentro do mesmo kernel do sistema operacional. O tempo de ida e volta (RTT) é virtualmente zero (~50 a 80 µs). O overhead total de rede por transação é de `< 0,6 ms`. A computação pura de consultas na CPU domina ~98% do tempo medido.
   - No **DigitalOcean (DOKS em 3 nós físicos distintos)**, a latência de rede entre VMs (`sfo3`) gira em torno de **~0,6 a 0,8 ms por RTT**. Para 8 consultas sequenciais, isso introduz um **piso irredutível de rede de $8 \times 0,7\text{ ms} \approx 5,6\text{ ms}$** por transação.
   - Esse piso de 5,6 ms é pago **tanto pelo Caminho A (Origem) quanto pelo Caminho B (PgCache)**. Pela Lei de Amdahl, adicionar uma constante fixa de rede $C \approx 5,6\text{ ms}$ a ambos os caminhos comprime matematicamente o ganho relativo percentual:
     $$\text{Docker: } \frac{34,0\text{ ms}}{13,5\text{ ms}} \approx 2,52\times \ (+152\%)$$
     $$\text{DOKS: } \frac{20,0 + 5,6\text{ ms}}{10,5 + 5,6\text{ ms}} = \frac{25,6\text{ ms}}{16,1\text{ ms}} \approx 1,59\times \ (+59\%)$$

2. **Desempenho da Linha de Base da Origem (PostgreSQL)**:
   - No **Docker**, o PostgreSQL, o PgCache e o gerador de carga pgbench (8 a 32 workers) disputavam os mesmos núcleos de CPU, caches L3 e barramento de memória da máquina host. Sob essa concorrência, a latência da Origem foi inflacionada para **33 a 40 ms (196 a 246 rps)**.
   - No **DOKS**, a anti-afinidade estrita de pods garantiu à Origem um droplet dedicado de 4 vCPUs sem limitação de CFS e sem processos concorrentes. O PostgreSQL atingiu uma linha de base significativamente melhor: **23 a 27 ms (291 a 343 rps)** — cerca de ~40% mais rápida. Uma origem mais rápida estreita naturalmente o percentual relativo de ganho do cache.

3. **Frequência de CPU e IPC de Núcleo Único**:
   - Estações de trabalho locais modernas utilizam processadores de alto IPC (ex: Apple Silicon ou CPUs desktop modernas a 3,5–4,5 GHz). O proxy assíncrono em Rust do PgCache opera com latência mínima nesses núcleos.
   - Os droplets padrão da DOKS (`s-4vcpu-8gb`) operam com núcleos compartilhados AMD EPYC a ~2,0–2,5 GHz com overhead de virtualização KVM, resultando em um tempo ligeiramente maior de parsing e manipulação de conexões.

4. **Implicações da Topologia: Proxy Centralizado vs Sidecar no Nó**:
   - Este benchmark avaliou rigorosamente a topologia de **Proxy Centralizado** (3 nós físicos separados: Nó 1 = Loadgen, Nó 2 = PgCache, Nó 3 = Origem), forçando todo o tráfego a atravessar a rede física do cluster.
   - Se o PgCache for implantado em produção como **Sidecar** (no mesmo pod da aplicação) ou como **DaemonSet** (proxy local em cada nó):
     - As 8 consultas da aplicação chegam ao PgCache via `localhost` ou Unix Domain Socket (`< 0,05 ms` de RTT).
     - Os acertos de cache (hits) nunca cruzam a rede física, eliminando totalmente o piso de rede de 5,6 ms.
     - Sob essa topologia descentralizada (sidecar/local), os ganhos de aceleração na nuvem voltam a se aproximar ou superar os ~2,5× (+150%) vistos no Docker.

### 4.2 Principais Conclusões de Ambiente

1. **Escalabilidade do Espaço de Chaves**:
   - Escalar os tenants ativos de 1 até 1.000 (e até 2.000 no DOKS) **não degrada a taxa de acerto do cache**, mantendo-se em **99,9%–100,0%** em todas as versões testadas no dashboard baseline.
2. **Validade para Produção**:
   - O Docker superestima o ganho relativo percentual devido à ausência de latência de rede. O DOKS entrega a medição fidedigna e autoritativa para topologias reais de nuvem.

---

## 5. Estrutura de Diretórios por Tag

- [`0.6.3/`](0.6.3/README-pt.md): Resultados completos, TSVs (`results-doks.tsv`, `results-docker.tsv`) e logs da tag `0.6.3`.
- [`0.6.4/`](0.6.4/README-pt.md): Resultados completos, TSVs (`results-doks.tsv`, `results-docker.tsv`) e logs da tag `0.6.4`.
- [`0.7.0/`](0.7.0/README-pt.md): Resultados completos, TSVs (`results-doks.tsv`, `results-docker.tsv`) e logs da tag `0.7.0`.
- [`0.7.1/`](0.7.1/README-pt.md): Resultados completos, TSVs (`results.tsv`, `results-docker.tsv`, `results-complex.tsv`), gate diferencial de correção (`verify-correctness.txt`) e logs dos cenários complexos da tag `0.7.1`.
- [`tuned/`](tuned/README-pt.md): Resultados completos, TSVs (`results.tsv`) e logs do Perfil Otimizado / Tuned (`0.7.0` com ajustes de rede e engine).
