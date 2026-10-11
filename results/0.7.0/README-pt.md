# Verificação do PgCache Benchmark — Versão 0.7.0

> 🇺🇸 **[English version](README.md)**

Execução de verificação para o **PgCache v0.7.0** (`pgcache/pgcache:0.7.0-arm64` / `pgcache/pgcache:0.7.0`) executada no ambiente Docker local em uma escala de 1.000 tenants seguindo o protocolo do benchmark.

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100,0%** entre os tenants 1..500 e **99,7%** com 1.000 tenants (primeiro indício de expansão do espaço de chaves / evicção de entradas menos frequentes).
- **Linha de Base com 1 Cliente**: **2,06× mais rápido** (5,55 ms vs 11,45 ms) sem filas.
- **Ganho Máximo em Saturação**: **+145%** com 8 clientes (14,90 ms vs 36,48 ms, 537 rps) e **+111% a +126%** entre 16 e 32 clientes.
- **Resiliência a Escritas**: Manteve ganho de vazão de **+24% a +69%** sob escritas concorrentes em 1.000 tenants. Em Docker local em máquina única, a invalidação concorrente do CDC concorre pelos mesmos núcleos de CPU da máquina, cenário que se beneficia do isolamento em 3 nós físicos no Kubernetes.

---

## 2. Varredura 1 — Varredura por Quantidade de Tenants

Avaliando a dispersão do espaço de chaves em 1, 10, 50, 200, 500 e 1.000 tenants ativos (concorrência fixa em 8 clientes):

| Tenants Ativos | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 46,1 ms · 174 rps | 13,98 ms · 572 rps | +229% | 100,0% | 3 |
| 10 | 33,5 ms · 239 rps | 14,12 ms · 567 rps | +137% | 100,0% | 2 |
| 50 | 32,5 ms · 246 rps | 15,13 ms · 529 rps | +115% | 100,0% | 3 |
| 200 | 37,0 ms · 216 rps | 15,37 ms · 521 rps | +141% | 100,0% | 3 |
| 500 | 36,5 ms · 219 rps | 16,13 ms · 496 rps | +126% | 100,0% | 4 |
| 1000 | 36,0 ms · 222 rps | 15,70 ms · 510 rps | +130% | 99,7% | 5 |

---

## 3. Varredura 2 — Concorrência de Clientes

Separando o ganho puro do cache da saturação da origem (1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 11,5 ms · 87 rps | 5,55 ms · 180 rps | +107% | 100,0% | 2 |
| 4 | 19,5 ms · 205 rps | 9,10 ms · 439 rps | +114% | 100,0% | 2 |
| 8 | 36,5 ms · 219 rps | 14,90 ms · 537 rps | +145% | 100,0% | 2 |
| 16 | 58,9 ms · 272 rps | 25,97 ms · 616 rps | +126% | 100,0% | 2 |
| 32 | 107,8 ms · 297 rps | 51,09 ms · 626 rps | +111% | 100,0% | 2 |

---

## 4. Varredura 3 — Taxa de Escrita e Concentração

Testando a resiliência à invalidação de cache com leitura e escrita misturadas (8 clientes, 1.000 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 1000 | 35,6 ms · 225 rps | 14,91 ms · 537 rps | +139% | 100,0% | 2 |
| 5% | 1 | 32,5 ms · 246 rps | 19,60 ms · 408 rps | +66% | 100,0% | 2 |
| 5% | 10 | 31,6 ms · 253 rps | 19,43 ms · 412 rps | +63% | 100,0% | 2 |
| 5% | 1000 | 31,8 ms · 252 rps | 20,96 ms · 382 rps | +52% | 100,0% | 2 |
| 10% | 1 | 32,1 ms · 249 rps | 18,97 ms · 422 rps | +69% | 100,0% | 2 |
| 10% | 1000 | 31,2 ms · 257 rps | 25,14 ms · 318 rps | +24% | 100,0% | 2 |

---

## 5. Artefatos Brutos

- Dados tabulares legíveis por máquina: [`results.tsv`](results.tsv)
- Log bruto da varredura de tenants: [`run-tenants.txt`](run-tenants.txt)
- Log bruto da varredura de clientes: [`run-clients.txt`](run-clients.txt)
- Log bruto da varredura de escrita: [`run-writes.txt`](run-writes.txt)
