# Verificação do Benchmark PgCache — Versão 0.6.3

> 🇺🇸 **[English version](README.md)**

Execução de verificação para o **PgCache v0.6.3** (`pgcache/pgcache:0.6.3-arm64` / `pgcache/pgcache:0.6.3`) realizada em ambiente local Docker seguindo o protocolo do benchmark.

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100,0%** em todas as contagens de tenants, níveis de concorrência e proporções de escrita.
- **Linha de Base com Cliente Único**: **7,37× mais rápido** (3,36 ms vs 24,77 ms) sem qualquer enfileiramento.
- **Ganho Máximo na Saturação**: **+1299%** com 32 clientes concorrentes (23,34 ms vs 327,39 ms).
- **Resiliência a Escrita**: Manteve **+706% de ganho de vazão** mesmo sob 10% de escritas distribuídas por todos os 200 tenants.

---

## 2. Varredura 1 — Varredura de Contagem de Tenants

Avaliação da expansão do espaço de consultas entre 1, 10, 50 e 200 tenants ativos (concorrência fixada em 8 clientes):

| Tenants Ativos | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 88,3 ms · 91 rps | 7,55 ms · 1.060 rps | +1065% | 100,0% | 2 |
| 10 | 83,9 ms · 95 rps | 7,86 ms · 1.017 rps | +971% | 100,0% | 2 |
| 50 | 84,5 ms · 95 rps | 8,03 ms · 997 rps | +949% | 100,0% | 2 |
| 200 | 88,5 ms · 90 rps | 8,13 ms · 984 rps | +993% | 100,0% | 2 |

---

## 3. Varredura 2 — Varredura de Concorrência de Clientes

Separando o ganho exclusivo de cache da saturação do banco de origem (200 tenants):

| Clientes | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---|---|---:|---:|---:|
| 1 | 24,8 ms · 40 rps | 3,36 ms · 298 rps | +645% | 100,0% | 2 |
| 4 | 49,2 ms · 81 rps | 4,91 ms · 814 rps | +905% | 100,0% | 2 |
| 8 | 86,7 ms · 92 rps | 7,68 ms · 1.041 rps | +1032% | 100,0% | 2 |
| 16 | 160,2 ms · 100 rps | 12,64 ms · 1.266 rps | +1166% | 100,0% | 2 |
| 32 | 327,4 ms · 98 rps | 23,34 ms · 1.371 rps | +1299% | 100,0% | 2 |

---

## 4. Varredura 3 — Proporção de Escrita e Concentração

Testando a resiliência à invalidação do cache sob leituras e escritas mistas (8 clientes, 200 tenants):

| Escritas | Tenants de Escrita | Origem (Caminho A) | PgCache (Caminho B) | Ganho | Hit Ratio | Passes de Aquecimento |
|---:|---:|---|---|---:|---:|---:|
| 0% | 200 | 84,1 ms · 95 rps | 7,69 ms · 1.040 rps | +995% | 100,0% | 2 |
| 5% | 1 | 84,3 ms · 95 rps | 7,50 ms · 1.066 rps | +1022% | 100,0% | 2 |
| 5% | 10 | 79,9 ms · 100 rps | 7,77 ms · 1.029 rps | +929% | 100,0% | 2 |
| 5% | 200 | 84,2 ms · 95 rps | 8,28 ms · 967 rps | +918% | 100,0% | 2 |
| 10% | 1 | 81,4 ms · 98 rps | 7,62 ms · 1.050 rps | +971% | 100,0% | 2 |
| 10% | 200 | 79,2 ms · 101 rps | 9,83 ms · 814 rps | +706% | 100,0% | 2 |

---

## 5. Artefatos Brutos

- Dados legíveis por máquina: [`results.tsv`](results.tsv)
- Log bruto da varredura de tenants: [`run-tenants.txt`](run-tenants.txt)
- Log bruto da varredura de concorrência: [`run-clients.txt`](run-clients.txt)
- Log bruto da varredura de escritas: [`run-writes.txt`](run-writes.txt)
