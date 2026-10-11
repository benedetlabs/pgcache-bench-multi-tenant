# Verificação do PgCache Benchmark — Versão 0.6.4

> 🇺🇸 **[English version](README.md)**

Execução de verificação para o **PgCache v0.6.4** (`pgcache/pgcache:0.6.4-arm64` / `pgcache/pgcache:0.6.4`) executada no ambiente Docker local em uma escala de 1.000 tenants seguindo o protocolo do benchmark.

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100,0%** em todos os tenants (1..1.000), níveis de concorrência e proporções de escrita.
- **Linha de Base com 1 Cliente**: **2,05× mais rápido** (5,15 ms vs 10,55 ms) sem filas.
- **Ganho Máximo em Saturação**: **+141% a +149%** com 8–16 clientes e **+144%** com 32 clientes (42,81 ms vs 104,07 ms, 748 rps).
- **Resiliência a Escritas**: Manteve ganho de vazão de **+135% a +146%** sob escritas concorrentes distribuídas em 1.000 tenants.

---

## 2. Varredura 1 — Varredura por Quantidade de Tenants

Avaliando a dispersão do espaço de chaves em 1, 10, 50, 200, 500 e 1.000 tenants ativos (concorrência fixa em 8 clientes):

| Tenants Ativos | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 34,6 ms · 231 rps | 13,24 ms · 604 rps | +161% | 100,0% | 2 |
| 10 | 33,5 ms · 239 rps | 15,09 ms · 530 rps | +122% | 100,0% | 2 |
| 50 | 34,9 ms · 229 rps | 14,00 ms · 572 rps | +150% | 100,0% | 3 |
| 200 | 33,2 ms · 241 rps | 14,00 ms · 572 rps | +137% | 100,0% | 3 |
| 500 | 33,7 ms · 238 rps | 14,31 ms · 559 rps | +135% | 100,0% | 4 |
| 1000 | 33,6 ms · 238 rps | 14,52 ms · 551 rps | +132% | 100,0% | 5 |

---

## 3. Varredura 2 — Concorrência de Clientes

Separando o ganho puro do cache da saturação da origem (1.000 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 10,5 ms · 95 rps | 5,15 ms · 194 rps | +104% | 100,0% | 2 |
| 4 | 18,8 ms · 213 rps | 10,51 ms · 381 rps | +79% | 100,0% | 2 |
| 8 | 38,1 ms · 210 rps | 15,34 ms · 522 rps | +149% | 100,0% | 2 |
| 16 | 61,6 ms · 260 rps | 25,54 ms · 627 rps | +141% | 100,0% | 2 |
| 32 | 104,1 ms · 307 rps | 42,81 ms · 748 rps | +144% | 100,0% | 2 |

---

## 4. Varredura 3 — Taxa de Escrita e Concentração

Testando a resiliência à invalidação de cache com leitura e escrita misturadas (8 clientes, 1.000 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---|---:|---:|---:|
| 0% | 1000 | 34,3 ms · 233 rps | 13,86 ms · 577 rps | +148% | 100,0% | 2 |
| 5% | 1 | 32,1 ms · 249 rps | 13,38 ms · 598 rps | +140% | 100,0% | 2 |
| 5% | 10 | 32,3 ms · 248 rps | 13,10 ms · 611 rps | +146% | 100,0% | 2 |
| 5% | 1000 | 32,7 ms · 245 rps | 13,31 ms · 601 rps | +145% | 100,0% | 2 |
| 10% | 1 | 30,1 ms · 265 rps | 12,47 ms · 642 rps | +142% | 100,0% | 2 |
| 10% | 1000 | 29,8 ms · 268 rps | 12,67 ms · 631 rps | +135% | 100,0% | 2 |

---

## 5. Artefatos Brutos

- Dados tabulares legíveis por máquina: [`results.tsv`](results.tsv)
- Log bruto da varredura de tenants: [`run-tenants.txt`](run-tenants.txt)
- Log bruto da varredura de clientes: [`run-clients.txt`](run-clients.txt)
- Log bruto da varredura de escrita: [`run-writes.txt`](run-writes.txt)
