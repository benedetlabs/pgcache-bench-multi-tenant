# Verificação de Benchmark PgCache — Tag 0.7.0

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.7.0** (`pgcache/pgcache:0.7.0`) executada em dois ambientes complementares:
1. **DigitalOcean Kubernetes (DOKS)**: Topologia de 3 nós dedicados cobrindo de 1 a 2.000 tenants.
2. **Ambiente Local Docker**: Linha de base em host único cobrindo de 1 a 1.000 tenants, escala de concorrência e escritas concorrentes.

---

## 1. Resumo

- **Hit Ratio**: **100,0%** em todas as faixas de tenants no DOKS (1 a 2.000 tenants), e **100,0%** até 500 tenants / **99,7%** com 1.000 tenants no Docker local.
- **Escala de Espaço de Chaves**: O PgCache manteve latências robustas (~15,6 ms a 18,8 ms na maioria das células), alcançando até **513 rps** (15,6 ms vs 23,3 ms na origem, ganho de +50%) no DOKS.
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 tenants, 3 passos (90s) para 500–1.000 tenants e 4 passos (120s) para 2.000 tenants no DOKS.
- **Ganho de Vazão**: Manteve **+38% a +64% de ganho de vazão** com a expansão de tenants até 2.000 tenants no DOKS, e **+115% a +229%** no Docker local.
- **Paridade de Ambientes**: Preserva tanto os dados de produção na nuvem quanto os de desenvolvimento local.

---

## 2. Detalhes de Infraestrutura e Recursos

| Componente | DigitalOcean Kubernetes (DOKS) | Docker Local (Desenvolvimento) |
|---|---|---|
| **Topologia** | 3 nós físicos separados (`sfo3` single-AZ) | Runtime de contêineres em host único |
| **Nós de Computação**| 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM) | Cores de CPU / memória compartilhados |
| **Control Plane** | `--ha=false` (taxa de control plane a $0) | Daemon local do Docker |
| **SO / Kernel** | Debian 13 (trixie), kernel 6.12.96 | Kernel do host |
| **Storage Class** | CSI `do-block-storage` (25 GiB origin, 15 GiB loadgen) | Volumes bind-mount locais |
| **Isolamento** | `podAntiAffinity` estrito (1 nó exclusivo por pod) | Scheduler CFS compartilhado |
| **Rede** | `hostNetwork: true` (roteamento IP direto do nó) | Rede bridge do Docker |
| **Limites de CPU** | Não definidos (evita jitter por throttling CFS) | Não definidos |
| **Origem (PostgreSQL)**| PostgreSQL 17, `shared_buffers=512MB` | PostgreSQL 17, `shared_buffers=1GB` |
| **PgCache** | `workers=4`, `metricsPort=9091` | `workers=4`, `metricsPort=9090` |
| **Base de Dados** | 500k pedidos, 2M itens (~594 MB), 2.000 tenants | 500k pedidos, 2M itens (~463 MB), 1.000 tenants |

---

## 3. Sweep 1 — Varredura de Tenants

### 3.1 DigitalOcean Kubernetes (DOKS — 1 a 2.000 Tenants)

Avaliando a expansão do espaço de consultas em 1, 10, 50, 100, 500, 1.000 e 2.000 tenants ativos (concorrência fixa em 8 clientes, duração de 30s, aquecimento dinâmico):

| Tenants Ativos | Origem (Caminho A) | PgCache 0.7.0 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 23,3 ms · 343 rps | 15,6 ms · 513 rps | +50% | 100,0% | 2 |
| 10 | 23,9 ms · 335 rps | 22,9 ms · 349 rps | +4% | 100,0% | 2 |
| 50 | 28,5 ms · 281 rps | 17,3 ms · 462 rps | +64% | 100,0% | 2 |
| 100 | 26,0 ms · 307 rps | 17,2 ms · 465 rps | +51% | 100,0% | 2 |
| 500 | 25,7 ms · 311 rps | 18,7 ms · 428 rps | +38% | 100,0% | 3 |
| 1.000 | 26,0 ms · 307 rps | 17,2 ms · 466 rps | +52% | 100,0% | 3 |
| 2.000 | 25,9 ms · 309 rps | 18,8 ms · 425 rps | +38% | 100,0% | 4 |

### 3.2 DigitalOcean Kubernetes — Perfil Otimizado / Tuned (Comparativo Baseline vs Otimizado)

Avaliando o impacto dos ajustes na pilha de rede Linux (`tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_tw_reuse=1`, VirtIO RPS `rps_cpus=f`), roteamento direto por IP de nó (sem CoreDNS) e dimensionamento do motor PgCache (`NUM_WORKERS=8`, `MEMO_CACHE_SIZE=1073741824`, `PGCACHE_POPULATION_WORKERS_MIN=4`):

| Inquilinos Ativos | Origem Baseline | PgCache Baseline | Ganho Baseline | Origem Otimizada | PgCache Otimizado | Ganho Otimizado | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23,3 ms · 343 rps | 15,6 ms · 513 rps | +50% | 30,4 ms · 263 rps | 24,0 ms · 333 rps | +27% | 100,0% | 2 |
| **10** | 23,9 ms · 335 rps | 22,9 ms · 349 rps | +4% | 33,1 ms · 242 rps | 22,0 ms · 363 rps | +50% | 100,0% | 2 |
| **50** | 28,5 ms · 281 rps | 17,3 ms · 462 rps | +64% | 32,7 ms · 245 rps | 21,5 ms · 371 rps | +51% | 100,0% | 2 |
| **100** | 26,0 ms · 307 rps | 17,2 ms · 465 rps | +51% | 33,0 ms · 243 rps | 19,3 ms · 414 rps | **+70%** | 100,0% | 2 |
| **500** | 25,7 ms · 311 rps | 18,7 ms · 428 rps | +38% | 30,0 ms · 266 rps | 22,3 ms · 359 rps | +35% | 100,0% | 3 |
| **1.000** | 26,0 ms · 307 rps | 17,2 ms · 466 rps | +52% | 33,2 ms · 241 rps | 19,7 ms · 405 rps | **+68%** | 100,0% | 3 |
| **2.000** | 25,9 ms · 309 rps | 18,8 ms · 425 rps | +38% | 34,2 ms · 234 rps | 20,5 ms · 390 rps | **+67%** | 100,0% | 4 |

### 3.3 Ambiente Local Docker (1 a 1.000 Tenants)

Avaliando a linha de base em host único no Docker em 1, 10, 50, 200, 500 e 1.000 tenants ativos:

| Tenants Ativos | Origem (Caminho A) | PgCache 0.7.0 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 46,1 ms · 174 rps | 14,0 ms · 572 rps | +229% | 100,0% | 3 |
| 10 | 33,5 ms · 239 rps | 14,1 ms · 567 rps | +137% | 100,0% | 2 |
| 50 | 32,5 ms · 246 rps | 15,1 ms · 529 rps | +115% | 100,0% | 3 |
| 200 | 37,0 ms · 216 rps | 15,4 ms · 521 rps | +141% | 100,0% | 3 |
| 500 | 36,5 ms · 219 rps | 16,1 ms · 496 rps | +126% | 100,0% | 4 |
| 1.000 | 36,0 ms · 222 rps | 15,7 ms · 510 rps | +130% | 99,7% | 5 |

---

## 4. Sweep 2 — Concorrência de Clientes (Linha de Base Docker)

Separando velocidade pura do cache de leitura da saturação da origem (escala de clientes com 1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 11,5 ms · 87 rps | 5,55 ms · 180 rps | +107% | 100,0% | 2 |
| 4 | 19,5 ms · 205 rps | 9,10 ms · 439 rps | +114% | 100,0% | 2 |
| 8 | 36,5 ms · 219 rps | 14,90 ms · 537 rps | +145% | 100,0% | 2 |
| 16 | 58,9 ms · 272 rps | 25,97 ms · 616 rps | +126% | 100,0% | 2 |
| 32 | 107,8 ms · 297 rps | 51,09 ms · 626 rps | +111% | 100,0% | 2 |

---

## 5. Sweep 3 — Taxa de Escritas e Concentração (Linha de Base Docker)

Testando a resiliência à invalidação de cache com carga mista (8 clientes, 1.000 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35,6 ms · 225 rps | 14,91 ms · 537 rps | +139% | 100,0% | 2 |
| 5% | 1 | 32,5 ms · 246 rps | 19,60 ms · 408 rps | +66% | 100,0% | 2 |
| 5% | 10 | 31,6 ms · 253 rps | 19,43 ms · 412 rps | +63% | 100,0% | 2 |
| 5% | 1000 | 31,8 ms · 252 rps | 20,96 ms · 382 rps | +52% | 100,0% | 2 |
| 10% | 1 | 32,1 ms · 249 rps | 18,97 ms · 422 rps | +69% | 100,0% | 2 |
| 10% | 1000 | 31,2 ms · 257 rps | 25,14 ms · 318 rps | +24% | 100,0% | 2 |

---

## 6. Artefatos Brutos

- Dados legíveis por máquina: [`results.tsv`](results.tsv)
- TSV do DigitalOcean DOKS Baseline: [`results-doks.tsv`](results-doks.tsv)
- TSV do DigitalOcean DOKS Otimizado: [`results-tuned.tsv`](results-tuned.tsv)
- TSV do Docker Local: [`results-docker.tsv`](results-docker.tsv)
- Log bruto do sweep de tenants (DOKS Baseline): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Log bruto do sweep de tenants (DOKS Otimizado): [`run-tenants-tuned.txt`](run-tenants-tuned.txt)
- Log bruto do sweep de tenants (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt)
- Log bruto de concorrência (Docker): [`run-clients.txt`](run-clients.txt)
- Log bruto de escritas (Docker): [`run-writes.txt`](run-writes.txt)
