# Verificação de Benchmark PgCache — Tag 0.6.4

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.6.4** (`pgcache/pgcache:0.6.4`) executada em dois ambientes complementares:
1. **DigitalOcean Kubernetes (DOKS)**: Topologia de 3 nós dedicados cobrindo de 1 a 2.000 tenants.
2. **Ambiente Local Docker**: Linha de base em host único cobrindo de 1 a 1.000 tenants, escala de concorrência e escritas concorrentes.

---

## 1. Resumo

- **Hit Ratio**: **100,0%** em todas as faixas de tenants (de 1 a 2.000 tenants no DOKS, de 1 a 1.000 no Docker).
- **Escala de Espaço de Chaves**: De 1 tenant a 2.000 tenants no DOKS, o PgCache manteve latências entre 15,5 ms e 21,0 ms, atingindo **515 rps** com 2.000 tenants contra 308 rps na origem (+67% de ganho).
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 tenants, 3 passos (90s) para 500–1.000 tenants e 4 passos (120s) para 2.000 tenants no DOKS.
- **Ganho de Vazão**: Entregou **+33% a +90% de ganho de vazão** no DOKS, e **+122% a +161%** no Docker local.
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

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.4 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 27,1 ms · 295 rps | 16,8 ms · 476 rps | +61% | 100,0% | 2 |
| 10 | 27,7 ms · 288 rps | 21,0 ms · 382 rps | +33% | 100,0% | 2 |
| 50 | 29,9 ms · 267 rps | 15,8 ms · 506 rps | +90% | 100,0% | 2 |
| 100 | 25,2 ms · 317 rps | 16,3 ms · 492 rps | +55% | 100,0% | 2 |
| 500 | 26,9 ms · 298 rps | 15,7 ms · 510 rps | +71% | 100,0% | 3 |
| 1.000 | 24,5 ms · 326 rps | 16,8 ms · 476 rps | +46% | 100,0% | 3 |
| 2.000 | 26,0 ms · 308 rps | 15,5 ms · 515 rps | +67% | 100,0% | 4 |

### 3.2 Ambiente Local Docker (1 a 1.000 Tenants)

Avaliando a linha de base em host único no Docker em 1, 10, 50, 200, 500 e 1.000 tenants ativos:

| Tenants Ativos | Origem (Caminho A) | PgCache 0.6.4 (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 34,6 ms · 231 rps | 13,2 ms · 604 rps | +161% | 100,0% | 2 |
| 10 | 33,5 ms · 239 rps | 15,1 ms · 530 rps | +122% | 100,0% | 2 |
| 50 | 34,9 ms · 229 rps | 14,0 ms · 572 rps | +150% | 100,0% | 3 |
| 200 | 33,2 ms · 241 rps | 14,0 ms · 572 rps | +137% | 100,0% | 3 |
| 500 | 33,7 ms · 238 rps | 14,3 ms · 559 rps | +135% | 100,0% | 4 |
| 1.000 | 33,6 ms · 238 rps | 14,5 ms · 551 rps | +132% | 100,0% | 5 |

---

## 4. Sweep 2 — Concorrência de Clientes (Linha de Base Docker)

Separando velocidade pura do cache de leitura da saturação da origem (escala de clientes com 1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 10,5 ms · 95 rps | 5,15 ms · 194 rps | +104% | 100,0% | 2 |
| 4 | 18,8 ms · 213 rps | 10,51 ms · 381 rps | +79% | 100,0% | 2 |
| 8 | 38,1 ms · 210 rps | 15,34 ms · 522 rps | +149% | 100,0% | 2 |
| 16 | 61,6 ms · 260 rps | 25,54 ms · 627 rps | +141% | 100,0% | 2 |
| 32 | 104,1 ms · 307 rps | 42,81 ms · 748 rps | +144% | 100,0% | 2 |

---

## 5. Sweep 3 — Taxa de Escritas e Concentração (Linha de Base Docker)

Testando a resiliência à invalidação de cache com carga mista (8 clientes, 1.000 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 34,3 ms · 233 rps | 13,86 ms · 577 rps | +148% | 100,0% | 2 |
| 5% | 1 | 32,1 ms · 249 rps | 13,38 ms · 598 rps | +140% | 100,0% | 2 |
| 5% | 10 | 32,3 ms · 248 rps | 13,10 ms · 611 rps | +146% | 100,0% | 2 |
| 5% | 1000 | 32,7 ms · 245 rps | 13,31 ms · 601 rps | +145% | 100,0% | 2 |
| 10% | 1 | 30,1 ms · 265 rps | 12,47 ms · 642 rps | +142% | 100,0% | 2 |
| 10% | 1000 | 29,8 ms · 268 rps | 12,67 ms · 631 rps | +135% | 100,0% | 2 |

---

## 6. Artefatos Brutos

- Dados legíveis por máquina: [`results.tsv`](results.tsv)
- TSV do DigitalOcean DOKS: [`results-doks.tsv`](results-doks.tsv)
- TSV do Docker Local: [`results-docker.tsv`](results-docker.tsv)
- Log bruto do sweep de tenants (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
- Log bruto do sweep de tenants (Docker): [`run-tenants-docker.txt`](run-tenants-docker.txt)
- Log bruto de concorrência (Docker): [`run-clients.txt`](run-clients.txt)
- Log bruto de escritas (Docker): [`run-writes.txt`](run-writes.txt)
