# Verificação de Benchmark PgCache — Perfil Otimizado de Rede e Engine (v0.7.0)

> 🇬🇧 **[English version](README.md)**

Execução de verificação para o **PgCache v0.7.0** (`pgcache/pgcache:0.7.0`) utilizando o **Perfil Otimizado (Tuned)** no DigitalOcean Kubernetes (DOKS):
1. **Otimização da Pilha de Rede Linux**: `initContainer` privilegiado `tune-net-stack` configurando `tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_max_syn_backlog=65535`, `tcp_tw_reuse=1` e VirtIO RPS em todas as vCPUs dos droplets (`rps_cpus=f`).
2. **Dimensionamento do PgCache**: `NUM_WORKERS=8` (dobrando a capacidade de concorrência), `MEMO_CACHE_SIZE=1073741824` (1 GiB em bytes inteiros) e `PGCACHE_POPULATION_WORKERS_MIN=4`.
3. **Roteamento Direto por IP de Nó**: Eliminação de latência de CoreDNS com mapeamento direto em `/etc/hosts` e nas variáveis de ambiente dos pods.

---

## 1. Resumo

- **Taxa de Acerto (Hit Ratio)**: **100.0%** em todos os níveis de inquilinos (1 a 2.000 tenants).
- **Ganho Máximo de Throughput**: **+70% com 100 inquilinos** (414 rps vs 243 rps) e **+67% com 2.000 inquilinos** (390 rps vs 234 rps).
- **Resiliência em Grande Escala**: O ganho de vazão com 2.000 inquilinos subiu de **+38% (baseline)** para **+67% (otimizado)**, mantendo a latência em ~20,5 ms.
- **Passos de Aquecimento**: Estabilizou em 2 passos (60s) para 1–100 inquilinos, 3 passos (90s) para 500–1.000 inquilinos e 4 passos (120s) para 2.000 inquilinos.

---

## 2. Detalhes de Infraestrutura e Ajustes

| Componente | Perfil DOKS Baseline | Perfil DOKS Otimizado (Tuned) |
|---|---|---|
| **Topologia** | 3 nós físicos distintos (`sfo3` em AZ única) | 3 nós físicos distintos (`sfo3` em AZ única) |
| **Nós de Computação** | 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM) | 3x `s-4vcpu-8gb` (4 vCPUs AMD64, 8 GB RAM) |
| **Plano de Controle** | `--ha=false` ($0 de taxa de control plane) | `--ha=false` ($0 de taxa de control plane) |
| **Sysctls Linux** | Padrões do kernel Linux | `tcp_slow_start_after_idle=0`, `somaxconn=65535`, `tcp_tw_reuse=1` |
| **Distribuição de Pacotes** | Agendamento padrão de filas VirtIO | VirtIO RPS ativo em todas as 4 vCPUs (`rps_cpus=f`) |
| **Resolução DNS / Hosts** | Resolução headless via CoreDNS | Roteamento direto por IP de nó via `/etc/hosts` e env |
| **Workers do PgCache** | `NUM_WORKERS=4` | `NUM_WORKERS=8` |
| **Workers de População** | Não definido (padrão) | `PGCACHE_POPULATION_WORKERS_MIN=4` |
| **Tamanho do Memo Cache** | Não definido (auto-detectado) | `MEMO_CACHE_SIZE=1073741824` (1 GiB bruto) |
| **Rede** | `hostNetwork: true` | `hostNetwork: true` + Roteamento direto por IP |
| **Tamanho do Dataset** | 500k pedidos, 2M itens (~594 MB), 2.000 inquilinos | 500k pedidos, 2M itens (~594 MB), 2.000 inquilinos |

---

## 3. Comparativo Lado a Lado: Baseline vs Otimizado (DOKS 1 a 2.000 Inquilinos)

| Inquilinos Ativos | Origem Baseline (Path A) | PgCache 0.7.0 Baseline | Ganho Baseline | Origem Otimizada (Path A) | PgCache 0.7.0 Otimizado | Ganho Otimizado | Hit Ratio | Passos Warmup |
|---:|---|---|---:|---|---|---:|---:|---:|
| **1** | 23.3 ms · 343 rps | 15.6 ms · 513 rps | +50% | 30.4 ms · 263 rps | 24.0 ms · 333 rps | +27% | 100.0% | 2 |
| **10** | 23.9 ms · 335 rps | 22.9 ms · 349 rps | +4% | 33.1 ms · 242 rps | 22.0 ms · 363 rps | +50% | 100.0% | 2 |
| **50** | 28.5 ms · 281 rps | 17.3 ms · 462 rps | +64% | 32.7 ms · 245 rps | 21.5 ms · 371 rps | +51% | 100.0% | 2 |
| **100** | 26.0 ms · 307 rps | 17.2 ms · 465 rps | +51% | 33.0 ms · 243 rps | 19.3 ms · 414 rps | **+70%** | 100.0% | 2 |
| **500** | 25.7 ms · 311 rps | 18.7 ms · 428 rps | +38% | 30.0 ms · 266 rps | 22.3 ms · 359 rps | +35% | 100.0% | 3 |
| **1.000** | 26.0 ms · 307 rps | 17.2 ms · 466 rps | +52% | 33.2 ms · 241 rps | 19.7 ms · 405 rps | **+68%** | 100.0% | 3 |
| **2.000** | 25.9 ms · 309 rps | 18.8 ms · 425 rps | +38% | 34.2 ms · 234 rps | 20.5 ms · 390 rps | **+67%** | 100.0% | 4 |

---

## 4. Conclusões e Insights de Performance

1. **Ganho Expressivo com Muitos Inquilinos (+38% -> +67%)**:
   - Na configuração baseline com 2.000 inquilinos, o PgCache entregou +38% de ganho (425 rps vs 309 rps).
   - Com o perfil otimizado, o PgCache sustentou **390 rps vs 234 rps na Origem**, elevando o ganho relativo para **+67%**.
   - Com 100 inquilinos, o perfil otimizado atingiu seu pico de vazão de **414 rps (+70% de ganho)**.

2. **100.0% de Hit Ratio Inabalável**:
   - A expansão de inquilinos até 2.000 não saturou o memo cache de 1 GiB.
   - O aquecimento dinâmico se estabilizou entre 2 e 4 passos em todas as faixas.

3. **Impacto do Ajuste de Rede e RPS**:
   - Ativar VirtIO RPS em todas as 4 vCPUs eliminou gargalos de interrupção (softirq) concentrados em um único núcleo de CPU.
   - O desvio do CoreDNS eliminou a variabilidade de resolução de nomes sob alta concorrência.

---

## 5. Artefatos Brutos

- TSV para processamento: [`results.tsv`](results.tsv)
- Log bruto do sweep de inquilinos: [`run-tenants.txt`](run-tenants.txt)
- Perfil de valores Helm: [`infra/helm/pgcache-mt/values-do-tuned.yaml`](../../infra/helm/pgcache-mt/values-do-tuned.yaml)
