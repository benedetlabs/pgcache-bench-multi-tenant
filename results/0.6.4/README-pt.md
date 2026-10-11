# Verificação de Benchmark PgCache — Tag 0.6.4

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.6.4** (`pgcache/pgcache:0.6.4`) no DigitalOcean Kubernetes (DOKS) em 1, 10, 50, 100, 500, 1.000 e 2.000 tenants seguindo o protocolo do benchmark.

## 1. Resumo

- **Hit Ratio**: **100,0%** em todas as faixas de tenants (de 1 a 2.000 tenants).
- **Escala de Espaço de Chaves**: De 1 tenant a 2.000 tenants, o PgCache manteve latências entre 15,5 ms e 20,9 ms, atingindo **515 rps** com 2.000 tenants contra 308 rps na origem (+67% de ganho).
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 tenants, 3 passos (90s) para 500–1.000 tenants e 4 passos (120s) para 2.000 tenants.
- **Ganho de Vazão**: Entregou consistentemente **+33% a +90% de ganho de vazão** em todas as contagens de tenants.
- **Ambiente**: Cluster DigitalOcean Kubernetes com 3 nós (`s-4vcpu-8gb`, região sfo3) com `podAntiAffinity` estrito e `hostNetwork: true`.

---

## 2. Detalhes de Infraestrutura e Recursos

| Componente | Especificação |
|---|---|
| **Provedor Cloud** | DigitalOcean Kubernetes (DOKS) |
| **Região / Topologia** | `sfo3` (single-AZ, todos os 3 nós na mesma zona) |
| **Nós do Cluster** | 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM cada) |
| **Control Plane** | `--ha=false` (custo de control plane a $0) |
| **SO do Nó / Runtime** | Debian GNU/Linux 13 (trixie), kernel 6.12.96, containerd 2.3.3 |
| **Storage Class** | `do-block-storage` (`dobs.csi.digitalocean.com`), 25 GiB (origem) e 15 GiB (gerador de carga) |
| **Distribuição de Pods** | `podAntiAffinity` estrito (1 nó exclusivo para cada: `origin`, `pgcache`, `loadgen`) |
| **Rede** | `hostNetwork: true` (roteamento IP direto do nó, eliminando NAT de overlay) |
| **Política de Limites de CPU** | Sem limites rígidos de CPU (`resources.limits.cpu` não configurado) para eliminar variações de CFS throttling |
| **Pod Origin** | PostgreSQL 17 (`postgres:17`), requests: 2500m CPU / 5Gi RAM, `shared_buffers=512MB` |
| **Pod PgCache** | PgCache 0.6.4 (`pgcache/pgcache:0.6.4`), requests: 2500m CPU / 5Gi RAM, `workers=4`, `metricsPort=9091` |
| **Pod Loadgen** | PostgreSQL 17 (`postgres:17` com pgbench), requests: 2500m CPU / 2Gi RAM |
| **Pod Metrics Reader** | Alpine 3.20 (`alpine:3.20`), requests: 50m CPU / 64Mi RAM |
| **Tamanho da Base** | 500k pedidos, 2M itens (~594 MB total), 2.000 tenants (250 pedidos/tenant) |

---

## 3. Sweep 1 — Varredura de Tenants (DigitalOcean DOKS)

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

---

## 4. Sweep 2 — Concorrência de Clientes (Linha de Base)

Separando velocidade pura do cache de leitura da saturação da origem (escala de clientes com 1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 10,55 ms · 95 rps | 5,15 ms · 194 rps | +104% | 100,0% | 2 |
| 4 | 18,78 ms · 213 rps | 10,51 ms · 381 rps | +79% | 100,0% | 2 |
| 8 | 38,10 ms · 210 rps | 15,34 ms · 522 rps | +149% | 100,0% | 2 |
| 16 | 61,58 ms · 260 rps | 25,54 ms · 627 rps | +141% | 100,0% | 2 |
| 32 | 104,07 ms · 307 rps | 42,81 ms · 748 rps | +144% | 100,0% | 2 |

---

## 5. Sweep 3 — Taxa de Escritas e Concentração (Linha de Base)

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
- Log bruto do sweep de tenants (DOKS): [`run-tenants.txt`](run-tenants.txt)
- Log bruto de concorrência: [`run-clients.txt`](run-clients.txt)
- Log bruto de escritas: [`run-writes.txt`](run-writes.txt)
