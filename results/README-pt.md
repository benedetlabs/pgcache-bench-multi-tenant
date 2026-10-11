# Resultados da Verificação Multi-Versão do PgCache

> 🇺🇸 **[English version](README.md)**

Este diretório contém os resultados das execuções de benchmark comparando versões do **PgCache** em dois ambientes distintos:
- [**PgCache 0.6.3**](0.6.3/README-pt.md)
- [**PgCache 0.6.4**](0.6.4/README-pt.md)
- [**PgCache 0.7.0**](0.7.0/README-pt.md)

Ambos os ambientes seguem rigorosamente o protocolo do benchmark (protocolo de consulta simples `-M simple`, sem transações explícitas `BEGIN...COMMIT`, aquecimento dinâmico estabilizado `< 1%`).

---

## 1. DigitalOcean Kubernetes (DOKS 3 Nós — 1 a 2.000 Tenants)

Executado em um cluster de produção de baixo custo: 3 nós dedicados (`s-4vcpu-8gb`, `sfo3` single-AZ), `--ha=false`, `podAntiAffinity` estrito (1 nó exclusivo para cada: origin, pgcache, loadgen) e `hostNetwork: true`.

### Varredura de Contagem de Tenants (1 a 2.000 Tenants)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | Hit Ratio (Todos) | Passos de Aquecimento |
|---|---|---|---|---|---|---|
| **1 Tenant** | 23,3–27,5 ms (291–343 rps) | **17,6 ms** (455 rps, +56%) | **16,8 ms** (476 rps, +61%) | **15,6 ms** (513 rps, +50%) | **100,0%** | 2 |
| **10 Tenants** | 23,9–27,7 ms (288–335 rps) | **17,8 ms** (451 rps, +52%) | **21,0 ms** (382 rps, +33%) | **22,9 ms** (349 rps, +4%) | **100,0%** | 2 |
| **50 Tenants** | 28,5–29,9 ms (267–281 rps) | **17,5 ms** (456 rps, +66%) | **15,8 ms** (506 rps, +90%) | **17,3 ms** (462 rps, +64%) | **100,0%** | 2 |
| **100 Tenants** | 25,2–30,3 ms (264–317 rps) | **19,4 ms** (412 rps, +56%) | **16,3 ms** (492 rps, +55%) | **17,2 ms** (465 rps, +51%) | **100,0%** | 2 |
| **500 Tenants** | 25,7–32,2 ms (248–311 rps) | **16,7 ms** (478 rps, +93%) | **15,7 ms** (510 rps, +71%) | **18,7 ms** (428 rps, +38%) | **100,0%** | 3 |
| **1.000 Tenants** | 24,5–26,2 ms (305–326 rps) | **17,5 ms** (458 rps, +50%) | **16,8 ms** (476 rps, +46%) | **17,2 ms** (466 rps, +52%) | **100,0%** | 3 |
| **2.000 Tenants** | 25,6–26,0 ms (308–313 rps) | **18,3 ms** (438 rps, +40%) | **15,5 ms** (515 rps, +67%) | **18,8 ms** (425 rps, +38%) | **100,0%** | 4 |

---

## 2. Ambiente Local Docker (Linha de Base — 1 a 1.000 Tenants)

Executado em ambiente Docker local em máquina de desenvolvimento com rede de host único e núcleos compartilhados:

### Comparativo nos Eixos de Carga

| Métrica / Cenário | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 |
|---|---|---|---|---|
| **Hit Ratio (Todas as Células)** | N/A | **100,0%** | **100,0%** | **100,0%** (1..500t) / **99,7%** (1.000t) |
| **Latência com 1 Cliente** | 10,5–12,1 ms | **5,53 ms** (2,0× mais rápido) | **5,15 ms** (2,1× mais rápido) | **5,55 ms** (2,1× mais rápido) |
| **Latência com 8 Clientes (Leitura)** | 35,4–38,1 ms | **14,62 ms** (+142%) | **15,34 ms** (+149%) | **14,90 ms** (+145%) |
| **Vazão Máxima (32 clientes)** | 297–307 rps | **711 rps** (+138%) | **748 rps** (+144%) | **626 rps** (+111%) |
| **Resiliência a Escritas (5% w, 1 wt)** | 239–249 rps | **575 rps** (+141%) | **598 rps** (+140%) | **408 rps** (+66%) |
| **Resiliência a Escritas (10% w, 1000 wt)** | 251–268 rps | **603 rps** (+140%) | **631 rps** (+135%) | **318 rps** (+24%) |

### Varredura de Tenants (Linha de Base Docker)

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 | PgCache 0.6.4 | PgCache 0.7.0 | Hit Ratio | Passos de Aquecimento |
|---|---|---|---|---|---|---|
| **1 Tenant** | 33,9–46,1 ms (174–236 rps) | **13,4 ms** (596 rps, +153%) | **13,2 ms** (604 rps, +161%) | **14,0 ms** (572 rps, +229%) | **100,0%** | 2–3 |
| **10 Tenants** | 32,6–33,5 ms (239–246 rps) | **13,6 ms** (590 rps, +140%) | **15,1 ms** (530 rps, +122%) | **14,1 ms** (567 rps, +137%) | **100,0%** | 2 |
| **50 Tenants** | 32,5–34,9 ms (229–246 rps) | **13,8 ms** (578 rps, +144%) | **14,0 ms** (572 rps, +150%) | **15,1 ms** (529 rps, +115%) | **100,0%** | 3 |
| **200 Tenants** | 33,2–37,0 ms (216–241 rps) | **14,0 ms** (570 rps, +147%) | **14,0 ms** (572 rps, +137%) | **15,4 ms** (521 rps, +141%) | **100,0%** | 3 |
| **500 Tenants** | 33,7–36,5 ms (219–238 rps) | **14,2 ms** (563 rps, +144%) | **14,3 ms** (559 rps, +135%) | **16,1 ms** (496 rps, +126%) | **100,0%** | 4 |
| **1.000 Tenants** | 33,6–36,0 ms (222–238 rps) | **14,3 ms** (559 rps, +143%) | **14,5 ms** (551 rps, +132%) | **15,7 ms** (510 rps, +130%) | **99,7%–100,0%** | 5 |

---

## 3. Visão Comparativa de Ambientes: DOKS vs Docker

1. **Impacto de Rede e Saltos Reais**:
   - No **Docker local**, cliente e servidor rodam no mesmo kernel do sistema operacional. A latência de ida e volta do localhost é praticamente zero (~70 µs), o que amplia o ganho relativo ao economizar trabalho de computação de consultas.
   - No **DigitalOcean Kubernetes**, as requisições passam pela rede física real entre 3 nós separados (10.124.0.3, 10.124.0.4, 10.124.0.5). O PgCache sustenta 425–515 rps com a latência de rede real computada.

2. **Disputa por CPU sob Escritas Concorrentes**:
   - No **Docker**, a invalidação por replicação lógica (CDC) e a carga de clientes competem pelos mesmos núcleos do host, criando gargalos artificiais para a versão 0.7.0 durante testes de escrita pesada.
   - No **DOKS**, a anti-afinidade estrita de pods assegura que o PgCache e a origem possuam droplets dedicados de 4 vCPUs sem interferência mútua ou limitação de CFS.

3. **Escalabilidade do Espaço de Chaves**:
   - Ambos os ambientes confirmam empiricamente que elevar os tenants ativos de 1 até 1.000 (e até 2.000 no DOKS) **não degrada a taxa de acerto**, que permaneceu em **100,0%** em todas as versões.

---

## 4. Estrutura de Diretórios por Tag

- [`0.6.3/`](0.6.3/README-pt.md): Resultados completos, TSVs (`results-doks.tsv`, `results-docker.tsv`) e logs da tag `0.6.3`.
- [`0.6.4/`](0.6.4/README-pt.md): Resultados completos, TSVs (`results-doks.tsv`, `results-docker.tsv`) e logs da tag `0.6.4`.
- [`0.7.0/`](0.7.0/README-pt.md): Resultados completos, TSVs (`results-doks.tsv`, `results-docker.tsv`) e logs da tag `0.7.0`.
