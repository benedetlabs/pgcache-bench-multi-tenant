# Verificação do PgCache Benchmark — Versão 0.6.3

> 🇺🇸 **[English version](README.md)**

Execução de verificação para o **PgCache v0.6.3** (`pgcache/pgcache:0.6.3-arm64` / `pgcache/pgcache:0.6.3`) executada no ambiente Docker local em uma escala de 1.000 tenants seguindo o protocolo do benchmark.

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100,0%** em todos os tenants (1..1.000), níveis de concorrência e proporções de escrita.
- **Linha de Base com 1 Cliente**: **2,04× mais rápido** (5,53 ms vs 11,25 ms) sem filas.
- **Ganho Máximo em Saturação**: **+140% a +142%** com 8–16 clientes e **+138%** com 32 clientes (45,02 ms vs 107,17 ms, 711 rps).
- **Resiliência a Escritas**: Manteve ganho de vazão estável de **+137% a +141%** mesmo sob 10% de escritas distribuídas em 1.000 tenants.

---

## 2. Varredura 1 — Varredura por Quantidade de Tenants

Avaliando a dispersão do espaço de chaves em 1, 10, 50, 200, 500 e 1.000 tenants ativos (concorrência fixa em 8 clientes):

| Tenants Ativos | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 33,9 ms · 236 rps | 13,42 ms · 596 rps | +153% | 100,0% | 2 |
| 10 | 32,6 ms · 246 rps | 13,57 ms · 590 rps | +140% | 100,0% | 2 |
| 50 | 33,7 ms · 237 rps | 13,84 ms · 578 rps | +144% | 100,0% | 3 |
| 200 | 34,6 ms · 231 rps | 14,05 ms · 570 rps | +147% | 100,0% | 3 |
| 500 | 34,6 ms · 231 rps | 14,22 ms · 563 rps | +144% | 100,0% | 4 |
| 1000 | 34,7 ms · 230 rps | 14,31 ms · 559 rps | +143% | 100,0% | 5 |

---

## 3. Varredura 2 — Concorrência de Clientes

Separando o ganho puro do cache da saturação da origem (1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 11,2 ms · 89 rps | 5,53 ms · 181 rps | +103% | 100,0% | 2 |
| 4 | 19,2 ms · 208 rps | 8,79 ms · 455 rps | +119% | 100,0% | 2 |
| 8 | 35,4 ms · 226 rps | 14,62 ms · 547 rps | +142% | 100,0% | 2 |
| 16 | 60,3 ms · 265 rps | 25,18 ms · 635 rps | +140% | 100,0% | 2 |
| 32 | 107,2 ms · 299 rps | 45,02 ms · 711 rps | +138% | 100,0% | 2 |

---

## 4. Varredura 3 — Taxa de Escrita e Concentração

Testando a resiliência à invalidação de cache com leitura e escrita misturadas (8 clientes, 1.000 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---|---:|---:|---:|
| 0% | 1000 | 35,1 ms · 228 rps | 14,52 ms · 551 rps | +142% | 100,0% | 2 |
| 5% | 1 | 33,5 ms · 239 rps | 13,92 ms · 575 rps | +141% | 100,0% | 2 |
| 5% | 10 | 33,3 ms · 240 rps | 14,03 ms · 570 rps | +138% | 100,0% | 2 |
| 5% | 1000 | 33,2 ms · 241 rps | 13,93 ms · 574 rps | +138% | 100,0% | 2 |
| 10% | 1 | 31,4 ms · 254 rps | 13,28 ms · 603 rps | +137% | 100,0% | 2 |
| 10% | 1000 | 31,9 ms · 251 rps | 13,27 ms · 603 rps | +140% | 100,0% | 2 |

---

## 5. Artefatos Brutos

- Dados tabulares legíveis por máquina: [`results.tsv`](results.tsv)
- Log bruto da varredura de tenants: [`run-tenants.txt`](run-tenants.txt)
- Log bruto da varredura de clientes: [`run-clients.txt`](run-clients.txt)
- Log bruto da varredura de escrita: [`run-writes.txt`](run-writes.txt)
