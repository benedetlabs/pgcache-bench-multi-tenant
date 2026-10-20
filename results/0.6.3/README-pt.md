# Relatório de Benchmark PgCache 0.6.3: Escalando de 1 a 2.000 Tenants em um Cluster de 3 Nós na Nuvem

> 🇺🇸 **[Read in English](README.md)**

Este relatório documenta a verificação da versão **PgCache v0.6.3** (`pgcache/pgcache:0.6.3`) no nosso cluster **DigitalOcean Kubernetes de 3 nós (DOKS)** (`3× s-4vcpu-8gb` na mesma zona), rodando o PostgreSQL 17, o PgCache e o gerador de carga em três máquinas virtuais separadas.

> **Por que mostramos apenas números do cluster de 3 nós**: O Docker Compose local é usado exclusivamente para montar o ambiente e testar a corretude do SQL; todos os números de performance vêm do cluster Kubernetes de 3 nós na nuvem.

---

## 1. Principais Conclusões

- **100,0% de Acerto no Cache até 2.000 Tenants**: Multiplicar o número de clientes ativos de 1 para 2.000 não derrubou a taxa de acerto nem causou expulsões de memória. Depois de aquecido, o PgCache respondeu 100% das consultas direto da memória.
- **Ganho Consistente de +40% a +93%**: No dashboard operacional de 8 consultas (`workload/dashboard.sql`), o PgCache reduziu o tempo de resposta da tela de **25,6–32,2 ms** no PostgreSQL para **16,7–19,4 ms**, entregando **+40% a +93% mais telas por segundo**.
- **Aquecimento Previsível**: O cache estabilizou em 2 ciclos de aquecimento (60s) para 1–100 tenants, 3 ciclos (90s) para 500–1.000 tenants e 4 ciclos (120s) para 2.000 tenants.

---

## 2. Configuração do Cluster (3 VMs Dedicadas na Nuvem)

| Componente | Configuração |
|---|---|
| **Topologia** | 3 nós físicos separados na DigitalOcean (`sfo3` single-AZ, `--ha=false`) |
| **Tamanho das VMs** | 3× `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM por máquina) |
| **Isolamento Físico** | `podAntiAffinity` estrito (1 nó exclusivo para `origin`, `pgcache` e `loadgen`) |
| **Rede** | `hostNetwork: true` (roteamento direto por IP do nó) |
| **Banco Principal** | PostgreSQL 17, `shared_buffers=512MB`, 500 mil pedidos, 2 milhões de itens (~594 MB), 2.000 tenants |
| **PgCache** | `pgcache/pgcache:0.6.3`, `NUM_WORKERS=4` |

---

## 3. Escalando de 1 até 2.000 Tenants (8 Clientes Simultâneos)

Cada requisição executa em sequência as 8 consultas SQL do arquivo `workload/dashboard.sql`:

| Tenants Ativos | PostgreSQL Direto (Caminho A) | PgCache 0.6.3 (Caminho B) | Ganho | Taxa de Acerto | Passos de Aquecimento |
|---:|---|---|---:|---:|---:|
| **1** | 27,5 ms · 291 telas/s | **17,6 ms · 455 telas/s** | **+56%** | 100,0% | 2 |
| **10** | 27,0 ms · 296 telas/s | **17,8 ms · 451 telas/s** | **+52%** | 100,0% | 2 |
| **50** | 29,2 ms · 274 telas/s | **17,5 ms · 456 telas/s** | **+66%** | 100,0% | 2 |
| **100** | 30,3 ms · 264 telas/s | **19,4 ms · 412 telas/s** | **+56%** | 100,0% | 2 |
| **500** | 32,2 ms · 248 telas/s | **16,7 ms · 478 telas/s** | **+93%** | 100,0% | 3 |
| **1.000** | 26,2 ms · 305 telas/s | **17,5 ms · 458 telas/s** | **+50%** | 100,0% | 3 |
| **2.000** | 25,6 ms · 313 telas/s | **18,3 ms · 438 telas/s** | **+40%** | 100,0% | 4 |

---

## 4. Arquivos Brutos

- TSV DOKS (3 Nós): [`results-doks.tsv`](results-doks.tsv)
- Log Bruto da Varredura de Tenants (DOKS): [`run-tenants-doks.txt`](run-tenants-doks.txt)
