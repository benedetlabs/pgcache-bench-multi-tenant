# Verificação de Benchmark PgCache — Tag 0.6.3

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.6.3** (`pgcache/pgcache:0.6.3`) executada em dois ambientes complementares:
1. **DigitalOcean Kubernetes (DOKS)**: Topologia de 3 nós dedicados cobrindo de 1 a 2.000 tenants.
2. **Ambiente Local Docker**: Linha de base em host único cobrindo de 1 a 1.000 tenants, escala de concorrência e escritas concorrentes.

---

## 1. Resumo

- **Hit Ratio**: **100,0%** em todas as faixas de tenants (de 1 a 2.000 tenants no DOKS, de 1 a 1.000 no Docker).
- **Escala de Espaço de Chaves**: De 1 tenant a 2.000 tenants no DOKS, o PgCache manteve latências estáveis (~16,7 ms a 19,4 ms) contra ~25,6 ms a 32,2 ms na origem.
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 tenants, 3 passos (90s) para 500–1.000 tenants e 4 passos (120s) para 2.000 tenants no DOKS.
- **Ganho de Vazão**: Entregou **+40% a +93% de ganho de vazão** no DOKS, e **+140% a +153%** no Docker local.
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

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 27,5 ms · 291 rps | 17,6 ms · 455 rps | +56% | 100,0% | 2 |
| 10 | 27,0 ms · 296 rps | 17,8 ms · 451 rps | +52% | 100,0% | 2 |
| 50 | 29,2 ms · 274 rps | 17,5 ms · 456 rps | +66% | 100,0% | 2 |
| 100 | 30,3 ms · 264 rps | 19,4 ms · 412 rps | +56% | 100,0% | 2 |
| 500 | 32,2 ms · 248 rps | 16,7 ms · 478 rps | +93% | 100,0% | 3 |
| 1.000 | 26,2 ms · 305 rps | 17,5 ms · 458 rps | +50% | 100,0% | 3 |
| 2.000 | 25,6 ms · 313 rps | 18,3 ms · 438 rps | +40% | 100,0% | 4 |

### 3.2 Ambiente Local Docker (1 a 1.000 Tenants)

Avaliando a linha de base em host único no Docker em 1, 10, 50, 200, 500 e 1.000 tenants ativos:

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.3 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 33,9 ms · 236 rps | 13,4 ms · 596 rps | +153% | 100,0% | 2 |
| 10 | 32,6 ms · 246 rps | 13,6 ms · 590 rps | +140% | 100,0% | 2 |
| 50 | 33,7 ms · 237 rps | 13,8 ms · 578 rps | +144% | 100,0% | 3 |
| 200 | 34,6 ms · 231 rps | 14,0 ms · 570 rps | +147% | 100,0% | 3 |
| 500 | 34,6 ms · 231 rps | 14,2 ms · 563 rps | +144% | 100,0% | 4 |
| 1.000 | 34,7 ms · 230 rps | 14,3 ms · 559 rps | +143% | 100,0% | 5 |

---

## 4. Sweep 2 — Concorrência de Clientes (Linha de Base Docker)

Separando velocidade pura do cache de leitura da saturação da origem (escala de clientes com 1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 11,2 ms · 89 rps | 5,53 ms · 181 rps | +103% | 100,0% | 2 |
| 4 | 19,2 ms · 208 rps | 8,79 ms · 455 rps | +119% | 100,0% | 2 |
| 8 | 35,4 ms · 226 rps | 14,62 ms · 547 rps | +142% | 100,0% | 2 |
| 16 | 60,3 ms · 265 rps | 25,18 ms · 635 rps | +140% | 100,0% | 2 |
| 32 | 107,2 ms · 299 rps | 45,02 ms · 711 rps | +138% | 100,0% | 2 |

---

## 5. Sweep 3 — Taxa de Escritas e Concentração (Linha de Base Docker)

Testando a resiliência à invalidação de cache com carga mista (8 clientes, 1.000 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35,1 ms · 228 rps | 14,52 ms · 551 rps | +142% | 100,0% | 2 |
| 5% | 1 | 33,5 ms · 239 rps | 13,92 ms · 575 rps | +141% | 100,0% | 2 |
| 5% | 10 | 33,3 ms · 240 rps | 14,03 ms · 570 rps | +138% | 100,0% | 2 |
| 5% | 1000 | 33,2 ms · 241 rps | 13,93 ms · 574 rps | +138% | 100,0% | 2 |
| 10% | 1 | 31,4 ms · 254 rps | 13,28 ms · 603 rps | +137% | 100,0% | 2 |
| 10% | 1000 | 31,9 ms · 251 rps | 13,27 ms · 603 rps | +140% | 100,0% | 2 |

---

## 6. Artefatos Brutos

- Dados legíveis por máquina: [`results.tsv`](results.tsv)
- TSV do DigitalOcean DOKS: [`results-doks.tsv`](results-doks.tsv)
- TSV do Docker Local: [`results-docker.tsv`](results-docker.tsv)
- Log bruto do sweep de tenants (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Log bruto do sweep de tenants (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt)
- Log bruto de concorrência (Docker): [`run-clients.txt`](run-clients.txt)
- Log bruto de escritas (Docker): [`run-writes.txt`](run-writes.txt)
