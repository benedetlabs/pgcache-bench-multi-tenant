# Verificação do Benchmark PgCache — Versão 0.7.0

> 🇺🇸 **[English version](README.md)**

Execução de verificação para o **PgCache v0.7.0** (`pgcache/pgcache:0.7.0-arm64` / `pgcache/pgcache:0.7.0`) realizada em ambiente local Docker seguindo o protocolo do benchmark.

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100,0%** em todas as contagens de tenants, níveis de concorrência e proporções de escrita.
- **Linha de Base com Cliente Único**: **5,20× mais rápido** (4,00 ms vs 20,78 ms) sem qualquer enfileiramento.
- **Ganho Máximo na Saturação**: **+896%** com 16 clientes concorrentes (15,30 ms vs 152,81 ms) e **+869%** com 32 clientes (30,85 ms vs 300,46 ms, 1.037 rps).
- **Resiliência a Escrita**: Manteve ganhos de vazão entre **+83% e +401%** sob escritas concorrentes. Em ambientes locais Docker com host compartilhado, a invalidação concorrente via CDC compete pelos mesmos núcleos de CPU locais com maior intensidade do que nas versões anteriores, o que se beneficiará do isolamento de 3 nós físicos no Kubernetes.

---

## 2. Varredura 1 — Varredura de Contagem de Tenants

Avaliação da expansão do espaço de consultas entre 1, 10, 50 e 200 tenants ativos (concorrência fixada em 8 clientes):

| Tenants Ativos | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 85,6 ms · 93 rps | 9,23 ms · 867 rps | +832% | 100,0% | 2 |
| 10 | 87,3 ms · 92 rps | 8,83 ms · 906 rps | +885% | 100,0% | 2 |
| 50 | 81,6 ms · 98 rps | 9,29 ms · 861 rps | +779% | 100,0% | 3 |
| 200 | 93,7 ms · 85 rps | 10,00 ms · 800 rps | +841% | 100,0% | 4 |

---

## 3. Varredura 2 — Varredura de Concorrência de Clientes

Separando o ganho exclusivo de cache da saturação do banco de origem (200 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 20,8 ms · 48 rps | 4,00 ms · 250 rps | +421% | 100,0% | 2 |
| 4 | 46,1 ms · 87 rps | 5,94 ms · 674 rps | +675% | 100,0% | 2 |
| 8 | 80,8 ms · 99 rps | 8,84 ms · 905 rps | +814% | 100,0% | 2 |
| 16 | 152,8 ms · 105 rps | 15,30 ms · 1.046 rps | +896% | 100,0% | 2 |
| 32 | 300,5 ms · 107 rps | 30,85 ms · 1.037 rps | +869% | 100,0% | 2 |

---

## 4. Varredura 3 — Proporção de Escrita e Concentração

Testando a resiliência à invalidação do cache sob leituras e escritas mistas (8 clientes, 200 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 200 | 83,2 ms · 96 rps | 8,90 ms · 899 rps | +836% | 100,0% | 2 |
| 5% | 1 | 78,0 ms · 103 rps | 15,49 ms · 516 rps | +401% | 100,0% | 2 |
| 5% | 10 | 76,3 ms · 105 rps | 33,33 ms · 240 rps | +129% | 100,0% | 2 |
| 5% | 200 | 80,6 ms · 99 rps | 35,99 ms · 222 rps | +124% | 100,0% | 2 |
| 10% | 1 | 73,7 ms · 108 rps | 21,53 ms · 372 rps | +244% | 100,0% | 2 |
| 10% | 200 | 73,8 ms · 108 rps | 40,37 ms · 198 rps | +83% | 100,0% | 2 |

---

## 5. Artefatos Brutos

- Dados legíveis por máquina: [`results.tsv`](results.tsv)
- Log bruto da varredura de tenants: [`run-tenants.txt`](run-tenants.txt)
- Log bruto da varredura de concorrência: [`run-clients.txt`](run-clients.txt)
- Log bruto da varredura de escritas: [`run-writes.txt`](run-writes.txt)
