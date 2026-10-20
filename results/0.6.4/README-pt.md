# Relatório de Benchmark PgCache 0.6.4: Escalando de 1 a 2.000 Tenants em um Cluster de 3 Nós na Nuvem

> 🇺🇸 **[Read in English](README.md)**

Este relatório documenta a verificação da versão **PgCache v0.6.4** (`pgcache/pgcache:0.6.4`) no nosso cluster **DigitalOcean Kubernetes de 3 nós (DOKS)** (`3× s-4vcpu-8gb` na mesma zona), rodando o PostgreSQL 17, o PgCache e o gerador de carga em três máquinas virtuais separadas.

> **Por que mostramos apenas números do cluster de 3 nós**: O Docker Compose local é usado exclusivamente para montar o ambiente e testar a corretude do SQL; todos os números de performance vêm do cluster Kubernetes de 3 nós na nuvem.

---

## 1. Principais Conclusões

- **100,0% de Acerto no Cache até 2.000 Tenants**: Em todas as faixas de 1 a 2.000 clientes ativos, o PgCache 0.6.4 manteve 100,0% de acerto após o aquecimento.
- **Pico de Vazão em 2.000 Tenants (515 telas/s, +67%)**: No dashboard operacional de 8 consultas (`workload/dashboard.sql`), o PgCache reduziu o tempo de resposta de **24,5–29,9 ms** no PostgreSQL para **15,5–21,0 ms**, entregando **+33% a +90% mais vazão**.
- **Aquecimento Rápido**: Estabilizou em 2 ciclos (60s) para 1–100 tenants, 3 ciclos (90s) para 500–1.000 tenants e 4 ciclos (120s) para 2.000 tenants.

---

## 2. Configuração do Cluster (3 VMs Dedicadas na Nuvem)

| Componente | Configuração |
|---|---|
| **Topologia** | 3 nós físicos separados na DigitalOcean (`sfo3` single-AZ, `--ha=false`) |
| **Tamanho das VMs** | 3× `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM por máquina) |
| **Isolamento Físico** | `podAntiAffinity` estrito (1 nó exclusivo para `origin`, `pgcache` e `loadgen`) |
| **Rede** | `hostNetwork: true` (roteamento direto por IP do nó) |
| **Banco Principal** | PostgreSQL 17, `shared_buffers=512MB`, 500 mil pedidos, 2 milhões de itens (~594 MB), 2.000 tenants |
| **PgCache** | `pgcache/pgcache:0.6.4`, `NUM_WORKERS=4` |

---

## 3. Escalando de 1 até 2.000 Tenants (8 Clientes Simultâneos)

Cada requisição executa em sequência as 8 consultas SQL do arquivo `workload/dashboard.sql`:

| Tenants Ativos | PostgreSQL Direto (Caminho A) | PgCache 0.6.4 (Caminho B) | Ganho | Taxa de Acerto | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 27,1 ms · 295 telas/s | **16,8 ms · 476 telas/s** | **+61%** | 100,0% | 2 |
| **10** | 27,7 ms · 288 telas/s | **21,0 ms · 382 telas/s** | **+33%** | 100,0% | 2 |
| **50** | 29,9 ms · 267 telas/s | **15,8 ms · 506 telas/s** | **+90%** | 100,0% | 2 |
| **100** | 25,2 ms · 317 telas/s | **16,3 ms · 492 telas/s** | **+55%** | 100,0% | 2 |
| **500** | 26,9 ms · 298 telas/s | **15,7 ms · 510 telas/s** | **+71%** | 100,0% | 3 |
| **1.000** | 24,5 ms · 326 telas/s | **16,8 ms · 476 telas/s** | **+46%** | 100,0% | 3 |
| **2.000** | 26,0 ms · 308 telas/s | **15,5 ms · 515 telas/s** | **+67%** | 100,0% | 4 |

---

## 4. Arquivos Brutos

- TSV DOKS (3 Nós): [`results-doks.tsv`](results-doks.tsv)
- Log Bruto da Varredura de Tenants (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
