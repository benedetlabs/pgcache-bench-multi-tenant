# Verificação do Benchmark PgCache — Versão 0.6.4

> 🇺🇸 **[English version](README.md)**

Execução de verificação para o **PgCache v0.6.4** (`pgcache/pgcache:0.6.4-arm64` / `pgcache/pgcache:0.6.4`) realizada em ambiente local Docker seguindo o protocolo do benchmark.

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100,0%** em todas as contagens de tenants, níveis de concorrência e proporções de escrita.
- **Linha de Base com Cliente Único**: **7,05× mais rápido** (3,02 ms vs 21,28 ms) sem qualquer enfileiramento.
- **Ganho Máximo na Saturação**: **+1177%** com 16 clientes concorrentes (12,65 ms vs 161,05 ms) e **+1153%** com 32 clientes.
- **Resiliência a Escrita**: Manteve **+744% de ganho de vazão** mesmo sob 10% de escritas distribuídas por todos os 200 tenants.

---

## 2. Varredura 1 — Varredura de Contagem de Tenants

Avaliação da expansão do espaço de consultas entre 1, 10, 50 e 200 tenants ativos (concorrência fixada em 8 clientes):

| Tenants Ativos | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 81,6 ms · 98 rps | 7,37 ms · 1.086 rps | +1008% | 100,0% | 2 |
| 10 | 79,9 ms · 100 rps | 7,25 ms · 1.104 rps | +1004% | 100,0% | 2 |
| 50 | 87,9 ms · 91 rps | 7,87 ms · 1.017 rps | +1018% | 100,0% | 3 |
| 200 | 84,9 ms · 94 rps | 7,90 ms · 1.012 rps | +977% | 100,0% | 5 |

---

## 3. Varredura 2 — Varredura de Concorrência de Clientes

Separando o ganho exclusivo de cache da saturação do banco de origem (200 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 21,3 ms · 47 rps | 3,02 ms · 331 rps | +604% | 100,0% | 2 |
| 4 | 49,2 ms · 81 rps | 4,87 ms · 822 rps | +915% | 100,0% | 2 |
| 8 | 85,7 ms · 93 rps | 7,73 ms · 1.034 rps | +1012% | 100,0% | 2 |
| 16 | 161,0 ms · 99 rps | 12,65 ms · 1.264 rps | +1177% | 100,0% | 2 |
| 32 | 317,4 ms · 101 rps | 25,28 ms · 1.266 rps | +1153% | 100,0% | 2 |

---

## 4. Varredura 3 — Proporção de Escrita e Concentração

Testando a resiliência à invalidação do cache sob leituras e escritas mistas (8 clientes, 200 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 200 | 90,8 ms · 88 rps | 7,62 ms · 1.050 rps | +1093% | 100,0% | 2 |
| 5% | 1 | 82,4 ms · 97 rps | 7,56 ms · 1.058 rps | +991% | 100,0% | 2 |
| 5% | 10 | 79,7 ms · 100 rps | 7,71 ms · 1.037 rps | +937% | 100,0% | 2 |
| 5% | 200 | 87,0 ms · 92 rps | 8,12 ms · 985 rps | +971% | 100,0% | 2 |
| 10% | 1 | 75,1 ms · 107 rps | 7,19 ms · 1.112 rps | +939% | 100,0% | 2 |
| 10% | 200 | 74,3 ms · 108 rps | 8,78 ms · 911 rps | +744% | 100,0% | 2 |

---

## 5. Artefatos Brutos

- Dados legíveis por máquina: [`results.tsv`](results.tsv)
- Log bruto da varredura de tenants: [`run-tenants.txt`](run-tenants.txt)
- Log bruto da varredura de concorrência: [`run-clients.txt`](run-clients.txt)
- Log bruto da varredura de escritas: [`run-writes.txt`](run-writes.txt)
