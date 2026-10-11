# Verificação de Benchmark PgCache — Tag 0.6.3

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.6.3** (`pgcache/pgcache:0.6.3`) no DigitalOcean Kubernetes (DOKS) em 1, 10, 50, 100, 500, 1.000 e 2.000 tenants seguindo o protocolo do benchmark.

## 1. Resumo

- **Hit Ratio**: **100,0%** em todas as faixas de tenants (de 1 a 2.000 tenants).
- **Escala de Espaço de Chaves**: De 1 tenant a 2.000 tenants, o PgCache manteve latências estáveis (~16,7 ms a 19,4 ms) contra ~25,6 ms a 32,2 ms na origem.
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 tenants, 3 passos (90s) para 500–1.000 tenants e 4 passos (120s) para 2.000 tenants.
- **Ganho de Vazão**: Entregou **+40% a +93% de ganho de vazão** (+56% com 100 tenants, +93% com 500 tenants, +40% com 2.000 tenants).
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
| **Pod PgCache** | PgCache 0.6.3 (`pgcache/pgcache:0.6.3`), requests: 2500m CPU / 5Gi RAM, `workers=4`, `metricsPort=9091` |
| **Pod Loadgen** | PostgreSQL 17 (`postgres:17` com pgbench), requests: 2500m CPU / 2Gi RAM |
| **Pod Metrics Reader** | Alpine 3.20 (`alpine:3.20`), requests: 50m CPU / 64Mi RAM |
| **Tamanho da Base** | 500k pedidos, 2M itens (~594 MB total), 2.000 tenants (250 pedidos/tenant) |

---

## 3. Sweep 1 — Varredura de Tenants (DigitalOcean DOKS)

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

---

## 4. Sweep 2 — Concorrência de Clientes (Linha de Base)

Separando velocidade pura do cache de leitura da saturação da origem (escala de clientes com 1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 11,2 ms · 89 rps | 5,53 ms · 181 rps | +103% | 100,0% | 2 |
| 4 | 19,2 ms · 208 rps | 8,79 ms · 455 rps | +119% | 100,0% | 2 |
| 8 | 35,4 ms · 226 rps | 14,62 ms · 547 rps | +142% | 100,0% | 2 |
| 16 | 60,3 ms · 265 rps | 25,18 ms · 635 rps | +140% | 100,0% | 2 |
| 32 | 107,2 ms · 299 rps | 45,02 ms · 711 rps | +138% | 100,0% | 2 |

---

## 5. Sweep 3 — Taxa de Escritas e Concentração (Linha de Base)

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
- Log bruto do sweep de tenants (DOKS): [`run-tenants.txt`](run-tenants.txt)
- Log bruto de concorrência: [`run-clients.txt`](run-clients.txt)
- Log bruto de escritas: [`run-writes.txt`](run-writes.txt)
