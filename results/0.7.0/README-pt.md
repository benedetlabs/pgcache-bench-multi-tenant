# Verificação de Benchmark PgCache — Tag 0.7.0

> 🇺🇸 **[English version](README.md)**

Execução de verificação para **PgCache v0.7.0** (`pgcache/pgcache:0.7.0`) no DigitalOcean Kubernetes (DOKS) em 1, 10, 50, 100, 500, 1.000 e 2.000 tenants seguindo o protocolo do benchmark.

## 1. Resumo

- **Hit Ratio**: **100,0%** em todas as faixas de tenants (de 1 a 2.000 tenants).
- **Escala de Espaço de Chaves**: O PgCache manteve latências robustas (~15,6 ms a 18,8 ms na maioria das células), alcançando até **513 rps** (15,6 ms vs 23,3 ms na origem, ganho de +50%).
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 tenants, 3 passos (90s) para 500–1.000 tenants e 4 passos (120s) para 2.000 tenants.
- **Ganho de Vazão**: Manteve **+38% a +64% de ganho de vazão** com a expansão de tenants até 2.000 tenants.
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
| **Storage Class** | `do-block-storage` (`dobs.csi.digitalocean.com`) |
| **Distribuição de Pods** | `podAntiAffinity` estrito (1 nó exclusivo para cada: `origin`, `pgcache`, `loadgen`) |
| **Rede** | `hostNetwork: true` (roteamento IP direto do nó, eliminando NAT de overlay) |
| **Pod Origin** | PostgreSQL 17 (`postgres:17`), requests: 2500m CPU / 5Gi RAM, `shared_buffers=512MB` |
| **Pod PgCache** | PgCache 0.7.0 (`pgcache/pgcache:0.7.0`), requests: 2500m CPU / 5Gi RAM, `workers=4`, `metricsPort=9091` |
| **Pod Loadgen** | PostgreSQL 17 (`postgres:17` com pgbench), requests: 2500m CPU / 2Gi RAM |
| **Pod Metrics Reader** | Alpine 3.20 (`alpine:3.20`), requests: 50m CPU / 64Mi RAM |
| **Tamanho da Base** | 500k pedidos, 2M itens (~594 MB total), 2.000 tenants (250 pedidos/tenant) |

---

## 3. Sweep 1 — Varredura de Tenants (DigitalOcean DOKS)

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

---

## 4. Sweep 2 — Concorrência de Clientes (Linha de Base)

Separando velocidade pura do cache de leitura da saturação da origem (escala de clientes com 1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 11,5 ms · 87 rps | 5,55 ms · 180 rps | +107% | 100,0% | 2 |
| 4 | 19,5 ms · 205 rps | 9,10 ms · 439 rps | +114% | 100,0% | 2 |
| 8 | 36,5 ms · 219 rps | 14,90 ms · 537 rps | +145% | 100,0% | 2 |
| 16 | 58,9 ms · 272 rps | 25,97 ms · 616 rps | +126% | 100,0% | 2 |
| 32 | 107,8 ms · 297 rps | 51,09 ms · 626 rps | +111% | 100,0% | 2 |

---

## 5. Sweep 3 — Taxa de Escritas e Concentração (Linha de Base)

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
- Log bruto do sweep de tenants (DOKS): [`run-tenants.txt`](run-tenants.txt)
- Log bruto de concorrência: [`run-clients.txt`](run-clients.txt)
- Log bruto de escritas: [`run-writes.txt`](run-writes.txt)
